"""v0.18 §3.1: MCP servers managed from Settings (``mcp.v1``, plan rulings 4–14).

``McpSettings`` answers the app's ``mcp.*`` requests with ``mcp.servers``:
the four sources (``mcp_inventory.read_servers``: built in, user, local,
shipped) merged by name with the status of the most recently started live
engine on Settings' folder (ruling 7), plus a fifth group for servers that
status names and no source has (claude.ai connectors, ruling 14).

What changes what:

- Turn off / on writes ``projects["<folder>"].disabledMcpServers`` in
  ``~/.claude.json`` (the key Claude Code's own toggle writes), atomically,
  keeping every other key, their order and the file's mode. Nothing else
  here writes that file; nothing of its content is ever logged.
- Add, remove, sign in and sign out run the bundled CLI (``CliRunner``),
  in Settings' folder.
- None of these touches a running engine (ruling 5): they take effect at
  the next engine start. Only Reconnect (and a finished sign-in) calls
  ``mcp_reconnect`` on the live engines on Settings' folder.

``ToolPolicy`` is the person's per-tool choice (ruling 10), kept in
``<state>/mcp_tools.json`` as ``{"<server>/<tool>": "allow" | "ask"}``,
only where it differs from the default.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shlex
import tempfile
from datetime import UTC, datetime
from collections.abc import Awaitable, Callable, Coroutine, Mapping
from pathlib import Path
from typing import Any, Literal

from .mcp_inventory import (  # noqa: F401 — strip_url_queries is used here and imported from here
    PORTICO_SERVER,
    CliRunner,
    ServerEntry,
    claude_json_path,
    disabled_servers,
    read_servers,
    strip_url_queries,
)
from .messages import Error, McpServerRow, McpServers, McpToolRow, ProtocolError
from .state import StateDir

log = logging.getLogger(__name__)

Policy = Literal["allow", "ask"]

TOOL_POLICY_FILE = "mcp_tools.json"

CLI_TIMEOUT = 60.0
LOGIN_TIMEOUT = 300.0
STATUS_TIMEOUT = 10.0
CLI_MESSAGE_CHARS = 240
ERROR_CHARS = 120

NAME_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")

GROUP_ORDER = ("core", "user", "local", "shipped", "account")

# Status lines (ruling 8, 7, 13): exact copy.
NOT_STARTED = "Starts with your next chat"
NEEDS_AUTH = "Needs you to sign in"
FAILED_DEFAULT = "it stopped as soon as it opened"
CONNECTING = "Connecting…"
OFF = "Off"
OFF_SHIPPED = "Off for you · it stays off through updates"
SIGNING_IN = "Signing in… finish in your browser"
PORTICO_WHAT = "the viewer, files and screen"

# Refusals.
BAD_NAME = "Use letters, numbers, - and _ only"
CORE_TOGGLE = "Built-in servers can't be turned off"
CORE_REMOVE = "Built-in servers can't be removed"
SHIPPED_REMOVE = "A server that ships with the agent can be turned off, not removed"
ACCOUNT_REMOVE = "Servers from your Claude account can be turned off, not removed"
CORE_POLICY = "Built-in servers' tools can't be changed"
UNREADABLE = "Couldn't read Claude Code's settings file, so nothing was changed"


def _tools_word(n: int) -> str:
    return f"{n} tool" if n == 1 else f"{n} tools"


def _cli_message(stderr: str, args: list[str], code: int) -> str:
    """The command's last non-empty stderr line, query strings stripped, cut to 240 characters (ruling 6)."""
    lines = [ln.strip() for ln in stderr.splitlines() if ln.strip()]
    if lines:
        return strip_url_queries(lines[-1])[:CLI_MESSAGE_CHARS]
    return f"claude {' '.join(args[:2])} failed (exit {code})"


def _same_folder(a: Path, b: Path) -> bool:
    try:
        return Path(a).resolve() == Path(b).resolve()
    except OSError:
        return Path(a) == Path(b)


# --- the per-tool policy (ruling 10) -------------------------------------------------

_NOT_NAME_CHAR = re.compile(r"[^A-Za-z0-9_-]")
CLAUDE_AI_PREFIX = "claude.ai "


def normalise_server(server: str) -> str:
    """A server name as Claude Code puts it in tool names.

    Copied from the bundled CLI 2.1.310 (its ``vn``): every character
    outside ``[A-Za-z0-9_-]`` becomes ``_``; for a name starting
    "claude.ai " runs of ``_`` then collapse to one and a leading or
    trailing ``_`` is dropped.
    """
    out = _NOT_NAME_CHAR.sub("_", server)
    if server.startswith(CLAUDE_AI_PREFIX):
        out = re.sub(r"_+", "_", out).strip("_")
    return out


def tool_name(server: str, tool: str) -> str:
    """``mcp__<server normalised>__<tool>``: the CLI normalises the server only (its ``g5``), the tool stays as given."""
    return f"mcp__{normalise_server(server)}__{tool}"


class ToolPolicy:
    """The person's choice per tool: ``allow`` (runs without asking) or ``ask``; the default is by ``read_only``."""

    def __init__(self, path: Path, choices: dict[str, Policy]) -> None:
        self.path = path
        self._choices = choices

    @classmethod
    def load(cls, state: StateDir) -> ToolPolicy:
        path = Path(state.path) / TOOL_POLICY_FILE
        choices: dict[str, Policy] = {}
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            data = {}
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as e:
            log.warning("%s is unusable (%s); every tool has its default", path, type(e).__name__)
            data = {}
        if isinstance(data, dict):
            for key, value in data.items():
                if isinstance(key, str) and value in ("allow", "ask"):
                    choices[key] = value
        return cls(path, choices)

    @staticmethod
    def key(server: str, tool: str) -> str:
        """The tool's full name as Claude Code names it (R-c8): ``mcp__<server normalised>__<tool>``."""
        return tool_name(server, tool)

    def allows(self, full_name: str) -> bool:
        """Whether the person set the tool named exactly ``full_name`` to run without asking."""
        return self._choices.get(full_name) == "allow"

    def drop_server(self, server: str) -> None:
        """Forget every choice for ``server``'s tools (after it is removed)."""
        prefix = f"mcp__{normalise_server(server)}__"
        kept = {k: v for k, v in self._choices.items() if not k.startswith(prefix)}
        if kept != self._choices:
            self._choices = kept
            _atomic_replace(self.path, json.dumps(self._choices, indent=2) + "\n", 0o600)

    @staticmethod
    def default(read_only: bool) -> Policy:
        return "allow" if read_only else "ask"

    def stored(self, server: str, tool: str) -> Policy | None:
        return self._choices.get(self.key(server, tool))

    def effective(self, server: str, tool: str, read_only: bool) -> Policy:
        """The person's choice for this tool, else ``allow`` for a read-only tool and ``ask`` for the rest."""
        return self.stored(server, tool) or self.default(read_only)

    def set(self, server: str, tool: str, policy: Policy | None, read_only: bool | None = None) -> None:
        """Keep ``policy`` for the tool (``None``: back to the default) and write the file.

        When ``read_only`` is known, a choice equal to the default is not stored.
        """
        key = self.key(server, tool)
        if policy is None or (read_only is not None and policy == self.default(read_only)):
            self._choices.pop(key, None)
        else:
            self._choices[key] = policy
        _atomic_replace(self.path, json.dumps(self._choices, indent=2) + "\n", 0o600)


def _atomic_replace(target: Path, text: str, mode: int) -> None:
    """Write ``text`` to a temp file beside ``target`` at ``mode``, then ``os.replace`` it into place."""
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{target.name}.", suffix=".tmp", dir=target.parent)
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, target)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


# --- ~/.claude.json: the one key the toggle writes -----------------------------------


def set_disabled(folder: Path, name: str, disabled: bool, env: Mapping[str, str] = os.environ) -> None:
    """Add ``name`` to (or take it out of) ``projects["<folder>"].disabledMcpServers``.

    Every other key stays as it was, in its order; the file keeps its mode
    (0600 when new). A file that doesn't parse is never rewritten: the
    change is refused. A missing project entry is created holding only the list.
    """
    path = claude_json_path(env)
    if path.is_symlink():
        # Replace the file the link points at, never the link itself.
        path = path.resolve()
    mode = 0o600
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        data: Any = {}
    else:
        try:
            mode = path.stat().st_mode & 0o777
            data = json.loads(raw.decode("utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as e:
            log.warning("%s does not parse (%s); not changing it", path, type(e).__name__)
            raise ProtocolError("mcp.config_unreadable", UNREADABLE) from None
    if not isinstance(data, dict):
        raise ProtocolError("mcp.config_unreadable", UNREADABLE)
    projects = data.setdefault("projects", {})
    if not isinstance(projects, dict):
        raise ProtocolError("mcp.config_unreadable", UNREADABLE)
    key = str(folder)
    for candidate in (str(folder), str(Path(folder).resolve())):
        if candidate in projects:
            key = candidate
            break
    entry = projects.setdefault(key, {})
    if not isinstance(entry, dict):
        raise ProtocolError("mcp.config_unreadable", UNREADABLE)
    current = entry.get("disabledMcpServers")
    names = [n for n in current if isinstance(n, str)] if isinstance(current, list) else []
    if disabled:
        if name not in names:
            names.append(name)
    else:
        names = [n for n in names if n != name]
    entry["disabledMcpServers"] = names
    _atomic_replace(path, json.dumps(data, indent=2, ensure_ascii=False), mode)
    log.info("MCP server %s turned %s for %s", name, "off" if disabled else "on", key)


# --- the service --------------------------------------------------------------------

LiveEngines = Callable[[], list[tuple[Path, Any]]]


class McpSettings:
    """The ``mcp.*`` requests. Every method returns the ``mcp.servers`` reply or raises ``ProtocolError``.

    ``folder`` gives Settings' folder (ruling 4); ``engines`` the live
    engines as ``(folder, engine)``, most recently started first; ``push``
    sends a frame to the attached app; ``spawn`` runs a background task.
    """

    def __init__(
        self,
        *,
        folder: Callable[[], Path],
        core: Callable[[], list[str]],
        cli: CliRunner,
        engines: LiveEngines,
        policy: ToolPolicy,
        push: Callable[[Any], Awaitable[None]],
        spawn: Callable[[Coroutine[Any, Any, None], str], Any],
        env: Mapping[str, str] = os.environ,
        config_lock: asyncio.Lock | None = None,
        reconnected: Callable[[Any], None] | None = None,
    ) -> None:
        self._folder = folder
        self._core = core
        self.cli = cli
        self._engines = engines
        self.policy = policy
        self._push = push
        self._spawn = spawn
        self._env = env
        # R-c9: the gateway-wide lock every writer of Claude Code's config holds
        # (this toggle's write, the mcp CLI runs, the plugin CLI runs).
        self._config_lock = config_lock if config_lock is not None else asyncio.Lock()
        self.signing_in: set[str] = set()
        # v0.18 (ruling 22): told of each engine after a reconnect, so MCP Apps rebuild its UI map.
        self._reconnected = reconnected

    # --- reading --------------------------------------------------------------

    def folder(self) -> Path:
        return self._folder()

    def live_engines(self) -> list[Any]:
        """The live engines on Settings' folder, most recently started first."""
        here = self.folder()
        return [engine for folder, engine in self._engines() if _same_folder(folder, here)]

    async def _status(self) -> tuple[bool, list[dict[str, Any]]]:
        """``(live, status)`` from the most recently started live engine on Settings' folder (ruling 7)."""
        engines = self.live_engines()
        if not engines:
            return False, []
        try:
            status = await asyncio.wait_for(engines[0].mcp_status(), STATUS_TIMEOUT)
        except Exception as e:
            log.warning("could not read the MCP status: %s", type(e).__name__)
            return False, []
        return True, [s for s in status if isinstance(s, dict) and isinstance(s.get("name"), str)]

    def _entries(self) -> list[ServerEntry]:
        return read_servers(self.folder(), list(self._core()), self._env)

    async def servers(self, id: str | None = None) -> McpServers:
        live, status = await self._status()
        return McpServers(ts=_now(), id=id, live=live, servers=self._rows(self._entries(), live, status))

    def _rows(self, entries: list[ServerEntry], live: bool, status: list[dict[str, Any]]) -> list[McpServerRow]:
        by_name = {s["name"]: s for s in status}
        known = {e.name for e in entries}
        rows = [self._row(e.name, e.scope, e.config, e.disabled, live, by_name.get(e.name)) for e in entries]
        disabled = disabled_servers(self.folder(), self._env)
        for s in _account_entries(status, known):
            config = s.get("config") if isinstance(s.get("config"), dict) else {}
            rows.append(self._row(s["name"], "account", config, s["name"] in disabled, live, s))
        rows.sort(key=lambda r: GROUP_ORDER.index(r.group))  # stable: each group keeps its order
        return rows

    def _row(
        self, name: str, group: str, config: dict, disabled: bool, live: bool, status: dict[str, Any] | None
    ) -> McpServerRow:
        info = status.get("serverInfo") if status is not None and isinstance(status.get("serverInfo"), dict) else {}
        title = info.get("title") if isinstance(info.get("title"), str) and info.get("title") else name
        transport = _transport(config if config else (status or {}).get("config") or {})
        if name == PORTICO_SERVER:
            transport = "sdk"
        account = None
        for source in (status or {}, info):
            if isinstance(source.get("account"), str) and source.get("account"):
                account = source["account"]
                break

        word, detail = "unknown", NOT_STARTED
        raw_tools = status.get("tools") if live and status is not None else None
        tool_list = [t for t in raw_tools if isinstance(t, dict) and isinstance(t.get("name"), str)] if isinstance(raw_tools, list) else []
        raw = status.get("status") if live and status is not None else None
        if name in self.signing_in:
            word, detail = "signing_in", SIGNING_IN
        elif disabled and group != "core":
            word, detail = "off", OFF_SHIPPED if group == "shipped" else OFF
        elif raw == "connected":
            word = "connected"
            detail = f"Connected · {_tools_word(len(tool_list))}"
            if name == PORTICO_SERVER:
                detail = f"Connected · {PORTICO_WHAT} · {_tools_word(len(tool_list))}"
        elif raw == "needs-auth":
            word, detail = "needs_auth", NEEDS_AUTH
        elif raw == "failed":
            error = status.get("error") if status is not None else None
            reason = strip_url_queries(error.strip())[:ERROR_CHARS] if isinstance(error, str) and error.strip() else FAILED_DEFAULT
            word, detail = "failed", f"Couldn't start: {reason}"
        elif raw == "pending":
            word, detail = "pending", CONNECTING
        elif name == PORTICO_SERVER:
            # Built in and always there; without a live engine there is no count to give.
            detail = PORTICO_WHAT[0].upper() + PORTICO_WHAT[1:]

        has_tools = live and status is not None and isinstance(raw_tools, list)
        tools = [
            McpToolRow(
                name=t["name"],
                description=t.get("description") if isinstance(t.get("description"), str) else "",
                read_only=_read_only(t),
                policy=self.policy.effective(name, t["name"], _read_only(t)),
            )
            for t in tool_list
        ]
        return McpServerRow(
            name=name,
            title=title,
            group=group,  # type: ignore[arg-type]
            transport=transport,  # type: ignore[arg-type]
            status=word,  # type: ignore[arg-type]
            detail=detail,
            tool_count=len(tool_list) if has_tools else None,
            tools=tools,
            account=account,
            can_toggle=group != "core",
            can_remove=group in ("user", "local"),
            can_sign_out=bool(account) or (transport in ("http", "sse") and word == "connected"),
        )

    async def _find(self, name: str) -> tuple[str | None, list[ServerEntry], list[dict[str, Any]]]:
        """The group ``name`` is in (``None``: no such server), with the entries and live status read for it."""
        entries = self._entries()
        for e in entries:
            if e.name == name:
                return e.scope, entries, []
        _, status = await self._status()
        if any(s["name"] == name for s in _account_entries(status, {e.name for e in entries})):
            return "account", entries, status
        return None, entries, status

    # --- changing -------------------------------------------------------------

    async def toggle(self, name: str, enabled: bool, id: str | None = None) -> McpServers:
        group, _, _ = await self._find(name)
        if group == "core":
            raise ProtocolError("mcp.refused", CORE_TOGGLE)
        if group is None:
            raise ProtocolError("mcp.unknown", f"There's no server called {name}")
        async with self._config_lock:
            set_disabled(self.folder(), name, not enabled, self._env)
        return await self.servers(id)

    async def reconnect(self, name: str, id: str | None = None) -> McpServers:
        await self._reconnect_all(name)
        return await self.servers(id)

    async def _reconnect_all(self, name: str) -> None:
        for engine in self.live_engines():
            try:
                await engine.mcp_reconnect(name)
            except Exception as e:
                log.warning("could not reconnect MCP server %s: %s", name, type(e).__name__)
                continue
            if self._reconnected is not None:
                self._reconnected(engine)

    async def remove(self, name: str, id: str | None = None) -> McpServers:
        group, _, _ = await self._find(name)
        if group is None:
            raise ProtocolError("mcp.unknown", f"There's no server called {name}")
        refusal = {"core": CORE_REMOVE, "shipped": SHIPPED_REMOVE, "account": ACCOUNT_REMOVE}.get(group)
        if refusal is not None:
            raise ProtocolError("mcp.refused", refusal)
        await self._run(["mcp", "remove", name, "--scope", group])
        log.info("MCP server %s removed (%s scope)", name, group)
        self.policy.drop_server(name)
        return await self.servers(id)

    async def add(
        self,
        name: str,
        transport: str,
        where: str,
        url: str | None = None,
        command: str | None = None,
        id: str | None = None,
    ) -> McpServers:
        if not NAME_PATTERN.match(name):
            raise ProtocolError("mcp.invalid", BAD_NAME)
        group, entries, status = await self._find(name)
        if group is not None:
            raise ProtocolError("mcp.invalid", f"There's already a server called {name}")
        if where not in ("user", "local"):
            raise ProtocolError("mcp.invalid", "Choose where it works")
        if transport == "http":
            address = (url or "").strip()
            if not address:
                raise ProtocolError("mcp.invalid", "Enter the server's web address")
            args = ["mcp", "add", "--scope", where, "--transport", "http", name, address]
        elif transport == "stdio":
            try:
                parts = shlex.split(command or "")
            except ValueError:
                raise ProtocolError("mcp.invalid", "That command line has an unclosed quote") from None
            if not parts:
                raise ProtocolError("mcp.invalid", "Enter the command that starts the server")
            args = ["mcp", "add", "--scope", where, name, "--", *parts]
        else:
            raise ProtocolError("mcp.invalid", "Choose how it connects")
        await self._run(args)
        log.info("MCP server %s added (%s, %s scope)", name, transport, where)
        if transport == "http" and self.live_engines():
            # Ruling 12: an http server that needs a sign-in gets one now (the browser opens).
            await self._reconnect_all(name)
            _, status = await self._status()
            if any(s["name"] == name and s.get("status") == "needs-auth" for s in status):
                self._start_sign_in(name)
        return await self.servers(id)

    async def sign_in(self, name: str, id: str | None = None) -> McpServers:
        group, _, _ = await self._find(name)
        if group is None:
            raise ProtocolError("mcp.unknown", f"There's no server called {name}")
        self._start_sign_in(name)
        return await self.servers(id)

    def _start_sign_in(self, name: str) -> None:
        """``claude mcp login`` in the background (ruling 13); when it ends, reconnect and push a fresh list."""
        if name in self.signing_in:
            return
        self.signing_in.add(name)

        async def task() -> None:
            failure: str | None = None
            try:
                # Not under the config lock (R-c9): a sign-in can take 300 s while the
                # person finishes in the browser, and it writes only the OAuth
                # credentials, never the server list the other writers change.
                # R-c9a: login stays outside the lock: a 300 s browser login would freeze every Settings change.
                await self._run(["mcp", "login", name], timeout=LOGIN_TIMEOUT, lock=False)
            except ProtocolError as e:
                failure = e.message
            except Exception as e:
                failure = f"Couldn't sign in: {type(e).__name__}"
            finally:
                self.signing_in.discard(name)
            if failure is None:
                log.info("signed in to MCP server %s", name)
                await self._reconnect_all(name)
            else:
                log.warning("signing in to MCP server %s failed", name)
                await self._push(Error(ts=_now(), code="mcp.failed", message=failure))
            await self._push(await self.servers())

        self._spawn(task(), f"portico-mcp-login-{name}")

    async def sign_out(self, name: str, id: str | None = None) -> McpServers:
        group, _, _ = await self._find(name)
        if group is None:
            raise ProtocolError("mcp.unknown", f"There's no server called {name}")
        await self._run(["mcp", "logout", name])
        log.info("signed out of MCP server %s", name)
        return await self.servers(id)

    async def tool_policy(self, server: str, tool: str, policy: Policy | None, id: str | None = None) -> McpServers:
        group, _, _ = await self._find(server)
        if group == "core":
            raise ProtocolError("mcp.refused", CORE_POLICY)
        if group is None:
            raise ProtocolError("mcp.unknown", f"There's no server called {server}")
        _, status = await self._status()
        read_only: bool | None = None
        for s in status:
            if s["name"] == server and isinstance(s.get("tools"), list):
                for t in s["tools"]:
                    if isinstance(t, dict) and t.get("name") == tool:
                        read_only = _read_only(t)
        self.policy.set(server, tool, policy, read_only)
        return await self.servers(id)

    async def _run(self, args: list[str], timeout: float = CLI_TIMEOUT, *, lock: bool = True) -> None:
        """Run the CLI in Settings' folder; with ``lock`` (every run but sign-in) under the config lock (R-c9)."""
        try:
            if lock:
                async with self._config_lock:
                    result = await self.cli.run(args, cwd=self.folder(), timeout=timeout)
            else:
                result = await self.cli.run(args, cwd=self.folder(), timeout=timeout)
        except Exception as e:
            raise ProtocolError("mcp.failed", f"Couldn't run Claude Code: {type(e).__name__}") from e
        if result.code != 0:
            raise ProtocolError("mcp.failed", _cli_message(result.stderr, args, result.code))


def _account_entries(status: list[dict[str, Any]], known: set[str]) -> list[dict[str, Any]]:
    """Status entries for claude.ai connectors (R-c4): in no source, scope ``claudeai`` or config ``claudeai-proxy``.

    Plugin-provided servers (``plugin:…``) and anything else are not listed.
    """
    out = []
    for s in status:
        name = s["name"]
        if name in known or name.startswith("plugin:"):
            continue
        config = s.get("config") if isinstance(s.get("config"), dict) else {}
        if s.get("scope") == "claudeai" or config.get("type") == "claudeai-proxy":
            out.append(s)
    return out


def _read_only(tool: dict[str, Any]) -> bool:
    annotations = tool.get("annotations")
    return isinstance(annotations, dict) and annotations.get("readOnly") is True


def _transport(config: Any) -> str:
    if not isinstance(config, dict):
        return "other"
    kind = config.get("type")
    if kind is None:
        if "command" in config:
            return "stdio"
        if "url" in config:
            return "http"
        return "other"
    return kind if kind in ("stdio", "http", "sse", "sdk") else "other"


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
