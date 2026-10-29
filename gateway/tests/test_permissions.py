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
    TurnFinished,
    dump,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from tests.conftest import AskPermission, fake_result, make_config
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
