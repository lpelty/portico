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
import subprocess
import sys
import tomllib
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path

from . import REPO_ROOT
from .config import EMPTY_SETTING_SOURCES_MESSAGE, ConfigError, load_config
from .plugins import check_plugin
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

    ``PATH`` is the exception (v0.11): it is always set, so the file's
    entries go first and the rest of the PATH is kept after them. Applying
    the same file twice changes nothing more.

    A missing file sets nothing. A malformed file sets nothing and raises
    EnvFileError, so a partial load can never happen.
    """
    from .shellpath import merged

    if not path.is_file():
        return []
    pairs = parse_env_file(path)
    applied: list[str] = []
    for key, value in pairs.items():
        if key == "PATH":
            environ[key] = merged(value, environ.get(key, ""))
            applied.append(key)
        elif key not in environ:
            environ[key] = value
            applied.append(key)
    return applied


@dataclass(frozen=True)
class Check:
    """One check: its short name, whether it passed, and one line saying why.

    A ``warn`` check passes (the exit code stays 0) but is printed as a
    warning: something a person should know, nothing that stops the gateway.
    """

    name: str
    ok: bool
    line: str
    warn: bool = False


def format_check(check: Check) -> str:
    word = ("warn" if check.warn else "ok  ") if check.ok else "FAIL"
    return f"{word} {check.name}: {check.line}"


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
    return Check(
        "python", False, f"{got} is too old; the gateway needs {want} or newer, and uv provides it: run bin/install"
    )


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


# --- prerequisites: what bin/install needs to build the app ---------------------

CLT_PKG = "com.apple.pkg.CLTools_Executables"
PKGUTIL = "/usr/sbin/pkgutil"
# Written by app/Packaging/build-app.sh: which macOS SDK the release build used and why.
BUILD_RECORD = Path("app") / ".build" / "portico-build.env"
CLT_INSTALL_HINT = "run: xcode-select --install (Xcode is not needed)"

Runner = Callable[[list[str]], subprocess.CompletedProcess[str]]


def _run(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)


def _try(run: Runner, argv: list[str]) -> subprocess.CompletedProcess[str] | None:
    """``run(argv)``, or None when the program is missing or does not answer."""
    try:
        return run(argv)
    except (OSError, subprocess.TimeoutExpired):
        return None


def _first_line(text: str) -> str:
    for line in text.splitlines():
        if line.strip():
            return _one_line(line)
    return ""


def developer_dir(run: Runner = _run) -> str | None:
    """The active developer directory (``xcode-select -p``), or None when there is none."""
    done = _try(run, ["xcode-select", "-p"])
    if done is None or done.returncode != 0:
        return None
    path = done.stdout.strip()
    return path if path and Path(path).is_dir() else None


def check_clt(run: Runner = _run) -> Check:
    """The Command Line Tools build the app; Xcode is not needed (but works when it is the active dir)."""
    dev = developer_dir(run)
    if dev is None:
        return Check("command line tools", False, f"not installed; {CLT_INSTALL_HINT}")
    info = _try(run, [PKGUTIL, f"--pkg-info={CLT_PKG}"])
    version = ""
    if info is not None and info.returncode == 0:
        for line in info.stdout.splitlines():
            if line.startswith("version:"):
                version = line.split(":", 1)[1].strip()
    if version:
        return Check("command line tools", True, f"{version} (active developer dir: {dev})")
    return Check(
        "command line tools",
        True,
        f"no Command Line Tools package; the active developer dir {dev} provides the tools",
    )


def check_swift(run: Runner = _run, which: Callable[[str], str | None] = shutil.which, clt_present: bool = True) -> Check:
    """``swift`` runs. Not asked without developer tools: the /usr/bin shim would open an installer dialog."""
    if not clt_present:
        return Check("swift", False, "not checked: swift comes with the Command Line Tools (see above)")
    path = which("swift")
    if not path:
        return Check("swift", False, f"swift is not on PATH; {CLT_INSTALL_HINT}")
    done = _try(run, [path, "--version"])
    if done is None or done.returncode != 0:
        said = _first_line((done.stderr or done.stdout) if done is not None else "") or "no answer"
        return Check("swift", False, f"swift does not run ({said}); reinstall the Command Line Tools: {CLT_INSTALL_HINT}")
    m = re.search(r"Swift version (\S+)", done.stdout + done.stderr)
    return Check("swift", True, f"Swift {m.group(1)} ({path})" if m else f"{_first_line(done.stdout)} ({path})")


def check_uv(run: Runner = _run, which: Callable[[str], str | None] = shutil.which) -> Check:
    path = which("uv")
    if not path:
        return Check(
            "uv",
            False,
            "uv is not on PATH; bin/install and bin/update need it: https://docs.astral.sh/uv/getting-started/installation/",
        )
    done = _try(run, [path, "--version"])
    version = _first_line(done.stdout) if done is not None and done.returncode == 0 else ""
    return Check("uv", True, f"{version or 'uv'} ({path})")


def locked_version(lock_path: Path, dist: str = SDK_DIST) -> str | None:
    """The version ``uv.lock`` pins for ``dist``, or None when the lock or the package is absent."""
    try:
        data = tomllib.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError):
        return None
    for package in data.get("package", []):
        if package.get("name") == dist:
            version = package.get("version")
            return str(version) if version else None
    return None


def installed_version(dist: str = SDK_DIST) -> str | None:
    try:
        return importlib.metadata.version(dist)
    except importlib.metadata.PackageNotFoundError:
        return None


def check_sdk_lock(lock_path: Path | None = None, installed: Callable[[], str | None] = installed_version) -> Check:
    """The installed engine SDK is the one ``gateway/uv.lock`` pins: what was tested is what runs."""
    lock_path = REPO_ROOT / "gateway" / "uv.lock" if lock_path is None else lock_path
    have = installed()
    want = locked_version(lock_path)
    if want is None:
        return Check("sdk lock", True, f"{lock_path} pins no {SDK_DIST}; not compared")
    if have is None:
        return Check("sdk lock", False, f"{SDK_DIST} is not installed; {lock_path.name} pins {want}; run bin/install")
    if have == want:
        return Check("sdk lock", True, f"{SDK_DIST} {have} is the version {lock_path.name} pins")
    return Check(
        "sdk lock",
        False,
        f"{SDK_DIST} {have} is installed but {lock_path.name} pins {want}; run bin/install (uv sync) to install {want}",
    )


def _read_build_record(path: Path) -> dict[str, str]:
    record: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, sep, value = line.partition("=")
        if sep:
            record[key.strip()] = value.strip()
    return record


def check_app_sdk(repo: Path = REPO_ROOT, run: Runner = _run, clt_present: bool = True) -> Check:
    """Which macOS SDK the app builds with: the one bin/install recorded, else the default one."""
    path = Path(repo) / BUILD_RECORD
    if path.is_file():
        try:
            record = _read_build_record(path)
        except (OSError, UnicodeDecodeError) as e:
            return Check("macos sdk", True, f"{path} could not be read ({_one_line(str(e))}); run bin/install to rebuild", warn=True)
        sdk = record.get("sdk", "")
        version = record.get("sdk_version", "unknown")
        chosen = record.get("chosen", "")
        if sdk and not Path(sdk).is_dir():
            return Check(
                "macos sdk",
                False,
                f"the app was built with the macOS {version} SDK ({sdk}), which is no longer installed; run bin/install to pick another",
            )
        why = {
            "fallback": "; the default SDK does not compile the app, bin/install picked this one",
            "PORTICO_SDKROOT": ", set by PORTICO_SDKROOT",
            "default": " (the default)",
        }.get(chosen, "")
        return Check("macos sdk", True, f"the app builds with the macOS {version} SDK ({sdk}){why}")
    if not clt_present:
        return Check("macos sdk", False, "not checked: the macOS SDK comes with the Command Line Tools (see above)")
    sdk_path = _try(run, ["xcrun", "--sdk", "macosx", "--show-sdk-path"])
    sdk_version = _try(run, ["xcrun", "--sdk", "macosx", "--show-sdk-version"])
    where = sdk_path.stdout.strip() if sdk_path is not None and sdk_path.returncode == 0 else ""
    version = sdk_version.stdout.strip() if sdk_version is not None and sdk_version.returncode == 0 else ""
    if not where:
        return Check("macos sdk", False, f"no macOS SDK found; reinstall the Command Line Tools: {CLT_INSTALL_HINT}")
    return Check(
        "macos sdk",
        True,
        f"the app is not built yet; the default is the macOS {version or 'unknown'} SDK ({where}), and bin/install falls back to another installed SDK if it does not compile",
    )
def check_gateway_config(state: StateDir) -> Check:
    """Whether the running gateway is using the config file as it is now (v0.3)."""
    from .status import gateway_status

    status = gateway_status(state)
    if not status.get("running"):
        return Check("gateway config", True, "no gateway running; the next one reads the config at start")
    pid = status.get("pid", "?")
    if status.get("config_stale"):
        return Check(
            "gateway config",
            True,
            f"the running gateway (pid {pid}) started before the config file changed: "
            "restart the gateway to apply (portico-gateway stop; the app starts a fresh one)",
            warn=True,
        )
    if "config_stale" not in status:
        return Check("gateway config", True, f"a gateway is running (pid {pid}) but could not be asked about its config")
    return Check("gateway config", True, f"the running gateway (pid {pid}) uses the config as it is now")


def check_plugins(config_path: Path) -> list[Check]:
    """One check per configured plug-in: it imports and speaks this API, or why not. Prints no config values."""
    try:
        config = load_config(config_path)
    except ConfigError:
        return [Check("plugins", True, "not checked: the config does not load (see the config check)")]
    if not config.plugins:
        return [Check("plugins", True, "none configured")]
    checks: list[Check] = []
    for name in config.plugins:
        ok, line = check_plugin(name, config.plugin_paths)
        checks.append(Check(f"plugin {name}", ok, _one_line(line)))
    return checks


# The config keys whose errors are the services check's to report.
SERVICES_KEYS = frozenset({"services", "services_interval_seconds"})


def check_services(config_path: Path) -> Check:
    """The deployment's ``[[services]]`` (v0.4): how many and which, or why they cannot be read. Runs no check."""
    try:
        config = load_config(config_path)
    except ConfigError as e:
        if e.keys & SERVICES_KEYS:
            return Check("services", False, _one_line(str(e)))
        return Check("services", True, "not checked: the config does not load (see the config check)")
    status = config.deployment.status
    if not config.services:
        if status:
            return Check("services", True, f"listed by [deployment] status, every {config.services_interval_seconds} s")
        return Check("services", True, "none configured; the app shows the Gateway row only")
    names = ", ".join(s.id for s in config.services)
    source = "; rows from [deployment] status" if status else ""
    return Check(
        "services",
        True,
        f"{len(config.services)} configured ({names}), checked every {config.services_interval_seconds} s{source}",
    )


PATH_TOOLS = ("node", "npx", "uvx")


def check_path(config_path: Path, env: Mapping[str, str] | None = None, read: Callable[[Mapping[str, str]], str | None] | None = None) -> Check:
    """The PATH the gateway gives the engine (v0.11), and whether the usual MCP launchers are on it."""
    from portico_gateway.shellpath import login_shell_path, merged

    env = os.environ if env is None else env
    inherited = env.get("PATH", "")
    try:
        use_login = load_config(config_path).login_shell_path
    except ConfigError:
        use_login = True
    path, source = inherited, "inherited"
    if use_login:
        shell = (read or login_shell_path)(env)
        if shell is None:
            source = "inherited (the login shell's could not be read)"
        else:
            path, source = merged(shell, inherited), "from the login shell"
    missing = [tool for tool in PATH_TOOLS if shutil.which(tool, path=path) is None]
    found = "all of node, npx, uvx found" if not missing else f"not found: {', '.join(missing)}"
    return Check("path", True, f"{source}; {found}", warn=bool(missing) or source.startswith("inherited ("))


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL)


def check_checkout(repo: Path = REPO_ROOT) -> Check:
    """Which release this checkout is on, and a warning (never a failure) when it has local changes."""
    if shutil.which("git") is None:
        return Check("checkout", True, "git is not on PATH; the release was not checked")
    try:
        inside = _git(repo, "rev-parse", "--show-toplevel")
        if inside.returncode != 0 or Path(inside.stdout.strip()).resolve() != Path(repo).resolve():
            return Check("checkout", True, f"{repo} is not a git checkout; the release was not checked")
        tag = _git(repo, "describe", "--tags", "--exact-match", "HEAD")
        if tag.returncode == 0 and tag.stdout.strip():
            where = f"tag {tag.stdout.strip()}"
        else:
            branch = _git(repo, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
            head = _git(repo, "rev-parse", "--short", "HEAD").stdout.strip()
            where = f"commit {head}" + (f" on {branch}" if branch and branch != "HEAD" else "")
        status = _git(repo, "status", "--porcelain")
    except (OSError, subprocess.TimeoutExpired) as e:
        return Check("checkout", True, f"git could not be asked about {repo}: {_one_line(str(e))}")
    changed = [line for line in status.stdout.splitlines() if line.strip()]
    if changed:
        return Check(
            "checkout",
            True,
            f"{where}; {len(changed)} local change(s) in the checkout: move the change into a plug-in "
            "or ask upstream for it (bin/update will not update over local changes)",
            warn=True,
        )
    return Check("checkout", True, f"{where}, no local changes")


# --- the whole run ------------------------------------------------------------


def doctor(state: StateDir, config_path: Path, repo: Path = REPO_ROOT) -> list[Check]:
    """Every check, in the order a person reads them. Never raises for a bad machine; it reports."""
    config_path = Path(config_path)
    return [
        check_checkout(repo),
        check_python(),
        check_sdk(),
        check_sdk_lock(Path(repo) / "gateway" / "uv.lock"),
        check_credential(),
        check_config(config_path),
        check_setting_sources(config_path),
        *check_plugins(config_path),
        check_services(config_path),
        check_path(config_path),
        check_token(state),
        check_env_file(state),
        check_ledger(state),
        check_gateway_config(state),
        *prerequisite_checks(repo),
    ]


def prerequisite_checks(repo: Path = REPO_ROOT, run: Runner = _run, which: Callable[[str], str | None] = shutil.which) -> list[Check]:
    """What building the app needs: the Command Line Tools, swift, uv, and the SDK the app builds with."""
    clt = check_clt(run)
    return [
        clt,
        check_swift(run, which, clt_present=clt.ok),
        check_uv(run, which),
        check_app_sdk(repo, run, clt_present=clt.ok),
    ]
