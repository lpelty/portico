"""Task 8: cards — permission and question round trips, chat/always scopes, hold, cancel, stale answers, replay.

A real ``websockets`` client against the server on an ephemeral port; the
engine behind every chat is the scripted ``FakeEngine`` from ``conftest``,
so nothing here touches a model. The broker itself gets a few direct tests
at the end.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection

from portico_gateway import __version__
from portico_gateway.cards import NOBODY_ANSWERED, CardBroker, QuestionDeclined, question_card, title_for
from portico_gateway.chats import Chat, ChatRegistry
from portico_gateway.messages import (
    CardAnswer,
    CardAnswered,
    CardAsk,
    CardCancel,
    ChatHistory,
    ChatLive,
    ChatOpen,
    ChatState,
    ChatStop,
    Error,
    MessageSend,
    ProtocolError,
    ServerMessage,
    TextDelta,
    TurnFinished,
    TurnStarted,
    TurnStop,
    UserText,
    dump,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from tests.conftest import AskPermission, AskQuestion, FakeEngine, fake_result, make_config
from tests.test_server import attach
from tests.test_turns import EngineFactory, new_chat, recv, recv_until, text_delta

TS = "2026-10-27T12:00:00Z"

QUESTIONS = [
    {
        "question": "Which colour?",
        "header": "Colour",
        "options": [{"label": "Blue", "description": "calm"}, {"label": "Red", "description": "loud"}],
        "multiSelect": False,
    },
    {
        "question": "Which sizes?",
        "header": "Sizes",
        "options": [{"label": "S", "description": "small"}, {"label": "L", "description": "large"}],
        "multiSelect": True,
    },
]


# --- fixtures -----------------------------------------------------------------


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
async def server(state_dir: StateDir, factory: EngineFactory) -> AsyncIterator[GatewayServer]:
    config = make_config(setting_sources=["project"])
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


def write_ask(folder: Path, tool_use_id: str = "toolu_w1") -> AskPermission:
    return AskPermission(
        "Write",
        {"file_path": str(folder / "summary.md"), "content": "# Summary\n"},
        suggestions=[{"type": "addRules", "behavior": "allow", "destination": "localSettings", "rules": []}],
        tool_use_id=tool_use_id,
    )


async def start_turn_with_card(
    conn: ClientConnection, number: int, engine: FakeEngine, *items: object, text: str = "go"
) -> tuple[list[ServerMessage], CardAsk]:
    """Send a message whose script asks a card; returns the frames up to the card and the card."""
    engine.script(*items)
    await conn.send(dump(MessageSend(ts=TS, chat=number, text=text)))
    frames = await recv_until(conn, CardAsk)
    card = frames[-1]
    assert isinstance(card, CardAsk)
    return frames, card


async def wait_for(predicate, timeout: float = 5.0) -> None:
    async with asyncio.timeout(timeout):
        while not predicate():
            await asyncio.sleep(0.01)


# --- permission cards ---------------------------------------------------------


async def test_permission_card_round_trip_allow_once(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        frames, card = await start_turn_with_card(conn, number, engine, write_ask(folder), fake_result())
        waiting = await recv(conn)

        assert [type(m) for m in frames] == [TurnStarted, UserText, ChatState, CardAsk]
        assert card.chat == number and card.kind == "permission" and card.id
        assert card.title == "Write a file"
        assert card.permission is not None
        assert card.permission.tool == "Write"
        assert card.permission.summary == str(folder / "summary.md")
        assert card.permission.input == {"file_path": str(folder / "summary.md"), "content": "# Summary\n"}
        assert card.questions is None and card.form is None
        assert card.seq is not None
        assert isinstance(waiting, ChatState) and waiting.state == "waiting on you"
        assert server.registry.get(number).state == "waiting on you"
        assert [c.id for c in server.cards.open_cards(server.registry.get(number))] == [card.id]

        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "allow"}, scope="once")))
        after = await recv_until(conn, TurnFinished)
        idle = await recv(conn)
        assert [type(m) for m in after] == [CardAnswered, ChatState, TurnFinished]
        assert isinstance(after[0], CardAnswered) and after[0].id == card.id
        assert isinstance(after[1], ChatState) and after[1].state == "working"
        assert isinstance(after[2], TurnFinished) and after[2].outcome == "done"
        assert isinstance(idle, ChatState) and idle.state == "idle"

        assert engine.decisions == ["allow"]
        assert server.cards.open_cards(server.registry.get(number)) == []
        assert server.registry.get(number).chat_allows == set()

        # The card and the states around it are history: gapless seq through the whole turn.
        chat = server.registry.get(number)
        assert [m.seq for m in chat.ring] == list(range(1, chat.seq + 1))
        assert any(isinstance(m, CardAsk) and m.id == card.id for m in chat.ring)
    finally:
        await conn.close()


async def test_permission_scope_chat_skips_next_ask_for_same_tool(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        _, card = await start_turn_with_card(
            conn, number, engine, write_ask(folder, "toolu_1"), write_ask(folder, "toolu_2"), fake_result()
        )
        await recv(conn)  # waiting on you
        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "allow"}, scope="chat")))
        after = await recv_until(conn, TurnFinished)
        await recv(conn)  # idle

        # The second Write in the same turn was allowed without a card.
        assert engine.decisions == ["allow", "allow"]
        assert not any(isinstance(m, CardAsk) for m in after)
        assert server.registry.get(number).chat_allows == {"Write"}

        # Still allowed on the next turn; a different tool still asks.
        engine.script(write_ask(folder, "toolu_3"), AskPermission("Bash", {"command": "ls"}, tool_use_id="toolu_4"), fake_result())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="again")))
        frames = await recv_until(conn, CardAsk)
        bash_card = frames[-1]
        assert isinstance(bash_card, CardAsk) and bash_card.permission is not None
        assert bash_card.permission.tool == "Bash" and bash_card.title == "Run a command"
        assert bash_card.permission.summary == "ls"
        assert engine.decisions == ["allow", "allow", "allow"]
        await recv(conn)  # waiting on you
        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=bash_card.id, answer={"decision": "deny"}, note="not now")))
        await recv_until(conn, TurnFinished)
        await recv(conn)
        assert engine.decisions[-1] == ("deny", "not now")
        assert server.registry.get(number).chat_allows == {"Write"}
    finally:
        await conn.close()


def bash_ask(command: str, tool_use_id: str, rules: list[str] | None = None) -> AskPermission:
    """A Bash ask; ``rules`` are the engine's own allow suggestions (``prefix:*`` or exact)."""
    suggestions = []
    if rules:
        suggestions.append(
            {
                "type": "addRules",
                "behavior": "allow",
                "destination": "session",
                "rules": [{"toolName": "Bash", "ruleContent": rule} for rule in rules],
            }
        )
    return AskPermission("Bash", {"command": command}, suggestions=suggestions, tool_use_id=tool_use_id)


async def answer(conn: ClientConnection, card: CardAsk, decision: str, scope: str | None = None) -> None:
    await conn.send(dump(CardAnswer(ts=TS, chat=card.chat, id=card.id, answer={"decision": decision}, scope=scope)))  # type: ignore[arg-type]


async def test_chat_scope_bash_does_not_cover_a_different_command(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    # "Allow for this chat" on one command must not silently allow every later
    # command: a chat allow for a command tool is keyed the way the engine keys
    # its own rules (its suggested prefix, else the exact command), never the bare tool name.
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        chat = server.registry.get(number)

        # No suggestion from the engine: the allow covers exactly "ls".
        _, card = await start_turn_with_card(conn, number, engine, bash_ask("ls", "t1"), bash_ask("rm -rf /", "t2"), fake_result())
        await recv(conn)  # waiting on you
        await answer(conn, card, "allow", "chat")
        frames = await recv_until(conn, CardAsk)
        second = frames[-1]
        assert isinstance(second, CardAsk) and second.permission is not None
        assert second.permission.summary == "rm -rf /", "a different command still asks"
        await recv(conn)
        await answer(conn, second, "deny")
        await recv_until(conn, TurnFinished)
        await recv(conn)
        assert engine.decisions == ["allow", ("deny", None)]
        assert chat.chat_allows == {"Bash(ls)"}

        # The exact command is covered; a longer one is not.
        _, card = await start_turn_with_card(
            conn, number, engine, bash_ask("ls", "t3"), bash_ask("ls -la", "t4", rules=["ls:*"]), fake_result(), text="again"
        )
        assert card.permission is not None and card.permission.summary == "ls -la"
        assert engine.decisions[-1] == "allow"  # "ls" went through without a card
        await recv(conn)
        # With the engine's own prefix rule, the chat allow is that prefix.
        await answer(conn, card, "allow", "chat")
        await recv_until(conn, TurnFinished)
        await recv(conn)
        assert chat.chat_allows == {"Bash(ls)", "Bash(ls:*)"}

        # The prefix covers "ls -R"; a compound command with an uncovered part, or a
        # look-alike word, still asks.
        _, card = await start_turn_with_card(
            conn, number, engine,
            bash_ask("ls -R", "t5"), bash_ask("lsof", "t6"), bash_ask("ls && rm -rf /", "t7"), fake_result(),
            text="more",
        )
        assert card.permission is not None and card.permission.summary == "lsof"
        assert engine.decisions[-1] == "allow"
        await recv(conn)
        await answer(conn, card, "deny")
        frames = await recv_until(conn, CardAsk)
        compound = frames[-1]
        assert isinstance(compound, CardAsk) and compound.permission is not None
        assert compound.permission.summary == "ls && rm -rf /"
        await recv(conn)
        await answer(conn, compound, "deny")
        await recv_until(conn, TurnFinished)
        await recv(conn)
        assert engine.decisions[-3:] == ["allow", ("deny", None), ("deny", None)]
    finally:
        await conn.close()


async def test_permission_scope_always_returns_always(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        _, card = await start_turn_with_card(conn, number, engine, write_ask(folder), fake_result())
        await recv(conn)
        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "allow"}, scope="always")))
        await recv_until(conn, TurnFinished)
        await recv(conn)
        assert engine.decisions == [("allow", "always")]
        # "Always" lives in the engine's own settings, not in the gateway's chat allows.
        assert server.registry.get(number).chat_allows == set()
    finally:
        await conn.close()


async def test_permission_deny_without_note_uses_default(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        _, card = await start_turn_with_card(conn, number, engine, write_ask(folder), fake_result())
        await recv(conn)
        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "deny"})))
        await recv_until(conn, TurnFinished)
        await recv(conn)
        assert engine.decisions == [("deny", None)]
    finally:
        await conn.close()


async def test_invalid_answer_is_refused_and_card_stays_open(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        _, card = await start_turn_with_card(conn, number, engine, write_ask(folder), fake_result())
        await recv(conn)

        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "maybe"})))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "card.invalid_answer" and err.id == card.id and err.chat == number

        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={})))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "card.invalid_answer"

        assert [c.id for c in server.cards.open_cards(server.registry.get(number))] == [card.id]
        assert engine.decisions == []

        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "allow"})))
        await recv_until(conn, TurnFinished)
        await recv(conn)
        assert engine.decisions == ["allow"]
    finally:
        await conn.close()


# --- question cards -----------------------------------------------------------


async def test_question_card_round_trip_maps_answers(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        _, card = await start_turn_with_card(conn, number, engine, AskQuestion(QUESTIONS), fake_result())
        waiting = await recv(conn)
        assert isinstance(waiting, ChatState) and waiting.state == "waiting on you"

        assert card.kind == "question" and card.permission is None and card.form is None
        assert card.title == "Colour"
        assert card.questions is not None and len(card.questions) == 2
        first, second = card.questions
        assert first.question == "Which colour?" and first.header == "Colour" and first.multi_select is False
        assert [(o.label, o.description) for o in first.options] == [("Blue", "calm"), ("Red", "loud")]
        assert second.question == "Which sizes?" and second.multi_select is True

        answers = {"Which colour?": "Blue", "Which sizes?": ["S", "L"]}
        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"answers": answers})))
        after = await recv_until(conn, TurnFinished)
        await recv(conn)
        assert isinstance(after[0], CardAnswered) and after[0].id == card.id
        assert isinstance(after[1], ChatState) and after[1].state == "working"
        assert engine.answers == [answers]
    finally:
        await conn.close()


async def test_question_answer_without_answers_is_invalid(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        _, card = await start_turn_with_card(conn, number, engine, AskQuestion(QUESTIONS[:1]), fake_result())
        await recv(conn)
        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "allow"})))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "card.invalid_answer"
        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"answers": {"Which colour?": "Red"}})))
        await recv_until(conn, TurnFinished)
        await recv(conn)
        assert engine.answers == [{"Which colour?": "Red"}]
    finally:
        await conn.close()


# --- hold while no app is attached ---------------------------------------------


async def test_no_app_attached_holds_then_denies_with_message(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    server.cards.hold_seconds = 0.2
    conn = await attach(server)
    number = await new_chat(conn, folder)
    engine = factory.last
    engine.script(text_delta("about to write"), write_ask(folder), fake_result())
    await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
    await recv_until(conn, ChatState)  # turn.started, chat.state working

    # The app goes away before anyone can answer.
    await conn.close()
    await wait_for(lambda: not server.attached)

    await engine.wait_idle()
    assert engine.decisions == [("deny", NOBODY_ANSWERED)]

    chat = server.registry.get(number)
    kinds = [type(m) for m in chat.ring]
    assert kinds == [ChatState, TurnStarted, UserText, ChatState, TextDelta, CardAsk, ChatState, CardCancel, ChatState, TurnFinished, ChatState]
    card = next(m for m in chat.ring if isinstance(m, CardAsk))
    cancel = next(m for m in chat.ring if isinstance(m, CardCancel))
    assert cancel.id == card.id and cancel.reason == NOBODY_ANSWERED
    states = [m.state for m in chat.ring if isinstance(m, ChatState)]
    assert states == ["idle", "working", "waiting on you", "working", "idle"]
    assert chat.state == "idle"
    assert server.cards.open_cards(chat) == []


async def test_no_app_attached_question_is_declined(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    server.cards.hold_seconds = 0.2
    conn = await attach(server)
    number = await new_chat(conn, folder)
    engine = factory.last
    engine.script(AskQuestion(QUESTIONS[:1]), fake_result())
    await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
    await recv_until(conn, ChatState)
    await conn.close()
    await wait_for(lambda: not server.attached)

    await engine.wait_idle()
    assert engine.answers == [("declined", NOBODY_ANSWERED)]
    chat = server.registry.get(number)
    assert any(isinstance(m, CardCancel) and m.reason == NOBODY_ANSWERED for m in chat.ring)
    assert chat.state == "idle"


async def test_held_card_delivered_on_attach(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    number = await new_chat(conn, folder)
    engine = factory.last
    engine.script(write_ask(folder), fake_result())
    await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
    seen = await recv_until(conn, ChatState)  # turn.started, working
    last_seen = seen[-1].seq
    assert last_seen is not None
    await conn.close()
    await wait_for(lambda: not server.attached)

    # The engine asks while nobody is attached: the card is held, the chat waits.
    chat = server.registry.get(number)
    await wait_for(lambda: bool(server.cards.open_cards(chat)))
    assert chat.state == "waiting on you"
    held = server.cards.open_cards(chat)[0]

    again = await attach(server)
    try:
        await again.send(dump(ChatOpen(ts=TS, chat=number, since=last_seen)))
        history = await recv(again)
        assert isinstance(history, ChatHistory) and not history.truncated
        assert [type(m) for m in history.events] == [CardAsk, ChatState]
        live = await recv(again)
        assert isinstance(live, ChatLive)
        # The open card is sent again after chat.live, unchanged: same id, same seq.
        replay = await recv(again)
        assert isinstance(replay, CardAsk)
        assert replay.id == held.id and replay.seq == held.seq

        await again.send(dump(CardAnswer(ts=TS, chat=number, id=held.id, answer={"decision": "allow"})))
        after = await recv_until(again, TurnFinished)
        assert isinstance(after[0], CardAnswered) and after[0].id == held.id
        assert isinstance(after[1], ChatState) and after[1].state == "working"
        await recv(again)
        assert engine.decisions == ["allow"]
    finally:
        await again.close()


async def test_hold_clock_stops_while_an_app_is_attached(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    server.cards.hold_seconds = 0.3
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        _, card = await start_turn_with_card(conn, number, engine, write_ask(folder), fake_result())
        await recv(conn)
        # Attached and thinking: well past the hold, the card is still open.
        await asyncio.sleep(0.6)
        assert [c.id for c in server.cards.open_cards(server.registry.get(number))] == [card.id]
        assert engine.decisions == []
        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "allow"})))
        await recv_until(conn, TurnFinished)
        await recv(conn)
        assert engine.decisions == ["allow"]
    finally:
        await conn.close()


# --- stale answers --------------------------------------------------------------


async def test_stale_card_answer_is_rejected_not_crash(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last

        # Unknown card id.
        await conn.send(dump(CardAnswer(ts=TS, chat=number, id="card-nope", answer={"decision": "allow"})))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "card.stale" and err.id == "card-nope" and err.chat == number

        # Answered twice.
        _, card = await start_turn_with_card(conn, number, engine, write_ask(folder), fake_result())
        await recv(conn)
        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "allow"})))
        await recv_until(conn, TurnFinished)
        await recv(conn)
        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "deny"})))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "card.stale" and err.id == card.id
        assert engine.decisions == ["allow"]

        # Answered after a cancel (turn.stop).
        _, card2 = await start_turn_with_card(conn, number, engine, write_ask(folder, "toolu_2"), fake_result())
        await recv(conn)
        await conn.send(dump(TurnStop(ts=TS, chat=number)))
        frames = await recv_until(conn, TurnFinished)
        await recv(conn)  # idle
        assert isinstance(frames[0], CardCancel) and frames[0].id == card2.id and frames[0].reason == "turn stopped"
        assert isinstance(frames[-1], TurnFinished) and frames[-1].outcome == "stopped"
        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card2.id, answer={"decision": "allow"})))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "card.stale"
        assert engine.decisions[-1] == ("deny", "turn stopped")

        # A wrong chat number for a real card is stale too, and the gateway is still alive.
        await conn.send(dump(CardAnswer(ts=TS, chat=99, id=card.id, answer={"decision": "allow"})))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code in ("card.stale", "chat.unknown")
        engine.script(fake_result())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="still here")))
        await recv_until(conn, TurnFinished)
    finally:
        await conn.close()


# --- replay and cancel ----------------------------------------------------------


async def test_answered_card_is_closed_in_a_ring_replay(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    # Answer a card, quit the app, reopen: the replay from the beginning must
    # carry the card and its closing event, so the app does not pin it again.
    conn = await attach(server)
    number = await new_chat(conn, folder)
    engine = factory.last
    _, card = await start_turn_with_card(conn, number, engine, write_ask(folder), fake_result())
    await recv(conn)  # waiting on you
    await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "allow"}, scope="once")))
    after = await recv_until(conn, TurnFinished)
    await recv(conn)  # idle
    assert [type(m) for m in after] == [CardAnswered, ChatState, TurnFinished]
    answered = after[0]
    assert isinstance(answered, CardAnswered) and answered.id == card.id and answered.chat == number
    assert answered.seq is not None and card.seq is not None and answered.seq > card.seq
    await conn.close()

    again = await attach(server)
    try:
        await again.send(dump(ChatOpen(ts=TS, chat=number)))
        history = await recv(again)
        assert isinstance(history, ChatHistory) and not history.truncated
        kinds = [type(m) for m in history.events]
        assert kinds.index(CardAsk) < kinds.index(CardAnswered)
        assert [m.id for m in history.events if isinstance(m, CardAnswered)] == [card.id]
        assert isinstance(await recv(again), ChatLive)
        # Nothing is open, so nothing is re-sent after chat.live.
        with pytest.raises(TimeoutError):
            await recv(again, timeout=0.2)
        # And the stale answer is refused, as before.
        await again.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "allow"})))
        err = await recv(again)
        assert isinstance(err, Error) and err.code == "card.stale"
    finally:
        await again.close()


async def test_open_cards_replay_on_chat_open(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        _, card = await start_turn_with_card(conn, number, engine, write_ask(folder), fake_result())
        waiting = await recv(conn)
        assert isinstance(waiting, ChatState) and waiting.seq is not None

        await conn.send(dump(ChatOpen(ts=TS, chat=number, since=waiting.seq, id="req-open")))
        history = await recv(conn)
        assert isinstance(history, ChatHistory) and history.events == []
        live = await recv(conn)
        assert isinstance(live, ChatLive) and live.seq == waiting.seq
        replay = await recv(conn)
        assert isinstance(replay, CardAsk) and replay.id == card.id and replay.seq == card.seq
        # Replaying does not advance the chat's sequence.
        assert server.registry.get(number).seq == waiting.seq

        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "allow"})))
        await recv_until(conn, TurnFinished)
        await recv(conn)

        # Nothing open now: chat.open ends at chat.live.
        await conn.send(dump(ChatOpen(ts=TS, chat=number, since=server.registry.get(number).seq)))
        assert isinstance(await recv(conn), ChatHistory)
        assert isinstance(await recv(conn), ChatLive)
        with pytest.raises(TimeoutError):
            await recv(conn, timeout=0.2)
    finally:
        await conn.close()


async def test_chat_stop_cancels_open_cards(server: GatewayServer, factory: EngineFactory, folder: Path, state_dir: StateDir) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        _, card = await start_turn_with_card(conn, number, engine, write_ask(folder), fake_result())
        await recv(conn)

        await conn.send(dump(ChatStop(ts=TS, chat=number)))
        frames = await recv_until(conn, TurnFinished)
        stopped = await recv(conn)
        assert [type(m) for m in frames] == [CardCancel, TurnFinished]
        cancel = frames[0]
        assert isinstance(cancel, CardCancel) and cancel.id == card.id and cancel.reason == "chat stopped"
        assert isinstance(frames[1], TurnFinished) and frames[1].outcome == "stopped"
        assert isinstance(stopped, ChatState) and stopped.state == "stopped"

        chat = server.registry.get(number)
        assert server.cards.open_cards(chat) == []
        assert engine.closed
        assert state_dir.load_index().chats[0].state == "stopped"
    finally:
        await conn.close()


# --- the broker on its own -------------------------------------------------------


def test_title_for_tools() -> None:
    assert title_for("Write") == "Write a file"
    assert title_for("Edit") == "Edit a file"
    assert title_for("MultiEdit") == "Edit a file"
    assert title_for("Read") == "Read a file"
    assert title_for("Bash") == "Run a command"
    assert title_for("WebFetch") == "Fetch a web page"
    assert title_for("mcp__thing__do") == "Use mcp__thing__do"


def test_question_card_maps_fields_and_tolerates_missing_description() -> None:
    card = question_card(3, [{"question": "Q?", "header": "H", "options": [{"label": "A"}], "multiSelect": True}])
    assert card.chat == 3 and card.kind == "question" and card.id
    assert card.questions is not None
    q = card.questions[0]
    assert q.question == "Q?" and q.header == "H" and q.multi_select is True
    assert [(o.label, o.description) for o in q.options] == [("A", "")]


async def test_broker_answer_unknown_is_stale_and_cancel_resolves_deny(tmp_path: Path) -> None:
    broker = CardBroker(hold_seconds=600)
    chat = Chat(1, tmp_path, 100)
    sent: list[ServerMessage] = []

    async def send(c: Chat, msg: ServerMessage) -> ServerMessage:
        stamped = c.stamp(msg)
        sent.append(stamped)
        return stamped

    with pytest.raises(ProtocolError) as e:
        broker.answer(chat.number, "nope", CardAnswer(ts=TS, chat=1, id="nope", answer={"decision": "allow"}))
    assert e.value.code == "card.stale"

    task = asyncio.create_task(broker.ask_permission(chat, "Bash", {"command": "ls"}, [], "t1", send))
    await wait_for(lambda: bool(broker.open_cards(chat)))
    card = broker.open_cards(chat)[0]
    await broker.cancel(chat, card.id, "turn stopped", send)
    assert await task == ("deny", "turn stopped")
    assert broker.open_cards(chat) == []
    assert isinstance(sent[-1], CardCancel) and sent[-1].id == card.id

    # A question cancelled the same way is declined, not answered.
    task2 = asyncio.create_task(broker.ask_question(chat, QUESTIONS[:1], send))
    await wait_for(lambda: bool(broker.open_cards(chat)))
    await broker.cancel_all(chat, "chat stopped", send)
    with pytest.raises(QuestionDeclined) as declined:
        await task2
    assert str(declined.value) == "chat stopped"
