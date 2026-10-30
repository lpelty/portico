"""v0.11 item 66: the agent's slash commands for the composer's completion list.

After an engine starts, the gateway reads its commands and skills
(``Engine.command_list``, the SDK's ``get_server_info()["commands"]``) and
sends ``chat.commands {chat, folder, commands}``. The last list per folder
is kept in ``commands.json`` so an app that connects before any engine has
started (the welcome) still has one: it hears the lists for the default
folder and the live sessions' folders right after ``services.status``.
Reading the commands never breaks a start: a failure is logged.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection

from portico_gateway.engine import SDKEngine, agent_commands
from portico_gateway.messages import AgentCommand, ChatCommands, ChatList, ChatNew, ChatState, ServicesStatus, dump, parse_server
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from tests.conftest import FakeEngine
from tests.test_server import attach
from tests.test_sessions import drain, start_server
from tests.test_turns import EngineFactory, new_chat, recv

TS = "2026-10-30T12:00:00Z"

RAW = [
    {"name": "standup", "description": "Draft a standup from today's log. Use when asked. (user)", "argumentHint": ""},
    {"name": "acme:review", "description": "Review a change before it ships\nMore detail here. (acme-tools)", "argumentHint": "[pr]"},
    {"name": "plain", "description": "No source here", "argumentHint": ""},
]


# --- the list as the engine gives it (pure) ---------------------------------------


def test_agent_commands_split_the_source_and_keep_the_first_sentence() -> None:
    got = agent_commands(RAW)
    assert got == [
        AgentCommand(name="standup", description="Draft a standup from today's log.", source="user"),
        AgentCommand(name="acme:review", description="Review a change before it ships", source="acme-tools"),
        AgentCommand(name="plain", description="No source here", source=None),
    ]


def test_agent_commands_skip_junk_and_repeats() -> None:
    raw = [
        {"name": "/standup", "description": "First. (user)"},
        {"name": "standup", "description": "Again. (project)"},
        {"name": "", "description": "nameless"},
        {"description": "no name"},
        "a bare string",
        {"name": "quiet"},
        {"name": 7, "description": "not a name"},
    ]
    assert agent_commands(raw) == [
        AgentCommand(name="standup", description="First.", source="user"),
        AgentCommand(name="quiet", description="", source=None),
    ]
    assert agent_commands(None) == []
    assert agent_commands({"name": "x"}) == []


def test_a_long_description_is_cut_with_an_ellipsis() -> None:
    long = "word " * 80
    (cmd,) = agent_commands([{"name": "long", "description": long.strip() + " (user)"}])
    assert len(cmd.description) <= 160 and cmd.description.endswith("…")
    assert cmd.source == "user"


def test_the_sdk_engine_keeps_the_list_from_its_server_info() -> None:
    engine = SDKEngine()
    assert engine.command_list() is None
    engine._note_commands_from_server_info({"commands": RAW})
    listed = engine.command_list()
    assert listed is not None and [c.name for c in listed] == ["standup", "acme:review", "plain"]
    # The names still feed the unknown-command check.
    assert engine.slash_commands() == {"standup", "acme:review", "plain"}


# --- the gateway -------------------------------------------------------------------


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


class CommandingFactory(EngineFactory):
    """Engines that know ``commands`` (or raise ``error`` when asked)."""

    def __init__(self, commands: list[AgentCommand] | None, error: Exception | None = None) -> None:
        super().__init__()
        self.commands = commands
        self.error = error

    def __call__(self) -> FakeEngine:
        engine = super().__call__()
        engine.command_entries = self.commands
        engine.command_error = self.error
        return engine


COMMANDS = agent_commands(RAW)


async def test_an_engine_start_sends_its_commands_and_keeps_them(state_dir: StateDir, folder: Path) -> None:
    srv = await start_server(state_dir, CommandingFactory(COMMANDS))
    try:
        conn = await attach(srv)
        try:
            await conn.send(dump(ChatNew(ts=TS, id="n1", folder=str(folder))))
            first = await recv(conn)
            assert isinstance(first, ChatCommands), first
            assert first.folder == str(folder) and first.commands == COMMANDS
            assert first.chat is not None and first.seq is None
            assert isinstance(await recv(conn), ChatState)
            assert isinstance(await recv(conn), ChatList)
        finally:
            await conn.close()
    finally:
        await srv.shutdown()
    assert state_dir.load_commands() == {str(folder): COMMANDS}


async def test_an_engine_that_cannot_say_sends_nothing(server: GatewayServer, folder: Path, state_dir: StateDir) -> None:
    conn = await attach(server)
    try:
        await new_chat(conn, folder)  # chat.state then chat.list, nothing before
        assert not any(isinstance(m, ChatCommands) for m in await drain(conn))
    finally:
        await conn.close()
    assert state_dir.load_commands() == {}


async def test_a_failure_to_read_the_commands_is_logged_never_fatal(
    state_dir: StateDir, folder: Path, caplog: pytest.LogCaptureFixture
) -> None:
    srv = await start_server(state_dir, CommandingFactory(None, error=RuntimeError("boom")))
    try:
        conn = await attach(srv)
        try:
            with caplog.at_level(logging.WARNING, logger="portico_gateway.server"):
                await new_chat(conn, folder)
            assert any("could not read the commands" in r.getMessage() for r in caplog.records)
        finally:
            await conn.close()
    finally:
        await srv.shutdown()


async def test_the_welcome_hears_the_last_list_before_any_engine(state_dir: StateDir, tmp_path: Path) -> None:
    home = tmp_path / "home-folder"
    home.mkdir()
    other = tmp_path / "other"
    other.mkdir()
    state_dir.save_commands({str(home): COMMANDS, str(other): COMMANDS[:1]})
    factory = EngineFactory()
    srv = await start_server(state_dir, factory, default_folder=str(home))
    try:
        conn = await attach(srv)
        try:
            got = await drain(conn)
            lists = [m for m in got if isinstance(m, ChatCommands)]
            # Only the default folder's: no live session is in ``other``.
            assert [(m.chat, m.folder, m.commands) for m in lists] == [(None, str(home), COMMANDS)]
            assert factory.engines == []
        finally:
            await conn.close()
    finally:
        await srv.shutdown()


async def test_a_live_sessions_folder_is_heard_on_connect(state_dir: StateDir, folder: Path) -> None:
    srv = await start_server(state_dir, CommandingFactory(COMMANDS))
    try:
        conn = await attach(srv)
        await new_chat_with_commands(conn, folder)
        await conn.close()
        again = await attach(srv)
        try:
            lists = [m for m in await drain(again) if isinstance(m, ChatCommands)]
            assert [(m.folder, m.commands) for m in lists] == [(str(folder), COMMANDS)]
        finally:
            await again.close()
    finally:
        await srv.shutdown()


async def new_chat_with_commands(conn: ClientConnection, folder: Path) -> int:
    """``chat.new`` on an engine that knows commands: ``chat.commands`` comes first."""
    await conn.send(dump(ChatNew(ts=TS, id="n1", folder=str(folder))))
    assert isinstance(await recv(conn), ChatCommands)
    state = await recv(conn)
    assert isinstance(state, ChatState)
    assert isinstance(await recv(conn), ChatList)
    return state.chat  # type: ignore[return-value]


def test_a_corrupt_commands_file_is_an_empty_cache(state_dir: StateDir) -> None:
    state_dir.commands_path.write_text("{not json")
    assert state_dir.load_commands() == {}


def test_the_cache_keeps_the_newest_folders(state_dir: StateDir) -> None:
    from portico_gateway.state import COMMAND_FOLDERS_KEPT

    lists = {f"/f{i}": COMMANDS[:1] for i in range(COMMAND_FOLDERS_KEPT + 3)}
    state_dir.save_commands(lists)
    kept = state_dir.load_commands()
    assert len(kept) == COMMAND_FOLDERS_KEPT
    assert list(kept)[-1] == f"/f{COMMAND_FOLDERS_KEPT + 2}"


def test_the_frame_round_trips() -> None:
    msg = ChatCommands(ts=TS, chat=3, folder="/x", commands=COMMANDS)
    assert parse_server(dump(msg)) == msg
    assert isinstance(parse_server(dump(ServicesStatus(ts=TS))), ServicesStatus)
