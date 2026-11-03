"""v0.18 §2: MCP Apps — a tool's ``ui://`` page, shown in the chat (``apps.v1``, plan rulings 20–28).

``AppHost`` is the gateway's side of it; the server calls into it at a few
points and it answers through the server (``broadcast``, ``emit``, the card
broker, the per-tool policy).

- **The UI map** (ruling 22), per engine: built from ``mcp_status()`` after
  the engine starts and after every Reconnect. For each tool: its
  ``_meta.ui.resourceUri`` (or the deprecated ``_meta["ui/resourceUri"]``),
  ``_meta.ui.visibility`` (default ``["model", "app"]``) and
  ``annotations.readOnly``; for each server its title (``serverInfo.title``,
  else the configured name, ruling 9). A server still ``pending`` when the
  map was read leaves it incomplete: a call to an MCP tool it does not know
  reads the status again (once per miss) before deciding.
- **Opening** (ruling 23): after ``tool.started`` for a tool with a page, the
  page is read (``mcp_app_read``, cached by server and URI per engine,
  retried while the server is ``pending`` for ``READ_RETRY_SECONDS``), then
  ``app.open`` goes out; only then the call's later events, so the wire reads
  ``tool.started`` → ``app.open`` → ``tool.finished`` → ``app.result``. The
  read never runs inside the engine's message pump: while it is in flight,
  the chat's later engine events wait in order in a backlog (the gate), and
  the SDK keeps reading the CLI. A read that fails turns apps off for that
  engine, logged once (ruling 21); its tools stay plain tool rows.
- **Records** (ruling 24): ``<state>/apps/<session_id>/<tool_use_id>.json``
  (folders 0700, files 0600: a result can hold personal data) keep what a
  replay and Reload need, never the HTML. A result over ``RESULT_CAP`` of
  JSON keeps ``content`` and drops ``structured_content``.
- **History** (ruling 25): each record comes back after its ``tool.finished``
  as ``app.open`` with no ``html`` (a frozen card), then ``app.result``.
- **Calls from the page** (ruling 27): checked in order (the record, the same
  server, offered to apps, consent) by the gateway itself: the CLI's
  ``mcp_call`` skips every permission check (§2.6.2).
- **Messages and context** (ruling 27): ``app.message`` is a typed message
  ``via`` the app; ``app.context`` is kept (latest per card, ``CONTEXT_CAP``)
  and goes first in the person's next message.

The ``app.*`` frames are not stamped and not kept in the ring: the HTML and
results are large, and the records already bring the cards back.
"""

from __future__ import annotations

import asyncio
import base64
import dataclasses
import json
import logging
import os
import html
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .engine import SHOW_SERVER
from .mcp_settings import normalise_server, strip_url_queries
from .messages import (
    APPS_CAPABILITY,
    AppCallResult,
    AppCallTool,
    AppCancelled,
    AppContext,
    AppMessage,
    AppOpen,
    AppReload,
    AppResult,
    Error,
    MessageSend,
    ProtocolError,
    ServerMessage,
    ToolFinished,
    ToolStarted,
)

__all__ = ["APPS_CAPABILITY", "AppHost"]

log = logging.getLogger(__name__)

# Ruling 24: the most JSON of a result a record keeps with its structured content.
RESULT_CAP = 4 * 1024 * 1024
# Ruling 27: the most of one app's context kept for the next message.
CONTEXT_CAP = 16_000
# Ruling 21 / §2.6.3: how long a read is retried while the server is still ``pending``.
READ_RETRY_SECONDS = 10.0
READ_RETRY_INTERVAL = 0.25
# The longest one read (or one status) may take before it counts as failed.
READ_TIMEOUT = 15.0

DEFAULT_VISIBILITY = ("model", "app")
RECORDS_DIR = "apps"
PENDING_MARK = "pending"

# Exact copy (ruling 27, AQ2).
UNKNOWN_APP = "Unknown app"
OTHER_SERVER = "That tool is on another server"
NOT_FOR_APPS = "That tool isn't offered to apps"
DENIED = "Denied"
NO_COMMANDS = "Apps can't run commands"
RELOAD_FAILED = "Couldn't reload: {}"
CONTEXT_NOTICE = "{} updated the context"
CONSENT = "The {} app wants to run {}"
FROM_CARD = " · from the card above"
APPS_OFF = "MCP Apps are off for this chat"
CALL_FAILED = "The call failed"
REASON_CHARS = 240


# A ``tool_use_id`` or session id used in a path: nothing that could leave the folder.
_SAFE_NAME = re.compile(r"^[A-Za-z0-9_-]{1,200}$")


# --- the UI map (ruling 22) -------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class ToolUi:
    """One tool as an app sees it."""

    server: str
    tool: str
    full: str
    resource_uri: str | None
    visibility: tuple[str, ...]
    read_only: bool
    description: str


@dataclasses.dataclass
class UiMap:
    # Keyed by (configured server, bare tool): two servers never share an entry.
    tools: dict[tuple[str, str], ToolUi] = dataclasses.field(default_factory=dict)
    # The full names Claude Code gives the tools, for the ones only one tool has.
    by_full: dict[str, ToolUi] = dataclasses.field(default_factory=dict)
    # Full names (and normalised server names) more than one server produces: no app
    # opens on them and no page may call them, since which server is meant is unknown.
    ambiguous_full: set[str] = dataclasses.field(default_factory=set)
    ambiguous_servers: set[str] = dataclasses.field(default_factory=set)
    titles: dict[str, str] = dataclasses.field(default_factory=dict)
    # False while a server was still connecting: its tools are not known yet.
    complete: bool = True

    def full(self, name: str) -> ToolUi | None:
        return self.by_full.get(name)


def server_title(status: dict[str, Any]) -> str:
    """Ruling 9: ``serverInfo.title`` when the status has one, else the configured name as written."""
    info = status.get("serverInfo")
    title = info.get("title") if isinstance(info, dict) else None
    return title if isinstance(title, str) and title.strip() else str(status.get("name") or "")


def _resource_uri(tool: dict[str, Any]) -> str | None:
    meta = tool.get("_meta")
    if not isinstance(meta, dict):
        return None
    ui = meta.get("ui")
    uri = ui.get("resourceUri") if isinstance(ui, dict) else None
    if not isinstance(uri, str):
        uri = meta.get("ui/resourceUri")  # the deprecated form
    return uri if isinstance(uri, str) and uri.startswith("ui://") else None


def _visibility(tool: dict[str, Any]) -> tuple[str, ...]:
    meta = tool.get("_meta")
    ui = meta.get("ui") if isinstance(meta, dict) else None
    seen = ui.get("visibility") if isinstance(ui, dict) else None
    if isinstance(seen, list) and all(isinstance(v, str) for v in seen):
        return tuple(seen)
    return DEFAULT_VISIBILITY


def build_ui_map(status: list[dict[str, Any]]) -> UiMap:
    """The UI map from ``mcp_status()``: every tool of every server Portico doesn't run itself."""
    out = UiMap()
    normalised: dict[str, str] = {}
    for server in status:
        name = server.get("name")
        if not isinstance(name, str) or not name or name == SHOW_SERVER:
            continue
        config = server.get("config")
        if isinstance(config, dict) and config.get("type") == "sdk":
            continue  # in-process servers never use apps (§2.2.6)
        short = normalise_server(name)
        if normalised.setdefault(short, name) != name:
            out.ambiguous_servers.add(short)
        out.titles[name] = server_title(server)
        if server.get("status") == "pending":
            out.complete = False
        tools = server.get("tools")
        for tool in tools if isinstance(tools, list) else []:
            if not isinstance(tool, dict) or not isinstance(tool.get("name"), str):
                continue
            bare = tool["name"]
            full = f"mcp__{short}__{bare}"
            annotations = tool.get("annotations")
            description = tool.get("description") if isinstance(tool.get("description"), str) else ""
            out.tools[(name, bare)] = ToolUi(
                server=name,
                tool=bare,
                full=full,
                resource_uri=_resource_uri(tool),
                visibility=_visibility(tool),
                read_only=isinstance(annotations, dict) and annotations.get("readOnly") is True,
                description=description,
            )
    for ui in out.tools.values():
        if ui.full in out.by_full and out.by_full[ui.full].server != ui.server:
            out.ambiguous_full.add(ui.full)
        out.by_full.setdefault(ui.full, ui)
    for full in out.ambiguous_full:
        del out.by_full[full]
    for short in out.ambiguous_servers:
        for full in [f for f in out.by_full if f.startswith(f"mcp__{short}__")]:
            out.ambiguous_full.add(full)
            del out.by_full[full]
    return out


# --- the page ---------------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Page:
    html: str
    csp: dict[str, Any] | None
    permissions: dict[str, Any] | None
    prefers_border: bool | None


def page_from_read(reply: Any) -> Page:
    """``mcp_read_resource``'s reply (``{contents: [{uri, mimeType, text?, blob?, _meta?}]}``) as a page; raises ``ValueError``."""
    contents = reply.get("contents") if isinstance(reply, dict) else None
    if not isinstance(contents, list) or not contents or not isinstance(contents[0], dict):
        raise ValueError("the server sent no page")
    item = contents[0]
    html = item.get("text")
    if not isinstance(html, str):
        blob = item.get("blob")
        if not isinstance(blob, str):
            raise ValueError("the server sent no page")
        html = base64.b64decode(blob).decode("utf-8")
    meta = item.get("_meta")
    ui = meta.get("ui") if isinstance(meta, dict) else None
    ui = ui if isinstance(ui, dict) else {}
    csp = ui.get("csp") if isinstance(ui.get("csp"), dict) else None
    permissions = ui.get("permissions") if isinstance(ui.get("permissions"), dict) else None
    border = ui.get("prefersBorder") if isinstance(ui.get("prefersBorder"), bool) else None
    return Page(html=html, csp=csp, permissions=permissions, prefers_border=border)


def _reason(e: BaseException) -> str:
    text = str(e).strip() or type(e).__name__
    return strip_url_queries(text)[:REASON_CHARS]


# --- records (ruling 24) -----------------------------------------------------------------------


@dataclasses.dataclass
class AppRecord:
    server: str
    tool: str
    resource_uri: str
    input: dict[str, Any]
    server_title: str
    csp: dict[str, Any] | None = None
    permissions: dict[str, Any] | None = None
    prefers_border: bool | None = None
    # ``{content, structured_content, is_error}`` (or ``structured_content_omitted``); ``None`` until it finishes.
    result: dict[str, Any] | None = None
    # The call ended with no result (``app.cancelled``).
    cancelled: bool = False

    def to_json(self) -> str:
        return json.dumps(dataclasses.asdict(self), ensure_ascii=False)

    @classmethod
    def from_json(cls, text: str) -> AppRecord | None:
        try:
            data = json.loads(text)
            if not isinstance(data, dict):
                return None
            fields = {f.name for f in dataclasses.fields(cls)}
            record = cls(**{k: v for k, v in data.items() if k in fields})
        except (ValueError, TypeError):
            return None
        if not all(isinstance(v, str) for v in (record.server, record.tool, record.resource_uri, record.server_title)):
            return None
        if not isinstance(record.input, dict):
            record.input = {}
        return record

    def finished(self) -> bool:
        return self.result is not None or self.cancelled


def result_of(raw: dict[str, Any], is_error: bool) -> dict[str, Any]:
    """A ``tool_use_result`` as a record keeps it; structured content over ``RESULT_CAP`` is dropped."""
    content = raw.get("content")
    content = [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []
    structured = raw.get("structuredContent")
    structured = structured if isinstance(structured, dict) else None
    out: dict[str, Any] = {"content": content, "structured_content": structured, "is_error": bool(raw.get("isError", is_error))}
    omitted = raw.get("structuredContentOmitted") is True
    if structured is not None and len(json.dumps(out, ensure_ascii=False)) > RESULT_CAP:
        omitted = True
    if omitted:
        out["structured_content"] = None
        out["structured_content_omitted"] = True
    return out


class RecordStore:
    """``<state>/apps/<session_id>/<tool_use_id>.json``: folders 0700, files 0600, written atomically."""

    def __init__(self, root: Path) -> None:
        self.root = Path(root) / RECORDS_DIR

    def _folder(self, session_id: str) -> Path | None:
        return self.root / session_id if _SAFE_NAME.match(session_id) else None

    def save(self, session_id: str, tool_use_id: str, record: AppRecord) -> None:
        folder = self._folder(session_id)
        if folder is None or not _SAFE_NAME.match(tool_use_id):
            return
        for path in (self.root, folder):
            path.mkdir(mode=0o700, exist_ok=True)
            os.chmod(path, 0o700)
        target = folder / f"{tool_use_id}.json"
        tmp = folder / f".{tool_use_id}.json.tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.fchmod(fd, 0o600)
            os.write(fd, record.to_json().encode("utf-8"))
        finally:
            os.close(fd)
        os.replace(tmp, target)

    def load(self, session_id: str, tool_use_id: str) -> AppRecord | None:
        folder = self._folder(session_id)
        if folder is None or not _SAFE_NAME.match(tool_use_id):
            return None
        try:
            return AppRecord.from_json((folder / f"{tool_use_id}.json").read_text(encoding="utf-8"))
        except OSError:
            return None


# --- per engine and per chat ------------------------------------------------------------------


class _EngineApps:
    """One engine's apps: its UI map (being read, or read), its page cache, whether apps are off for it."""

    def __init__(self, engine: Any) -> None:
        self.engine = engine
        self.map: UiMap | None = None
        self.map_task: asyncio.Task[None] | None = None
        self.pages: dict[tuple[str, str], Page] = {}
        self.off = False


@dataclasses.dataclass
class _Gate:
    """An open being read: the chat's later engine events wait here, in order."""

    backlog: list[ServerMessage]
    task: asyncio.Task[None] | None = None
    # Handing the held events on: never cancelled then (it may be mid-way through one).
    releasing: bool = False
    # Set by a stop: give up on the page and hand the held events on now (R-c16).
    abort: asyncio.Event = dataclasses.field(default_factory=asyncio.Event)


class AppHost:
    """The gateway's MCP Apps host. ``server`` is the ``GatewayServer`` (its emit, cards, policy and engines)."""

    def __init__(self, server: Any, state_path: Path, enabled: bool) -> None:
        self.server = server
        self.enabled = enabled
        self.records = RecordStore(state_path)
        self._engines: dict[int, _EngineApps] = {}
        self._gates: dict[int, _Gate] = {}
        # Per chat: tool_use_id -> record, for this launch (the disk has every launch's).
        self._live: dict[int, dict[str, AppRecord]] = {}
        # Per chat: tool_use_id -> (server, text), the latest context per card; and who was noticed.
        self._context: dict[int, dict[str, tuple[str, str]]] = {}
        self._noticed: dict[int, set[str]] = {}
        self._ambiguous_logged: set[tuple[int, str]] = set()

    # --- engines ----------------------------------------------------------------

    def engine_started(self, chat: Any, engine: Any) -> None:
        """After an engine starts: read its UI map in the background."""
        self._drop_gate(chat.number)
        if not self.enabled or not getattr(engine, "apps_capable", False):
            self._engines.pop(chat.number, None)
            return
        apps = _EngineApps(engine)
        self._engines[chat.number] = apps
        self._read_map(chat.number, apps)

    async def engine_closed(self, chat: Any) -> None:
        """The engine went: a page being read and the events held behind it go too, and every
        card whose call never finished is cancelled (saved so, so a replay doesn't show it running)."""
        self._drop_gate(chat.number)
        apps = self._engines.pop(chat.number, None)
        if apps is not None and apps.map_task is not None and not apps.map_task.done():
            apps.map_task.cancel()
        for tool_use_id, record in list(self._live.get(chat.number, {}).items()):
            if record.finished():
                continue
            record.cancelled = True
            self._save(chat, tool_use_id, record)
            await self.server.broadcast(self._result_frame(chat.number, tool_use_id, record))

    def engine_reconnected(self, engine: Any) -> None:
        """Ruling 22: after a Reconnect, read that engine's UI map again."""
        for number, apps in self._engines.items():
            if apps.engine is engine:
                self._read_map(number, apps)

    def _read_map(self, chat: int, apps: _EngineApps) -> None:
        async def read() -> None:
            try:
                status = await asyncio.wait_for(apps.engine.mcp_status(), READ_TIMEOUT)
            except Exception as e:
                log.warning("chat %d: could not read the MCP status for apps: %s", chat, type(e).__name__)
                if apps.map is None:
                    apps.map = UiMap(complete=False)
                return
            apps.map = build_ui_map([s for s in status if isinstance(s, dict)])

        apps.map_task = self.server._spawn(read(), name=f"portico-apps-map-{chat}")

    def _apps_for(self, chat: Any) -> _EngineApps | None:
        apps = self._engines.get(chat.number)
        if apps is None or apps.engine is not chat.engine:
            return None
        return apps

    async def _lookup(self, chat: int, apps: _EngineApps, full: str) -> ToolUi | None:
        """The tool in the engine's UI map; an incomplete map is read again on a miss."""
        task = apps.map_task
        if task is not None and not task.done():
            try:
                await asyncio.shield(task)
            except Exception:
                pass
        ui_map = apps.map
        if ui_map is not None and (full in ui_map.by_full or full in ui_map.ambiguous_full or ui_map.complete):
            return ui_map.full(full)
        self._read_map(chat, apps)
        try:
            await asyncio.shield(apps.map_task)  # type: ignore[arg-type]
        except Exception:
            pass
        return apps.map.full(full) if apps.map is not None else None

    # --- the gate: engine events wait while a page is read ------------------------------

    def holding(self, chat: int) -> bool:
        return chat in self._gates

    def hold(self, chat: int, event: ServerMessage) -> None:
        self._gates[chat].backlog.append(event)

    def _drop_gate(self, chat: int) -> None:
        gate = self._gates.pop(chat, None)
        if gate is None:
            return
        gate.backlog.clear()
        task = gate.task
        if task is not None and not gate.releasing and task is not asyncio.current_task() and not task.done():
            task.cancel()

    def _may_open(self, chat: Any, event: ToolStarted) -> bool:
        if not self.enabled or event.agent_id is not None:
            return False
        if not event.tool.startswith("mcp__") or event.tool.startswith(f"mcp__{SHOW_SERVER}__"):
            return False
        apps = self._apps_for(chat)
        if apps is None or apps.off:
            return False
        ui_map = apps.map
        if ui_map is not None and (apps.map_task is None or apps.map_task.done()):
            ui = ui_map.full(event.tool)
            if ui is not None:
                return ui.resource_uri is not None
            if ui_map.complete or event.tool in ui_map.ambiguous_full:
                return False
        return True  # not known yet: the open task decides

    def tool_started(self, chat: Any, event: ToolStarted) -> None:
        """After ``tool.started`` went out: for an app tool, read the page with the chat's later events held."""
        if not self._may_open(chat, event):
            return
        previous = self._gates.get(chat.number)
        gate = _Gate(backlog=previous.backlog if previous is not None else [])
        self._gates[chat.number] = gate
        gate.task = self.server._spawn(self._open_then_release(chat, event, gate), name=f"portico-app-open-{chat.number}")

    def abort_open(self, chat: int) -> None:
        """R-c16: a stop gives up on a page being read; the held events go on at once (a plain tool row)."""
        gate = self._gates.get(chat)
        if gate is not None and not gate.releasing:
            gate.abort.set()

    async def _open_then_release(self, chat: Any, event: ToolStarted, gate: _Gate) -> None:
        # R-c16: one deadline over the lookup and the read; a stop ends it at once.
        resolve = asyncio.ensure_future(self._resolve(chat, event))
        abort = asyncio.ensure_future(gate.abort.wait())
        found: tuple[_EngineApps, ToolUi, Page] | None = None
        try:
            done, _ = await asyncio.wait({resolve, abort}, timeout=READ_RETRY_SECONDS, return_when=asyncio.FIRST_COMPLETED)
            if resolve in done:
                try:
                    found = resolve.result()
                except Exception:
                    log.exception("chat %d: opening the app for %s failed", chat.number, event.tool)
            elif abort in done:
                log.info("chat %d: stopped while reading the page for %s; a plain tool row", chat.number, event.tool)
            else:
                apps = self._apps_for(chat)
                if apps is not None and not apps.off:
                    apps.off = True
                    log.warning(
                        "MCP Apps are off for chat %d: the page for %s took over %.0f s", chat.number, event.tool, READ_RETRY_SECONDS
                    )
        finally:
            for task in (resolve, abort):
                if not task.done():
                    task.cancel()
        if found is not None:
            try:
                await self._show(chat, event, *found)
            except Exception:
                log.exception("chat %d: showing the app for %s failed", chat.number, event.tool)
        gate.releasing = True
        while self._gates.get(chat.number) is gate:
            if not gate.backlog:
                del self._gates[chat.number]
                return
            held = gate.backlog.pop(0)
            try:
                await self.server.engine_event_now(chat, held)
            except Exception:
                log.exception("chat %d: a held engine event failed", chat.number)

    async def _resolve(self, chat: Any, event: ToolStarted) -> tuple[_EngineApps, ToolUi, Page] | None:
        """The tool's UI and its page, or ``None`` (not an app, or the read failed: apps off for the engine)."""
        apps = self._apps_for(chat)
        if apps is None or apps.off:
            return None
        ui = await self._lookup(chat.number, apps, event.tool)
        if ui is None or ui.resource_uri is None:
            return None
        try:
            page = await self._page(apps, ui.server, ui.resource_uri)
        except Exception as e:
            if not apps.off:
                apps.off = True
                log.warning("MCP Apps are off for chat %d: %s", chat.number, _reason(e))
            return None
        return apps, ui, page

    async def _show(self, chat: Any, event: ToolStarted, apps: _EngineApps, ui: ToolUi, page: Page) -> None:
        assert ui.resource_uri is not None
        title = apps.map.titles.get(ui.server, ui.server) if apps.map is not None else ui.server
        record = AppRecord(
            server=ui.server,
            tool=ui.tool,
            resource_uri=ui.resource_uri,
            input=dict(event.input),
            server_title=title,
            csp=page.csp,
            permissions=page.permissions,
            prefers_border=page.prefers_border,
        )
        self._live.setdefault(chat.number, {})[event.tool_use_id] = record
        self._save(chat, event.tool_use_id, record)
        log.info("chat %d: app %s · %s opened", chat.number, ui.server, ui.tool)
        await self.server.broadcast(self._open_frame(chat.number, event.tool_use_id, record, page.html))

    async def _page(self, apps: _EngineApps, server: str, uri: str, fresh: bool = False) -> Page:
        """The page, from the cache unless ``fresh``; read with retries while the server is still connecting."""
        key = (server, uri)
        if not fresh and key in apps.pages:
            return apps.pages[key]
        loop = asyncio.get_running_loop()
        deadline = loop.time() + READ_RETRY_SECONDS
        while True:
            try:
                reply = await asyncio.wait_for(apps.engine.mcp_app_read(server, uri), READ_TIMEOUT)
                break
            except Exception as e:
                if PENDING_MARK not in str(e) or loop.time() >= deadline:
                    raise
            await asyncio.sleep(READ_RETRY_INTERVAL)
        page = page_from_read(reply)
        apps.pages[key] = page
        return page

    # --- results (rulings 24 and 28) ----------------------------------------------------

    async def tool_finished(self, chat: Any, event: ToolFinished) -> None:
        """After ``tool.finished`` went out: the card's ``app.result`` (or ``app.cancelled``), saved first."""
        record = self._live.get(chat.number, {}).get(event.tool_use_id)
        if record is None or record.finished():
            return
        raw = event.raw_result
        if raw is None:
            record.cancelled = True
        else:
            record.result = result_of(raw, not event.ok)
        self._save(chat, event.tool_use_id, record)
        await self.server.broadcast(self._result_frame(chat.number, event.tool_use_id, record))

    def _save(self, chat: Any, tool_use_id: str, record: AppRecord) -> None:
        session = chat.session_id
        if not session:
            return  # kept in memory; saved once the session has a name (the result's save)
        try:
            self.records.save(session, tool_use_id, record)
        except OSError as e:
            log.warning("chat %d: could not save the app record: %s", chat.number, type(e).__name__)

    @staticmethod
    def _open_frame(chat: int, tool_use_id: str, record: AppRecord, html: str | None, id: str | None = None) -> AppOpen:
        return AppOpen(
            ts=_now(),
            chat=chat,
            id=id,
            tool_use_id=tool_use_id,
            server=record.server,
            server_title=record.server_title,
            tool=record.tool,
            resource_uri=record.resource_uri,
            html=html,
            csp=record.csp,
            permissions=record.permissions,
            prefers_border=record.prefers_border,
            input=dict(record.input),
        )

    @staticmethod
    def _result_frame(chat: int, tool_use_id: str, record: AppRecord) -> AppResult | AppCancelled:
        result = record.result
        if result is None:
            return AppCancelled(ts=_now(), chat=chat, tool_use_id=tool_use_id)
        return AppResult(
            ts=_now(),
            chat=chat,
            tool_use_id=tool_use_id,
            content=list(result.get("content") or []),
            structured_content=result.get("structured_content"),
            is_error=bool(result.get("is_error")),
        )

    def record(self, chat: Any, tool_use_id: str) -> AppRecord | None:
        """The card's record: this launch's, else the saved one for the chat's session."""
        live = self._live.get(chat.number, {}).get(tool_use_id)
        if live is not None:
            return live
        return self.records.load(chat.session_id, tool_use_id) if chat.session_id else None

    # --- history (ruling 25) ------------------------------------------------------------

    def replay(self, chat: Any, events: list[ServerMessage]) -> list[ServerMessage]:
        """``events`` with each card's frames after its ``tool.finished`` (after ``tool.started`` while it runs)."""
        if not self.enabled:
            return events
        live = self._live.get(chat.number, {})
        records: dict[str, AppRecord] = {}
        tried: set[str] = set()
        for e in events:
            if not isinstance(e, (ToolStarted, ToolFinished)) or e.tool_use_id in tried:
                continue
            tried.add(e.tool_use_id)
            if isinstance(e, ToolStarted) and not e.tool.startswith("mcp__"):
                continue  # only an MCP tool can have opened a card
            found = live.get(e.tool_use_id)
            if found is None and chat.session_id:
                found = self.records.load(chat.session_id, e.tool_use_id)
            if found is not None:
                records[e.tool_use_id] = found
        if not records:
            return events
        finished = {e.tool_use_id for e in events if isinstance(e, ToolFinished)}
        out: list[ServerMessage] = []
        for e in events:
            out.append(e)
            if isinstance(e, ToolStarted) and e.tool_use_id in records and e.tool_use_id not in finished:
                record = records[e.tool_use_id]
                out.append(self._open_frame(chat.number, e.tool_use_id, record, None))
                if record.finished():  # its engine went before the call finished: cancelled
                    out.append(self._result_frame(chat.number, e.tool_use_id, record))
            elif isinstance(e, ToolFinished) and e.tool_use_id in records:
                record = records[e.tool_use_id]
                out.append(self._open_frame(chat.number, e.tool_use_id, record, None))
                if record.finished():
                    out.append(self._result_frame(chat.number, e.tool_use_id, record))
        return out

    # --- calls from the page (ruling 27) ------------------------------------------------

    async def call_tool(self, chat: Any, msg: AppCallTool, conn: Any) -> None:
        """Answer ``app.call_tool`` with ``app.call_result`` (the request's ``id``). Runs as a task: consent waits."""
        record = self.record(chat, msg.tool_use_id) if chat.ended is None else None
        if record is None:
            reply, outcome, server = self._call_failed(chat, msg, UNKNOWN_APP), "unknown app", "?"
        else:
            reply, outcome = await self._call(chat, msg, record)
            server = record.server
        # The spec's audit SHOULD: every call from a page, at info.
        log.info("chat %d: app call from %s: %s → %s", chat.number, server, msg.tool, outcome)
        await self.server._send(conn, reply)

    @staticmethod
    def _call_failed(chat: Any, msg: AppCallTool, error: str) -> AppCallResult:
        return AppCallResult(ts=_now(), chat=chat.number, id=msg.id, tool_use_id=msg.tool_use_id, ok=False, error=error)

    async def _call(self, chat: Any, msg: AppCallTool, record: AppRecord) -> tuple[AppCallResult, str]:
        """The checks in ruling 27's order, then the call: ``(reply, outcome for the log)``."""
        prefix = f"mcp__{normalise_server(record.server)}__"
        full = msg.tool if msg.tool.startswith("mcp__") else prefix + msg.tool
        if not full.startswith(prefix):
            return self._call_failed(chat, msg, OTHER_SERVER), "another server"
        try:
            engine = await self.server._ensure_engine(chat)
        except ProtocolError as e:
            return self._call_failed(chat, msg, e.message), "no engine"
        apps = self._apps_for(chat)
        ui_map = apps.map if apps is not None else None
        ui = await self._lookup(chat.number, apps, full) if apps is not None else None
        ui_map = apps.map if apps is not None else ui_map
        short = normalise_server(record.server)
        if ui_map is not None and (full in ui_map.ambiguous_full or short in ui_map.ambiguous_servers):
            # Two servers give this name: which one would run is not certain.
            if (chat.number, full) not in self._ambiguous_logged:
                self._ambiguous_logged.add((chat.number, full))
                log.warning("chat %d: refused app calls to %s: more than one server has that name", chat.number, full)
            return self._call_failed(chat, msg, OTHER_SERVER), "ambiguous server"
        if ui is not None and ui.server != record.server:
            # ``mcp__acme__evil__wipe`` starts like acme's, but is server ``acme__evil``'s.
            return self._call_failed(chat, msg, OTHER_SERVER), "another server"
        if ui is None or "app" not in ui.visibility:
            return self._call_failed(chat, msg, NOT_FOR_APPS), "not offered to apps"
        if not await self._consent(chat, record, ui, msg.arguments):
            return self._call_failed(chat, msg, DENIED), "denied"
        # A consent card can stay open a long time: a Reconnect (or a new engine) meanwhile may have
        # changed what the name runs. Checked again with no wait between it and the call.
        if not self._still_the_same(chat, engine, record, full, ui):
            return self._call_failed(chat, msg, OTHER_SERVER), "changed during consent"
        try:
            result = await engine.mcp_app_call(full, dict(msg.arguments))
        except Exception as e:
            # R-c17: the page hears only that it failed; the detail stays in the log.
            return self._call_failed(chat, msg, CALL_FAILED), f"failed ({type(e).__name__}: {_reason(e)})"
        result = result if isinstance(result, dict) else {}
        content = result.get("content")
        structured = result.get("structuredContent")
        reply = AppCallResult(
            ts=_now(),
            chat=chat.number,
            id=msg.id,
            tool_use_id=msg.tool_use_id,
            ok=True,
            content=[b for b in content if isinstance(b, dict)] if isinstance(content, list) else [],
            structured_content=structured if isinstance(structured, dict) else None,
            is_error=result.get("isError") is True,
        )
        return reply, "ran"

    def _still_the_same(self, chat: Any, engine: Any, record: AppRecord, full: str, ui: ToolUi) -> bool:
        apps = self._apps_for(chat)
        if apps is None or apps.engine is not engine or apps.map is None:
            return False
        ui_map = apps.map
        if full in ui_map.ambiguous_full or normalise_server(record.server) in ui_map.ambiguous_servers:
            return False
        now = ui_map.full(full)
        return now is not None and now.server == record.server == ui.server and "app" in now.visibility

    async def _consent(self, chat: Any, record: AppRecord, ui: ToolUi, arguments: dict[str, Any]) -> bool:
        """§2.4: read-only runs unless the policy says ask; else the session's allows, else the permission card."""
        server = self.server
        if server.tool_policy.effective(ui.server, ui.tool, ui.read_only) == "allow":
            return True
        if server.cards.allowed(chat, ui.full, arguments):
            return True
        from .cards import permission_card  # the card the agent's own calls get

        text = CONSENT.format(record.server_title, ui.tool)
        what = ui.description.strip().split("\n", 1)[0].strip()[:80] or ui.tool
        card = permission_card(
            chat.number, ui.full, dict(arguments), None, chat.folder, [],
            thread=chat.thread is not None, threads_on=server.cards.threads_on,
        )
        assert card.permission is not None
        card = card.model_copy(
            update={
                "title": text,
                "permission": card.permission.model_copy(update={"summary": text}),
                "scope_note": what + FROM_CARD,
            }
        )
        try:
            answer = await server.cards.ask(chat, card, server._emit_card)
        finally:
            await self._settle_state(chat)
        if answer.answer.get("decision") != "allow":
            return False
        if answer.scope in ("chat", "always"):
            # The same key as the agent's own calls to that tool (``chat_allows``).
            chat.chat_allows.update(server.cards.chat_allow_keys(ui.full, dict(arguments), [], chat.folder))
            server.registry.persist()
        return True

    async def _settle_state(self, chat: Any) -> None:
        """After a page's card: back to ``working`` while a turn runs, else ``idle``, once no card is open."""
        server = self.server
        if chat.state == "waiting on you" and not server.cards.open_cards(chat):
            await server.set_state(chat, "working" if chat.number in server._runs else "idle")

    # --- messages and context -----------------------------------------------------------

    async def message(self, chat: Any, msg: AppMessage, conn: Any) -> None:
        """``app.message``: the person's message, ``via`` the app; a command is refused (ruling 27)."""
        record = self.record(chat, msg.tool_use_id)
        if record is None:
            raise ProtocolError("app.unknown", UNKNOWN_APP)
        if msg.text.lstrip().startswith("/"):
            log.info("chat %d: refused a command from the %s app", chat.number, record.server)
            raise ProtocolError("app.refused", NO_COMMANDS)
        send = MessageSend(ts=msg.ts, chat=chat.number, id=msg.id, text=msg.text)
        await self.server.send_or_queue(chat, send, conn, via=record.server_title)

    async def context(self, chat: Any, msg: AppContext) -> None:
        """``app.context``: the latest per card, cut to ``CONTEXT_CAP``; the first since the last message is noticed."""
        record = self.record(chat, msg.tool_use_id)
        if record is None:
            raise ProtocolError("app.unknown", UNKNOWN_APP)
        self._context.setdefault(chat.number, {})[msg.tool_use_id] = (record.server, msg.text[:CONTEXT_CAP])
        # Once per app (its server) between two messages.
        noticed = self._noticed.setdefault(chat.number, set())
        if record.server not in noticed:
            noticed.add(record.server)
            await self.server.notice(chat, CONTEXT_NOTICE.format(record.server_title))

    def take_context(self, chat: Any) -> dict[str, tuple[str, str]]:
        """The kept context blocks for the person's next message (``render`` them); cleared."""
        blocks = self._context.pop(chat.number, {})
        self._noticed.pop(chat.number, None)
        return blocks

    def put_back(self, chat: Any, blocks: dict[str, tuple[str, str]]) -> None:
        """R-c17: the message they were taken for never went; a newer update from the same card wins."""
        if not blocks:
            return
        kept = self._context.setdefault(chat.number, {})
        for tool_use_id, block in blocks.items():
            kept.setdefault(tool_use_id, block)

    @staticmethod
    def render(blocks: dict[str, tuple[str, str]]) -> str:
        """The blocks as the engine reads them. R-c19: the page's text can't close the block (and so
        speak as the person) in any spelling: every ``&``, ``<`` and ``>`` in it is escaped (the engine
        is a model, not an XML parser); the server name is escaped too."""
        return "".join(
            f'<app-context server="{html.escape(server, quote=True)}">\n{_escape_text(text)}\n</app-context>\n\n'
            for server, text in blocks.values()
        )

    # --- reload (ruling 26) ----------------------------------------------------------------

    async def reload(self, chat: Any, msg: AppReload, conn: Any) -> None:
        """``app.reload``: read the page again (starting the engine first if needed), then ``app.open`` and ``app.result``."""

        async def fail(reason: str) -> None:
            await self.server._send(
                conn, Error(ts=_now(), chat=chat.number, id=msg.id, code="app.reload_failed", message=RELOAD_FAILED.format(reason))
            )

        record = self.record(chat, msg.tool_use_id) if chat.ended is None else None
        if record is None or not self.enabled:
            await fail(UNKNOWN_APP)
            return
        try:
            await self.server._ensure_engine(chat)
        except ProtocolError as e:
            await fail(e.message)
            return
        apps = self._apps_for(chat)
        if apps is None:
            await fail(APPS_OFF)
            return
        try:
            page = await self._page(apps, record.server, record.resource_uri, fresh=True)
        except Exception as e:
            log.info("chat %d: reloading the %s app failed: %s", chat.number, record.server, _reason(e))
            await fail(_reason(e))
            return
        record.csp, record.permissions, record.prefers_border = page.csp, page.permissions, page.prefers_border
        self._live.setdefault(chat.number, {})[msg.tool_use_id] = record
        self._save(chat, msg.tool_use_id, record)
        await self.server._send(conn, self._open_frame(chat.number, msg.tool_use_id, record, page.html, id=msg.id))
        if record.finished():
            await self.server._send(conn, self._result_frame(chat.number, msg.tool_use_id, record).model_copy(update={"id": msg.id}))


def _escape_text(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
