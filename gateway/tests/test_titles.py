"""v0.8: generated session titles — the prompt, the cleaning, the fallback, and when the gateway asks.

The model call is the server's ``titler`` seam; every test hands it a
recording function, so nothing here reaches a model. Real ``websockets``
client, ``FakeEngine`` behind every chat.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import Config
from portico_gateway.messages import ChatAlias, ChatList, MessageSend, SessionLog, SessionLogged, TurnFinished, dump
from portico_gateway.server import GatewayServer
from portico_gateway.state import ChatRecord, Index, StateDir
from portico_gateway.titles import (
    DEFAULT_TITLE_MODEL,
    REPLY_CHARS,
    clean_title,
    generate_title,
    title_prompt,
)
from tests.conftest import FakeEngine, fake_result, make_config
from tests.test_server import attach
from tests.test_turns import EngineFactory, new_chat, recv, recv_until, text_delta

TS = "2026-10-29T12:00:00Z"


class Titler:
    """The server's ``titler``: records each ``(prompt, model)``; answers ``answer``, raises, or waits for ``gate``."""

    def __init__(self, answer: str = "Interview codebook for Q3 synthesis", error: Exception | None = None) -> None:
        self.answer = answer
        self.error = error
        self.gate: asyncio.Event | None = None
        self.calls: list[tuple[str, str]] = []
        self.called = asyncio.Event()

    async def __call__(self, prompt: str, model: str) -> str:
        self.calls.append((prompt, model))
        self.called.set()
        if self.gate is not None:
            await self.gate.wait()
        if self.error is not None:
            raise self.error
        return self.answer


# --- the prompt and the answer ------------------------------------------------------


def test_the_prompt_carries_the_first_message_and_the_start_of_the_reply() -> None:
    reply = "x" * (REPLY_CHARS + 100)
    prompt = title_prompt("  Plan the interview codebook  ", reply)
    assert "Plan the interview codebook" in prompt
    assert "x" * REPLY_CHARS in prompt and "x" * (REPLY_CHARS + 1) not in prompt
    assert "six" in prompt or "6" in prompt


@pytest.mark.parametrize(
    ("raw", "title"),
    [
        ("Interview codebook for Q3 synthesis", "Interview codebook for Q3 synthesis"),
        ('"Interview codebook draft."', "Interview codebook draft"),
        ("Title: Quarterly budget review!", "Quarterly budget review"),
        ("**Release notes cleanup**", "Release notes cleanup"),
        ("# Heading style title", "Heading style title"),
        ("\n\n  Second line wins when the first is blank  \nmore", "Second line wins when the first"),
        ("one two three four five six seven eight", "one two three four five six"),
        ("“Curly quoted title”", "Curly quoted title"),
        ("", None),
        ('  ""  \n  ', None),
    ],
)
def test_clean_title(raw: str, title: str | None) -> None:
    assert clean_title(raw) == title


async def test_generate_uses_the_small_model_by_default_and_the_override_when_set() -> None:
    titler = Titler()
    assert await generate_title(titler, "hi", "hello") == "Interview codebook for Q3 synthesis"
    assert await generate_title(titler, "hi", "hello", model="claude-small-x") == "Interview codebook for Q3 synthesis"
    assert [m for _, m in titler.calls] == [DEFAULT_TITLE_MODEL, "claude-small-x"]
    assert DEFAULT_TITLE_MODEL == "haiku"


async def test_generate_gives_none_on_failure_timeout_or_an_empty_answer() -> None:
    assert await generate_title(Titler(error=RuntimeError("no credentials")), "hi", "hello") is None
    slow = Titler()
    slow.gate = asyncio.Event()
    assert await generate_title(slow, "hi", "hello", timeout=0.05) is None
    assert await generate_title(Titler(answer="  \n"), "hi", "hello") is None


# --- the server ---------------------------------------------------------------------


async def start(
    state_dir: StateDir, factory: object, titler: Titler | None, index: Index | None = None, **config: object
) -> GatewayServer:
    cfg: Config = make_config(**config)
    if index is not None:
        state_dir.save_index(index)
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=cfg.history_buffer)
    srv = GatewayServer(
        config=cfg, state=state_dir, registry=registry, engine_factory=factory, version=__version__, titler=titler  # type: ignore[arg-type]
    )
    await srv.serve(0)
    return srv


@pytest.fixture
def titler() -> Titler:
    return Titler()


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
async def server(state_dir: StateDir, factory: EngineFactory, titler: Titler) -> AsyncIterator[GatewayServer]:
    srv = await start(state_dir, factory, titler)
    try:
        yield srv
    finally:
        await srv.shutdown()


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = tmp_path / "demo"
    path.mkdir()
    return path


async def send(conn: ClientConnection, chat: int, text: str) -> TurnFinished:
    await conn.send(dump(MessageSend(ts=TS, chat=chat, text=text)))
    finished = (await recv_until(conn, TurnFinished))[-1]
    await recv(conn)  # chat.state idle
    assert isinstance(finished, TurnFinished)
    return finished


async def settle() -> None:
    """Long enough for a spawned title task to have asked, were it going to."""
    await asyncio.sleep(0.05)


async def test_a_clean_first_turn_is_titled_persisted_and_pushed(
    server: GatewayServer, factory: EngineFactory, titler: Titler, folder: Path, state_dir: StateDir
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="Plan the interview codebook\nwith themes")))
        await recv_until(conn, ChatList)  # chat.new's list is already read: this is the title's
        chat = server.registry.get(number)
        assert chat.title == "Interview codebook for Q3 synthesis"
    finally:
        await conn.close()
    assert len(titler.calls) == 1
    prompt, model = titler.calls[0]
    assert "Plan the interview codebook\nwith themes" in prompt and model == DEFAULT_TITLE_MODEL
    assert {r.chat: r.title for r in state_dir.load_index().chats}[number] == "Interview codebook for Q3 synthesis"


async def test_the_title_arrives_in_chat_list_after_the_first_line(
    server: GatewayServer, factory: EngineFactory, titler: Titler, folder: Path
) -> None:
    titler.gate = asyncio.Event()
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="Plan the interview codebook")))
        await asyncio.wait_for(titler.called.wait(), 5)
        assert server.registry.get(number).title == "Plan the interview codebook", "the first line until the title arrives"
        titler.gate.set()
        got = await recv_until(conn, ChatList)
        listing = got[-1]
        assert isinstance(listing, ChatList)
        assert [c.title for c in listing.chats if c.chat == number] == ["Interview codebook for Q3 synthesis"]
    finally:
        await conn.close()


async def test_the_prompt_has_the_start_of_the_first_reply(
    state_dir: StateDir, titler: Titler, folder: Path
) -> None:
    long = "y" * (REPLY_CHARS + 50)

    def scripted() -> FakeEngine:
        engine = FakeEngine()
        engine.script(text_delta("Here is a codebook. "), text_delta(long), fake_result())
        return engine

    srv = await start(state_dir, scripted, titler)
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        await send(conn, number, "Plan the interview codebook")
        await asyncio.wait_for(titler.called.wait(), 5)
    finally:
        await conn.close()
        await srv.shutdown()
    prompt = titler.calls[0][0]
    assert ("Here is a codebook. " + long)[:REPLY_CHARS] in prompt
    assert ("Here is a codebook. " + long)[: REPLY_CHARS + 1] not in prompt


async def test_only_the_first_turn_asks(server: GatewayServer, titler: Titler, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await send(conn, number, "first")
        await asyncio.wait_for(titler.called.wait(), 5)
        await send(conn, number, "second")
        await settle()
    finally:
        await conn.close()
    assert len(titler.calls) == 1


async def test_first_line_titles_make_no_call(state_dir: StateDir, factory: EngineFactory, titler: Titler, folder: Path) -> None:
    srv = await start(state_dir, factory, titler, titles="first_line")
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        await send(conn, number, "Plan the interview codebook")
        await settle()
        assert srv.registry.get(number).title == "Plan the interview codebook"
    finally:
        await conn.close()
        await srv.shutdown()
    assert titler.calls == []


async def test_title_model_is_passed(state_dir: StateDir, factory: EngineFactory, titler: Titler, folder: Path) -> None:
    srv = await start(state_dir, factory, titler, title_model="claude-small-x")
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        await send(conn, number, "hello")
        await asyncio.wait_for(titler.called.wait(), 5)
    finally:
        await conn.close()
        await srv.shutdown()
    assert titler.calls[0][1] == "claude-small-x"


async def test_an_error_turn_is_not_titled(state_dir: StateDir, titler: Titler, folder: Path) -> None:
    def failing() -> FakeEngine:
        engine = FakeEngine()
        engine.script(fake_result(is_error=True))
        return engine

    srv = await start(state_dir, failing, titler)
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        finished = await send(conn, number, "hello")
        assert finished.outcome == "error"
        await settle()
        assert srv.registry.get(number).title == "hello"
    finally:
        await conn.close()
        await srv.shutdown()
    assert titler.calls == []


async def test_a_stopped_turn_is_not_titled(state_dir: StateDir, titler: Titler, folder: Path) -> None:
    from portico_gateway.messages import TurnStop
    from tests.conftest import Block

    engines: list[FakeEngine] = []

    def blocking() -> FakeEngine:
        engine = FakeEngine()
        engine.script(Block())
        engines.append(engine)
        return engine

    srv = await start(state_dir, blocking, titler)
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="hello")))
        await asyncio.wait_for(engines[0]._blocked.wait(), 5)
        await conn.send(dump(TurnStop(ts=TS, chat=number)))
        finished = (await recv_until(conn, TurnFinished))[-1]
        assert isinstance(finished, TurnFinished) and finished.outcome == "stopped"
        await settle()
    finally:
        await conn.close()
        await srv.shutdown()
    assert titler.calls == []


async def test_a_failing_call_keeps_the_first_line(state_dir: StateDir, factory: EngineFactory, folder: Path) -> None:
    titler = Titler(error=RuntimeError("the provider refused"))
    srv = await start(state_dir, factory, titler)
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        await send(conn, number, "Plan the interview codebook")
        await asyncio.wait_for(titler.called.wait(), 5)
        await settle()
        assert srv.registry.get(number).title == "Plan the interview codebook"
    finally:
        await conn.close()
        await srv.shutdown()


async def test_an_alias_given_meanwhile_is_never_overwritten(server: GatewayServer, titler: Titler, folder: Path) -> None:
    titler.gate = asyncio.Event()
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await send(conn, number, "Plan the interview codebook")
        await asyncio.wait_for(titler.called.wait(), 5)
        await conn.send(dump(ChatAlias(ts=TS, chat=number, alias="codebook")))
        await recv_until(conn, ChatList)
        titler.gate.set()
        await settle()
        chat = server.registry.get(number)
        assert chat.alias == "codebook" and chat.title == "Plan the interview codebook"
    finally:
        await conn.close()


async def test_a_session_with_an_alias_is_not_titled(server: GatewayServer, titler: Titler, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(ChatAlias(ts=TS, chat=number, alias="codebook")))
        await recv_until(conn, ChatList)
        await send(conn, number, "Plan the interview codebook")
        await settle()
    finally:
        await conn.close()
    assert titler.calls == []


async def test_a_title_set_otherwise_meanwhile_stays(server: GatewayServer, titler: Titler, folder: Path) -> None:
    titler.gate = asyncio.Event()
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await send(conn, number, "Plan the interview codebook")
        await asyncio.wait_for(titler.called.wait(), 5)
        server.registry.get(number).title = "Set by someone else"
        titler.gate.set()
        await settle()
        assert server.registry.get(number).title == "Set by someone else"
    finally:
        await conn.close()


async def test_the_log_step_turn_is_not_titled(state_dir: StateDir, factory: EngineFactory, titler: Titler, folder: Path) -> None:
    srv = await start(state_dir, factory, titler, log_prompt="/session-close")
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(SessionLog(ts=TS, id="req-l", chat=number)))
        await recv_until(conn, SessionLogged)
        await settle()
        assert srv.registry.get(number).title is None
    finally:
        await conn.close()
        await srv.shutdown()
    assert titler.calls == []


async def test_an_unknown_command_empty_turn_is_not_titled(state_dir: StateDir, titler: Titler, folder: Path) -> None:
    def knows_nothing() -> FakeEngine:
        engine = FakeEngine()
        engine.commands = set()
        return engine

    srv = await start(state_dir, knows_nothing, titler)
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="/nope")))
        finished = (await recv_until(conn, TurnFinished))[-1]
        assert isinstance(finished, TurnFinished) and finished.outcome == "done"
        await settle()
    finally:
        await conn.close()
        await srv.shutdown()
    assert titler.calls == []


async def test_a_restored_session_keeps_its_title(state_dir: StateDir, factory: EngineFactory, titler: Titler, folder: Path) -> None:
    index = Index(
        chats=[
            ChatRecord(
                chat=3, folder=str(folder), session_id="sess-3", state="idle", created=TS, title="Older title"
            )
        ],
        next_chat=4,
    )
    srv = await start(state_dir, factory, titler, index=index)
    conn = await attach(srv)
    try:
        await send(conn, 3, "a later message")
        await settle()
        assert srv.registry.get(3).title == "Older title"
    finally:
        await conn.close()
        await srv.shutdown()
    assert titler.calls == []


async def test_without_a_titler_the_first_line_stays(state_dir: StateDir, factory: EngineFactory, folder: Path) -> None:
    srv = await start(state_dir, factory, None)
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        await send(conn, number, "Plan the interview codebook")
        await settle()
        assert srv.registry.get(number).title == "Plan the interview codebook"
    finally:
        await conn.close()
        await srv.shutdown()
