"""v0.11 (item 74): messages typed while the agent works are queued, not refused.

A ``message.send`` during a turn (or the log step) from an app that
declared ``queue.v1`` is answered ``chat.queued`` and held; ``chat.queue``
carries the list after every change and on ``chat.open``. The gateway
writes held messages into the turn at the main agent's next tool result
(``Engine.inject``: same turn, a ``user.text`` there), or sends the first
as the next turn when the turn ends with them still held. ``chat.unqueue``
takes one back. An app without ``queue.v1`` still gets ``chat.busy``
(``test_turns.test_send_while_working_is_busy_error``).
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection, connect

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.messages import (
    ChatLive,
    ChatOpen,
    ChatQueue,
    ChatQueued,
    ChatState,
    ChatStop,
    ChatUnqueue,
    Error,
    HelloClient,
    HelloServer,
    MessageSend,
    SessionLog,
    SessionLogged,
    SessionRenew,
    SessionRenewed,
    ToolFinished,
    TurnFinished,
    TurnStarted,
    TurnStop,
    UserText,
    dump,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from tests.conftest import Pause, fake_result, make_config
from tests.test_server import ws_url
from tests.test_turns import EngineFactory, TS, new_chat, recv, recv_until, text_delta, tool_result, tool_use


async def start(state_dir: StateDir, factory: EngineFactory, **config: object) -> GatewayServer:
    cfg = make_config(setting_sources=["project"], **config)
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=cfg.history_buffer)
    srv = GatewayServer(config=cfg, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    return srv


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
async def server(state_dir: StateDir, factory: EngineFactory) -> AsyncIterator[GatewayServer]:
    srv = await start(state_dir, factory)
    try:
        yield srv
    finally:
        await srv.shutdown()


@pytest.fixture
async def logging_server(state_dir: StateDir, factory: EngineFactory) -> AsyncIterator[GatewayServer]:
    srv = await start(state_dir, factory, log_prompt="/log-it")
    try:
        yield srv
    finally:
        await srv.shutdown()


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = tmp_path / "demo"
    path.mkdir()
    return path


async def attach_queueing(server: GatewayServer) -> ClientConnection:
    """An app that declared ``queue.v1``: hello, chat.list, services.status."""
    conn = await connect(ws_url(server, server.token))
    await conn.send(dump(HelloClient(ts=TS, app_version="0.11.0", capabilities=["queue.v1"])))
    hello = await recv(conn)
    assert isinstance(hello, HelloServer) and "queue.v1" in hello.capabilities
    await recv(conn)  # chat.list
    await recv(conn)  # services.status
    return conn


async def queue(conn: ClientConnection, number: int, text: str, id: str) -> ChatQueue:
    """Send during a turn; expects ``chat.queued`` (after the turn's frames so far) then ``chat.queue``."""
    await conn.send(dump(MessageSend(ts=TS, chat=number, id=id, text=text)))
    queued = (await recv_until(conn, ChatQueued))[-1]
    assert isinstance(queued, ChatQueued) and queued.id == id and queued.chat == number, queued
    listing = await recv(conn)
    assert isinstance(listing, ChatQueue), listing
    return listing


async def busy_turn(conn: ClientConnection, number: int, text: str = "first") -> None:
    await conn.send(dump(MessageSend(ts=TS, chat=number, id="req-1", text=text)))
    await recv_until(conn, ChatState)  # turn.started, user.text, chat.state working


async def test_a_send_during_a_turn_is_queued_and_goes_at_the_next_tool_result(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach_queueing(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        pause = Pause()
        engine.script(
            tool_use("toolu_1", "Bash", {"command": "ls"}),
            pause,
            tool_result("toolu_1", "a.md"),
            text_delta("Checked uvx too."),
            fake_result(),
        )
        await busy_turn(conn, number)
        await asyncio.wait_for(pause.reached.wait(), 5)

        listing = await queue(conn, number, "Also check uvx.", "req-2")
        assert [(i.id, i.text) for i in listing.items] == [("req-2", "Also check uvx.")]
        # Held, not written: the engine has only the first message so far.
        assert [c for c in engine.calls if c[0] in ("send", "inject")] == [("send", "first")]
        ring = server.registry.get(number).ring
        assert not any(isinstance(m, (ChatQueued, ChatQueue)) for m in ring), "the queue is not history"

        pause.go.set()
        frames = await recv_until(conn, TurnFinished)
        assert ("inject", "Also check uvx.") in engine.calls
        kinds = [type(m) for m in frames]
        # The tool's result ends the step; the queue empties and the message
        # is the person's, inside the same turn; then the agent goes on.
        assert kinds[:3] == [ToolFinished, ChatQueue, UserText]
        emptied = frames[1]
        assert isinstance(emptied, ChatQueue) and emptied.items == []
        said = frames[2]
        assert isinstance(said, UserText) and said.text == "Also check uvx." and said.turn == 1 and said.seq is not None
        finished = frames[-1]
        assert isinstance(finished, TurnFinished) and finished.turn == 1
        assert [m for m in frames if isinstance(m, TurnStarted)] == []
        await recv(conn)  # chat.state idle
        assert [c for c in engine.calls if c[0] == "send"] == [("send", "first")], "no second turn"
    finally:
        await conn.close()


async def test_a_message_still_held_at_the_turns_end_goes_as_the_next_turn(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach_queueing(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        pause = Pause()
        engine.script(text_delta("Thinking it over."), pause, fake_result())
        await busy_turn(conn, number)
        await asyncio.wait_for(pause.reached.wait(), 5)
        await queue(conn, number, "one", "req-2")
        await queue(conn, number, "two", "req-3")

        pause.go.set()
        frames = await recv_until(conn, UserText)
        # The first turn ends; the first held message is the next turn, in order.
        finished = next(m for m in frames if isinstance(m, TurnFinished))
        assert finished.turn == 1
        listing = [m for m in frames if isinstance(m, ChatQueue)][-1]
        assert [i.text for i in listing.items] == ["two"]
        started = next(m for m in frames if isinstance(m, TurnStarted))
        assert started.turn == 2
        assert frames[-1].text == "one"  # type: ignore[union-attr]
        # The second waits for that turn: no tool result, so it goes at its end.
        frames = await recv_until(conn, UserText)
        assert frames[-1].text == "two" and frames[-1].turn == 3  # type: ignore[union-attr]
        await recv_until(conn, TurnFinished)
        assert [c for c in engine.calls if c[0] == "send"] == [("send", "first"), ("send", "one"), ("send", "two")]
    finally:
        await conn.close()


async def test_unqueue_takes_a_message_back_before_it_goes(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach_queueing(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        pause = Pause()
        engine.script(pause, fake_result())
        await busy_turn(conn, number)
        await asyncio.wait_for(pause.reached.wait(), 5)
        await queue(conn, number, "never mind", "req-2")

        await conn.send(dump(ChatUnqueue(ts=TS, chat=number, id="req-2")))
        listing = await recv(conn)
        assert isinstance(listing, ChatQueue) and listing.items == []
        # Gone already: said so, with the request's id.
        await conn.send(dump(ChatUnqueue(ts=TS, chat=number, id="req-2")))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "chat.not_queued" and err.id == "req-2"

        pause.go.set()
        await recv_until(conn, TurnFinished)
        await recv(conn)  # chat.state idle
        await asyncio.sleep(0.05)
        assert [c for c in engine.calls if c[0] in ("send", "inject")] == [("send", "first")]
    finally:
        await conn.close()


async def test_a_subagents_tool_result_does_not_deliver(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach_queueing(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        pause = Pause()
        engine.script(pause, fake_result())
        await busy_turn(conn, number)
        await asyncio.wait_for(pause.reached.wait(), 5)
        await queue(conn, number, "later", "req-2")

        chat = server.registry.get(number)
        await server.engine_event(
            chat, ToolFinished(ts=TS, chat=number, turn=1, tool_use_id="toolu_sub", ok=True, agent_id="a1")
        )
        assert not [c for c in engine.calls if c[0] == "inject"]
        assert [i.text for i in server.queued(number)] == ["later"]
        pause.go.set()
        await recv_until(conn, UserText)
        assert ("send", "later") in engine.calls
    finally:
        await conn.close()


async def test_a_slash_command_waits_for_the_turns_end(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach_queueing(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        pause = Pause()
        engine.script(tool_use("toolu_1", "Bash", {"command": "ls"}), pause, tool_result("toolu_1", "ok"), fake_result())
        await busy_turn(conn, number)
        await asyncio.wait_for(pause.reached.wait(), 5)
        await queue(conn, number, "/review", "req-2")
        await queue(conn, number, "and this", "req-3")

        pause.go.set()
        frames = await recv_until(conn, UserText)
        # Nothing went mid-turn (the command is first, order holds); the
        # command is the next turn, as typed.
        assert not [c for c in engine.calls if c[0] == "inject"]
        assert frames[-1].text == "/review" and frames[-1].turn == 2  # type: ignore[union-attr]
        frames = await recv_until(conn, UserText)
        assert frames[-1].text == "and this" and frames[-1].turn == 3  # type: ignore[union-attr]
    finally:
        await conn.close()


async def test_chat_open_sends_the_queue_after_chat_live(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach_queueing(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        pause = Pause()
        engine.script(pause, fake_result())
        await busy_turn(conn, number)
        await asyncio.wait_for(pause.reached.wait(), 5)
        await queue(conn, number, "held", "req-2")
        await conn.close()

        conn = await attach_queueing(server)
        await conn.send(dump(ChatOpen(ts=TS, chat=number, id="req-o")))
        frames = await recv_until(conn, ChatQueue)
        kinds = [type(m) for m in frames]
        assert kinds.index(ChatLive) < kinds.index(ChatQueue)
        assert [i.text for i in frames[-1].items] == ["held"]  # type: ignore[union-attr]
        pause.go.set()
    finally:
        await conn.close()


async def test_chat_stop_drops_the_queue(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach_queueing(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        pause = Pause()
        engine.script(pause, fake_result())
        await busy_turn(conn, number)
        await asyncio.wait_for(pause.reached.wait(), 5)
        await queue(conn, number, "held", "req-2")

        await conn.send(dump(ChatStop(ts=TS, chat=number)))
        frames = await recv_until(conn, ChatQueue)
        assert frames[-1].items == []  # type: ignore[union-attr]
        assert server.queued(number) == []
        assert not [c for c in engine.calls if c[0] == "inject" or c == ("send", "held")]
    finally:
        await conn.close()


async def test_a_stopped_turn_still_sends_what_was_held(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    from tests.conftest import Block

    conn = await attach_queueing(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        engine.script(Block())
        await busy_turn(conn, number)
        await engine.wait_blocked()
        await queue(conn, number, "do this instead", "req-2")

        await conn.send(dump(TurnStop(ts=TS, chat=number)))
        frames = await recv_until(conn, UserText)
        assert next(m for m in frames if isinstance(m, TurnFinished)).outcome == "stopped"
        assert frames[-1].text == "do this instead"  # type: ignore[union-attr]
    finally:
        await conn.close()


async def test_a_send_during_the_log_step_goes_into_it(
    logging_server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    server = logging_server
    conn = await attach_queueing(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        pause = Pause()
        # The log step asks for a rating, then writes the log.
        engine.script(
            text_delta("How would you rate the session?"),
            tool_use("toolu_1", "Read", {"file_path": "/tmp/x"}),
            pause,
            tool_result("toolu_1", "ok"),
            text_delta("Logged."),
            fake_result(),
        )
        await conn.send(dump(SessionLog(ts=TS, id="req-l", chat=number)))
        await recv_until(conn, ChatState)
        await asyncio.wait_for(pause.reached.wait(), 5)
        await queue(conn, number, "8/10", "req-2")

        pause.go.set()
        frames = await recv_until(conn, SessionLogged)
        assert ("inject", "8/10") in engine.calls
        said = [m.text for m in frames if isinstance(m, UserText)]
        assert said == ["8/10"]
        assert len([m for m in frames if isinstance(m, TurnFinished)]) == 1
    finally:
        await conn.close()


async def test_a_message_held_through_the_log_step_goes_after_it(
    logging_server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    server = logging_server
    conn = await attach_queueing(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        pause = Pause()
        engine.script(pause, fake_result())
        await conn.send(dump(SessionLog(ts=TS, id="req-l", chat=number)))
        await recv_until(conn, ChatState)
        await asyncio.wait_for(pause.reached.wait(), 5)
        await queue(conn, number, "next thing", "req-2")

        pause.go.set()
        frames = await recv_until(conn, UserText)
        kinds = [type(m) for m in frames]
        # The log step finishes and answers first; then the held message is a turn.
        assert kinds.index(SessionLogged) < kinds.index(UserText)
        assert frames[-1].text == "next thing"  # type: ignore[union-attr]
        assert engine.calls[-1] == ("send", "next thing")
    finally:
        await conn.close()


async def test_a_message_held_through_a_renewal_goes_to_the_next_session(
    logging_server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    server = logging_server
    conn = await attach_queueing(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        pause = Pause()
        engine.script(pause, fake_result())
        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=number, log=True)))
        await recv_until(conn, ChatState)
        await asyncio.wait_for(pause.reached.wait(), 5)
        await queue(conn, number, "carry on", "req-2")

        pause.go.set()
        frames = await recv_until(conn, SessionRenewed)
        following = frames[-1].next.chat  # type: ignore[union-attr]
        frames = await recv_until(conn, UserText)
        said = frames[-1]
        assert isinstance(said, UserText) and said.chat == following and said.text == "carry on"
        assert server.queued(number) == []
        assert factory.last.calls[-1] == ("send", "carry on")
    finally:
        await conn.close()
