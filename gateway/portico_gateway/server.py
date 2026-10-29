"""The gateway's front door: one WebSocket for the app, plain HTTP on the same port.

- The app connects to ``ws://127.0.0.1:<port>/v1?token=<token>``. A connect
  without the per-launch token is refused with HTTP 401 before the upgrade.
- The first frame must be ``hello``; the gateway answers ``hello`` then
  ``chat.list``. Anything else first gets ``error code=protocol.hello_required``
  and the socket is closed.
- One app at a time: a second connect replaces the first, which is told
  ``error code=session.replaced`` and closed.
- Plain HTTP on the same port serves ``GET /v1/health`` (no token) and, from
  Task 9, the artifact producer ``POST /v1/artifact``. The ``websockets``
  package only parses handshake requests (it refuses any request body), so
  a connection that is not an upgrade is answered by this module's own
  small HTTP/1.1 reader before ``websockets`` ever sees it.
- ``serve`` prints ``PORTICO_READY port=<n>`` on stdout once listening and
  writes the ledger; the app's supervisor reads that line when it launches
  the gateway itself and the ledger when it discovers a running one.

Message handlers register by type name (``register``). Task 6 wired the
handshake and the dispatch table; Task 7 added the chat and turn handlers
(``chat.new``, ``chat.open``, ``chat.stop``, ``chat.alias``, ``chat.remove``,
``message.send``, ``turn.stop``) and the per-chat engine callbacks that
stamp every engine event with the chat's ``seq`` and broadcast it.

A turn, as the gateway runs it: ``message.send`` emits ``turn.started``,
``user.text`` (the text as the engine receives it) and ``chat.state
working``, then hands the text to the engine; the engine's
events stream through ``engine_event``; its ``turn.finished`` ends the turn
and the chat goes back to ``idle``. ``turn.stop`` interrupts the engine and
the finish that follows is reported as ``outcome=stopped`` (synthesised,
and the wedged engine closed, if it never sends one within a grace
period). ``chat.stop`` closes the engine outright; a later send starts a
fresh engine resuming the same session.

Cards (Task 8): a permission or question from the engine goes through the
``CardBroker`` (``cards.py``). The chat is ``waiting on you`` while a card
is open and back to ``working`` once it resolves with the turn still
running; ``card.answer`` resolves it (``card.answered`` goes in the ring so
a replay closes the card too), ``turn.stop`` / ``chat.stop`` /
``chat.remove`` / gateway stop cancel it (``card.cancel`` with the reason),
and a card held while no app is attached is denied after the hold with
``nobody was there to answer``. ``chat.open`` re-sends the chat's open
cards after ``chat.live``. Nothing is ever allowed by default.

Artifacts (Task 9): every turn has a ``TurnCollector`` (``artifacts.py``)
fed from the engine's ``tool.started`` and ``text.delta`` events. When the
turn ends — the engine's own finish, or the one the gateway synthesises on
``turn.stop`` / ``chat.stop`` — the collector settles, each artifact is
sent as ``artifact.created`` (stamped, in the ring, in the index) just
before ``turn.finished``, with ``open`` on the newest viewable one only.
``POST /v1/artifact`` (``Authorization: Bearer <token>``, body ``{chat,
location, title?}``) is the producer seam: its artifact is reported at
once with ``open=true``. ``artifact.opened`` from the app is telemetry
and is acknowledged with nothing.

History (Task 10): ``chat.open`` replays from the ring when the ring can
serve ``since`` (or the chat was created this launch and nothing has
fallen off); otherwise — first open after a gateway restart, or ``since``
older than the ring — the engine's transcript is read (``read_history``)
and translated (``history_events``) into ``chat.history``, the chat's
stored artifacts follow as ``artifact.created open=false``, then
``chat.live``. A missing transcript is an empty history, not an error.

Files (Task 12): ``files.list {root, path}`` answers with the entries of
one directory — directories first, names in case-insensitive order,
hidden entries skipped. ``root`` is a name from ``hello.roots`` or
``chat`` (the chat's own folder, with ``chat`` set); ``path`` is relative
to it. A path that leaves the root once ``..`` and symlinks are resolved
is ``error code=files.outside_root``; a root name the gateway does not
offer is ``files.unknown_root``; a path that is not an existing directory
is ``files.not_found``. The reply is a direct answer (``id``), not a
history event: it carries no ``seq``.

Lifecycle (Task 11): the deployment's ``before_first_chat`` command runs
once per gateway launch, before the first engine starts (``chat.new``, or
``message.send`` on a chat restored from the index); its
lines go to the app as chat-less ``status.set`` frames, and a non-zero
exit or a timeout answers the request with
``error code=lifecycle.before_first_chat_failed`` (carrying the command's
last line) and creates no chat, so the next ``chat.new`` tries again.
``gateway.stop`` from the app, or SIGTERM/SIGINT to the process, takes
``stop``: every running turn is interrupted and reported
(``turn.finished outcome=stopped``, ``chat.state idle``), every engine is
closed, ``on_stop`` runs with its lines as ``status.set``, the index is
persisted, and ``stopping`` is set for the main loop to ``shutdown`` and
exit 0. Quitting the app only detaches; stopping is this explicit path.

Sessions (v0.2): a session is a chat. ``session.renew`` is checked in its
handler and run as a task (its log step is a whole turn, and the frames
that answer that turn's cards must still be read): the log step —
a plug-in's ``on_renew``, else ``log_prompt`` sent as a message — runs as
an ordinary turn, then the chat is ended and the next one created in the
same folder with ``parent`` set; ``chat.state`` for both, then
``session.renewed``, then ``chat.list``. In ``single`` presentation
``chat.new`` is refused while a session is live. After every turn the
engine's context reading goes out as ``context.usage`` (from its own task:
a failure is logged and skipped); its ``PreCompact`` hook becomes a stamped
``chat.compacted``. ``files.search`` answers from Spotlight under a root
(``search.py``) or from a plug-in's ``search``.

Logging and services (v0.4): ``session.log`` runs the same log step in the
live session without ending it (as a task, like a renewal; sends are
``chat.busy`` meanwhile) and answers ``session.logged`` then ``chat.list``.
Every finished turn marks the session as having unlogged work; a log step
that finishes cleanly (by ``session.log`` or a renewal) sets ``logged_at``
and clears it, and ``ChatSummary.unlogged`` is that mark when the
deployment can log. The ``ServiceMonitor`` (``services.py``) runs the
deployment's ``[[services]]`` checks; every connection gets
``services.status`` right after ``hello`` and ``chat.list``, and every
change is broadcast. ``service.restart`` runs a service's restart command
and checks it again.

Titles and the deployment's services (v0.8): when a session's first turn
(a ``message.send``, never a log step or an unknown command's empty turn)
finishes ``done``, a background task asks the ``titler`` (``titles.py``)
for a title; it replaces the first-line title, is persisted, and goes out
in ``chat.list``. It never replaces an alias or a title set any other way,
and a failure leaves the first line. ``titles = "first_line"`` or no
``titler`` makes no call. The services come from a plug-in's
``services_status``, else ``[deployment] status``, else the
``[[services]]`` checks; ``services.restart_all`` runs a plug-in's
``restart_services``, else ``[deployment] restart``, and is answered by
the ``services.status`` that follows (plus ``error
code=services.restart_failed`` when it failed).
"""

from __future__ import annotations

import asyncio
import http
import json
import logging
import os
import re
import secrets
import uuid
from collections.abc import Awaitable, Callable, Coroutine
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

from websockets.asyncio.server import Server, ServerConnection, serve
from websockets.exceptions import ConnectionClosed
from websockets.http11 import Request, Response
from websockets.server import ServerProtocol

from .artifacts import TurnCollector, artifact_for_location
from .cards import CardBroker
from .chats import Chat, ChatRegistry, UnknownChat, title_from
from .config import Config, hello_for
from .engine import READ_ONLY_TOOLS, Engine, PermissionDecision, friendly_model_name, history_events, read_history
from .lifecycle import CommandFailed, run_lifecycle_command
from .messages import (
    PROTOCOL_VERSION,
    Artifact,
    ArtifactCreated,
    ArtifactOpened,
    CardAnswer,
    CardAnswered,
    CardAsk,
    ChatAlias,
    ChatCompacted,
    ChatHistory,
    ChatList,
    ChatLive,
    ChatNotice,
    ChatNew,
    ChatOpen,
    ChatRemove,
    ChatState,
    ChatStateWord,
    ConfigStale,
    ChatStop,
    ClientMessage,
    ContextUsage,
    Entry,
    Envelope,
    Error,
    FilesList,
    FilesListRequest,
    FilesResults,
    FilesSearch,
    GatewayStop,
    HelloClient,
    MessageSend,
    Outcome,
    ProtocolError,
    ServerMessage,
    Service,
    ServiceRestart,
    ServicesRestartAll,
    ServicesStatus,
    SessionLog,
    SessionLogged,
    SessionMode,
    SessionRenew,
    SessionRenewed,
    StatusSet,
    TextDelta,
    ToolFinished,
    ToolStarted,
    TurnFinished,
    TurnStarted,
    TurnStop,
    UpdateAvailable,
    UserText,
    dump,
    parse_client,
)
from .plugins import Plugins, RenewContext
from .search import Runner, clean_hits, run_command, search_files
from .services import ServiceMonitor, command_restart, command_status, hook_restart, hook_status
from .state import StateDir
from .titles import REPLY_CHARS, TITLE_TIMEOUT, Titler, generate_title
from .update import UPDATE_CHECK_SECONDS, check_for_update

log = logging.getLogger(__name__)

HOST = "127.0.0.1"
PROTOCOL_PATH = "/v1"
READY_PREFIX = "PORTICO_READY"

# Plain-HTTP limits: a producer call is a small JSON object, a health probe
# has no body at all. Anything larger is not ours.
HTTP_HEAD_LIMIT = 64 * 1024
HTTP_BODY_LIMIT = 4 * 1024 * 1024
HTTP_BODY_TIMEOUT = 10.0

# WebSocket close codes (RFC 6455 §7.4.1).
CLOSE_GOING_AWAY = 1001
CLOSE_PROTOCOL_ERROR = 1002
CLOSE_POLICY = 1008

# How often the gateway looks at the config file's modification time.
CONFIG_CHECK_SECONDS = 10.0

# After ``turn.stop`` the engine is given this long to send its own
# ``turn.finished``; then the gateway ends the turn itself, and closes the
# engine, so the app is never left on a turn that cannot finish.
STOP_GRACE_SECONDS = 15.0

# The exact form attachments take in the text the engine receives
# (PROTOCOL.md, ``message.send``).
ATTACHMENT_HEADER = "Attached files:"

# A message that starts with a slash command: ``/word`` (``plugin:word``
# too) followed by a blank or the end. ``/Users/...`` is a path, not one.
SLASH_COMMAND = re.compile(r"^/([A-Za-z0-9][\w:.-]*)(?:\s|$)")

# Portico's own commands, which the app acts on (``/new`` renews the
# session, ``/log`` logs it without ending it: v0.4).
PORTICO_COMMANDS: frozenset[str] = frozenset({"new", "log"})

# The ``chat.notice`` a log step that did not finish cleanly leaves (v0.7).
LOG_STEP_UNFINISHED = "The log step didn't finish; the session isn't logged"


def slash_command(text: str) -> str | None:
    """The command a message starts with (without ``/``), or ``None``.

    A word that reads as a path is not a command: one with a ``.`` in it
    (``/file.md summarize``), or one that names something on disk at the
    root (``/tmp please summarize``, ``/etc``). The message goes through.
    """
    m = SLASH_COMMAND.match(text.lstrip())
    if not m:
        return None
    word = m.group(1)
    if "." in word or os.path.lexists("/" + word):
        return None
    return word


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _frame_type(raw: str | bytes) -> str | None:
    """The ``type`` of a frame without parsing it fully; ``None`` when it has none."""
    try:
        obj = json.loads(raw)
    except (ValueError, TypeError):
        return None
    if not isinstance(obj, dict):
        return None
    kind = obj.get("type")
    return kind if isinstance(kind, str) else None


# --- turns: helpers ----------------------------------------------------------


def with_attachments(text: str, attachments: list[str]) -> str:
    """``text`` with the attachment block appended; unchanged when there are none."""
    if not attachments:
        return text
    return text + "\n\n" + ATTACHMENT_HEADER + "\n" + "\n".join(f"- {path}" for path in attachments)


def check_attachments(paths: list[str]) -> list[str]:
    """Every attachment must be an absolute path to an existing file; otherwise ``attachment.missing``."""
    checked: list[str] = []
    for raw in paths:
        path = Path(raw)
        if not path.is_absolute():
            raise ProtocolError("attachment.missing", f"attachment path is not absolute: {raw}")
        if path.is_dir():
            raise ProtocolError("attachment.missing", f"attachment is a directory, not a file: {raw}")
        if not path.is_file():
            raise ProtocolError("attachment.missing", f"attachment does not exist: {raw}")
        checked.append(str(path))
    return checked


# --- files: helpers -----------------------------------------------------------

# The chat's own folder is always offered under this root name, next to the
# deployment's ``roots`` from config.
CHAT_ROOT = "chat"


def list_directory(root: Path, rel: str) -> tuple[str, list[Entry]]:
    """List ``rel`` under ``root``: dirs first, names case-insensitive, hidden skipped.

    Returns the normalised relative path (``""`` for the root itself) and
    the entries. ``rel`` must stay inside ``root`` once ``..`` and symlinks
    are resolved, or ``files.outside_root`` is raised; a path that is not an
    existing directory is ``files.not_found``. The root itself may be a
    symlink (a config root often is); only a path that leaves it is refused.
    """
    base = Path(root).resolve()
    requested = Path(rel)
    if requested.is_absolute():
        raise ProtocolError("files.outside_root", f"path must be relative to the root: {rel}")
    target = (base / requested).resolve()
    try:
        relative = target.relative_to(base)
    except ValueError:
        raise ProtocolError("files.outside_root", f"path leaves the root: {rel}") from None
    if not target.is_dir():
        raise ProtocolError("files.not_found", f"not a directory under the root: {rel}")
    dirs: list[Entry] = []
    files: list[Entry] = []
    with os.scandir(target) as it:
        for item in it:
            if item.name.startswith("."):
                continue
            try:
                is_dir = item.is_dir()
            except OSError:
                is_dir = False
            if is_dir:
                dirs.append(Entry(name=item.name, dir=True))
                continue
            try:
                size: int | None = item.stat().st_size
            except OSError:
                size = None
            files.append(Entry(name=item.name, dir=False, size=size))
    return relative.as_posix() if relative.parts else "", sorted(dirs, key=_entry_key) + sorted(files, key=_entry_key)


def _entry_key(entry: Entry) -> tuple[str, str]:
    """Case-insensitive order; the exact name breaks ties so the order is stable."""
    return (entry.name.casefold(), entry.name)


@dataclass
class TurnRun:
    """One turn in flight on a chat."""

    turn: int
    collector: TurnCollector
    stop_requested: bool = False
    # Whether the text went to the engine: a turn ended before that (its
    # engine could not start, or a stop came first) is neither work the log
    # has not seen nor a reply.
    sent: bool = False
    finished: asyncio.Event = field(default_factory=asyncio.Event)
    # How the turn ended, once it has; a turn ended by closing its engine
    # (``chat.stop``, gateway stop) leaves it unset and counts as stopped.
    outcome: Outcome | None = None
    # v0.8: on a session's first turn, what the title is generated from (the
    # person's first message) and the first-line title it would replace;
    # ``reply`` collects the start of the agent's answer.
    title_message: str | None = None
    first_line_title: str | None = None
    reply: str = ""


class ChatCallbacks:
    """The ``EngineCallbacks`` the server hands each chat's engine."""

    def __init__(self, server: GatewayServer, chat: Chat) -> None:
        self.server = server
        self.chat = chat

    async def on_event(self, event: ServerMessage) -> None:
        await self.server.engine_event(self.chat, event)

    async def on_permission(
        self, tool: str, input: dict[str, Any], suggestions: list[dict[str, Any]], tool_use_id: str
    ) -> PermissionDecision:
        return await self.server.ask_permission(self.chat, tool, input, suggestions, tool_use_id)

    async def on_question(self, questions: list[dict[str, Any]]) -> dict[str, str | list[str]]:
        return await self.server.ask_question(self.chat, questions)

    async def on_compacted(self, trigger: str) -> None:
        await self.server.compacted(self.chat, trigger)


# --- plain HTTP on the WebSocket port ----------------------------------------


@dataclass
class HttpRequest:
    """One plain HTTP request as the gateway's routes see it."""

    method: str
    path: str
    query: dict[str, str] = field(default_factory=dict)
    headers: dict[str, str] = field(default_factory=dict)  # names lowercased
    body: bytes = b""

    def bearer(self) -> str | None:
        """The token from ``Authorization: Bearer <token>``, or ``None``."""
        value = self.headers.get("authorization", "")
        scheme, _, token = value.partition(" ")
        if scheme.lower() != "bearer" or not token.strip():
            return None
        return token.strip()

    def json(self) -> Any:
        """The body as JSON; raises ``HttpError(400)`` when it is not."""
        try:
            return json.loads(self.body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as e:
            raise HttpError(http.HTTPStatus.BAD_REQUEST, f"body is not valid JSON: {e}") from e


@dataclass
class HttpResponse:
    """What a route returns. A ``dict``/``list`` body is sent as JSON."""

    status: int
    body: Any = None
    content_type: str = "application/json"

    @classmethod
    def json(cls, status: int, obj: Any) -> HttpResponse:
        return cls(status=int(status), body=obj)

    def serialize(self) -> bytes:
        body = self.body
        if isinstance(body, (dict, list)):
            payload = json.dumps(body).encode("utf-8")
        elif isinstance(body, str):
            payload = body.encode("utf-8")
        elif body is None:
            payload = b""
        else:
            payload = bytes(body)
        reason = http.HTTPStatus(self.status).phrase
        head = (
            f"HTTP/1.1 {self.status} {reason}\r\n"
            f"Content-Type: {self.content_type}\r\n"
            f"Content-Length: {len(payload)}\r\n"
            "Connection: close\r\n"
            "Server: portico-gateway\r\n"
            "\r\n"
        )
        return head.encode("ascii") + payload


class HttpError(Exception):
    """A route's refusal; becomes ``{"error": message}`` with the status."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = int(status)
        self.message = message


HttpHandler = Callable[[HttpRequest], Awaitable[HttpResponse]]


def _is_upgrade(head: bytes) -> bool:
    lowered = head.lower()
    return b"\r\nupgrade:" in lowered and b"websocket" in lowered


def _parse_head(head: bytes) -> tuple[str, str, dict[str, str], dict[str, str]]:
    """Request line and headers → (method, path, query, headers)."""
    try:
        text = head.decode("ascii")
    except UnicodeDecodeError as e:
        raise HttpError(http.HTTPStatus.BAD_REQUEST, "request head is not ASCII") from e
    lines = text.split("\r\n")
    parts = lines[0].split(" ")
    if len(parts) != 3 or not parts[2].startswith("HTTP/1."):
        raise HttpError(http.HTTPStatus.BAD_REQUEST, f"bad request line: {lines[0]!r}")
    method, target = parts[0].upper(), parts[1]
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if not line:
            continue
        name, sep, value = line.partition(":")
        if not sep:
            raise HttpError(http.HTTPStatus.BAD_REQUEST, f"bad header line: {line!r}")
        headers[name.strip().lower()] = value.strip()
    split = urlsplit(target)
    query = {k: v[0] for k, v in parse_qs(split.query, keep_blank_values=True).items()}
    return method, split.path, query, headers


class _Connection(ServerConnection):
    """A ``ServerConnection`` that answers plain HTTP itself.

    Bytes are sniffed until the end of the request head. An upgrade request
    is handed to ``websockets`` untouched; anything else is read in full
    here, given to the gateway's HTTP handler, answered, and closed. The
    handshake task ``websockets`` started for the connection then sees the
    connection go away before any request and exits on its own.
    """

    def __init__(self, protocol: ServerProtocol, server: Server, *, http_handler: HttpHandler, **kwargs: Any) -> None:
        super().__init__(protocol, server, **kwargs)
        self._http_handler = http_handler
        self._mode: str | None = None  # None while sniffing, then "ws" or "http"
        self._buf = bytearray()
        self._head_end = 0
        self._more = asyncio.Event()
        self._gone = False
        self._http_task: asyncio.Task[None] | None = None

    # --- asyncio.Protocol -----------------------------------------------------

    def data_received(self, data: bytes) -> None:
        if self._mode == "ws":
            super().data_received(data)
            return
        self._buf.extend(data)
        if self._mode is None:
            end = self._buf.find(b"\r\n\r\n")
            if end < 0:
                if len(self._buf) > HTTP_HEAD_LIMIT:
                    self.transport.abort()
                return
            head = bytes(self._buf[:end])
            if _is_upgrade(head):
                self._mode = "ws"
                pending = bytes(self._buf)
                self._buf = bytearray()
                super().data_received(pending)
                return
            self._mode = "http"
            self._head_end = end + 4
            self._http_task = self.loop.create_task(self._serve_http(head))
        self._more.set()

    def eof_received(self) -> bool | None:
        if self._mode == "ws":
            return super().eof_received()
        # The client half-closed after sending its request; keep our side
        # open so the response can still go out.
        self._gone = True
        self._more.set()
        return True

    def connection_lost(self, exc: Exception | None) -> None:
        self._gone = True
        self._more.set()
        super().connection_lost(exc)

    # --- plain HTTP -----------------------------------------------------------

    async def _serve_http(self, head: bytes) -> None:
        try:
            request = await self._read_request(head)
            response = await self._http_handler(request)
        except HttpError as e:
            response = HttpResponse.json(e.status, {"error": e.message})
        except TimeoutError:
            response = HttpResponse.json(http.HTTPStatus.REQUEST_TIMEOUT, {"error": "request body did not arrive"})
        except Exception:
            log.exception("http handler failed")
            response = HttpResponse.json(http.HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "internal error"})
        if self.transport.is_closing():
            return
        self.transport.write(response.serialize())
        self.transport.close()

    async def _read_request(self, head: bytes) -> HttpRequest:
        method, path, query, headers = _parse_head(head)
        raw_length = headers.get("content-length", "0")
        try:
            length = int(raw_length)
        except ValueError as e:
            raise HttpError(http.HTTPStatus.BAD_REQUEST, f"bad Content-Length: {raw_length!r}") from e
        if length > HTTP_BODY_LIMIT:
            raise HttpError(http.HTTPStatus.REQUEST_ENTITY_TOO_LARGE, f"body larger than {HTTP_BODY_LIMIT} bytes")
        if "transfer-encoding" in headers:
            raise HttpError(http.HTTPStatus.BAD_REQUEST, "chunked requests are not supported; send Content-Length")
        async with asyncio.timeout(HTTP_BODY_TIMEOUT):
            while len(self._buf) - self._head_end < length:
                if self._gone:
                    raise HttpError(http.HTTPStatus.BAD_REQUEST, "request body ended early")
                self._more.clear()
                await self._more.wait()
        body = bytes(self._buf[self._head_end : self._head_end + length])
        return HttpRequest(method=method, path=path, query=query, headers=headers, body=body)


# --- the gateway server ------------------------------------------------------

Handler = Callable[[Any, ServerConnection], Awaitable[None]]


class GatewayServer:
    """The WebSocket server, the HTTP routes, and the attached app."""

    def __init__(
        self,
        config: Config,
        state: StateDir,
        registry: ChatRegistry,
        engine_factory: Callable[[], Engine],
        version: str,
        plugins: Plugins | None = None,
        config_path: Path | None = None,
        titler: Titler | None = None,
    ) -> None:
        self.config = config
        # The file the config came from and its modification time at start:
        # a newer file means the running gateway is not using it (v0.3).
        self.config_path = Path(config_path) if config_path is not None else None
        self.config_mtime = self._config_mtime()
        self._config_stale_sent = False
        self.started_at = _now()
        # The version the deployment's update check last found, if any.
        self.update_version: str | None = None
        self.plugins = plugins if plugins is not None else Plugins.none()
        self.state = state
        self.registry = registry
        # A new session starts in the deployment's mode.
        self.registry.default_mode = config.permission_mode
        self.engine_factory = engine_factory
        self.version = version
        self.epoch = str(uuid.uuid4())
        self.token: str | None = None
        self.port = 0
        self._server: Server | None = None
        self._app: ServerConnection | None = None
        self._handlers: dict[str, Handler] = {}
        self._runs: dict[int, TurnRun] = {}
        self._tasks: set[asyncio.Task[None]] = set()
        # Chats with a ``session.renew`` in flight: no second renew, no send.
        self._renewing: set[int] = set()
        # Chats with a ``session.log`` in flight (v0.4): the same rule.
        self._logging: set[int] = set()
        # Whether a summary can be ``unlogged`` depends on the deployment having a log step.
        self.registry.can_log = self.has_log_step()
        # Asks a small model for a session's title (v0.8; ``titles.sdk_titler``
        # from the command line); ``None`` keeps first-line titles.
        self.titler = titler
        self.title_timeout = TITLE_TIMEOUT
        # The deployment's services (v0.4); started with ``serve``. v0.8: a
        # plug-in's hooks, else ``[deployment]``, give one status and one
        # restart for all of them.
        timeout = float(config.command_timeout_seconds)
        status, status_label = None, "status command"
        if self.plugins.services_status is not None:
            status, status_label = hook_status(self.plugins.services_status), "status plug-in"
        elif config.deployment.status:
            status = command_status(config.deployment.status, timeout)
        restart_all = None
        if self.plugins.restart_services is not None:
            restart_all = hook_restart(self.plugins.restart_services)
        elif config.deployment.restart:
            restart_all = command_restart(config.deployment.restart, timeout)
        self.services = ServiceMonitor(
            config.services,
            interval=float(config.services_interval_seconds),
            timeout=timeout,
            publish=self._publish_services,
            status=status,
            restart_all=restart_all,
            status_label=status_label,
        )
        # Lifecycle: ``before_first_chat`` runs once per launch; ``stop`` runs once.
        self._preflight_done = False
        self._preflight_lock = asyncio.Lock()
        # The preflight command while it runs: ``stop`` and ``shutdown`` cancel it.
        self._preflight_task: asyncio.Task[None] | None = None
        self._stop_lock = asyncio.Lock()
        # One engine start per chat at a time: a send that arrives while a
        # stopped turn's engine is still starting waits for it and uses it.
        self._engine_locks: dict[int, asyncio.Lock] = {}
        self._stopped = False
        # Set once ``stop`` has run; the main loop waits on it, then calls ``shutdown``.
        self.stopping = asyncio.Event()
        self.cards = CardBroker(hold_seconds=config.card_hold_seconds)
        # Reads a session's transcript (``engine.read_history``); replaceable for tests.
        self.history_reader: Callable[[str | None, Path], list[dict[str, Any]]] = read_history
        # Runs Spotlight for ``files.search`` (``search.run_command``); replaceable for tests.
        self.search_runner: Runner = run_command
        self.http_routes: dict[tuple[str, str], HttpHandler] = {
            ("GET", "/v1/health"): self._health,
            ("POST", "/v1/artifact"): self._producer,
            ("GET", "/v1/status"): self._status,
        }
        self.register("artifact.opened", self.on_artifact_opened)
        self.register("card.answer", self.on_card_answer)
        self.register("chat.new", self.on_chat_new)
        self.register("chat.open", self.on_chat_open)
        self.register("chat.stop", self.on_chat_stop)
        self.register("chat.alias", self.on_chat_alias)
        self.register("chat.remove", self.on_chat_remove)
        self.register("message.send", self.on_message_send)
        self.register("turn.stop", self.on_turn_stop)
        self.register("gateway.stop", self.on_gateway_stop)
        self.register("files.list", self.on_files_list)
        self.register("files.search", self.on_files_search)
        self.register("session.renew", self.on_session_renew)
        self.register("session.mode", self.on_session_mode)
        self.register("session.log", self.on_session_log)
        self.register("service.restart", self.on_service_restart)
        self.register("services.restart_all", self.on_services_restart_all)

    @property
    def attached(self) -> bool:
        return self._app is not None

    def register(self, type_name: str, handler: Handler) -> None:
        """Handle app frames of ``type_name`` (``message.send`` …) with ``handler(msg, conn)``."""
        self._handlers[type_name] = handler

    def route(self, method: str, path: str, handler: HttpHandler) -> None:
        """Serve plain ``method path`` on the gateway's port with ``handler``."""
        self.http_routes[(method.upper(), path)] = handler

    # --- lifecycle ------------------------------------------------------------

    async def serve(self, port: int = 0) -> int:
        """Bind loopback, write token and ledger, print the ready line; returns the port."""
        if self._server is not None:
            raise RuntimeError("already serving")
        self.token = self.state.write_token()
        self._server = await serve(
            self._handle_app,
            HOST,
            port,
            process_request=self._process_request,
            create_connection=self._make_connection,
        )
        self.port = self._server.sockets[0].getsockname()[1]
        self.state.write_ledger(HOST, self.port, os.getpid(), self.epoch)
        if self.config_path is not None:
            self._spawn(self._watch_config(), name="portico-config-watch")
        if self.config.update.check:
            self._spawn(self._watch_updates(), name="portico-update-check")
        if self.services.active:
            self._spawn(self.services.run(), name="portico-services")
        print(f"{READY_PREFIX} port={self.port}", flush=True)
        log.info("listening on %s:%d epoch=%s", HOST, self.port, self.epoch)
        return self.port

    async def shutdown(self) -> None:
        """Stop listening, close the app and every engine, clear the ledger, persist the index."""
        server, self._server = self._server, None
        app, self._app = self._app, None
        if server is not None:
            server.close(close_connections=False)
        self.cards.set_attached(False)
        if app is not None:
            await app.close(CLOSE_GOING_AWAY, "gateway stopping")
        self._cancel_preflight()
        for task in list(self._tasks):
            task.cancel()
        for chat in self.registry.chats():
            await self.cards.cancel_all(chat, "gateway stopping", self.emit)
            await self._close_engine(chat)
        if server is not None:
            # ``Server.close`` already ran once above and is idempotent, so it
            # cannot be asked to close connections now: a connection that was
            # accepted but never completed ``hello`` (not ``self._app``) is
            # closed here by hand, or ``wait_closed`` would wait on it forever.
            stragglers = [
                asyncio.create_task(conn.close(CLOSE_GOING_AWAY, "gateway stopping")) for conn in server.connections
            ]
            if stragglers:
                await asyncio.wait(stragglers)
            await server.wait_closed()
        self.state.clear_ledger()
        self.registry.persist()

    def request_stop(self, reason: str) -> None:
        """From a signal handler: run ``stop`` on the loop; the main loop sees ``stopping`` afterwards."""
        log.info("stop requested: %s", reason)
        self._spawn(self.stop(reason), name="portico-stop")

    async def stop(self, reason: str) -> None:
        """Interrupt every running turn, close every engine, run ``on_stop``, persist, set ``stopping``.

        Idempotent: a second call waits for the first and returns. The
        server keeps listening until ``shutdown``, so the app receives
        the interruptions and the on-stop lines before it is told goodbye.
        """
        async with self._stop_lock:
            if self._stopped:
                return
            self._stopped = True
            try:
                # A preflight still running is killed, not waited for: the
                # chat.new (or send) waiting on it is refused at once.
                self._cancel_preflight()
                await self.interrupt_all("gateway stopping")
                if self.config.on_stop:
                    await self._run_on_stop()
                self.registry.persist()
            finally:
                self.stopping.set()

    async def interrupt_all(self, reason: str) -> int:
        """Stop every running turn (``turn.finished outcome=stopped``, ``chat.state idle``) and close every engine."""
        running = [chat for chat in self.registry.chats() if chat.number in self._runs]
        if running:
            await self.broadcast(
                StatusSet(ts=_now(), text=f"Stopping: interrupting {len(running)} running turn{'s' if len(running) != 1 else ''}")
            )
        for chat in self.registry.chats():
            run = self._runs.get(chat.number)
            await self.cards.cancel_all(chat, reason, self.emit)
            await self._close_engine(chat)
            if run is not None:
                if run.sent:
                    chat.note_turn_done()
                await self._report_artifacts(chat, run)
                await self.emit(chat, TurnFinished(ts=_now(), chat=chat.number, turn=run.turn, outcome="stopped"))
                await self.set_state(chat, "idle")
        return len(running)

    async def _run_on_stop(self) -> None:
        """The deployment's ``on_stop`` command; a failure is reported on the strip and never blocks the stop."""
        assert self.config.on_stop
        try:
            await run_lifecycle_command(
                "on-stop", self.config.on_stop, self._status_line, float(self.config.command_timeout_seconds)
            )
        except CommandFailed as e:
            log.warning("on_stop: %s", e)
            await self._status_line(f"On-stop command problem: {e}")

    async def _status_line(self, text: str) -> None:
        """One chat-less ``status.set`` for the strip (lifecycle commands, stop progress)."""
        await self.broadcast(StatusSet(ts=_now(), text=text))

    # --- the config file and the gateway's status ----------------------------------

    def _config_mtime(self) -> float | None:
        if self.config_path is None:
            return None
        try:
            return self.config_path.stat().st_mtime
        except OSError:
            return None

    def config_stale(self) -> bool:
        """Whether the config file is newer than when this gateway started (or appeared since)."""
        if self.config_path is None:
            return False
        now = self._config_mtime()
        return now is not None and (self.config_mtime is None or now > self.config_mtime)

    async def check_config(self) -> None:
        """Send ``config.stale`` once, the first time the file is seen newer."""
        if self._config_stale_sent or not self.config_stale():
            return
        self._config_stale_sent = True
        log.info("%s changed after the gateway started; restart the gateway to apply it", self.config_path)
        await self.broadcast(ConfigStale(ts=_now()))

    async def _watch_config(self) -> None:
        while not self._config_stale_sent:
            await asyncio.sleep(CONFIG_CHECK_SECONDS)
            await self.check_config()

    async def check_update(self) -> None:
        """Run the deployment's update check once; a newly found version goes to the app as ``update.available``."""
        command = self.config.update.check
        if not command:
            return
        version = await check_for_update(command, float(self.config.command_timeout_seconds))
        if version is None or version == self.update_version:
            return
        self.update_version = version
        log.info("update available: %s", version)
        await self.broadcast(UpdateAvailable(ts=_now(), version=version))

    async def _watch_updates(self) -> None:
        """At start, then every ``UPDATE_CHECK_SECONDS``; in the background, never in anyone's way."""
        while True:
            try:
                await self.check_update()
            except Exception:
                log.exception("update check failed")
            await asyncio.sleep(UPDATE_CHECK_SECONDS)

    def status(self) -> dict[str, Any]:
        """What ``GET /v1/status`` answers (``portico-gateway status --json``): the live session, if any.

        The live session is the newest chat that has not ended (in
        ``multiple`` presentation, the newest open chat).
        """
        out: dict[str, Any] = {
            "version": 1,
            "running": True,
            "pid": os.getpid(),
            "port": self.port,
            "started_at": self.started_at,
            "config_stale": self.config_stale(),
        }
        live = [chat for chat in self.registry.chats() if chat.ended is None]
        if live:
            chat = live[-1]
            out.update(
                {"folder": str(chat.folder), "session": chat.number, "state": chat.state, "mode": chat.mode}
            )
        return {k: v for k, v in out.items() if v is not None}

    async def _status(self, request: HttpRequest) -> HttpResponse:
        self.require_token(request)
        return HttpResponse.json(http.HTTPStatus.OK, self.status())

    async def on_gateway_stop(self, msg: GatewayStop, conn: ServerConnection) -> None:
        await self.stop("the app asked")

    async def _preflight(self) -> None:
        """``before_first_chat``, once per launch; raises ``ProtocolError`` (no chat) when it fails.

        The command runs as its own task so ``stop`` can cancel it (which
        kills the process group) while the handler waits; that handler then
        answers ``lifecycle.before_first_chat_failed`` like any other failure.
        """
        command = self.config.before_first_chat
        if not command:
            return
        async with self._preflight_lock:
            if self._preflight_done:
                return
            if self._stopped:
                raise ProtocolError("lifecycle.before_first_chat_failed", "cannot open a chat: the gateway is stopping")
            task = asyncio.create_task(
                run_lifecycle_command(
                    "before-first-chat", command, self._status_line, float(self.config.command_timeout_seconds)
                ),
                name="portico-preflight",
            )
            self._preflight_task = task
            try:
                await task
            except CommandFailed as e:
                raise ProtocolError("lifecycle.before_first_chat_failed", f"cannot open a chat: {e}") from e
            except asyncio.CancelledError:
                current = asyncio.current_task()
                if current is not None and current.cancelling():
                    raise  # this handler itself is being cancelled (shutdown)
                raise ProtocolError(
                    "lifecycle.before_first_chat_failed", "cannot open a chat: the gateway is stopping"
                ) from None
            finally:
                if self._preflight_task is task:
                    self._preflight_task = None
            self._preflight_done = True

    def _cancel_preflight(self) -> None:
        task = self._preflight_task
        if task is not None and not task.done():
            task.cancel()

    def _spawn(self, coro: Coroutine[Any, Any, None], name: str) -> None:
        """Run ``coro`` in the background; the task is cancelled at ``shutdown``."""
        task = asyncio.create_task(coro, name=name)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    # --- connections ----------------------------------------------------------

    def _make_connection(self, protocol: ServerProtocol, server: Server, **kwargs: Any) -> _Connection:
        return _Connection(protocol, server, http_handler=self._handle_http, **kwargs)

    def _process_request(self, connection: ServerConnection, request: Request) -> Response | None:
        """Before the upgrade: the path must be ``/v1`` and ``?token=`` must match."""
        parts = urlsplit(request.path)
        if parts.path != PROTOCOL_PATH:
            return connection.respond(http.HTTPStatus.NOT_FOUND, "not found\n")
        presented = parse_qs(parts.query).get("token", [""])[0]
        if not presented or self.token is None or not secrets.compare_digest(presented, self.token):
            return connection.respond(http.HTTPStatus.UNAUTHORIZED, "unauthorized: the gateway token is required\n")
        return None

    async def _handle_app(self, conn: ServerConnection) -> None:
        try:
            raw = await conn.recv()
        except ConnectionClosed:
            return
        try:
            self._check_protocol_version(raw)
            first = parse_client(raw)
        except ProtocolError as e:
            await self._send(conn, Error(ts=_now(), code=e.code, message=e.message))
            await conn.close(CLOSE_PROTOCOL_ERROR, "hello required")
            return
        if not isinstance(first, HelloClient):
            await self._send(
                conn,
                Error(ts=_now(), code="protocol.hello_required", message="the first frame must be hello"),
            )
            await conn.close(CLOSE_PROTOCOL_ERROR, "hello required")
            return

        await self._attach(conn)
        stale = self.config_stale()
        if stale:
            self._config_stale_sent = True  # ``hello`` says it; no separate ``config.stale`` needed
        await self._send(conn, hello_for(self.config, self.epoch, self.version, self.plugins, config_stale=stale))
        await self._send(conn, ChatList(ts=_now(), chats=self.registry.summaries()))
        # v0.4: every connection hears the services as they stand (an empty
        # list when the deployment lists none: the app has its own Gateway row).
        await self._send(conn, ServicesStatus(ts=_now(), services=self.services.snapshot()))
        if self.update_version is not None:
            # Found before this app attached: it hears it now.
            await self._send(conn, UpdateAvailable(ts=_now(), version=self.update_version))
        # Frames are handled one at a time, in order, by a worker; this loop
        # only reads. So a ``gateway.stop`` is acted on at once even while
        # the worker is inside a slow handler (a hung ``before_first_chat``).
        frames: asyncio.Queue[str | bytes | None] = asyncio.Queue()
        self._spawn(self._handle_frames(conn, frames), name="portico-app-frames")
        try:
            async for raw in conn:
                if _frame_type(raw) == "gateway.stop":
                    await self._handle_frame(conn, raw)
                else:
                    frames.put_nowait(raw)
        except ConnectionClosed:
            pass
        finally:
            frames.put_nowait(None)
            if self._app is conn:
                self._app = None
                self.cards.set_attached(False)

    async def _handle_frames(self, conn: ServerConnection, frames: asyncio.Queue[str | bytes | None]) -> None:
        """The app's frames in order, one handler at a time; ``None`` ends it."""
        while True:
            raw = await frames.get()
            if raw is None:
                return
            await self._handle_frame(conn, raw)

    @staticmethod
    def _check_protocol_version(raw: str | bytes) -> None:
        """A ``hello`` from an app speaking another protocol version is refused in plain words.

        Checked before the strict parse, whose refusal would only say the
        field is not ``1``; a mismatch is reported, never silently tolerated.
        """
        try:
            obj = json.loads(raw)
        except (ValueError, TypeError):
            return  # parse_client reports it
        if not isinstance(obj, dict) or obj.get("type") != "hello":
            return
        version = obj.get("protocol")
        if isinstance(version, int) and not isinstance(version, bool) and version != PROTOCOL_VERSION:
            raise ProtocolError(
                "protocol.version",
                f"the app speaks protocol {version}; this gateway speaks protocol {PROTOCOL_VERSION}",
            )

    async def _attach(self, conn: ServerConnection) -> None:
        previous, self._app = self._app, conn
        self.cards.set_attached(True)
        if previous is not None and previous is not conn:
            await self._send(
                previous,
                Error(ts=_now(), code="session.replaced", message="another app attached to this gateway"),
            )
            await previous.close(CLOSE_POLICY, "replaced by a newer connection")

    async def _handle_frame(self, conn: ServerConnection, raw: str | bytes) -> None:
        try:
            msg = parse_client(raw)
        except ProtocolError as e:
            await self._send(conn, Error(ts=_now(), code=e.code, message=e.message))
            return
        if isinstance(msg, HelloClient):
            await self._send(conn, Error(ts=_now(), code="protocol.invalid", message="hello was already received"))
            return
        await self.dispatch(msg, conn)

    # --- dispatch -------------------------------------------------------------

    async def dispatch(self, msg: ClientMessage, conn: ServerConnection) -> None:
        """Route one parsed app frame to its handler; every failure becomes an ``error`` frame."""
        envelope: Envelope = msg  # type: ignore[assignment]
        handler = self._handlers.get(envelope.type)
        if handler is None:
            await self._send(
                conn,
                self.error(
                    "protocol.unsupported",
                    f"{envelope.type} is not handled by this gateway yet",
                    chat=envelope.chat,
                    id=envelope.id,
                ),
            )
            return
        try:
            await handler(msg, conn)
        except ProtocolError as e:
            await self._send(conn, self.error(e.code, e.message, chat=envelope.chat, id=envelope.id))
        except UnknownChat as e:
            await self._send(conn, self.error("chat.unknown", str(e), chat=envelope.chat, id=envelope.id))
        except Exception as e:
            log.exception("handler for %s failed", envelope.type)
            await self._send(
                conn,
                self.error("gateway.error", f"{envelope.type} failed: {e}", chat=envelope.chat, id=envelope.id),
            )

    @staticmethod
    def error(code: str, message: str, *, chat: int | None = None, id: str | None = None) -> Error:
        return Error(ts=_now(), chat=chat, id=id, code=code, message=message)

    # --- chat-scoped events ---------------------------------------------------

    async def emit(self, chat: Chat, msg: ServerMessage) -> ServerMessage:
        """Stamp ``msg`` with the chat's next ``seq``, keep it in the ring, send it to the app."""
        stamped = chat.stamp(msg)
        await self.broadcast(stamped)
        return stamped

    async def set_state(self, chat: Chat, word: ChatStateWord) -> ChatState:
        """Set the chat's state word, record it in the index, and emit ``chat.state``."""
        event = chat.set_state(word)
        self.registry.persist()
        await self.broadcast(event)
        return event

    async def send_chat_list(self) -> None:
        await self.broadcast(ChatList(ts=_now(), chats=self.registry.summaries()))

    # --- engines --------------------------------------------------------------

    async def _start_engine(self, chat: Chat) -> Engine:
        """A fresh engine for ``chat`` in its folder, resuming its session when it has one.

        The real engine often names its session only with the first turn's
        messages (``start`` then returns ``""``); ``_sync_session`` picks
        the id up from the engine as its events arrive.

        The deployment's ``before_first_chat`` runs first (once per launch):
        a chat restored from the index gets its engine from ``message.send``,
        not ``chat.new``, and the preflight guards that path too.
        """
        await self._preflight()
        engine = self.engine_factory()
        engine.chat = chat.number
        engine.permission_mode = chat.mode or self.config.permission_mode
        session = await engine.start(
            chat.folder, chat.session_id, list(self.config.setting_sources), ChatCallbacks(self, chat)
        )
        chat.engine = engine
        if session:
            chat.session_id = session
        self.registry.persist()
        return engine

    def _sync_session(self, chat: Chat) -> None:
        """Copy a session id the engine learned after ``start`` into the chat and the index."""
        engine = chat.engine
        if engine is None:
            return
        session = engine.session_id
        if session and session != chat.session_id:
            chat.session_id = session
            self.registry.persist()

    async def _close_engine(self, chat: Chat) -> None:
        """Interrupt and close the chat's engine; any turn in flight is forgotten (the caller reports it)."""
        engine, chat.engine = chat.engine, None
        run = self._runs.pop(chat.number, None)
        if run is not None:
            run.stop_requested = True
            run.finished.set()
        if engine is None:
            return
        try:
            if run is not None:
                await engine.interrupt()
            await engine.close()
        except Exception:
            log.exception("closing engine for chat %d failed", chat.number)

    async def engine_event(self, chat: Chat, event: ServerMessage) -> None:
        """An event from the chat's engine: stamp and send it; ``turn.finished`` ends the turn."""
        self._sync_session(chat)
        run = self._runs.get(chat.number)
        turn = getattr(event, "turn", None)
        if run is not None and turn is not None and turn != run.turn:
            # The gateway ended an earlier turn itself (the stop grace ran out)
            # and the engine is only now finishing it: that must not touch
            # the turn that is running now.
            log.warning("chat %d: engine event for turn %s during turn %d; dropped", chat.number, turn, run.turn)
            return
        if not isinstance(event, TurnFinished):
            if isinstance(event, ToolStarted):
                chat.started_tools[event.tool_use_id] = (event.tool, chat.mode)
            elif isinstance(event, ToolFinished):
                event = self._with_permission(chat, event)
            if run is not None:
                if isinstance(event, ToolStarted):
                    run.collector.note_tool(event.tool, event.input)
                elif isinstance(event, TextDelta):
                    run.collector.note_text(event.text)
                    if run.title_message is not None and len(run.reply) < REPLY_CHARS:
                        run.reply = (run.reply + event.text)[:REPLY_CHARS]
            await self.emit(chat, event)
            return
        if run is None:
            # The turn was already ended by the gateway (chat.stop, or the stop grace ran out).
            log.debug("chat %d: engine finish for turn %d after the turn ended; dropped", chat.number, event.turn)
            return
        if run.stop_requested:
            event = event.model_copy(update={"outcome": "stopped"})
        run.outcome = event.outcome
        await self._report_artifacts(chat, run)
        await self.emit(chat, event)
        await self._finish_run(chat, run)
        # Its own task: the engine is asked from inside its own event stream.
        if chat.engine is not None:
            self._spawn(self._report_context(chat, chat.engine), name=f"portico-context-{chat.number}")
        if run.outcome == "done" and run.title_message is not None and self.wants_title(chat):
            # Its own task too: a title never holds up or fails a turn.
            self._spawn(self._title_task(chat, run), name=f"portico-title-{chat.number}")

    def _with_permission(self, chat: Chat, event: ToolFinished) -> ToolFinished:
        """``event`` with what became of its permission (v0.3), recorded on the chat.

        The mode that counts is the session's mode when the tool started.
        In order: auto mode's classifier blocked it (seen in the result) —
        only when the tool started in ``auto`` mode and no person's answer
        or allow was recorded for it; a card's answer, a session allow or a
        cancel decided it; else, a tool started in ``auto`` mode that is not
        read-only ran without a card, so auto mode allowed it. Nothing for a
        read, or a step no one decided.
        """
        tool, mode = chat.started_tools.pop(event.tool_use_id, (None, chat.mode))
        decided = chat.permissions.get(event.tool_use_id)
        if decided is not None and decided.outcome in ("auto", "blocked"):
            decided = None  # not a person's answer
        if event.permission == "blocked" and mode == "auto" and decided is None:
            chat.note_permission(event.tool_use_id, "blocked")
        elif decided is not None:
            event = event.model_copy(update={"permission": decided.outcome, "note": decided.note})
        elif mode == "auto" and tool is not None and tool not in READ_ONLY_TOOLS:
            chat.note_permission(event.tool_use_id, "auto")
            event = event.model_copy(update={"permission": "auto"})
        else:
            return event.model_copy(update={"permission": None}) if event.permission is not None else event
        self.registry.persist()
        return event

    async def _finish_run(self, chat: Chat, run: TurnRun) -> None:
        if self._runs.get(chat.number) is run:
            del self._runs[chat.number]
        if run.sent:
            chat.note_turn_done()
        self._sync_session(chat)
        await self.set_state(chat, "idle")
        run.finished.set()

    async def _report_context(self, chat: Chat, engine: Engine) -> None:
        """After a turn: how full the context is, as ``context.usage``; kept on the record.

        Never breaks anything: an engine that cannot say is logged at
        WARNING and skipped, and ``None`` (unavailable) sends nothing.
        """
        try:
            usage = await engine.context_usage()
        except Exception as e:
            log.warning("chat %d: could not read the context usage: %s", chat.number, e)
            return
        if usage is None or chat.engine is not engine:
            return
        percent, model = usage
        chat.context_percent = percent
        self.registry.persist()
        await self.broadcast(
            ContextUsage(
                ts=_now(), chat=chat.number, percent=percent, model=model, model_name=friendly_model_name(model, os.environ)
            )
        )

    async def compacted(self, chat: Chat, trigger: str) -> None:
        """The engine is summarizing earlier conversation: ``chat.compacted`` (stamped), counted on the record."""
        chat.compactions += 1
        self.registry.persist()
        word = trigger if trigger in ("auto", "manual") else "auto"
        await self.emit(chat, ChatCompacted(ts=_now(), chat=chat.number, trigger=word))  # type: ignore[arg-type]

    # --- titles (v0.8) ------------------------------------------------------------

    def wants_title(self, chat: Chat) -> bool:
        """Whether a title would be generated for ``chat`` now: configured, a titler, and no alias."""
        return self.config.titles == "generated" and self.titler is not None and chat.alias is None

    async def _title_task(self, chat: Chat, run: TurnRun) -> None:
        """Ask for the session's title; store it and push ``chat.list`` when it may replace the current one.

        It replaces only the first-line title this turn set (or none): an
        alias given meanwhile, a removed chat, or a title from anywhere else
        stays as it is.
        """
        assert self.titler is not None and run.title_message is not None
        try:
            title = await generate_title(
                self.titler, run.title_message, run.reply, self.config.title_model, self.title_timeout
            )
        except Exception:
            log.exception("chat %d: generating a title failed", chat.number)
            return
        if title is None or chat.number not in self.registry or chat.alias is not None:
            return
        if chat.title not in (None, run.first_line_title):
            return
        chat.title = title
        log.info("chat %d: titled %r", chat.number, title)
        self.registry.persist()
        await self.send_chat_list()

    async def _await_stop(self, chat: Chat, run: TurnRun) -> None:
        """After ``turn.stop``: give the engine its grace, then end the turn on its behalf."""
        try:
            await asyncio.wait_for(run.finished.wait(), STOP_GRACE_SECONDS)
            return
        except TimeoutError:
            pass
        if self._runs.get(chat.number) is not run:
            return
        log.warning(
            "chat %d: engine did not finish turn %d within %.0fs of stop; ending it and closing the engine",
            chat.number, run.turn, STOP_GRACE_SECONDS,
        )
        # An engine that ignored the interrupt is in an unknown state: close
        # it, as chat.stop does, so its finish for this turn can never arrive
        # during a later one (the adapter stamps events with the current
        # turn). The next send resumes the session on a fresh engine.
        await self._close_engine(chat)
        run.outcome = "stopped"
        await self._report_artifacts(chat, run)
        await self.emit(chat, TurnFinished(ts=_now(), chat=chat.number, turn=run.turn, outcome="stopped"))
        await self._finish_run(chat, run)

    # --- artifacts ----------------------------------------------------------------

    async def _report_artifacts(self, chat: Chat, run: TurnRun) -> None:
        """Settle the turn's collector and send one ``artifact.created`` per artifact (newest viewable opens)."""
        artifacts = run.collector.finish(chat.folder)
        if not artifacts:
            return
        for artifact in artifacts:
            chat.artifacts.append(artifact)
            await self.emit(chat, ArtifactCreated(ts=_now(), chat=chat.number, artifact=artifact))
        self.registry.persist()

    async def _producer(self, request: HttpRequest) -> HttpResponse:
        """``POST /v1/artifact`` ``{chat, location, title?}``: report an artifact now, ``open=true``."""
        self.require_token(request)
        body = request.json()
        if not isinstance(body, dict):
            raise HttpError(http.HTTPStatus.BAD_REQUEST, "body must be a JSON object with chat and location")
        number = body.get("chat")
        if not isinstance(number, int) or isinstance(number, bool):
            raise HttpError(http.HTTPStatus.BAD_REQUEST, "chat is required: the chat number (an integer)")
        location = body.get("location")
        if not isinstance(location, str) or not location.strip():
            raise HttpError(http.HTTPStatus.BAD_REQUEST, "location is required: a file path or a URL")
        title = body.get("title")
        if title is not None and not isinstance(title, str):
            raise HttpError(http.HTTPStatus.BAD_REQUEST, "title must be a string")
        try:
            chat = self.registry.get(number)
        except UnknownChat as e:
            raise HttpError(http.HTTPStatus.NOT_FOUND, str(e)) from None
        artifact = artifact_for_location(
            location.strip(), source="producer", title=(title or "").strip() or None, open=True, folder=chat.folder
        )
        chat.artifacts.append(artifact)
        await self.emit(chat, ArtifactCreated(ts=_now(), chat=chat.number, artifact=artifact))
        self.registry.persist()
        return HttpResponse.json(http.HTTPStatus.CREATED, {"artifact": artifact.model_dump(mode="json")})

    async def on_artifact_opened(self, msg: ArtifactOpened, conn: ServerConnection) -> None:
        """Telemetry from the app; nothing to do and nothing to answer."""
        log.debug("chat %d: app opened artifact %s", msg.chat, msg.artifact_id)

    # --- cards ------------------------------------------------------------------

    async def ask_permission(
        self, chat: Chat, tool: str, input: dict[str, Any], suggestions: list[dict[str, Any]], tool_use_id: str
    ) -> PermissionDecision:
        """A permission card, unless a person already allowed the tool for this chat. Never allow by default."""
        if self.cards.allowed(chat, tool, input):
            chat.note_permission(tool_use_id, "session")
            return "allow"
        run = self._runs.get(chat.number)
        before = set(chat.chat_allows)
        try:
            decision = await self.cards.ask_permission(chat, tool, input, suggestions, tool_use_id, self._emit_card)
            if isinstance(decision, tuple) and decision[0] == "deny" and tool_use_id not in chat.permissions:
                # Cancelled (turn stopped, nobody there): declined, with the reason.
                chat.note_permission(tool_use_id, "declined", decision[1])
            return decision
        finally:
            if chat.chat_allows != before:
                # On the record at once: a gateway restart keeps the session's allows.
                self.registry.persist()
            await self._resume_working(chat, run)

    async def ask_question(self, chat: Chat, questions: list[dict[str, Any]]) -> dict[str, str | list[str]]:
        """A question card; raises ``QuestionDeclined`` (a deny to the engine) when nobody answered."""
        run = self._runs.get(chat.number)
        try:
            return await self.cards.ask_question(chat, questions, self._emit_card)
        finally:
            await self._resume_working(chat, run)

    async def _emit_card(self, chat: Chat, msg: ServerMessage) -> ServerMessage:
        """The broker's ``send``: emit, and once a ``card.ask`` is out the chat is ``waiting on you``."""
        stamped = await self.emit(chat, msg)
        if isinstance(msg, CardAsk):
            await self.set_state(chat, "waiting on you")
        return stamped

    async def _resume_working(self, chat: Chat, run: TurnRun | None) -> None:
        """Back to ``working`` after a card, but only while the same turn is still running."""
        if run is not None and self._runs.get(chat.number) is run and chat.state == "waiting on you":
            await self.set_state(chat, "working")

    async def on_card_answer(self, msg: CardAnswer, conn: ServerConnection) -> None:
        chat = self.registry.get(msg.chat)
        # Said at INFO so the log shows which answer a card got; the ring's
        # card.answered carries none of it, and a review this week spent an
        # hour working out who had pressed Allow.
        log.info(
            "chat %d: card %s answered %s%s", chat.number, msg.id,
            msg.answer.get("decision", "submit") if isinstance(msg.answer, dict) else "submit",
            f" scope={msg.scope}" if msg.scope else "")
        card = next((c for c in self.cards.open_cards(chat) if c.id == msg.id), None)
        self.cards.answer(chat.number, msg.id, msg)
        closing = CardAnswered(ts=_now(), chat=chat.number, id=msg.id)
        if card is not None and card.kind == "permission":
            # One permission unit (v0.3): the closing says what was decided,
            # for the tool row; ``tool.finished`` carries it again.
            if msg.answer.get("decision") == "allow":
                outcome = "once" if msg.scope in (None, "once") else "session"  # ``always`` covers the session too
                note = None
            else:
                outcome, note = "declined", msg.note
            if card.tool_use_id:
                chat.note_permission(card.tool_use_id, outcome, note)
                # On the record at once, not only at ``tool.finished``: a
                # restart before the tool ends still knows who decided it.
                self.registry.persist()
            closing = closing.model_copy(update={"tool_use_id": card.tool_use_id, "outcome": outcome, "note": note})
        # The closing goes in the ring before the engine resumes (and the
        # state goes back to working): a replay closes what it opened.
        await self.emit(chat, closing)

    # --- handlers: chats --------------------------------------------------------

    async def on_chat_new(self, msg: ChatNew, conn: ServerConnection) -> None:
        folder = Path(msg.folder)
        if not folder.is_absolute() or not folder.is_dir():
            raise ProtocolError("chat.folder_invalid", f"not an absolute path to a directory: {msg.folder}")
        if self.config.presentation == "single":
            live = [c.number for c in self.registry.chats() if c.ended is None]
            if live:
                raise ProtocolError(
                    "session.live",
                    f"this deployment keeps one session at a time and session {live[-1]} is live; "
                    "end it with session.renew to start the next",
                )
        await self._preflight()
        chat = self.registry.create(folder)
        try:
            await self._start_engine(chat)
        except Exception as e:
            log.exception("chat %d: engine failed to start", chat.number)
            self.registry.remove(chat.number)
            await self.send_chat_list()
            raise ProtocolError("engine.start_failed", f"the engine could not start in {msg.folder}: {e}") from e
        state = chat.set_state("idle")
        self.registry.persist()
        await self._send(conn, state.model_copy(update={"id": msg.id}))
        await self.send_chat_list()

    async def on_chat_open(self, msg: ChatOpen, conn: ServerConnection) -> None:
        chat = self.registry.get(msg.chat)
        events, truncated, artifacts = await self._history(chat, msg.since)
        await self._send(conn, ChatHistory(ts=_now(), chat=chat.number, id=msg.id, events=events, truncated=truncated))
        # Artifacts the index remembers from before this launch: listed, never opened.
        for artifact in artifacts:
            await self._send(conn, ArtifactCreated(ts=_now(), chat=chat.number, artifact=artifact.model_copy(update={"open": False})))
        await self._send(conn, ChatLive(ts=_now(), chat=chat.number, id=msg.id, seq=chat.seq))
        # The state word and the session's permission mode as they are now
        # (v0.3: the composer's mode chip reads it here). A direct reply like
        # ``chat.live`` — no ``seq``, not in the ring — so opening a chat
        # never adds to its history.
        await self._send(
            conn,
            ChatState(ts=_now(), chat=chat.number, id=msg.id, state=chat.state, mode=chat.mode, unlogged=chat.unlogged),
        )
        # Open cards again, as sent (same id and seq): the app de-duplicates by id.
        for card in self.cards.open_cards(chat):
            await self._send(conn, card)

    async def _history(self, chat: Chat, since: int | None) -> tuple[list[ServerMessage], bool, list[Artifact]]:
        """What ``chat.open`` replays: ring events, or the transcript when the ring cannot serve.

        The ring serves when ``since`` is inside it, or when the chat was
        created this launch and the ring still reaches back to its first
        event. Otherwise the engine's transcript is read and translated;
        the chat's stored artifacts come with it, and the ring's notices
        from this launch are put back in (v0.7). When there is no
        transcript to read, the ring is the best the gateway has: it is
        sent ``truncated`` only for a ``since`` request (the app then asks
        from the beginning), never for a from-the-beginning one, which no
        refetch could serve better.

        A ``since`` of 0 is from the beginning. A ``since`` beyond the
        chat's current ``seq`` is a number from an earlier launch: the ring
        cannot serve it, so it is treated like one the ring no longer reaches.
        """
        if since is not None and since <= 0:
            since = None
        if since is not None and since > chat.seq:
            ring, truncated = chat.events_since(None)[0], True
        else:
            ring, truncated = chat.events_since(since)
        if not truncated and (since is not None or not chat.restored):
            return ring, truncated, []
        transcript = await asyncio.to_thread(self.history_reader, chat.session_id, chat.folder)
        events = [self._replayed_permission(chat, e) for e in history_events(transcript, chat.number)]
        if not events:
            replayed = {e.artifact.id for e in ring if isinstance(e, ArtifactCreated)}
            return ring, truncated and since is not None, [a for a in chat.artifacts if a.id not in replayed]
        # Live turns continue the transcript's numbering when none has run yet this launch.
        turns = sum(1 for e in events if isinstance(e, TurnStarted))
        if chat.turn == 0 and chat.number not in self._runs:
            chat.turn = turns
        return self._with_notices(events, chat.events_since(None)[0]), False, list(chat.artifacts)

    @staticmethod
    def _with_notices(events: list[ServerMessage], ring: list[ServerMessage]) -> list[ServerMessage]:
        """Transcript ``events`` with this launch's ``chat.notice`` lines from ``ring`` put back in.

        The transcript is the engine's and has no notices. Each goes after
        the ``turn.finished`` of the turn before it in the ring, else before
        the ``turn.started`` of the turn after it, else at the end. Unstamped,
        as the transcript's events are.
        """
        # (notice, turn it follows, turn it precedes), in ring order.
        notices: list[tuple[ServerMessage, int | None, int | None]] = []
        last_turn: int | None = None
        for e in ring:
            if isinstance(e, ChatNotice):
                notices.append((e.model_copy(update={"seq": None}), last_turn, None))
            elif isinstance(e, TurnStarted):
                if last_turn is None:
                    notices = [(n, None, e.turn) for n, _, _ in notices]
                last_turn = e.turn
        if not notices:
            return events
        placed: set[int] = set()
        out: list[ServerMessage] = []
        for e in events:
            if isinstance(e, TurnStarted):
                for i, (n, _, nxt) in enumerate(notices):
                    if nxt == e.turn and i not in placed:
                        out.append(n)
                        placed.add(i)
            out.append(e)
            if isinstance(e, TurnFinished):
                for i, (n, prev, _) in enumerate(notices):
                    if prev == e.turn and i not in placed:
                        out.append(n)
                        placed.add(i)
        # Anchors the transcript does not have (a turn still running, one that
        # never reached the engine, or none at all) leave their notices at the end.
        out.extend(n for i, (n, _, _) in enumerate(notices) if i not in placed)
        return out

    @staticmethod
    def _replayed_permission(chat: Chat, event: ServerMessage) -> ServerMessage:
        """A transcript's ``tool.finished`` with the outcome recorded for it live."""
        if not isinstance(event, ToolFinished) or event.permission is not None:
            return event
        decided = chat.permissions.get(event.tool_use_id)
        if decided is None:
            return event
        return event.model_copy(update={"permission": decided.outcome, "note": decided.note})

    async def on_chat_stop(self, msg: ChatStop, conn: ServerConnection) -> None:
        chat = self.registry.get(msg.chat)
        run = self._runs.get(chat.number)
        await self.cards.cancel_all(chat, "chat stopped", self.emit)
        await self._close_engine(chat)
        if run is not None:
            if run.sent:
                chat.note_turn_done()
            await self._report_artifacts(chat, run)
            await self.emit(chat, TurnFinished(ts=_now(), chat=chat.number, turn=run.turn, outcome="stopped"))
        await self.set_state(chat, "stopped")

    async def on_chat_alias(self, msg: ChatAlias, conn: ServerConnection) -> None:
        chat = self.registry.get(msg.chat)
        chat.alias = msg.alias or None
        self.registry.persist()
        await self.send_chat_list()

    async def on_chat_remove(self, msg: ChatRemove, conn: ServerConnection) -> None:
        chat = self.registry.get(msg.chat)
        await self.cards.cancel_all(chat, "chat removed", self.emit)
        await self._close_engine(chat)
        self.registry.remove(chat.number)
        self._engine_locks.pop(chat.number, None)
        await self.send_chat_list()

    # --- handlers: files --------------------------------------------------------

    def root_path(self, name: str, chat: int | None) -> Path:
        """The directory a root name stands for: the chat's folder, or a config root."""
        if name == CHAT_ROOT:
            if chat is None:
                raise ProtocolError("files.unknown_root", "root 'chat' needs a chat number")
            return self.registry.get(chat).folder
        for root in self.config.roots:
            if root.name == name:
                return Path(root.path)
        raise ProtocolError("files.unknown_root", f"no root named {name!r}")

    async def on_files_list(self, msg: FilesListRequest, conn: ServerConnection) -> None:
        root = self.root_path(msg.root, msg.chat)
        rel, entries = await asyncio.to_thread(list_directory, root, msg.path)
        await self._send(conn, FilesList(ts=_now(), chat=msg.chat, id=msg.id, root=msg.root, path=rel, entries=entries))

    # --- handlers: sessions -----------------------------------------------------

    def has_log_step(self) -> bool:
        return self.plugins.renew is not None or bool(self.config.log_prompt)

    async def on_session_renew(self, msg: SessionRenew, conn: ServerConnection) -> None:
        """End session ``chat`` (after its log step, when asked) and open the next one in the same folder.

        Checked here, answered from a task: the log step is a whole turn,
        and the frames that answer its cards (or stop it) must still be read
        while it runs.
        """
        chat = self.registry.get(msg.chat)
        if chat.ended is not None:
            raise ProtocolError("session.ended", f"session {chat.number} has already ended")
        self._check_can_send(chat)
        self._renewing.add(chat.number)
        self._spawn(self._renew_task(chat, msg, conn), name=f"portico-renew-{chat.number}")

    async def _renew_task(self, chat: Chat, msg: SessionRenew, conn: ServerConnection) -> None:
        try:
            await self.renew(chat, msg.log, msg.id)
        except ProtocolError as e:
            await self._send(conn, self.error(e.code, e.message, chat=chat.number, id=msg.id))
        except Exception as e:
            log.exception("chat %d: renew failed", chat.number)
            await self._send(conn, self.error("gateway.error", f"session.renew failed: {e}", chat=chat.number, id=msg.id))
        finally:
            self._renewing.discard(chat.number)

    async def renew(self, chat: Chat, log_first: bool, id: str | None = None) -> Chat:
        """Run the log step (when asked and one exists), end ``chat``, create the next; returns it.

        Sends ``chat.state`` for both, then ``session.renewed`` (with ``id``),
        then ``chat.list``. The next session's engine starts with its first
        message, as a restored chat's does.

        Recorded in both conversations as ``chat.notice`` lines (v0.7): what
        is happening, at once, in the ending session; that it ended and
        which session follows; and, first in the next, which one it continues.
        """
        logging = log_first and self.has_log_step()
        text = "New — logging, then ending this session" if logging else "New — ending this session"
        await self.notice(chat, text)
        logged: bool | None = None
        if logging:
            logged = await self._noted_log_step(chat, ending=True)
            if logged:
                chat.note_logged(_now())
        await self.cards.cancel_all(chat, "session ended", self.emit)
        await self._close_engine(chat)
        chat.ended = _now()
        chat.logged = logged
        await self.set_state(chat, "stopped")
        following = self.registry.create(chat.folder, parent=chat.number)
        await self.notice(chat, f"Session ended · continues in Session {following.number}")
        await self.set_state(following, "idle")
        await self.notice(following, f"Continues Session {chat.number}")
        log.info("chat %d: session ended (logged=%s); session %d follows", chat.number, logged, following.number)
        await self.broadcast(SessionRenewed(ts=_now(), id=id, ended=chat.summary(), next=following.summary()))
        await self.send_chat_list()
        return following

    async def _run_log_step(self, chat: Chat, ending: bool) -> bool:
        """The plug-in's ``on_renew``, else ``log_prompt`` as a message; whether it finished cleanly.

        ``ending`` tells the plug-in whether a renewal ends the session
        afterwards (``session.renew``) or it stays live (``session.log``).
        """

        async def send(text: str) -> Outcome:
            # Turns are this method's own: the renew holds the chat.
            if chat.number in self._runs:
                raise ProtocolError("chat.busy", f"a turn is already running in chat {chat.number}")
            run = await self.start_turn(chat, text)
            await run.finished.wait()
            return run.outcome or "stopped"

        hook = self.plugins.renew
        if hook is None:
            assert self.config.log_prompt
            return await send(self.config.log_prompt) == "done"
        ctx = RenewContext(
            chat=chat.number, folder=chat.folder, log_prompt=self.config.log_prompt, send=send, ending=ending
        )
        try:
            return bool(await hook(ctx, chat.summary()))
        except Exception:
            log.exception("chat %d: the plug-in's on_renew failed; the session is not logged", chat.number)
            return False

    async def _noted_log_step(self, chat: Chat, ending: bool) -> bool:
        """``_run_log_step``; one that raises (its turn could not start) says so in the conversation first."""
        try:
            return await self._run_log_step(chat, ending)
        except Exception:
            await self.notice(chat, LOG_STEP_UNFINISHED)
            raise

    async def notice(self, chat: Chat, text: str) -> None:
        """A quiet line in ``chat``'s conversation: stamped, so it is in the ring and replays."""
        await self.emit(chat, ChatNotice(ts=_now(), chat=chat.number, text=text))

    async def on_session_log(self, msg: SessionLog, conn: ServerConnection) -> None:
        """Run the log step in the live session ``chat`` without ending it (v0.4).

        Checked here, answered from a task, as a renewal is: the log step is
        a whole turn whose cards (or stop) arrive as frames meanwhile.
        """
        chat = self.registry.get(msg.chat)
        if chat.ended is not None:
            raise ProtocolError("session.ended", f"session {chat.number} has ended; log the session that followed it")
        if not self.has_log_step():
            raise ProtocolError("session.cannot_log", "this deployment has no log step (no log_prompt, no plug-in on_renew)")
        self._check_can_send(chat)
        self._logging.add(chat.number)
        self._spawn(self._log_task(chat, msg, conn), name=f"portico-log-{chat.number}")

    async def _log_task(self, chat: Chat, msg: SessionLog, conn: ServerConnection) -> None:
        try:
            await self.log_session(chat, msg.id)
        except ProtocolError as e:
            await self._send(conn, self.error(e.code, e.message, chat=chat.number, id=msg.id))
        except Exception as e:
            log.exception("chat %d: log failed", chat.number)
            await self._send(conn, self.error("gateway.error", f"session.log failed: {e}", chat=chat.number, id=msg.id))
        finally:
            self._logging.discard(chat.number)

    async def log_session(self, chat: Chat, id: str | None = None) -> None:
        """The log step in the live session; ``chat.state``, ``session.logged`` (with ``id``), then ``chat.list``.

        A log step that does not finish cleanly (an error, a stop) still
        answers: ``logged_at`` stays where it was, and ``unlogged`` is true,
        since the log turn itself finished and counts as work the log has
        not seen. The log turn's own ``chat.state idle`` goes out before the
        step's verdict is known (a plug-in may send more than one turn), so
        a ``chat.state`` follows the step with ``unlogged`` as it now stands.

        The conversation records it (v0.7): a ``chat.notice`` at once, and
        one with the verdict when the step is done.
        """
        await self.notice(chat, "Log session — running the log step")
        logged = await self._noted_log_step(chat, ending=False)
        if logged:
            chat.note_logged(_now())
        await self.notice(chat, "Session logged" if logged else LOG_STEP_UNFINISHED)
        await self.set_state(chat, chat.state)
        log.info("chat %d: session log step ran (logged=%s); the session stays live", chat.number, logged)
        # ``chat`` is a summary here, not a number: the frame names the session in it.
        await self.broadcast(SessionLogged(ts=_now(), id=id, chat=chat.summary()))
        await self.send_chat_list()

    # --- handlers: services -------------------------------------------------------

    async def _publish_services(self, services: list[Service]) -> None:
        await self.broadcast(ServicesStatus(ts=_now(), services=services))

    async def on_service_restart(self, msg: ServiceRestart, conn: ServerConnection) -> None:
        """Restart one service and check it again; the ``services.status`` frames that follow are the answer.

        Refusals (``service.unknown``, ``service.no_restart``) are checked
        here; the restart itself runs as a task so other frames keep moving.
        """
        self.services.check_restart(msg.service)
        self._spawn(self._restart_task(msg, conn), name=f"portico-restart-{msg.service}")

    async def _restart_task(self, msg: ServiceRestart, conn: ServerConnection) -> None:
        try:
            await self.services.restart(msg.service)
        except ProtocolError as e:
            await self._send(conn, self.error(e.code, e.message, id=msg.id))
        except Exception as e:
            log.exception("service %s: restart failed", msg.service)
            await self._send(conn, self.error("gateway.error", f"service.restart failed: {e}", id=msg.id))

    async def on_services_restart_all(self, msg: ServicesRestartAll, conn: ServerConnection) -> None:
        """Restart all the deployment's services (v0.8); the ``services.status`` frames that follow are the answer.

        ``services.no_restart_all`` (nothing to run) and ``services.busy``
        (one already running) are checked here; the restart runs as a task.
        A restart that fails ends with ``error code=services.restart_failed``
        and the request's ``id``, after the status read once it was done.
        """
        if not self.services.can_restart_all:
            raise ProtocolError("services.no_restart_all", "this deployment has no restart for all its services")
        if self.services.restarting_all:
            raise ProtocolError("services.busy", "a restart of all services is already running")
        self._spawn(self._restart_all_task(msg, conn), name="portico-restart-all")

    async def _restart_all_task(self, msg: ServicesRestartAll, conn: ServerConnection) -> None:
        try:
            await self.services.restart_all()
        except ProtocolError as e:
            await self._send(conn, self.error(e.code, e.message, id=msg.id))
        except Exception as e:
            log.exception("services: restart all failed")
            await self._send(conn, self.error("services.restart_failed", f"services.restart_all failed: {e}", id=msg.id))

    async def on_session_mode(self, msg: SessionMode, conn: ServerConnection) -> None:
        """Change the session's permission mode: the running engine at once, every later engine from the record.

        Answered with ``chat.state`` (stamped, carrying ``mode`` and the
        request's ``id``). A mode the engine refuses leaves the record as it was.
        """
        chat = self.registry.get(msg.chat)
        if chat.ended is not None:
            raise ProtocolError("session.ended", f"session {chat.number} has ended")
        if chat.engine is not None:
            await chat.engine.set_permission_mode(msg.mode)
        chat.mode = msg.mode
        log.info("chat %d: permission mode %s", chat.number, msg.mode)
        event = chat.set_state(chat.state)
        self.registry.persist()
        await self._send(conn, event.model_copy(update={"id": msg.id}))

    async def on_files_search(self, msg: FilesSearch, conn: ServerConnection) -> None:
        """Hits for ``query`` under a root (named as ``files.list`` names them): a plug-in's, else Spotlight's."""
        root = self.root_path(msg.root, msg.chat)
        if not root.is_dir():
            raise ProtocolError("files.not_found", f"root {msg.root!r} is not a directory")
        if self.plugins.search is not None:
            base = root.resolve()
            hits = clean_hits(base, await self.plugins.run_search(base, msg.query), msg.query)
        else:
            hits = await search_files(root, msg.query, self.search_runner)
        await self._send(
            conn, FilesResults(ts=_now(), chat=msg.chat, id=msg.id, root=msg.root, query=msg.query, hits=hits)
        )

    # --- handlers: turns --------------------------------------------------------

    async def on_message_send(self, msg: MessageSend, conn: ServerConnection) -> None:
        chat = self.registry.get(msg.chat)
        self._check_can_send(chat)
        attachments = check_attachments(msg.attachments)
        # The session's title: the first line of the first thing the person
        # said (never a log step's message, which does not come this way).
        # A chat restored from a v0.1 index keeps no title rather than
        # taking a later message's. No ``chat.list`` is pushed for it: the
        # app has the same first line in ``user.text``, and the next
        # ``chat.list`` (renew, new, alias, reattach) carries the title.
        command = slash_command(msg.text)
        if command is not None and not await self._knows_command(chat, command):
            await self._unknown_command(chat, command, with_attachments(msg.text, attachments))
            return
        title = None
        first = chat.title is None and chat.turn == 0 and not chat.restored
        if first:
            title = title_from(msg.text)
        text = with_attachments(msg.text, attachments)
        run = await self._echo_turn(chat, text)
        if first and msg.text.strip():
            # v0.8: this turn may name the session once it finishes cleanly.
            run.title_message = msg.text
            run.first_line_title = title
        # The engine start and the send run from a task (v0.7): a cold engine
        # takes seconds, and the frames that stop the turn must be read meanwhile.
        self._spawn(self._send_task(chat, run, text, title, msg, conn), name=f"portico-send-{chat.number}")

    async def _send_task(
        self, chat: Chat, run: TurnRun, text: str, title: str | None, msg: MessageSend, conn: ServerConnection
    ) -> None:
        """``_begin_turn`` for a ``message.send``; a refusal goes to the sender with the request's ``id``."""
        try:
            await self._begin_turn(chat, run, text)
        except ProtocolError as e:
            await self._send(conn, self.error(e.code, e.message, chat=chat.number, id=msg.id))
            return
        except Exception as e:
            log.exception("chat %d: message.send failed", chat.number)
            if self._runs.get(chat.number) is run:
                await self._fail_turn(chat, run)
            await self._send(conn, self.error("gateway.error", f"message.send failed: {e}", chat=chat.number, id=msg.id))
            return
        if title is not None and chat.title is None:
            chat.title = title
            self.registry.persist()

    def deployment_commands(self) -> set[str]:
        """Command names (no ``/``) the deployment offers: ``hello.commands`` and its actions' slash text."""
        hello = hello_for(self.config, self.epoch, self.version, self.plugins)
        names = {c.strip().lstrip("/").split()[0] for c in hello.commands if c.strip().lstrip("/")}
        for action in hello.actions:
            name = slash_command(action.text)
            if name:
                names.add(name)
        return names

    async def _knows_command(self, chat: Chat, command: str) -> bool:
        """Whether someone knows ``/command``: Portico, the deployment, or the engine.

        The engine's commands are only known once it runs, so a chat without
        one has its engine started first (as the send would). An engine that
        cannot say is trusted: the message goes to it as typed.
        """
        if command in PORTICO_COMMANDS or command in self.deployment_commands():
            return True
        engine = await self._ensure_engine(chat)
        known = engine.slash_commands()
        return known is None or command in known

    async def _unknown_command(self, chat: Chat, command: str, text: str) -> None:
        """An empty turn: what was typed, one ``chat.notice``, done. Nothing reaches the agent."""
        log.info("chat %d: no command /%s here; not sent to the agent", chat.number, command)
        chat.turn += 1
        turn = chat.turn
        await self.emit(chat, TurnStarted(ts=_now(), chat=chat.number, turn=turn))
        await self.emit(chat, UserText(ts=_now(), chat=chat.number, turn=turn, text=text))
        await self.emit(chat, ChatNotice(ts=_now(), chat=chat.number, text=f"No command /{command} here"))
        await self.emit(chat, TurnFinished(ts=_now(), chat=chat.number, turn=turn, outcome="done"))
        await self.set_state(chat, "idle")

    async def _ensure_engine(self, chat: Chat) -> Engine:
        """The chat's engine, started (resuming its session) when it has none."""
        engine = chat.engine
        if engine is not None:
            return engine
        async with self._engine_locks.setdefault(chat.number, asyncio.Lock()):
            # Another start may have finished while this one waited.
            if chat.engine is not None:
                return chat.engine
            return await self._start_or_refuse(chat)

    async def _start_or_refuse(self, chat: Chat) -> Engine:
        """Start ``chat``'s engine; a failure is ``engine.start_failed`` unless the preflight refused."""
        try:
            return await self._start_engine(chat)
        except ProtocolError:
            raise  # the preflight refused: lifecycle.before_first_chat_failed, as on chat.new
        except Exception as e:
            log.exception("chat %d: engine failed to start", chat.number)
            raise ProtocolError("engine.start_failed", f"the engine could not start in {chat.folder}: {e}") from e

    def _check_can_send(self, chat: Chat) -> None:
        if chat.ended is not None:
            raise ProtocolError("session.ended", f"session {chat.number} has ended; send to the session that followed it")
        if chat.number in self._runs or chat.number in self._renewing or chat.number in self._logging:
            raise ProtocolError("chat.busy", f"a turn is already running in chat {chat.number}")

    async def start_turn(self, chat: Chat, text: str) -> TurnRun:
        """Start one turn of ``text`` in ``chat`` (starting its engine if needed); returns the run.

        The caller has checked the chat can take a turn. ``run.finished`` is
        set when the turn ends, with ``run.outcome`` saying how.

        The echo goes first (v0.7): ``turn.started``, ``user.text`` and
        ``chat.state working`` precede starting or resuming the engine, so
        the person's message shows at once however long a cold engine takes.
        An engine that cannot start ends the turn ``error``, as a refused
        send does, and the start's ``ProtocolError`` is raised.

        Awaited whole by the log step, whose own task it runs in; a
        ``message.send`` echoes here and begins from a task.
        """
        run = await self._echo_turn(chat, text)
        await self._begin_turn(chat, run, text)
        return run

    async def _echo_turn(self, chat: Chat, text: str) -> TurnRun:
        """Register the next turn and send its echo: ``turn.started``, ``user.text``, ``chat.state working``."""
        chat.turn += 1
        run = TurnRun(turn=chat.turn, collector=TurnCollector(chat))
        # Registered before the engine starts: a second send meanwhile is busy.
        self._runs[chat.number] = run
        await self.emit(chat, TurnStarted(ts=_now(), chat=chat.number, turn=chat.turn))
        # The person's words go in the ring too, as the engine receives them,
        # so a replay from this launch reads as a conversation, not a monologue.
        await self.emit(chat, UserText(ts=_now(), chat=chat.number, turn=chat.turn, text=text))
        await self.set_state(chat, "working")
        return run

    async def _begin_turn(self, chat: Chat, run: TurnRun, text: str) -> None:
        """Start or resume the engine for an echoed ``run`` and send ``text``, unless the turn ended meanwhile."""
        try:
            engine = await self._ensure_engine(chat)
        except ProtocolError:
            if self._runs.get(chat.number) is not run:
                # Ended while the engine started (chat.stop, chat.remove,
                # gateway stop): that reported the turn, and a failure now
                # has no turn left to end.
                log.info("chat %d: engine failed to start for turn %d after it ended", chat.number, run.turn)
                return
            await self._fail_turn(chat, run)
            raise
        if self._runs.get(chat.number) is not run:
            # Ended while the engine started (chat.stop, chat.remove, gateway
            # stop): that reported the turn; the fresh engine goes as well.
            if chat.number not in self._runs:
                await self._close_engine(chat)
            return
        if run.stop_requested:
            # turn.stop while the engine started: nothing was sent to stop.
            run.outcome = "stopped"
            await self.emit(chat, TurnFinished(ts=_now(), chat=chat.number, turn=run.turn, outcome="stopped"))
            await self._finish_run(chat, run)
            return
        # ``send`` advances the engine's own turn counter; align it so the
        # engine's events carry this turn even after an engine restart.
        engine.turn = run.turn - 1
        # From here the turn counts as work and a reply, a refused send too:
        # the engine may have taken part of it.
        run.sent = True
        try:
            await engine.send(text)
        except Exception as e:
            log.exception("chat %d: engine send failed", chat.number)
            await self._fail_turn(chat, run)
            raise ProtocolError("engine.send_failed", f"the engine refused the message: {e}") from e

    async def _fail_turn(self, chat: Chat, run: TurnRun) -> None:
        """End ``run`` with ``error``: the engine could not start, or refused the message."""
        run.outcome = "error"
        await self.emit(chat, TurnFinished(ts=_now(), chat=chat.number, turn=run.turn, outcome="error"))
        await self._finish_run(chat, run)

    async def on_turn_stop(self, msg: TurnStop, conn: ServerConnection) -> None:
        chat = self.registry.get(msg.chat)
        run = self._runs.get(chat.number)
        if run is None:
            return  # nothing running: a stop is harmless
        run.stop_requested = True
        if chat.engine is None:
            return  # the engine is still starting: ``_begin_turn`` ends the turn stopped instead of sending
        # An open card would keep the engine's permission call waiting past the interrupt.
        await self.cards.cancel_all(chat, "turn stopped", self.emit)
        await chat.engine.interrupt()
        self._spawn(self._await_stop(chat, run), name=f"portico-stop-{chat.number}")

    # --- sending --------------------------------------------------------------

    async def broadcast(self, msg: ServerMessage) -> None:
        """Send to the attached app; dropped silently when none is attached."""
        app = self._app
        if app is not None:
            await self._send(app, msg)

    @staticmethod
    async def _send(conn: ServerConnection, msg: ServerMessage | Error) -> None:
        try:
            await conn.send(dump(msg))
        except ConnectionClosed:
            pass

    # --- plain HTTP -----------------------------------------------------------

    async def _handle_http(self, request: HttpRequest) -> HttpResponse:
        handler = self.http_routes.get((request.method, request.path))
        if handler is None:
            return HttpResponse.json(http.HTTPStatus.NOT_FOUND, {"error": f"no route {request.method} {request.path}"})
        return await handler(request)

    async def _health(self, request: HttpRequest) -> HttpResponse:
        return HttpResponse.json(http.HTTPStatus.OK, {"epoch": self.epoch, "protocol": PROTOCOL_VERSION})

    def require_token(self, request: HttpRequest) -> None:
        """Refuse a producer call without ``Authorization: Bearer <token>`` (401)."""
        presented = request.bearer()
        if not presented or self.token is None or not secrets.compare_digest(presented, self.token):
            raise HttpError(http.HTTPStatus.UNAUTHORIZED, "the gateway token is required")
