"""Task 7: turns — chat.new, message.send streaming with seq, turn.stop, chat.stop, attachments, chat.open replay.

A real ``websockets`` client against the server on an ephemeral port; the
engine behind every chat is the scripted ``FakeEngine`` from ``conftest``,
so nothing here touches a model.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from claude_agent_sdk import AssistantMessage, StreamEvent, TextBlock, ToolResultBlock, ToolUseBlock, UserMessage
from websockets.asyncio.client import ClientConnection

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import Config
from portico_gateway.messages import (
    ChatAlias,
    ChatHistory,
    ChatList,
    ChatLive,
    ChatNew,
    ChatOpen,
    ChatRemove,
    ChatState,
    ChatStop,
    Error,
    MessageSend,
    ServerMessage,
    TextDelta,
    ToolFinished,
    ToolStarted,
    TurnFinished,
    TurnStarted,
    TurnStop,
    dump,
    parse_server,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from tests.conftest import Block, FakeEngine, fake_result, make_config
from tests.test_server import attach

TS = "2026-10-27T12:00:00Z"


# --- fixtures -----------------------------------------------------------------


class EngineFactory:
    """Hands out ``FakeEngine``s and remembers them in creation order."""

    def __init__(self, late_session: bool = False) -> None:
        self.engines: list[FakeEngine] = []
        self.late_session = late_session

    def __call__(self) -> FakeEngine:
        engine = FakeEngine(late_session=self.late_session)
        self.engines.append(engine)
        return engine

    @property
    def last(self) -> FakeEngine:
        assert self.engines, "no engine was created"
        return self.engines[-1]


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
async def server(state_dir: StateDir, factory: EngineFactory) -> AsyncIterator[GatewayServer]:
    config: Config = make_config(setting_sources=["project"])
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    try:
        yield srv
    finally:
        await srv.shutdown()


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = tmp_path / "demo"
    path.mkdir()
    return path


async def recv(conn: ClientConnection, timeout: float = 5.0) -> ServerMessage:
    return parse_server(await asyncio.wait_for(conn.recv(), timeout))


async def recv_until(conn: ClientConnection, kind: type, timeout: float = 5.0) -> list[ServerMessage]:
    """Every frame up to and including the first of ``kind``."""
    got: list[ServerMessage] = []
    while True:
        msg = await recv(conn, timeout)
        got.append(msg)
        if isinstance(msg, kind):
            return got


async def new_chat(conn: ClientConnection, folder: Path, id: str = "req-new") -> int:
    """``chat.new`` and the ``chat.state idle`` + ``chat.list`` replies; returns the number."""
    await conn.send(dump(ChatNew(ts=TS, id=id, folder=str(folder))))
    state = await recv(conn)
    assert isinstance(state, ChatState), state
    assert state.state == "idle"
    assert state.id == id
    listing = await recv(conn)
    assert isinstance(listing, ChatList), listing
    assert state.chat in [c.chat for c in listing.chats]
    return state.chat


def text_delta(text: str) -> StreamEvent:
    return StreamEvent(
        uuid="u1",
        session_id="fake-session",
        event={"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}},
    )


def tool_use(tool_use_id: str, tool: str, input: dict) -> AssistantMessage:
    return AssistantMessage(content=[ToolUseBlock(id=tool_use_id, name=tool, input=input)], model="fake")


def tool_result(tool_use_id: str, content: str, is_error: bool = False) -> UserMessage:
    return UserMessage(content=[ToolResultBlock(tool_use_id=tool_use_id, content=content, is_error=is_error)])


# --- chat.new -----------------------------------------------------------------


async def test_new_chat_starts_engine_in_folder_with_project_setting_sources(
    server: GatewayServer, factory: EngineFactory, folder: Path, state_dir: StateDir
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        assert number == 1

        engine = factory.last
        assert engine.started
        assert engine.chat == 1
        assert engine.calls[0] == ("start", (folder, None, ["project"]))

        chat = server.registry.get(1)
        assert chat.engine is engine
        assert chat.folder == folder
        assert chat.state == "idle"
        assert chat.session_id == "fake-session"

        # Persisted at once: the index on disk knows the chat and its session.
        records = state_dir.load_index().chats
        assert [(r.chat, r.folder, r.session_id) for r in records] == [(1, str(folder), "fake-session")]
    finally:
        await conn.close()


async def test_session_id_learned_after_start_is_persisted(state_dir: StateDir, folder: Path) -> None:
    # The real engine names its session with the first turn, not at start:
    # the chat must learn it then, keep it in the index, and resume with it.
    factory = EngineFactory(late_session=True)
    config: Config = make_config(setting_sources=["project"])
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        chat = srv.registry.get(number)
        assert chat.session_id is None, "start named no session"
        assert state_dir.load_index().chats[0].session_id is None

        engine = factory.last
        engine._session_id = "real-session-abc"
        engine.script(text_delta("hi"), fake_result(session_id="real-session-abc"))
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
        await recv_until(conn, TurnFinished)
        await recv(conn)  # idle

        assert chat.session_id == "real-session-abc"
        assert state_dir.load_index().chats[0].session_id == "real-session-abc"

        # After chat.stop the next send starts a fresh engine on the learned session.
        await conn.send(dump(ChatStop(ts=TS, chat=number)))
        await recv_until(conn, ChatState)
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="back")))
        await recv_until(conn, TurnFinished)
        assert factory.last is not engine
        assert factory.last.calls[0] == ("start", (folder, "real-session-abc", ["project"]))
    finally:
        await conn.close()
        await srv.shutdown()


async def test_new_chat_refuses_a_folder_that_is_not_a_directory(
    server: GatewayServer, factory: EngineFactory, tmp_path: Path
) -> None:
    conn = await attach(server)
    try:
        await conn.send(dump(ChatNew(ts=TS, id="req-bad", folder=str(tmp_path / "nope"))))
        err = await recv(conn)
        assert isinstance(err, Error)
        assert err.code == "chat.folder_invalid"
        assert err.id == "req-bad"
        assert factory.engines == []
        assert len(server.registry) == 0
    finally:
        await conn.close()


# --- message.send -------------------------------------------------------------


async def test_send_streams_text_and_tool_events_with_seq(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        engine.script(
            text_delta("Hello"),
            tool_use("toolu_1", "Read", {"file_path": str(folder / "a.md")}),
            tool_result("toolu_1", "read 3 lines"),
            text_delta(" world"),
            fake_result(),
        )

        await conn.send(dump(MessageSend(ts=TS, chat=number, id="req-send", text="hi")))
        frames = await recv_until(conn, TurnFinished)
        # One more frame: the chat goes back to idle after the turn.
        idle = await recv(conn)

        assert engine.calls[-1] == ("send", "hi")
        kinds = [type(m) for m in frames]
        assert kinds == [TurnStarted, ChatState, TextDelta, ToolStarted, ToolFinished, TextDelta, TurnFinished]

        started, working, d1, t_on, t_off, d2, finished = frames
        assert isinstance(started, TurnStarted) and started.turn == 1 and started.chat == number
        assert isinstance(working, ChatState) and working.state == "working"
        assert isinstance(d1, TextDelta) and d1.text == "Hello" and d1.turn == 1
        assert isinstance(t_on, ToolStarted) and t_on.tool == "Read" and t_on.summary == str(folder / "a.md")
        assert isinstance(t_off, ToolFinished) and t_off.ok and t_off.tool_use_id == "toolu_1"
        assert isinstance(d2, TextDelta) and d2.text == " world"
        assert isinstance(finished, TurnFinished) and finished.outcome == "done" and finished.turn == 1
        assert isinstance(idle, ChatState) and idle.state == "idle"

        # Every chat-scoped event is stamped with a gapless seq, starting after chat.new's idle (seq 1).
        seqs = [m.seq for m in [*frames, idle]]
        assert seqs == list(range(2, 2 + len(seqs)))

        chat = server.registry.get(number)
        assert chat.state == "idle" and chat.turn == 1 and chat.seq == seqs[-1]
        assert [m.seq for m in chat.ring] == list(range(1, chat.seq + 1))
    finally:
        await conn.close()


async def test_send_while_working_is_busy_error(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        engine.script(Block())

        await conn.send(dump(MessageSend(ts=TS, chat=number, text="first")))
        await recv_until(conn, ChatState)  # turn.started, chat.state working
        await engine.wait_blocked()

        await conn.send(dump(MessageSend(ts=TS, chat=number, id="req-2", text="second")))
        err = await recv(conn)
        assert isinstance(err, Error)
        assert err.code == "chat.busy"
        assert err.chat == number and err.id == "req-2"
        assert [c for c in engine.calls if c[0] == "send"] == [("send", "first")]

        # The busy refusal is a reply, not history: nothing landed in the ring.
        assert not any(isinstance(m, Error) for m in server.registry.get(number).ring)

        await conn.send(dump(TurnStop(ts=TS, chat=number)))
        await recv_until(conn, TurnFinished)
    finally:
        await conn.close()


async def test_send_to_unknown_chat_is_error(server: GatewayServer) -> None:
    conn = await attach(server)
    try:
        await conn.send(dump(MessageSend(ts=TS, chat=9, id="req-x", text="hi")))
        err = await recv(conn)
        assert isinstance(err, Error)
        assert err.code == "chat.unknown" and err.chat == 9 and err.id == "req-x"
    finally:
        await conn.close()


# --- turn.stop / chat.stop ----------------------------------------------------


async def test_turn_stop_interrupts_and_finishes_stopped(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        engine.script(text_delta("thinking"), Block())

        await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
        await recv_until(conn, TextDelta)
        await engine.wait_blocked()

        await conn.send(dump(TurnStop(ts=TS, chat=number)))
        frames = await recv_until(conn, TurnFinished)
        idle = await recv(conn)

        assert ("interrupt", None) in engine.calls
        finished = frames[-1]
        assert isinstance(finished, TurnFinished)
        assert finished.outcome == "stopped" and finished.turn == 1
        assert isinstance(idle, ChatState) and idle.state == "idle"

        # The engine is still there: the next send goes to the same engine as turn 2.
        engine.script(fake_result())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="again")))
        frames = await recv_until(conn, TurnFinished)
        assert isinstance(frames[0], TurnStarted) and frames[0].turn == 2
        assert isinstance(frames[-1], TurnFinished) and frames[-1].outcome == "done"
        assert not engine.closed
    finally:
        await conn.close()


async def test_turn_stop_when_idle_is_harmless(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(TurnStop(ts=TS, chat=number)))
        await conn.send(dump(ChatAlias(ts=TS, chat=number, alias="ping")))
        # Nothing but the alias's chat.list comes back: no error, no turn.finished.
        listing = await recv(conn)
        assert isinstance(listing, ChatList)
        assert factory.last.calls[-1][0] == "start"
    finally:
        await conn.close()


async def test_chat_stop_closes_engine_and_state_stopped(
    server: GatewayServer, factory: EngineFactory, folder: Path, state_dir: StateDir
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        engine.script(Block())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
        await recv_until(conn, ChatState)
        await engine.wait_blocked()

        await conn.send(dump(ChatStop(ts=TS, chat=number)))
        frames = await recv_until(conn, TurnFinished)
        assert isinstance(frames[-1], TurnFinished) and frames[-1].outcome == "stopped"
        stopped = await recv(conn)
        assert isinstance(stopped, ChatState) and stopped.state == "stopped"

        assert engine.closed
        chat = server.registry.get(number)
        assert chat.engine is None and chat.state == "stopped"
        assert state_dir.load_index().chats[0].state == "stopped"

        # A send after stop starts a fresh engine on the same session and the chat comes back idle.
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="back")))
        frames = await recv_until(conn, TurnFinished)
        assert factory.last is not engine
        assert factory.last.calls[0] == ("start", (folder, "fake-session", ["project"]))
        assert isinstance(frames[0], TurnStarted) and frames[0].turn == 2
        kinds = [type(m) for m in frames]
        assert kinds == [TurnStarted, ChatState, TurnFinished]
    finally:
        await conn.close()


# --- attachments --------------------------------------------------------------


async def test_attachment_appended_in_exact_form(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    one = folder / "notes.md"
    two = folder / "data.csv"
    one.write_text("a")
    two.write_text("b")
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(
            dump(MessageSend(ts=TS, chat=number, text="Summarise these.", attachments=[str(one), str(two)]))
        )
        await recv_until(conn, TurnFinished)
        assert factory.last.calls[-1] == ("send", f"Summarise these.\n\nAttached files:\n- {one}\n- {two}")
    finally:
        await conn.close()


async def test_send_without_attachments_is_unchanged(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="plain")))
        await recv_until(conn, TurnFinished)
        assert factory.last.calls[-1] == ("send", "plain")
    finally:
        await conn.close()


async def test_send_with_missing_attachment_is_refused(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    present = folder / "here.md"
    present.write_text("x")
    missing = folder / "gone.md"
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last

        await conn.send(dump(MessageSend(ts=TS, chat=number, id="req-a", text="hi", attachments=[str(present), str(missing)])))
        err = await recv(conn)
        assert isinstance(err, Error)
        assert err.code == "attachment.missing" and err.id == "req-a" and err.chat == number
        assert str(missing) in err.message

        # A directory is not an attachment either.
        await conn.send(dump(MessageSend(ts=TS, chat=number, id="req-b", text="hi", attachments=[str(folder)])))
        err = await recv(conn)
        assert isinstance(err, Error)
        assert err.code == "attachment.missing" and err.id == "req-b"

        # Nothing reached the engine, no turn started, the chat is still idle.
        assert [c for c in engine.calls if c[0] == "send"] == []
        chat = server.registry.get(number)
        assert chat.state == "idle" and chat.turn == 0
        assert not any(isinstance(m, TurnStarted) for m in chat.ring)
    finally:
        await conn.close()


# --- chat.open ----------------------------------------------------------------


async def test_chat_open_since_replays_ring_then_live(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        factory.last.script(text_delta("one"), text_delta("two"), fake_result())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
        await recv_until(conn, TurnFinished)
        idle = await recv(conn)
        assert isinstance(idle, ChatState)
        last_seq = idle.seq
        assert last_seq is not None

        # From the beginning: every stamped event, in order, with its original seq.
        await conn.send(dump(ChatOpen(ts=TS, chat=number, id="req-open")))
        history = await recv(conn)
        assert isinstance(history, ChatHistory)
        assert history.id == "req-open" and not history.truncated
        assert [m.seq for m in history.events] == list(range(1, last_seq + 1))
        assert [type(m) for m in history.events] == [
            ChatState, TurnStarted, ChatState, TextDelta, TextDelta, TurnFinished, ChatState
        ]
        live = await recv(conn)
        assert isinstance(live, ChatLive)
        assert live.chat == number and live.seq == last_seq and live.id == "req-open"

        # Since the turn.started (seq 2): only what came after it.
        await conn.send(dump(ChatOpen(ts=TS, chat=number, since=2)))
        history = await recv(conn)
        assert isinstance(history, ChatHistory)
        assert [m.seq for m in history.events] == list(range(3, last_seq + 1))
        live = await recv(conn)
        assert isinstance(live, ChatLive) and live.seq == last_seq

        # Up to date: empty history, still followed by live.
        await conn.send(dump(ChatOpen(ts=TS, chat=number, since=last_seq)))
        history = await recv(conn)
        assert isinstance(history, ChatHistory) and history.events == []
        assert isinstance(await recv(conn), ChatLive)

        # chat.open neither stamps nor advances the sequence.
        assert server.registry.get(number).seq == last_seq
    finally:
        await conn.close()


async def test_chat_open_reports_truncation_when_since_fell_off_the_ring(
    state_dir: StateDir, factory: EngineFactory, folder: Path
) -> None:
    config = make_config(history_buffer=3)
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=3)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        factory.last.script(text_delta("a"), text_delta("b"), text_delta("c"), fake_result())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
        await recv_until(conn, TurnFinished)
        await recv(conn)  # idle

        await conn.send(dump(ChatOpen(ts=TS, chat=number, since=1)))
        history = await recv(conn)
        assert isinstance(history, ChatHistory)
        assert history.truncated
        assert len(history.events) == 3
        assert isinstance(await recv(conn), ChatLive)
    finally:
        await conn.close()
        await srv.shutdown()


async def test_events_while_detached_are_kept_for_reattach(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach(server)
    number = await new_chat(conn, folder)
    engine = factory.last
    engine.script(text_delta("while you were away"), Block())
    await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
    seen = await recv_until(conn, TextDelta)
    last_seq = seen[-1].seq
    assert last_seq is not None
    await engine.wait_blocked()

    # The app goes away mid-turn; the turn ends with nobody listening.
    await conn.close()
    await asyncio.sleep(0.05)
    assert not server.attached
    await engine.interrupt()
    await engine.wait_idle()

    again = await attach(server)
    try:
        await again.send(dump(ChatOpen(ts=TS, chat=number, since=last_seq)))
        history = await recv(again)
        assert isinstance(history, ChatHistory) and not history.truncated
        assert [type(m) for m in history.events] == [TurnFinished, ChatState]
        assert isinstance(history.events[0], TurnFinished) and history.events[0].outcome == "done"
        assert isinstance(await recv(again), ChatLive)
    finally:
        await again.close()


# --- chat.alias / chat.remove -------------------------------------------------


async def test_chat_alias_sets_and_clears(server: GatewayServer, folder: Path, state_dir: StateDir) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(ChatAlias(ts=TS, chat=number, alias="report draft")))
        listing = await recv(conn)
        assert isinstance(listing, ChatList)
        assert listing.chats[0].alias == "report draft"
        assert state_dir.load_index().chats[0].alias == "report draft"

        await conn.send(dump(ChatAlias(ts=TS, chat=number)))
        listing = await recv(conn)
        assert isinstance(listing, ChatList)
        assert listing.chats[0].alias is None
    finally:
        await conn.close()


async def test_chat_remove_closes_engine_and_drops_from_list(
    server: GatewayServer, factory: EngineFactory, folder: Path, state_dir: StateDir
) -> None:
    conn = await attach(server)
    try:
        first = await new_chat(conn, folder, id="a")
        second = await new_chat(conn, folder, id="b")
        engine_first = factory.engines[0]

        await conn.send(dump(ChatRemove(ts=TS, chat=first)))
        listing = await recv(conn)
        assert isinstance(listing, ChatList)
        assert [c.chat for c in listing.chats] == [second]
        assert engine_first.closed
        assert [r.chat for r in state_dir.load_index().chats] == [second]

        await conn.send(dump(ChatOpen(ts=TS, chat=first)))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "chat.unknown"
    finally:
        await conn.close()
