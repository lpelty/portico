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
the finish that follows is reported as ``outcome=stopped`` (synthesised if
the engine never sends one within a grace period). ``chat.stop`` closes the
engine outright; a later send starts a fresh engine resuming the same
session.

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
"""

from __future__ import annotations

import asyncio
import http
import json
import logging
import os
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
from .chats import Chat, ChatRegistry, UnknownChat
from .config import Config, hello_for
from .engine import Engine, PermissionDecision, history_events, read_history
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
    ChatHistory,
    ChatList,
    ChatLive,
    ChatNew,
    ChatOpen,
    ChatRemove,
    ChatState,
    ChatStateWord,
    ChatStop,
    ClientMessage,
    Entry,
    Envelope,
    Error,
    FilesList,
    FilesListRequest,
    GatewayStop,
    HelloClient,
    MessageSend,
    ProtocolError,
    ServerMessage,
    StatusSet,
    TextDelta,
    ToolStarted,
    TurnFinished,
    TurnStarted,
    TurnStop,
    UserText,
    dump,
    parse_client,
)
from .state import StateDir

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

# After ``turn.stop`` the engine is given this long to send its own
# ``turn.finished``; then the gateway ends the turn itself so the app is
# never left on a turn that cannot finish.
STOP_GRACE_SECONDS = 15.0

# The exact form attachments take in the text the engine receives
# (PROTOCOL.md, ``message.send``).
ATTACHMENT_HEADER = "Attached files:"


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


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
    finished: asyncio.Event = field(default_factory=asyncio.Event)


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
    ) -> None:
        self.config = config
        self.state = state
        self.registry = registry
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
        # Lifecycle: ``before_first_chat`` runs once per launch; ``stop`` runs once.
        self._preflight_done = False
        self._preflight_lock = asyncio.Lock()
        self._stop_lock = asyncio.Lock()
        self._stopped = False
        # Set once ``stop`` has run; the main loop waits on it, then calls ``shutdown``.
        self.stopping = asyncio.Event()
        self.cards = CardBroker(hold_seconds=config.card_hold_seconds)
        # Reads a session's transcript (``engine.read_history``); replaceable for tests.
        self.history_reader: Callable[[str | None, Path], list[dict[str, Any]]] = read_history
        self.http_routes: dict[tuple[str, str], HttpHandler] = {
            ("GET", "/v1/health"): self._health,
            ("POST", "/v1/artifact"): self._producer,
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
        for task in list(self._tasks):
            task.cancel()
        for chat in self.registry.chats():
            await self.cards.cancel_all(chat, "gateway stopping", self.emit)
            await self._close_engine(chat)
        if server is not None:
            server.close()
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

    async def on_gateway_stop(self, msg: GatewayStop, conn: ServerConnection) -> None:
        await self.stop("the app asked")

    async def _preflight(self) -> None:
        """``before_first_chat``, once per launch; raises ``ProtocolError`` (no chat) when it fails."""
        command = self.config.before_first_chat
        if not command:
            return
        async with self._preflight_lock:
            if self._preflight_done:
                return
            try:
                await run_lifecycle_command(
                    "before-first-chat", command, self._status_line, float(self.config.command_timeout_seconds)
                )
            except CommandFailed as e:
                raise ProtocolError("lifecycle.before_first_chat_failed", f"cannot open a chat: {e}") from e
            self._preflight_done = True

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
        await self._send(conn, hello_for(self.config, self.epoch, self.version))
        await self._send(conn, ChatList(ts=_now(), chats=self.registry.summaries()))
        try:
            async for raw in conn:
                await self._handle_frame(conn, raw)
        except ConnectionClosed:
            pass
        finally:
            if self._app is conn:
                self._app = None
                self.cards.set_attached(False)

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
        if not isinstance(event, TurnFinished):
            if run is not None:
                if isinstance(event, ToolStarted):
                    run.collector.note_tool(event.tool, event.input)
                elif isinstance(event, TextDelta):
                    run.collector.note_text(event.text)
            await self.emit(chat, event)
            return
        if run is None:
            # The turn was already ended by the gateway (chat.stop, or the stop grace ran out).
            log.debug("chat %d: engine finish for turn %d after the turn ended; dropped", chat.number, event.turn)
            return
        if run.stop_requested:
            event = event.model_copy(update={"outcome": "stopped"})
        await self._report_artifacts(chat, run)
        await self.emit(chat, event)
        await self._finish_run(chat, run)

    async def _finish_run(self, chat: Chat, run: TurnRun) -> None:
        if self._runs.get(chat.number) is run:
            del self._runs[chat.number]
        self._sync_session(chat)
        await self.set_state(chat, "idle")
        run.finished.set()

    async def _await_stop(self, chat: Chat, run: TurnRun) -> None:
        """After ``turn.stop``: give the engine its grace, then end the turn on its behalf."""
        try:
            await asyncio.wait_for(run.finished.wait(), STOP_GRACE_SECONDS)
            return
        except TimeoutError:
            pass
        if self._runs.get(chat.number) is not run:
            return
        log.warning("chat %d: engine did not finish turn %d within %.0fs of stop; ending it", chat.number, run.turn, STOP_GRACE_SECONDS)
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
        if self.cards.allowed(chat, tool):
            return "allow"
        run = self._runs.get(chat.number)
        try:
            return await self.cards.ask_permission(chat, tool, input, suggestions, tool_use_id, self._emit_card)
        finally:
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
        self.cards.answer(chat.number, msg.id, msg)
        # The closing goes in the ring before the engine resumes (and the
        # state goes back to working): a replay closes what it opened.
        await self.emit(chat, CardAnswered(ts=_now(), chat=chat.number, id=msg.id))

    # --- handlers: chats --------------------------------------------------------

    async def on_chat_new(self, msg: ChatNew, conn: ServerConnection) -> None:
        folder = Path(msg.folder)
        if not folder.is_absolute() or not folder.is_dir():
            raise ProtocolError("chat.folder_invalid", f"not an absolute path to a directory: {msg.folder}")
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
        # Open cards again, as sent (same id and seq): the app de-duplicates by id.
        for card in self.cards.open_cards(chat):
            await self._send(conn, card)

    async def _history(self, chat: Chat, since: int | None) -> tuple[list[ServerMessage], bool, list[Artifact]]:
        """What ``chat.open`` replays: ring events, or the transcript when the ring cannot serve.

        The ring serves when ``since`` is inside it, or when the chat was
        created this launch and the ring still reaches back to its first
        event. Otherwise the engine's transcript is read and translated;
        the chat's stored artifacts come with it. When there is no
        transcript to read, the ring is the best the gateway has and is
        sent with its own ``truncated`` flag.
        """
        ring, truncated = chat.events_since(since)
        if not truncated and (since is not None or not chat.restored):
            return ring, truncated, []
        transcript = await asyncio.to_thread(self.history_reader, chat.session_id, chat.folder)
        events = history_events(transcript, chat.number)
        if not events:
            replayed = {e.artifact.id for e in ring if isinstance(e, ArtifactCreated)}
            return ring, truncated, [a for a in chat.artifacts if a.id not in replayed]
        # Live turns continue the transcript's numbering when none has run yet this launch.
        turns = sum(1 for e in events if isinstance(e, TurnStarted))
        if chat.turn == 0 and chat.number not in self._runs:
            chat.turn = turns
        return events, False, list(chat.artifacts)

    async def on_chat_stop(self, msg: ChatStop, conn: ServerConnection) -> None:
        chat = self.registry.get(msg.chat)
        run = self._runs.get(chat.number)
        await self.cards.cancel_all(chat, "chat stopped", self.emit)
        await self._close_engine(chat)
        if run is not None:
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

    # --- handlers: turns --------------------------------------------------------

    async def on_message_send(self, msg: MessageSend, conn: ServerConnection) -> None:
        chat = self.registry.get(msg.chat)
        if chat.number in self._runs:
            raise ProtocolError("chat.busy", f"a turn is already running in chat {chat.number}")
        attachments = check_attachments(msg.attachments)
        engine = chat.engine
        if engine is None:
            try:
                engine = await self._start_engine(chat)
            except ProtocolError:
                raise  # the preflight refused: lifecycle.before_first_chat_failed, as on chat.new
            except Exception as e:
                log.exception("chat %d: engine failed to start", chat.number)
                raise ProtocolError("engine.start_failed", f"the engine could not start in {chat.folder}: {e}") from e
        text = with_attachments(msg.text, attachments)

        chat.turn += 1
        run = TurnRun(turn=chat.turn, collector=TurnCollector(chat))
        self._runs[chat.number] = run
        await self.emit(chat, TurnStarted(ts=_now(), chat=chat.number, turn=chat.turn))
        # The person's words go in the ring too, as the engine receives them,
        # so a replay from this launch reads as a conversation, not a monologue.
        await self.emit(chat, UserText(ts=_now(), chat=chat.number, turn=chat.turn, text=text))
        await self.set_state(chat, "working")
        # ``send`` advances the engine's own turn counter; align it so the
        # engine's events carry this turn even after an engine restart.
        engine.turn = chat.turn - 1
        try:
            await engine.send(text)
        except Exception as e:
            log.exception("chat %d: engine send failed", chat.number)
            await self.emit(chat, TurnFinished(ts=_now(), chat=chat.number, turn=run.turn, outcome="error"))
            await self._finish_run(chat, run)
            raise ProtocolError("engine.send_failed", f"the engine refused the message: {e}") from e

    async def on_turn_stop(self, msg: TurnStop, conn: ServerConnection) -> None:
        chat = self.registry.get(msg.chat)
        run = self._runs.get(chat.number)
        if run is None or chat.engine is None:
            return  # nothing running: a stop is harmless
        run.stop_requested = True
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
