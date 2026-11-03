"""v0.18 §3.2: the person's MCP servers and plugins, and what each engine is given of them.

Portico leaves ``setting_sources`` as the deployment set it (``["project"]``
by default), so Claude Code itself loads only the folder's ``.mcp.json``.
The person's own servers (user scope, and local scope for the agent folder)
and plugins are brought in here, and only those: their instructions, hooks
and permissions never cross over.

Where things are (plan ruling 1):

- ``~/.claude.json`` is ``$CLAUDE_CONFIG_DIR/.claude.json`` when that is set.
  User-scope servers are its top-level ``mcpServers``; local-scope servers are
  ``projects["<folder>"].mcpServers``; servers turned off are
  ``projects["<folder>"].disabledMcpServers``.
- The deployment's servers are ``<folder>/.mcp.json`` ``mcpServers``.

A missing file or key is an empty set. A file that doesn't parse is logged
(path and error kind only: ``~/.claude.json`` can hold keys and tokens, so
nothing of its content is ever logged) and treated as empty. This module
never writes either file; changes go through the CLI (``CliRunner``).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
import time
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, Protocol

log = logging.getLogger(__name__)

# The in-process server every engine gets (``engine.SHOW_SERVER``); named here
# too so this module stays free of the engine's imports.
PORTICO_SERVER = "portico"

Scope = Literal["user", "local", "shipped", "core"]


def claude_json_path(env: Mapping[str, str] = os.environ) -> Path:
    """``$CLAUDE_CONFIG_DIR/.claude.json`` when the variable is set, else ``~/.claude.json``."""
    config_dir = env.get("CLAUDE_CONFIG_DIR")
    if config_dir:
        return Path(config_dir).expanduser() / ".claude.json"
    return Path.home() / ".claude.json"


@dataclass(frozen=True)
class ServerEntry:
    name: str
    scope: Scope
    config: dict
    disabled: bool


# (path, mtime_ns) of each unusable file already logged: a broken file is
# logged once per version of it (controller ruling R-c3), not on every read.
_logged_unusable: set[tuple[str, int]] = set()


def _log_unusable(path: Path, message: str, kind: str) -> None:
    try:
        mtime = path.stat().st_mtime_ns
    except OSError:
        mtime = -1
    key = (str(path), mtime)
    if key in _logged_unusable:
        return
    _logged_unusable.add(key)
    log.warning(message, path, kind)


def _read_json(path: Path) -> dict[str, Any]:
    """The file's top-level object; ``{}`` when missing or unusable (logged once per mtime, never with content)."""
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return {}
    except OSError as e:
        _log_unusable(path, "could not read %s (%s); treating it as empty", type(e).__name__)
        return {}
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        _log_unusable(path, "%s does not parse (%s); treating it as empty", type(e).__name__)
        return {}
    return data if isinstance(data, dict) else {}


def _servers(value: Any) -> dict[str, dict]:
    """The ``mcpServers`` map, keeping only entries whose config is an object."""
    if not isinstance(value, dict):
        return {}
    return {str(name): dict(cfg) for name, cfg in value.items() if isinstance(cfg, dict)}


def _project(claude_json: dict[str, Any], folder: Path) -> dict[str, Any]:
    """The ``projects`` entry for ``folder``: by the path as given, else its resolved form."""
    projects = claude_json.get("projects")
    if not isinstance(projects, dict):
        return {}
    for key in (str(folder), str(folder.resolve())):
        entry = projects.get(key)
        if isinstance(entry, dict):
            return entry
    return {}


@dataclass(frozen=True)
class _Sources:
    user: dict[str, dict]
    local: dict[str, dict]
    disabled: frozenset[str]
    shipped: dict[str, dict]


def _sources(folder: Path, env: Mapping[str, str]) -> _Sources:
    folder = Path(folder)
    claude_json = _read_json(claude_json_path(env))
    project = _project(claude_json, folder)
    raw_disabled = project.get("disabledMcpServers")
    disabled = frozenset(n for n in raw_disabled if isinstance(n, str)) if isinstance(raw_disabled, list) else frozenset()
    return _Sources(
        user=_servers(claude_json.get("mcpServers")),
        local=_servers(project.get("mcpServers")),
        disabled=disabled,
        shipped=_servers(_read_json(folder / ".mcp.json").get("mcpServers")),
    )


def disabled_servers(folder: Path, env: Mapping[str, str] = os.environ) -> frozenset[str]:
    """The folder's ``disabledMcpServers`` (any name, in a source or not: claude.ai connectors too)."""
    return _sources(Path(folder), env).disabled


def read_servers(folder: Path, core: list[str], env: Mapping[str, str] = os.environ) -> list[ServerEntry]:
    """Every server the folder's agent could have, grouped (Settings' list; ruling 1).

    Core is ``portico`` first, then the ``.mcp.json`` servers named in
    ``core`` (``[mcp] core``), in that order; shipped is the folder's other
    ``.mcp.json`` servers; then local and user. A name appears once, by
    precedence core > shipped > local > user.
    """
    src = _sources(folder, env)
    entries: list[ServerEntry] = [ServerEntry(PORTICO_SERVER, "core", {"type": "sdk", "name": PORTICO_SERVER}, False)]
    seen = {PORTICO_SERVER}

    def add(name: str, scope: Scope, config: dict) -> None:
        if name in seen:
            return
        seen.add(name)
        entries.append(ServerEntry(name, scope, config, name in src.disabled))

    for name in core:
        if name in src.shipped:
            add(name, "core", src.shipped[name])
    for name, config in src.shipped.items():
        add(name, "shipped", config)
    for name, config in src.local.items():
        add(name, "local", config)
    for name, config in src.user.items():
        add(name, "user", config)
    return entries


def servers_for_engine(
    folder: Path, setting_sources: list[str], core: list[str], env: Mapping[str, str] = os.environ
) -> dict[str, dict]:
    """The ``mcp_servers`` to pass an engine beside ``portico`` (ruling 2).

    User servers, then the folder's local servers (a local one wins over a
    user one of the same name), minus the folder's ``disabledMcpServers``.
    Never ``portico`` or a ``.mcp.json`` name: the folder's file loads itself.
    A source already in ``setting_sources`` is left to Claude Code, and a
    user server is still dropped when a local one of its name exists (Claude
    Code loads that one).
    """
    del core  # core names are .mcp.json names, which are never passed
    src = _sources(folder, env)
    blocked = {PORTICO_SERVER, *src.shipped}
    out: dict[str, dict] = {}
    if "user" not in setting_sources:
        for name, config in src.user.items():
            if name not in src.local:
                out[name] = config
    if "local" not in setting_sources:
        out.update(src.local)
    return {name: config for name, config in out.items() if name not in blocked and name not in src.disabled}


# --- the CLI (ruling 6) ---------------------------------------------------------------


@dataclass
class CliResult:
    code: int
    stdout: str
    stderr: str


class CliRunner(Protocol):
    async def run(self, args: list[str], *, cwd: Path, timeout: float, stdin_text: str | None = None) -> CliResult: ...


def cli_path() -> str:
    """The CLI the SDK runs (``<claude_agent_sdk>/_bundled/claude``); ``claude`` on ``PATH`` only when that is missing."""
    import claude_agent_sdk

    bundled = Path(claude_agent_sdk.__file__).parent / "_bundled" / "claude"
    if bundled.is_file():
        return str(bundled)
    return shutil.which("claude") or "claude"


class SubprocessCli:
    """``CliRunner`` that runs ``cli_path()`` with the gateway's environment (so ``CLAUDE_CONFIG_DIR`` carries).

    Stdin is closed unless ``stdin_text`` is given. A run past ``timeout`` is
    killed and comes back as code -1 with "timed out" in ``stderr``.
    """

    async def run(self, args: list[str], *, cwd: Path, timeout: float, stdin_text: str | None = None) -> CliResult:
        proc = await asyncio.create_subprocess_exec(
            cli_path(),
            *args,
            cwd=str(cwd),
            env=dict(os.environ),
            stdin=asyncio.subprocess.PIPE if stdin_text is not None else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            out, err = await asyncio.wait_for(
                proc.communicate(stdin_text.encode("utf-8") if stdin_text is not None else None), timeout
            )
        except TimeoutError:
            proc.kill()
            await proc.wait()
            return CliResult(code=-1, stdout="", stderr=f"claude {args[0] if args else ''} timed out after {timeout:.0f}s")
        return CliResult(
            code=proc.returncode if proc.returncode is not None else -1,
            stdout=out.decode("utf-8", errors="replace"),
            stderr=err.decode("utf-8", errors="replace"),
        )


# --- plugins (ruling 3) --------------------------------------------------------------

PLUGIN_CACHE_SECONDS = 30.0
PLUGIN_LIST_TIMEOUT = 60.0
PLUGIN_LIST_ARGS = ["plugin", "list", "--json"]

# Per folder (the list runs there, and ``enabled`` is the CLI's answer for it):
# when it was read and its entries (``[]`` after a failed read).
_plugin_cache: dict[str, tuple[float, list[dict[str, Any]]]] = {}
_plugin_failure_logged = False


def invalidate_plugin_cache() -> None:
    """Forget every cached ``plugin list`` (after any plugin change, so the next engine start reads it fresh)."""
    _plugin_cache.clear()


async def _plugin_list(runner: CliRunner, folder: Path) -> list[dict[str, Any]]:
    global _plugin_failure_logged
    try:
        key = str(folder.resolve())
    except OSError:
        key = str(folder)
    cached = _plugin_cache.get(key)
    now = time.monotonic()
    if cached is not None and now - cached[0] < PLUGIN_CACHE_SECONDS:
        return cached[1]
    entries: list[dict[str, Any]] = []
    reason: str | None = None
    try:
        result = await runner.run(list(PLUGIN_LIST_ARGS), cwd=folder, timeout=PLUGIN_LIST_TIMEOUT)
    except Exception as e:  # a CLI that cannot run never breaks an engine start
        reason = f"{type(e).__name__}: {e}"
    else:
        if result.code != 0:
            lines = [ln.strip() for ln in result.stderr.splitlines() if ln.strip()]
            reason = f"exit {result.code}" + (f": {lines[-1][:240]}" if lines else "")
        else:
            try:
                data = json.loads(result.stdout)
            except json.JSONDecodeError:
                reason = "the output is not JSON"
            else:
                if isinstance(data, list):
                    entries = [e for e in data if isinstance(e, dict)]
                else:
                    reason = "the output is not a list"
    if reason is not None:
        if not _plugin_failure_logged:
            log.warning("could not list the plugins (%s); engines start without the person's plugins", reason)
            _plugin_failure_logged = True
    else:
        _plugin_failure_logged = False
    _plugin_cache[key] = (now, entries)
    return entries


def _same_folder(path: Any, folder: Path) -> bool:
    if not isinstance(path, str) or not path:
        return False
    try:
        return Path(path).resolve() == folder.resolve()
    except OSError:
        return Path(path) == folder


async def plugin_paths_for_engine(runner: CliRunner, folder: Path, setting_sources: list[str]) -> list[str]:
    """The ``installPath`` of each plugin to pass an engine in ``folder`` (ruling 3).

    From ``claude plugin list --json`` (cached 30 s per folder): every entry
    with ``enabled: true`` whose scope is ``user``, or ``local`` with
    ``projectPath`` equal to the folder. User entries are skipped when
    ``setting_sources`` has ``user``, local ones when it has ``local``
    (Claude Code loads those itself). ``project`` entries are never passed:
    the ``project`` source already loads them (R-c1); nor are ``synced`` ones
    (R-c2). A failed list is ``[]``, logged once.
    """
    folder = Path(folder)
    want_user = "user" not in setting_sources
    want_local = "local" not in setting_sources
    if not want_user and not want_local:
        return []
    paths: list[str] = []
    for entry in await _plugin_list(runner, folder):
        if entry.get("enabled") is not True:
            continue
        install = entry.get("installPath")
        if not isinstance(install, str) or not install:
            continue
        scope = entry.get("scope")
        if scope == "user" and want_user:
            pass
        elif scope == "local" and want_local and _same_folder(entry.get("projectPath"), folder):
            pass
        else:
            continue
        if install not in paths:
            paths.append(install)
    return paths
