"""``portico-gateway doctor``: one line per check, every failure says what and why.

The checks read the machine, the state directory and the config file;
nothing here starts a gateway or talks to a model. A failing check names
the thing in plain words ("a provider credential") — never a provider, a
key, or a deployment.
"""

from __future__ import annotations

import importlib.metadata
import os
import re
from collections.abc import MutableMapping
import shutil
import socket
import stat
import sys
import tomllib
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from .config import EMPTY_SETTING_SOURCES_MESSAGE, ConfigError, load_config
from .state import StateDir

MIN_PYTHON = (3, 13)
MIN_SDK = (0, 2, 174)
SDK_DIST = "claude-agent-sdk"

# How the engine learns its credential, from the environment only. The
# exact variables are the engine's: a direct API credential, a login token
# (what the engine's own ``setup-token`` issues), or a switch that routes
# to a third-party provider (whose own variables then apply). A login kept
# in the keychain is not visible here and is not checked.
CREDENTIAL_VARS: tuple[str, ...] = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN")
CREDENTIAL_PREFIXES: tuple[str, ...] = ("CLAUDE_CODE_USE_",)

ENV_FILE = "env"
STALE_LEDGER = "stale ledger, will be rewritten"

# One line of the env file: ``KEY=value``, optionally ``export``ed. The value is a
# literal string: bare (no blanks or quotes), single-quoted (no escapes), or
# double-quoted (``\\`` and ``\"`` only). A comment needs a blank before its ``#``.
# Nothing is expanded: no ``$``, no backticks, no shell at all. The file is read by
# this module and never sourced, so the rule here is the only rule.
_ENV_LINE = re.compile(
    r"^[ \t]*(?:export[ \t]+)?(?P<key>[A-Za-z_][A-Za-z0-9_]*)="
    r"(?P<value>'[^']*'|\"(?:[^\"\\]|\\[\\\"])*\"|[^ \t'\"]*)"
    r"(?:[ \t]+#.*)?[ \t]*$",
    re.ASCII,
)
_CONTROL_CHAR = re.compile(r"[\x00-\x08\x0b-\x1f\x7f\x85\u2028\u2029]")


class EnvFileError(ValueError):
    """The env file has lines that are not ``KEY=value``; ``lines`` holds their 1-based numbers."""

    def __init__(self, lines: list[int]) -> None:
        super().__init__(f"line(s) {' '.join(str(n) for n in lines[:3])} are not KEY=value")
        self.lines = lines


def parse_env_file(path: Path) -> dict[str, str]:
    """The ``KEY=value`` pairs of ``path``, values literal. Raises EnvFileError naming bad lines by number.

    Split on ``\\n`` only and read as bytes, so a stray ``\\r`` or form feed is a bad
    line rather than a second line. A bad line's content is never part of the
    error: it may hold a credential.
    """
    raw_lines = path.read_bytes().split(b"\n")
    if raw_lines and raw_lines[-1] == b"":
        raw_lines.pop()
    pairs: dict[str, str] = {}
    bad: list[int] = []
    for number, raw_line in enumerate(raw_lines, start=1):
        try:
            line = raw_line.decode("utf-8")  # strict: a mangled credential must be a bad line, not a loaded one
        except UnicodeDecodeError:
            bad.append(number)
            continue
        stripped = line.strip(" \t")
        if not stripped or stripped.startswith("#"):
            continue
        m = None if _CONTROL_CHAR.search(line) else _ENV_LINE.match(line)
        if m is None:
            bad.append(number)
            continue
        raw = m.group("value")
        if raw.startswith("'"):
            value = raw[1:-1]
        elif raw.startswith('"'):
            value = raw[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        else:
            value = raw
        pairs[m.group("key")] = value
    if bad:
        raise EnvFileError(bad)
    return pairs


def env_file_bad_lines(path: Path) -> list[int]:
    """1-based numbers of the lines in ``path`` that are not ``KEY=value`` lines; [] when all are."""
    try:
        parse_env_file(path)
    except EnvFileError as e:
        return e.lines
    return []


def apply_env_file(path: Path, environ: MutableMapping[str, str]) -> list[str]:
    """Load ``path`` into ``environ`` without overriding variables already set; returns the keys set.

    A missing file sets nothing. A malformed file sets nothing and raises
    EnvFileError, so a partial load can never happen.
    """
    if not path.is_file():
        return []
    pairs = parse_env_file(path)
    applied: list[str] = []
    for key, value in pairs.items():
        if key not in environ:
            environ[key] = value
            applied.append(key)
    return applied


@dataclass(frozen=True)
class Check:
    """One check: its short name, whether it passed, and one line saying why."""

    name: str
    ok: bool
    line: str


def format_check(check: Check) -> str:
    return f"{'ok  ' if check.ok else 'FAIL'} {check.name}: {check.line}"


# --- helpers -------------------------------------------------------------------


def has_credential(env: Mapping[str, str]) -> bool:
    """Whether the environment carries a provider credential the engine will pick up."""
    for name, value in env.items():
        if not value:
            continue
        if name in CREDENTIAL_VARS or any(name.startswith(p) for p in CREDENTIAL_PREFIXES):
            return True
    return False


def _version_tuple(text: str) -> tuple[int, ...]:
    parts: list[int] = []
    for piece in text.split("."):
        digits = ""
        for ch in piece:
            if not ch.isdigit():
                break
            digits += ch
        if not digits:
            break
        parts.append(int(digits))
    return tuple(parts)


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _port_listening(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except OSError:
        return False


def _mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def _one_line(text: str) -> str:
    return " ".join(text.split())


# --- the checks ----------------------------------------------------------------


def check_python() -> Check:
    have = sys.version_info[:3]
    want = ".".join(str(n) for n in MIN_PYTHON)
    got = ".".join(str(n) for n in have)
    if have[:2] >= MIN_PYTHON:
        return Check("python", True, f"{got} ({sys.executable})")
    return Check("python", False, f"{got} is too old; the gateway needs {want} or newer")


def check_sdk() -> Check:
    try:
        version = importlib.metadata.version(SDK_DIST)
    except importlib.metadata.PackageNotFoundError:
        return Check("sdk", False, f"{SDK_DIST} is not installed in this environment; run bin/install")
    try:
        import claude_agent_sdk  # noqa: F401
    except Exception as e:  # pragma: no cover - import failures are environment-specific
        return Check("sdk", False, f"{SDK_DIST} {version} is installed but does not import: {_one_line(str(e))}")
    want = ".".join(str(n) for n in MIN_SDK)
    if _version_tuple(version) >= MIN_SDK:
        return Check("sdk", True, f"{SDK_DIST} {version}")
    return Check("sdk", False, f"{SDK_DIST} {version} is older than {want}; run bin/update")


def check_credential(env: Mapping[str, str] | None = None) -> Check:
    env = os.environ if env is None else env
    if has_credential(env):
        return Check("credential", True, "a provider credential is present in the environment")
    return Check(
        "credential",
        False,
        "no provider credential in the environment; put it in the shell or in the state directory's env file",
    )


def check_config(config_path: Path) -> Check:
    if not config_path.exists():
        return Check("config", True, f"{config_path} absent, using defaults")
    try:
        load_config(config_path)
    except ConfigError as e:
        return Check("config", False, _one_line(str(e)))
    return Check("config", True, f"{config_path} loads")


def check_setting_sources(config_path: Path) -> Check:
    """Read the raw key so an empty list is reported in the exact words, independent of the config check."""
    if not config_path.exists():
        return Check("setting_sources", True, "default [project]")
    try:
        data = tomllib.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as e:
        return Check("setting_sources", False, f"{config_path} could not be read: {_one_line(str(e))}")
    if "setting_sources" not in data:
        return Check("setting_sources", True, "default [project]")
    value = data["setting_sources"]
    if isinstance(value, list) and not value:
        return Check("setting_sources", False, f"{config_path}: {EMPTY_SETTING_SOURCES_MESSAGE}")
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        return Check("setting_sources", False, f"{config_path}: setting_sources must be a list of strings")
    return Check("setting_sources", True, "[" + ", ".join(value) + "]")


def check_token(state: StateDir) -> Check:
    path = state.token_path
    if not path.exists():
        return Check("token", True, "no token file yet (written at launch)")
    mode = _mode(path)
    if mode != 0o600:
        return Check("token", False, f"{path} has mode {mode:04o}; expected 0600 (rewritten at launch, but fix the directory)")
    return Check("token", True, f"{path} mode 0600")


def check_env_file(state: StateDir) -> Check:
    path = state.path / ENV_FILE
    if not path.exists():
        return Check("env", True, f"no {path} (the credential comes from the shell)")
    mode = _mode(path)
    if mode != 0o600:
        return Check("env", False, f"{path} has mode {mode:04o}; expected 0600 — run: chmod 600 {path}")
    try:
        bad = env_file_bad_lines(path)
    except OSError as e:
        return Check("env", False, f"{path} could not be read: {_one_line(str(e))}")
    if bad:
        more = f" (and {len(bad) - 1} more)" if len(bad) > 1 else ""
        return Check(
            "env",
            False,
            f"{path} line {bad[0]} is not a KEY=value line{more}; the file is not loaded until every line is one (values are literal: no $, no quotes inside bare values)",
        )
    return Check("env", True, f"{path} mode 0600, KEY=value lines, loaded")


def check_ledger(state: StateDir) -> Check:
    ledger = state.read_ledger()
    if ledger is None:
        if state.ledger_path.exists():
            return Check("ledger", False, f"{state.ledger_path} is not readable as a ledger; {STALE_LEDGER}")
        return Check("ledger", True, "no ledger (no gateway running)")
    alive = _pid_alive(ledger.pid)
    listening = _port_listening(ledger.host, ledger.port)
    if alive and listening:
        return Check("ledger", True, f"gateway running: pid {ledger.pid}, {ledger.host}:{ledger.port}")
    if not alive and listening:
        return Check(
            "ledger",
            False,
            f"pid {ledger.pid} is gone but {ledger.host}:{ledger.port} is busy with another process; {STALE_LEDGER}",
        )
    if alive and not listening:
        return Check("ledger", False, f"pid {ledger.pid} is alive but nothing listens on {ledger.host}:{ledger.port}; {STALE_LEDGER}")
    return Check("ledger", False, f"pid {ledger.pid} is gone and nothing listens on {ledger.host}:{ledger.port}; {STALE_LEDGER}")


def check_swift() -> Check:
    path = shutil.which("swift")
    if path:
        return Check("swift", True, path)
    return Check("swift", False, "swift is not on PATH; install Xcode or the Command Line Tools to build the app")


# --- the whole run ------------------------------------------------------------


def doctor(state: StateDir, config_path: Path) -> list[Check]:
    """Every check, in the order a person reads them. Never raises for a bad machine; it reports."""
    config_path = Path(config_path)
    return [
        check_python(),
        check_sdk(),
        check_credential(),
        check_config(config_path),
        check_setting_sources(config_path),
        check_token(state),
        check_env_file(state),
        check_ledger(state),
        check_swift(),
    ]
