"""v0.3: permissions at the right altitude — the session's mode, one permission unit, session allows that last.

A real ``websockets`` client against the server on an ephemeral port; the
engine behind every chat is the scripted ``FakeEngine`` from ``conftest``.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path

import pytest

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import Config
from portico_gateway.messages import (
    ChatHistory,
    ChatList,
    ChatLive,
    ChatOpen,
    ChatState,
    ChatStop,
    Error,
    MessageSend,
    SessionMode,
    SessionRenew,
    SessionRenewed,
    TurnFinished,
    dump,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from tests.conftest import make_config
from tests.test_server import attach
from tests.test_turns import EngineFactory, new_chat, recv, recv_until

TS = "2026-10-28T12:00:00Z"


async def start_server(state_dir: StateDir, factory: EngineFactory, **overrides: object) -> GatewayServer:
    cfg: Config = make_config(**overrides)
    registry = ChatRegistry(
        index=state_dir.load_index(), state=state_dir, history_buffer=cfg.history_buffer, default_mode=cfg.permission_mode
    )
    srv = GatewayServer(config=cfg, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    return srv


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
async def server(state_dir: StateDir, factory: EngineFactory) -> AsyncIterator[GatewayServer]:
    srv = await start_server(state_dir, factory)
    try:
        yield srv
    finally:
        await srv.shutdown()


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = tmp_path / "demo"
    path.mkdir()
    return path


async def turn(conn, number: int, text: str = "go") -> list:  # noqa: ANN001
    await conn.send(dump(MessageSend(ts=TS, chat=number, text=text)))
    frames = await recv_until(conn, TurnFinished)
    frames.append(await recv(conn))  # chat.state idle
    return frames


# --- the session's permission mode ----------------------------------------------


async def test_a_new_session_starts_in_the_deployment_mode(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        assert factory.last.started_mode == "auto"  # the v0.3 default
        chat = server.registry.get(number)
        assert chat.mode == "auto" and chat.summary().mode == "auto"
        assert state_of(server, number).mode == "auto"
    finally:
        await conn.close()


def state_of(server: GatewayServer, number: int) -> ChatState:
    states = [m for m in server.registry.get(number).ring if isinstance(m, ChatState)]
    return states[-1]


async def test_the_deployment_mode_comes_from_config(state_dir: StateDir, factory: EngineFactory, folder: Path) -> None:
    srv = await start_server(state_dir, factory, permission_mode="default")
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        assert factory.last.started_mode == "default"
        assert srv.registry.get(number).mode == "default"
    finally:
        await conn.close()
        await srv.shutdown()


async def test_session_mode_changes_the_running_engine_and_is_kept(
    server: GatewayServer, factory: EngineFactory, folder: Path, state_dir: StateDir
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        await conn.send(dump(SessionMode(ts=TS, id="req-mode", chat=number, mode="default")))
        reply = await recv(conn)
        assert isinstance(reply, ChatState) and reply.id == "req-mode"
        assert reply.mode == "default" and reply.state == "idle" and reply.seq is not None
        assert engine.mode_changes == ["default"]
        assert server.registry.get(number).summary().mode == "default"
        assert [c.mode for c in state_dir.load_index().chats] == ["default"]

        # A later engine (after chat.stop) starts in the session's mode, not the deployment's.
        await conn.send(dump(ChatStop(ts=TS, chat=number)))
        await recv(conn)
        await turn(conn, number)
        assert len(factory.engines) == 2 and factory.last.started_mode == "default"
    finally:
        await conn.close()


async def test_session_mode_without_an_engine_is_recorded_for_the_next(
    state_dir: StateDir, factory: EngineFactory, folder: Path
) -> None:
    first = await start_server(state_dir, factory)
    conn = await attach(first)
    number = await new_chat(conn, folder)
    await conn.close()
    await first.shutdown()

    # After a restart the chat has no engine until its next message.
    srv = await start_server(state_dir, factory)
    conn = await attach(srv)
    try:
        await conn.send(dump(SessionMode(ts=TS, chat=number, mode="acceptEdits")))
        reply = await recv(conn)
        assert isinstance(reply, ChatState) and reply.mode == "acceptEdits"
        assert len(factory.engines) == 1, "no engine is started just to change the mode"
        await turn(conn, number)
        assert factory.last.started_mode == "acceptEdits"
    finally:
        await conn.close()
        await srv.shutdown()


async def test_session_mode_errors(state_dir: StateDir, factory: EngineFactory, folder: Path) -> None:
    srv = await start_server(state_dir, factory, presentation="single")
    conn = await attach(srv)
    try:
        await conn.send(dump(SessionMode(ts=TS, id="r1", chat=99, mode="auto")))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "chat.unknown" and err.id == "r1"

        number = await new_chat(conn, folder)
        await conn.send(dump(SessionMode(ts=TS, chat=number, mode="default")))
        await recv(conn)
        await conn.send(dump(SessionRenew(ts=TS, id="r2", chat=number, log=False)))
        renewed = await recv_until(conn, SessionRenewed)
        assert isinstance(renewed[-1], SessionRenewed)
        # The next session starts with the deployment's mode, not the one chosen in the last.
        assert renewed[-1].next.mode == "auto"
        assert isinstance(await recv(conn), ChatList)

        await conn.send(dump(SessionMode(ts=TS, id="r3", chat=number, mode="auto")))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "session.ended" and err.id == "r3"
    finally:
        await conn.close()
        await srv.shutdown()


async def test_chat_open_says_the_state_and_mode_after_live(server: GatewayServer, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        seq = server.registry.get(number).seq
        await conn.send(dump(ChatOpen(ts=TS, id="req-open", chat=number, since=seq)))
        assert isinstance(await recv(conn), ChatHistory)
        assert isinstance(await recv(conn), ChatLive)
        state = await recv(conn)
        assert isinstance(state, ChatState) and state.mode == "auto" and state.state == "idle"
        assert state.id == "req-open" and state.seq is None, "a direct reply: opening adds nothing to the history"
        assert server.registry.get(number).seq == seq
    finally:
        await conn.close()
