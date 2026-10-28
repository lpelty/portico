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

Message handlers register by type name (``register``); this task wires the
handshake and the dispatch table, later tasks add the handlers.
"""

from __future__ import annotations

import asyncio
import http
import json
import logging
import os
import secrets
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any
from urllib.parse import parse_qs, urlsplit

from websockets.asyncio.server import Server, ServerConnection, serve
from websockets.exceptions import ConnectionClosed
from websockets.http11 import Request, Response
from websockets.server import ServerProtocol

from .chats import ChatRegistry, UnknownChat
from .config import Config, hello_for
from .engine import Engine
from .messages import (
    PROTOCOL_VERSION,
    ChatList,
    ClientMessage,
    Envelope,
    Error,
    HelloClient,
    ProtocolError,
    ServerMessage,
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


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


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
        self.http_routes: dict[tuple[str, str], HttpHandler] = {("GET", "/v1/health"): self._health}

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
        if app is not None:
            await app.close(CLOSE_GOING_AWAY, "gateway stopping")
        for chat in self.registry.chats():
            engine, chat.engine = chat.engine, None
            if engine is not None:
                try:
                    await engine.close()
                except Exception:
                    log.exception("closing engine for chat %d failed", chat.number)
        if server is not None:
            server.close()
            await server.wait_closed()
        self.state.clear_ledger()
        self.registry.persist()

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

    async def _attach(self, conn: ServerConnection) -> None:
        previous, self._app = self._app, conn
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
