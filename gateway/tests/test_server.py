"""Task 6: the WebSocket server — token at connect, hello handshake, dispatch, ready sentinel.

A real ``websockets`` client talks to the server on an ephemeral port; the
engine behind every chat is the scripted ``FakeEngine`` from ``conftest``.
"""

from __future__ import annotations

import asyncio
import json
import os
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection, connect
from websockets.exceptions import ConnectionClosed, InvalidStatus

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import Config
from portico_gateway.messages import (
    ChatList,
    ChatOpen,
    Error,
    FilesListRequest,
    HelloClient,
    HelloServer,
    ServicesStatus,
    StatusSet,
    dump,
    parse_server,
)
from portico_gateway.server import PROTOCOL_PATH, READY_PREFIX, GatewayServer
from portico_gateway.state import StateDir
from tests.conftest import FakeEngine

TS = "2026-10-27T12:00:00Z"
FOLDER = "/Users/someone/projects/demo"


# --- fixtures -----------------------------------------------------------------


def make_server(state_dir: StateDir, config: Config) -> GatewayServer:
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    return GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=FakeEngine, version=__version__)


@pytest.fixture
async def server(state_dir: StateDir, config: Config) -> AsyncIterator[GatewayServer]:
    srv = make_server(state_dir, config)
    await srv.serve(0)
    try:
        yield srv
    finally:
        await srv.shutdown()


def ws_url(server: GatewayServer, token: str | None = None) -> str:
    base = f"ws://127.0.0.1:{server.port}{PROTOCOL_PATH}"
    return base if token is None else f"{base}?token={token}"


async def attach(server: GatewayServer) -> ClientConnection:
    """Connect with the token and complete the hello handshake; returns the live connection.

    The handshake is ``hello``, ``chat.list`` and (v0.4) ``services.status``.
    """
    conn = await connect(ws_url(server, server.token))
    await conn.send(dump(HelloClient(ts=TS, app_version="0.1.0")))
    assert isinstance(parse_server(await conn.recv()), HelloServer)
    assert isinstance(parse_server(await conn.recv()), ChatList)
    assert isinstance(parse_server(await conn.recv()), ServicesStatus)
    return conn


async def http_get(port: int, path: str) -> tuple[int, dict[str, str], bytes]:
    """One plain HTTP/1.1 GET over a raw socket; returns status, headers (lowercased), body."""
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".encode())
    await writer.drain()
    raw = await asyncio.wait_for(reader.read(), 5)
    writer.close()
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.decode().split("\r\n")
    status = int(lines[0].split(" ")[1])
    headers = {k.strip().lower(): v.strip() for k, v in (line.split(":", 1) for line in lines[1:])}
    return status, headers, body


# --- tests --------------------------------------------------------------------


async def test_ready_line_and_ledger(state_dir: StateDir, config: Config, capsys: pytest.CaptureFixture[str]) -> None:
    server = make_server(state_dir, config)
    try:
        port = await server.serve(0)
        assert port == server.port > 0
        out = capsys.readouterr().out
        assert f"{READY_PREFIX} port={server.port}" in out.splitlines()

        ledger = state_dir.read_ledger()
        assert ledger is not None
        assert (ledger.host, ledger.port, ledger.pid) == ("127.0.0.1", server.port, os.getpid())
        assert ledger.epoch == server.epoch

        # The token the app must present is the one on disk, mode 0600.
        assert state_dir.read_token() == server.token
        assert oct(state_dir.token_path.stat().st_mode & 0o777) == "0o600"
    finally:
        await server.shutdown()


async def test_connect_without_token_is_401(server: GatewayServer) -> None:
    with pytest.raises(InvalidStatus) as missing:
        await connect(ws_url(server))
    assert missing.value.response.status_code == 401

    with pytest.raises(InvalidStatus) as wrong:
        await connect(ws_url(server, "not-the-token"))
    assert wrong.value.response.status_code == 401
    assert not server.attached


async def test_hello_handshake_returns_hello_and_chat_list(server: GatewayServer, config: Config) -> None:
    server.registry.create(Path(FOLDER))
    conn = await connect(ws_url(server, server.token))
    try:
        await conn.send(dump(HelloClient(ts=TS, app_version="0.1.0")))

        hello = parse_server(await conn.recv())
        assert isinstance(hello, HelloServer)
        assert hello.protocol == 1
        assert hello.epoch == server.epoch
        assert hello.gateway_version == __version__
        assert hello.brand == config.brand.for_hello()
        assert hello.actions == config.actions
        assert hello.roots == config.roots

        listing = parse_server(await conn.recv())
        assert isinstance(listing, ChatList)
        assert [c.chat for c in listing.chats] == [1]
        assert listing.chats[0].folder == FOLDER
        services = parse_server(await conn.recv())
        assert isinstance(services, ServicesStatus) and services.services == [], "no [[services]]: an empty list"
        assert server.attached
    finally:
        await conn.close()


async def test_non_hello_first_frame_is_error(server: GatewayServer) -> None:
    conn = await connect(ws_url(server, server.token))
    await conn.send(dump(ChatOpen(ts=TS, chat=1)))

    err = parse_server(await conn.recv())
    assert isinstance(err, Error)
    assert err.code == "protocol.hello_required"
    with pytest.raises(ConnectionClosed):
        await asyncio.wait_for(conn.recv(), 5)
    assert not server.attached


async def test_unparseable_first_frame_is_error_and_close(server: GatewayServer) -> None:
    conn = await connect(ws_url(server, server.token))
    await conn.send("not json")
    err = parse_server(await conn.recv())
    assert isinstance(err, Error)
    assert err.code == "protocol.invalid"
    with pytest.raises(ConnectionClosed):
        await asyncio.wait_for(conn.recv(), 5)


async def test_hello_with_another_protocol_version_is_refused_in_plain_words(server: GatewayServer) -> None:
    conn = await connect(ws_url(server, server.token))
    await conn.send(json.dumps({"type": "hello", "protocol": 2, "app_version": "9.0.0", "ts": TS}))
    err = parse_server(await conn.recv())
    assert isinstance(err, Error)
    assert err.code == "protocol.version"
    assert "protocol 2" in err.message and "protocol 1" in err.message
    with pytest.raises(ConnectionClosed):
        await asyncio.wait_for(conn.recv(), 5)
    assert not server.attached


async def test_second_connection_replaces_first(server: GatewayServer) -> None:
    first = await attach(server)
    second = await attach(server)
    try:
        replaced = parse_server(await asyncio.wait_for(first.recv(), 5))
        assert isinstance(replaced, Error)
        assert replaced.code == "session.replaced"
        with pytest.raises(ConnectionClosed):
            await asyncio.wait_for(first.recv(), 5)

        # The survivor is the attached app: a broadcast reaches it alone.
        assert server.attached
        await server.broadcast(StatusSet(ts=TS, text="hello, second"))
        status = parse_server(await asyncio.wait_for(second.recv(), 5))
        assert isinstance(status, StatusSet)
        assert status.text == "hello, second"
    finally:
        await second.close()
    await asyncio.sleep(0.05)
    assert not server.attached


async def test_bad_frame_after_hello_is_error_not_close(server: GatewayServer) -> None:
    conn = await attach(server)
    try:
        await conn.send(json.dumps({"type": "nope", "ts": TS}))
        err = parse_server(await asyncio.wait_for(conn.recv(), 5))
        assert isinstance(err, Error)
        assert err.code == "protocol.unknown_type"

        # Still attached: the connection survives a bad frame.
        await server.broadcast(StatusSet(ts=TS, text="still here"))
        status = parse_server(await asyncio.wait_for(conn.recv(), 5))
        assert isinstance(status, StatusSet)
    finally:
        await conn.close()


async def test_unhandled_known_type_answers_with_error_and_id(server: GatewayServer) -> None:
    # Every client type has a handler since Task 12; unregister one to exercise the dispatch fallback.
    del server._handlers["files.list"]
    conn = await attach(server)
    try:
        await conn.send(dump(FilesListRequest(ts=TS, chat=1, id="req-9", root="chat", path="")))
        err = parse_server(await asyncio.wait_for(conn.recv(), 5))
        assert isinstance(err, Error)
        assert err.id == "req-9"
        assert err.chat == 1
        assert err.code == "protocol.unsupported"
    finally:
        await conn.close()


async def test_health_needs_no_token(server: GatewayServer) -> None:
    status, headers, body = await http_get(server.port, "/v1/health")
    assert status == 200
    assert headers["content-type"].startswith("application/json")
    assert json.loads(body) == {"epoch": server.epoch, "protocol": 1}


async def test_unknown_http_route_is_404(server: GatewayServer) -> None:
    status, _, body = await http_get(server.port, "/v1/nothing")
    assert status == 404
    assert json.loads(body)["error"]


async def test_shutdown_closes_app_and_clears_ledger(state_dir: StateDir, config: Config) -> None:
    srv = make_server(state_dir, config)
    await srv.serve(0)
    conn = await attach(srv)
    await srv.shutdown()
    with pytest.raises(ConnectionClosed):
        await asyncio.wait_for(conn.recv(), 5)
    assert state_dir.read_ledger() is None
    assert not srv.attached


async def test_shutdown_completes_with_a_client_that_never_said_hello(state_dir: StateDir, config: Config) -> None:
    # A connection with a valid token that sends nothing: shutdown must close
    # it and return, not wait on it forever (and leave the ledger behind).
    srv = make_server(state_dir, config)
    await srv.serve(0)
    conn = await connect(ws_url(srv, srv.token))
    try:
        await asyncio.wait_for(srv.shutdown(), 5)
        with pytest.raises(ConnectionClosed):
            await asyncio.wait_for(conn.recv(), 5)
        assert state_dir.read_ledger() is None
    finally:
        await conn.close()


# --- v0.3: a stale config, the status route ----------------------------------------


async def test_config_newer_than_the_start_is_said_once_and_in_hello(
    state_dir: StateDir, config: Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    import portico_gateway.server as server_mod
    from portico_gateway.messages import ConfigStale

    monkeypatch.setattr(server_mod, "CONFIG_CHECK_SECONDS", 0.05)
    path = state_dir.config_path
    path.write_text("")
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(
        config=config, state=state_dir, registry=registry, engine_factory=FakeEngine, version=__version__, config_path=path
    )
    await srv.serve(0)
    try:
        conn = await connect(ws_url(srv, srv.token))
        await conn.send(dump(HelloClient(ts=TS, app_version="0.3.0")))
        hello = parse_server(await conn.recv())
        assert isinstance(hello, HelloServer) and hello.config_stale is False
        await conn.recv()  # chat.list
        await conn.recv()  # services.status
        assert srv.status()["config_stale"] is False

        later = path.stat().st_mtime + 5
        os.utime(path, (later, later))
        stale = parse_server(await asyncio.wait_for(conn.recv(), 5))
        assert isinstance(stale, ConfigStale) and stale.seq is None
        with pytest.raises(TimeoutError):  # once
            await asyncio.wait_for(conn.recv(), 0.3)
        await conn.close()

        # An app that attaches later reads it in hello.
        again = await connect(ws_url(srv, srv.token))
        await again.send(dump(HelloClient(ts=TS, app_version="0.3.0")))
        hello = parse_server(await again.recv())
        assert isinstance(hello, HelloServer) and hello.config_stale is True
        await again.close()
    finally:
        await srv.shutdown()


async def test_status_route_needs_the_token_and_names_the_live_session(server: GatewayServer, tmp_path: Path) -> None:
    status, _, body = await http_get(server.port, "/v1/status")
    assert status == 401
    first = server.registry.create(tmp_path)
    first.ended = "2026-10-28T00:00:00Z"
    live = server.registry.create(tmp_path)
    live.mode = "default"
    got = server.status()
    assert got["version"] == 1 and got["running"] is True and got["pid"] == os.getpid() and got["port"] == server.port
    assert (got["session"], got["folder"], got["state"], got["mode"]) == (live.number, str(tmp_path), "idle", "default")
    assert got["config_stale"] is False and "started_at" in got


async def test_update_check_at_start_reaches_the_app_now_and_later(state_dir: StateDir, tmp_path: Path) -> None:
    from portico_gateway.messages import UpdateAvailable
    from tests.conftest import make_config

    gate = tmp_path / "go"
    config = make_config(update={"check": f"while [ ! -f {gate} ]; do sleep 0.05; done; echo 0.3.1", "run": "true"})
    srv = make_server(state_dir, config)
    await srv.serve(0)
    try:
        conn = await connect(ws_url(srv, srv.token))
        await conn.send(dump(HelloClient(ts=TS, app_version="0.3.0")))
        hello = parse_server(await conn.recv())
        assert isinstance(hello, HelloServer) and hello.can_update is True
        await conn.recv()  # chat.list: the check runs in the background and blocks nothing
        await conn.recv()  # services.status
        gate.write_text("")
        found = parse_server(await asyncio.wait_for(conn.recv(), 5))
        assert isinstance(found, UpdateAvailable) and found.version == "0.3.1"
        await conn.close()

        again = await connect(ws_url(srv, srv.token))
        await again.send(dump(HelloClient(ts=TS, app_version="0.3.0")))
        assert isinstance(parse_server(await again.recv()), HelloServer)
        assert isinstance(parse_server(await again.recv()), ChatList)
        assert isinstance(parse_server(await again.recv()), ServicesStatus)
        later = parse_server(await again.recv())
        assert isinstance(later, UpdateAvailable) and later.version == "0.3.1"
        await again.close()
    finally:
        await srv.shutdown()
