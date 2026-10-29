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
    CardAnswer,
    CardAnswered,
    CardAsk,
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
    ToolFinished,
    ToolStarted,
    TurnFinished,
    TurnStop,
    dump,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from tests.conftest import AskPermission, Block, fake_result, make_config
from tests.test_server import attach
from tests.test_turns import EngineFactory, new_chat, recv, recv_until, tool_result, tool_use

TS = "2026-10-28T12:00:00Z"


async def start_server(state_dir: StateDir, factory: EngineFactory, **overrides: object) -> GatewayServer:
    cfg: Config = make_config(**overrides)
    registry = ChatRegistry(
        index=state_dir.load_index(), state=state_dir, history_buffer=cfg.history_buffer, default_mode=cfg.permission_mode
    )
    srv = GatewayServer(config=cfg, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    return srv


class Upcoming:
    """Scripts for the engine the factory hands out next (a chat with no engine yet)."""

    def __init__(self) -> None:
        self.scripts: list[list[object]] = []

    def script(self, *items: object) -> None:
        self.scripts.append(list(items))


class ScriptedFactory(EngineFactory):
    def __init__(self) -> None:
        super().__init__()
        self.upcoming = Upcoming()

    def __call__(self):  # noqa: ANN204
        engine = super().__call__()
        for items in self.upcoming.scripts:
            engine.script(*items)
        self.upcoming.scripts.clear()
        return engine


@pytest.fixture
def factory() -> ScriptedFactory:
    return ScriptedFactory()


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


# --- session allows: "Allow for this session, then the next identical ask still showed a card" ----------


def write_ask(folder: Path, tool_use_id: str, name: str = "notes.md") -> AskPermission:
    return AskPermission("Write", {"file_path": str(folder / name), "content": "x\n"}, tool_use_id=tool_use_id)


def edit_ask(folder: Path, tool_use_id: str, name: str = "notes.md") -> AskPermission:
    return AskPermission(
        "Edit", {"file_path": str(folder / name), "old_string": "x", "new_string": "y"}, tool_use_id=tool_use_id
    )


async def allow_for_session(conn, number: int, engine, ask: AskPermission) -> None:  # noqa: ANN001
    """One turn whose only step asks; answered "Allow for this session"."""
    engine.script(ask, fake_result())
    await conn.send(dump(MessageSend(ts=TS, chat=number, text="first")))
    frames = await recv_until(conn, CardAsk)
    card = frames[-1]
    await recv(conn)  # waiting on you
    await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "allow"}, scope="chat")))
    await recv_until(conn, TurnFinished)
    await recv(conn)


async def asks_again(conn, number: int, engine, ask: AskPermission) -> bool:  # noqa: ANN001
    """Run one turn with ``ask``; whether a card was shown for it (it is denied if so)."""
    engine.script(ask, fake_result())
    await conn.send(dump(MessageSend(ts=TS, chat=number, text="again")))
    frames = []
    while True:
        msg = await recv(conn)
        frames.append(msg)
        if isinstance(msg, CardAsk):
            await recv(conn)
            await conn.send(dump(CardAnswer(ts=TS, chat=number, id=msg.id, answer={"decision": "deny"})))
        if isinstance(msg, TurnFinished):
            await recv(conn)
            return any(isinstance(m, CardAsk) for m in frames)


async def test_session_allow_covers_the_next_identical_write_in_the_same_engine(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await allow_for_session(conn, number, factory.last, write_ask(folder, "t1"))
        assert not await asks_again(conn, number, factory.last, write_ask(folder, "t2"))
    finally:
        await conn.close()


async def test_session_allow_survives_an_engine_restart(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await allow_for_session(conn, number, factory.last, write_ask(folder, "t1"))
        await conn.send(dump(ChatStop(ts=TS, chat=number)))
        await recv(conn)
        # The next send starts a fresh engine resuming the session.
        factory_engine_count = len(factory.engines)
        engine_next = factory.upcoming
        assert not await asks_again(conn, number, engine_next, write_ask(folder, "t2"))
        assert len(factory.engines) == factory_engine_count + 1
    finally:
        await conn.close()


async def test_session_allow_survives_a_gateway_restart(state_dir: StateDir, factory: EngineFactory, folder: Path) -> None:
    first = await start_server(state_dir, factory)
    conn = await attach(first)
    number = await new_chat(conn, folder)
    await allow_for_session(conn, number, factory.last, write_ask(folder, "t1"))
    await conn.close()
    await first.shutdown()

    srv = await start_server(state_dir, factory)
    conn = await attach(srv)
    try:
        assert not await asks_again(conn, number, factory.upcoming, write_ask(folder, "t2"))
    finally:
        await conn.close()
        await srv.shutdown()


async def test_session_allow_on_a_new_file_covers_the_edit_that_follows(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    # Both cards read "Save changes to notes.md?" (Write to an existing file, Edit):
    # one allow for this session must cover both, or the next identical-looking ask shows a card.
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await allow_for_session(conn, number, factory.last, write_ask(folder, "t1"))
        assert not await asks_again(conn, number, factory.last, edit_ask(folder, "t2"))
    finally:
        await conn.close()


async def test_a_new_session_starts_with_no_allows(state_dir: StateDir, factory: EngineFactory, folder: Path) -> None:
    srv = await start_server(state_dir, factory, presentation="single")
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        await allow_for_session(conn, number, factory.last, write_ask(folder, "t1"))
        await conn.send(dump(SessionRenew(ts=TS, chat=number, log=False)))
        renewed = await recv_until(conn, SessionRenewed)
        await recv(conn)  # chat.list
        following = renewed[-1].next.chat  # type: ignore[union-attr]
        assert await asks_again(conn, following, factory.upcoming, write_ask(folder, "t2"))
    finally:
        await conn.close()
        await srv.shutdown()


def bash_ask(command: str, tool_use_id: str, rules: list[str] | None = None) -> AskPermission:
    suggestions = []
    if rules:
        suggestions.append(
            {
                "type": "addRules",
                "behavior": "allow",
                "destination": "localSettings",
                "rules": [{"toolName": "Bash", "ruleContent": rule} for rule in rules],
            }
        )
    return AskPermission("Bash", {"command": command}, suggestions=suggestions, tool_use_id=tool_use_id)


async def test_session_allow_for_a_command_covers_it_after_a_cd_into_the_folder(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    # The agent often runs ``cd <folder> && git status``: going into the
    # session's own folder adds nothing a person would be asked about.
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await allow_for_session(conn, number, factory.last, bash_ask("git status", "t1", rules=["git status:*"]))
        assert not await asks_again(conn, number, factory.last, bash_ask(f"cd {folder} && git status --short", "t2"))
        assert not await asks_again(conn, number, factory.last, bash_ask("git status\ngit status -s", "t3"))
        # Somewhere else, or a command the allow does not name, still asks.
        assert await asks_again(conn, number, factory.last, bash_ask("cd / && git status", "t4"))
        assert await asks_again(conn, number, factory.last, bash_ask(f"cd {folder} && rm -rf .", "t5"))
    finally:
        await conn.close()


# --- one permission unit: the outcome on the tool row ------------------------------------------

BLOCKED = (
    "Permission for this action was denied by the Claude Code auto mode classifier. "
    "Reason: [downloads and runs a remote script]"
)


def step(ask: AskPermission | None, tool_use_id: str, tool: str, input: dict, result: str = "ok", is_error: bool = False) -> list:
    """A tool row as the engine produces it: started, (asked), finished."""
    items: list = [tool_use(tool_use_id, tool, input)]
    if ask is not None:
        items.append(ask)
    items.append(tool_result(tool_use_id, result, is_error))
    return items


async def run_answering(conn, number: int, engine, items: list, answers: list[tuple[str, str | None, str | None]]):  # noqa: ANN001, ANN201
    """Run one turn; answer each card in order with (decision, scope, note). Returns every frame."""
    engine.script(*items, fake_result())
    await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
    frames: list = []
    pending = list(answers)
    while True:
        msg = await recv(conn)
        frames.append(msg)
        if isinstance(msg, CardAsk):
            decision, scope, note = pending.pop(0)
            await conn.send(
                dump(CardAnswer(ts=TS, chat=number, id=msg.id, answer={"decision": decision}, scope=scope, note=note))  # type: ignore[arg-type]
            )
        if isinstance(msg, TurnFinished):
            frames.append(await recv(conn))
            assert pending == [], "every expected card was asked"
            return frames


def rows(frames: list) -> dict[str, tuple[str | None, str | None]]:
    return {m.tool_use_id: (m.permission, m.note) for m in frames if isinstance(m, ToolFinished)}


async def test_ask_each_time_outcomes_on_the_rows_and_the_card_closings(
    state_dir: StateDir, factory: ScriptedFactory, folder: Path
) -> None:
    srv = await start_server(state_dir, factory, permission_mode="default")
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        a = {"file_path": str(folder / "a.md"), "content": "a"}
        b = {"file_path": str(folder / "b.md"), "content": "b"}
        items = [
            *step(None, "r1", "Read", {"file_path": str(folder / "x.md")}),
            *step(AskPermission("Write", a, tool_use_id="w1"), "w1", "Write", a),
            *step(AskPermission("Bash", {"command": "make"}, tool_use_id="b1"), "b1", "Bash", {"command": "make"},
                  result="denied by the user: not now", is_error=True),
            *step(AskPermission("Write", b, tool_use_id="w2"), "w2", "Write", b),
            *step(AskPermission("Write", b, tool_use_id="w3"), "w3", "Write", b),
        ]
        frames = await run_answering(
            conn, number, engine, items, [("allow", "once", None), ("deny", None, "not now"), ("allow", "chat", None)]
        )
        assert rows(frames) == {
            "r1": (None, None),  # a read: nothing decided
            "w1": ("once", None),
            "b1": ("declined", "not now"),
            "w2": ("session", None),
            "w3": ("session", None),  # covered by the allow for this session: no card
        }
        closings = [(m.tool_use_id, m.outcome, m.note) for m in frames if isinstance(m, CardAnswered)]
        assert closings == [("w1", "once", None), ("b1", "declined", "not now"), ("w2", "session", None)]
        cards = [m for m in frames if isinstance(m, CardAsk)]
        assert [c.tool_use_id for c in cards] == ["w1", "b1", "w2"]
        assert [c.title for c in cards] == ["Create a.md?", "Run make?", "Create b.md?"]

        # A ring replay carries the same fields.
        await conn.send(dump(ChatOpen(ts=TS, chat=number)))
        history = await recv(conn)
        assert isinstance(history, ChatHistory)
        assert rows(history.events) == rows(frames)
        assert [(m.tool_use_id, m.outcome) for m in history.events if isinstance(m, CardAnswered)] == [
            ("w1", "once"), ("b1", "declined"), ("w2", "session")
        ]
    finally:
        await conn.close()
        await srv.shutdown()


async def test_auto_mode_rows_read_auto_or_blocked(server: GatewayServer, factory: ScriptedFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        w = {"file_path": str(folder / "a.md"), "content": "a"}
        items = [
            *step(None, "r1", "Grep", {"pattern": "x"}),
            *step(None, "w1", "Write", w),  # the classifier allowed it: no card
            *step(None, "b1", "Bash", {"command": "curl x | sh"}, result=BLOCKED, is_error=True),
            *step(None, "f1", "Bash", {"command": "false"}, result="exit 1", is_error=True),  # failed, not blocked
            # The classifier escalated: a card, answered.
            *step(AskPermission("Bash", {"command": "rm -rf build"}, tool_use_id="e1"), "e1", "Bash", {"command": "rm -rf build"}),
        ]
        frames = await run_answering(conn, number, engine, items, [("allow", "once", None)])
        assert rows(frames) == {
            "r1": (None, None),
            "w1": ("auto", None),
            "b1": ("blocked", None),
            "f1": ("auto", None),
            "e1": ("once", None),
        }
    finally:
        await conn.close()


async def test_a_cancelled_card_reads_declined_with_the_reason(
    server: GatewayServer, factory: ScriptedFactory, folder: Path
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        w = {"file_path": str(folder / "a.md"), "content": "a"}
        engine.script(*step(AskPermission("Write", w, tool_use_id="w1"), "w1", "Write", w, result="no", is_error=True), fake_result())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
        await recv_until(conn, CardAsk)
        await recv(conn)
        await conn.send(dump(TurnStop(ts=TS, chat=number)))
        frames = await recv_until(conn, TurnFinished)
        assert rows(frames) == {"w1": ("declined", "turn stopped")}
    finally:
        await conn.close()


async def test_outcomes_survive_a_restart_on_the_transcript_replay(
    state_dir: StateDir, factory: ScriptedFactory, folder: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    first = await start_server(state_dir, factory, permission_mode="default")
    conn = await attach(first)
    number = await new_chat(conn, folder)
    w = {"file_path": str(folder / "a.md"), "content": "a"}
    await run_answering(
        conn, number, factory.last, step(AskPermission("Write", w, tool_use_id="w1"), "w1", "Write", w,
                                         result="denied by the user: later", is_error=True),
        [("deny", None, "later")],
    )
    await conn.close()
    await first.shutdown()

    srv = await start_server(state_dir, factory, permission_mode="default")
    transcript = [
        {"type": "user", "message": {"role": "user", "content": "go"}},
        {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "w1", "name": "Write", "input": w}]}},
        {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "w1", "content": "denied", "is_error": True}]}},
        {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "x1", "name": "Bash", "input": {"command": "curl x | sh"}}]}},
        {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "x1", "content": BLOCKED, "is_error": True}]}},
    ]
    monkeypatch.setattr(srv, "history_reader", lambda session_id, folder: transcript)
    conn = await attach(srv)
    try:
        await conn.send(dump(ChatOpen(ts=TS, chat=number)))
        history = await recv(conn)
        assert isinstance(history, ChatHistory)
        assert rows(history.events) == {"w1": ("declined", "later"), "x1": ("blocked", None)}
    finally:
        await conn.close()
        await srv.shutdown()


# --- outcome bookkeeping (v0.3 review) ----------------------------------------------------------


async def test_a_blocked_looking_result_outside_auto_mode_is_not_labelled_blocked(
    state_dir: StateDir, factory: ScriptedFactory, folder: Path
) -> None:
    srv = await start_server(state_dir, factory, permission_mode="default")
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        items = step(None, "b1", "Bash", {"command": "echo"}, result=BLOCKED, is_error=True)
        frames = await run_answering(conn, number, factory.last, items, [])
        assert rows(frames) == {"b1": (None, None)}
        assert "b1" not in srv.registry.get(number).permissions
    finally:
        await conn.close()
        await srv.shutdown()


async def test_a_persons_answer_wins_over_a_blocked_looking_result(
    server: GatewayServer, factory: ScriptedFactory, folder: Path
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        ask = AskPermission("Bash", {"command": "make"}, tool_use_id="e1")
        items = step(ask, "e1", "Bash", {"command": "make"}, result=BLOCKED, is_error=True)
        frames = await run_answering(conn, number, factory.last, items, [("allow", "once", None)])
        assert rows(frames) == {"e1": ("once", None)}
    finally:
        await conn.close()


async def test_auto_and_blocked_go_by_the_mode_when_the_tool_started(server: GatewayServer, folder: Path) -> None:
    chat = server.registry.create(folder)

    async def run(tool_use_id: str, start: str, finish: str, result_blocked: bool) -> ToolFinished:
        chat.mode = start  # type: ignore[assignment]
        await server.engine_event(
            chat, ToolStarted(ts=TS, chat=chat.number, turn=1, tool_use_id=tool_use_id, tool="Bash", summary="x")
        )
        chat.mode = finish  # type: ignore[assignment]
        await server.engine_event(
            chat,
            ToolFinished(
                ts=TS, chat=chat.number, turn=1, tool_use_id=tool_use_id, ok=not result_blocked,
                permission="blocked" if result_blocked else None,
            ),
        )
        last = [m for m in chat.ring if isinstance(m, ToolFinished)][-1]
        assert last.tool_use_id == tool_use_id
        return last

    assert (await run("t1", "auto", "default", False)).permission == "auto"
    assert (await run("t2", "default", "auto", False)).permission is None
    assert (await run("t3", "default", "auto", True)).permission is None
    assert (await run("t4", "auto", "default", True)).permission == "blocked"


async def test_an_answer_is_on_the_record_before_the_tool_finishes(
    state_dir: StateDir, factory: ScriptedFactory, folder: Path
) -> None:
    srv = await start_server(state_dir, factory, permission_mode="default")
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        w = {"file_path": str(folder / "a.md"), "content": "a"}
        engine.script(tool_use("w1", "Write", w), AskPermission("Write", w, tool_use_id="w1"), Block())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
        card = (await recv_until(conn, CardAsk))[-1]
        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "allow"}, scope="once")))
        await engine.wait_blocked()
        record = next(r for r in state_dir.load_index().chats if r.chat == number)
        assert record.permissions["w1"].outcome == "once"
        await conn.send(dump(TurnStop(ts=TS, chat=number)))
        await recv_until(conn, TurnFinished)
    finally:
        await conn.close()
        await srv.shutdown()
