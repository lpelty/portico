"""v0.2: context usage after every turn, and compaction reported as ``chat.compacted``.

After a turn ends the gateway asks the engine how full the context window
is and sends ``context.usage`` (not stamped: it is a reading, not history);
the record keeps the last percentage. The engine's ``PreCompact`` hook
reaches the server as ``on_compacted`` and goes out as a stamped
``chat.compacted``, counted in the record's ``compactions``.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from pathlib import Path

import pytest

from portico_gateway.messages import ChatCompacted, ChatOpen, ChatHistory, ChatState, ContextUsage, MessageSend, TurnFinished, dump
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from tests.conftest import Compact, fake_result
from tests.test_server import attach
from tests.test_sessions import drain, start_server
from tests.test_turns import EngineFactory, new_chat, recv, recv_until

TS = "2026-10-28T12:00:00Z"


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = tmp_path / "demo"
    path.mkdir()
    return path


@pytest.fixture
async def server(state_dir: StateDir, factory: EngineFactory) -> AsyncIterator[GatewayServer]:
    srv = await start_server(state_dir, factory)
    try:
        yield srv
    finally:
        await srv.shutdown()


async def test_context_usage_follows_every_turn(server: GatewayServer, factory: EngineFactory, folder: Path, state_dir: StateDir) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        factory.last.context = (62.4, "some-model")
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
        got = await recv_until(conn, ContextUsage)
        usage = got[-1]
        assert isinstance(usage, ContextUsage)
        assert (usage.chat, usage.percent, usage.model) == (number, 62.4, "some-model")
        assert usage.seq is None
        assert any(isinstance(m, TurnFinished) for m in got)
        assert server.registry.get(number).context_percent == 62.4
        assert state_dir.load_index().chats[0].context_percent == 62.4

        factory.last.context = (70.0, None)
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="again")))
        usage = (await recv_until(conn, ContextUsage))[-1]
        assert usage.percent == 70.0 and usage.model is None  # type: ignore[union-attr]
    finally:
        await conn.close()


async def test_no_reading_means_no_frame(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
        await recv_until(conn, ChatState)
        await recv_until(conn, TurnFinished)
        rest = await drain(conn)
        assert not [m for m in rest if isinstance(m, ContextUsage)]
        assert server.registry.get(number).context_percent is None
    finally:
        await conn.close()


async def test_a_failing_reading_never_breaks_the_turn(
    server: GatewayServer, factory: EngineFactory, folder: Path, caplog: pytest.LogCaptureFixture
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        factory.last.context_error = RuntimeError("control request timed out")
        with caplog.at_level(logging.WARNING, logger="portico_gateway.server"):
            await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
            got = await recv_until(conn, TurnFinished)
            assert got[-1].outcome == "done"  # type: ignore[union-attr]
            state = await recv(conn)
            assert isinstance(state, ChatState) and state.state == "idle"
            await drain(conn)
        assert any("context" in r.message and r.levelno == logging.WARNING for r in caplog.records)

        # The chat goes on.
        factory.last.context_error = None
        factory.last.context = (10.0, "m")
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="again")))
        assert isinstance((await recv_until(conn, ContextUsage))[-1], ContextUsage)
    finally:
        await conn.close()


async def test_compaction_is_stamped_counted_and_replayed(server: GatewayServer, factory: EngineFactory, folder: Path, state_dir: StateDir) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        factory.last.script(Compact("auto"), fake_result())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
        got = await recv_until(conn, TurnFinished)
        compacted = [m for m in got if isinstance(m, ChatCompacted)]
        assert len(compacted) == 1
        assert compacted[0].chat == number and compacted[0].trigger == "auto" and compacted[0].seq is not None
        await recv(conn)

        factory.last.script(Compact("manual"), fake_result())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="/compact")))
        await recv_until(conn, TurnFinished)
        await recv(conn)
        assert server.registry.get(number).compactions == 2
        assert state_dir.load_index().chats[0].compactions == 2
        assert server.registry.summaries()[0].compactions == 2

        await conn.send(dump(ChatOpen(ts=TS, id="req-o", chat=number)))
        history = await recv(conn)
        assert isinstance(history, ChatHistory)
        assert [e.trigger for e in history.events if isinstance(e, ChatCompacted)] == ["auto", "manual"]
    finally:
        await conn.close()


async def test_an_unknown_trigger_is_reported_as_auto(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        factory.last.script(Compact("something-new"), fake_result())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
        got = await recv_until(conn, TurnFinished)
        assert [m.trigger for m in got if isinstance(m, ChatCompacted)] == ["auto"]
    finally:
        await conn.close()
