"""v0.11 decision 5 (item 55): the next session's number.

``chat.list`` carries ``next_chat`` so the welcome names the real next
session, not "Session 1" whatever the counter says. ``[sessions]
next_number`` is a deployment command whose stdout is that number, run when
a new session starts (and once at start for the welcome); anything unusable
falls back to Portico's own counter, logged. Real ``websockets`` client,
``FakeEngine`` behind every chat: no model.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from websockets.asyncio.client import connect

from portico_gateway.chats import ChatRegistry
from portico_gateway.config import ConfigError, load_config
from portico_gateway.messages import ChatList, HelloClient, HelloServer, SessionRenew, SessionRenewed, dump, parse_server
from portico_gateway.server import GatewayServer
from portico_gateway.session_numbers import NoNumber, next_session_number, number_from_command
from portico_gateway.state import Index, StateDir
from tests.test_server import attach, ws_url
from tests.test_sessions import start_server
from tests.test_turns import EngineFactory, new_chat, recv, recv_until

TS = "2026-10-30T12:00:00Z"


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = tmp_path / "demo"
    path.mkdir()
    return path


@pytest.fixture
async def servers() -> AsyncIterator[list[GatewayServer]]:
    started: list[GatewayServer] = []
    yield started
    for srv in started:
        await srv.shutdown()


async def first_list(srv: GatewayServer) -> ChatList:
    """The ``chat.list`` a fresh attach is sent."""
    conn = await connect(ws_url(srv, srv.token))
    try:
        await conn.send(dump(HelloClient(ts=TS, app_version="0.11.0")))
        assert isinstance(parse_server(await conn.recv()), HelloServer)
        listing = parse_server(await conn.recv())
        assert isinstance(listing, ChatList)
        return listing
    finally:
        await conn.close()


# --- the command ------------------------------------------------------------------


async def test_the_command_s_stdout_is_the_number() -> None:
    assert await number_from_command("echo 42") == 42
    assert await number_from_command("echo '  7 '; echo progress >&2") == 7, "stderr is not the number"


@pytest.mark.parametrize(
    ("command", "reason"),
    [
        ("exit 3", "exited 3"),
        ("echo soon", "not a whole number"),
        ("echo 0", "above zero"),
        ("echo 4; echo 5", "not a whole number"),
        ("sleep 5", "timed out"),
    ],
)
async def test_an_unusable_command_says_why(command: str, reason: str) -> None:
    with pytest.raises(NoNumber) as e:
        await number_from_command(command, timeout=0.3)
    assert reason in str(e.value)


async def test_anything_unusable_falls_back_to_portico_s_counter_and_logs(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.WARNING, logger="portico_gateway.session_numbers")
    assert await next_session_number(None, 5) == 5
    assert await next_session_number("echo 80", 5) == 80
    assert await next_session_number("exit 1", 5) == 5
    assert await next_session_number("echo 3", 5) == 5, "a number already passed is never reused"
    assert await next_session_number("sleep 5", 5, timeout=0.3) == 5
    lines = [r.getMessage() for r in caplog.records]
    assert any("exited 1" in line and "using Portico's own number 5" in line for line in lines)
    assert any("below Portico's next number 5" in line for line in lines)
    assert any("timed out" in line for line in lines)


def test_the_config_key_loads_and_blank_is_unset(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text('[sessions]\nnext_number = "acme-sessions next"\n')
    assert load_config(path).sessions.next_number == "acme-sessions next"
    path.write_text('[sessions]\nnext_number = "  "\n')
    assert load_config(path).sessions.next_number is None
    path.write_text("[sessions]\nnumber = 3\n")
    with pytest.raises(ConfigError):
        load_config(path)


def test_the_registry_takes_a_number_at_or_above_its_own(state_dir: StateDir) -> None:
    registry = ChatRegistry(index=Index(next_chat=4), state=state_dir, history_buffer=10)
    assert registry.next_number == 4
    assert registry.create(Path("/tmp"), number=40).number == 40
    assert registry.next_number == 41
    assert registry.create(Path("/tmp"), number=12).number == 41, "never below the counter"
    assert registry.create(Path("/tmp")).number == 42


# --- through the gateway -------------------------------------------------------------


async def test_chat_list_names_the_next_number(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    state_dir.save_index(Index(next_chat=17))
    srv = await start_server(state_dir, factory, presentation="single")
    servers.append(srv)
    assert (await first_list(srv)).next_chat == 17, "not Session 1 whatever the counter says"
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        assert number == 17
        assert srv.chat_list().next_chat == 18
    finally:
        await conn.close()


async def test_the_command_numbers_the_session_and_the_welcome(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    counter = folder.parent / "acme-counter"
    counter.write_text("78")
    srv = await start_server(
        state_dir, factory, presentation="single", sessions={"next_number": f"cat {counter}"}
    )
    servers.append(srv)
    assert (await first_list(srv)).next_chat == 78, "the welcome shows the deployment's number"
    conn = await attach(srv)
    try:
        assert await new_chat(conn, folder) == 78
        counter.write_text("81")
        await conn.send(dump(SessionRenew(ts=TS, id="r1", chat=78, log=False)))
        frames = await recv_until(conn, SessionRenewed)
        renewed = frames[-1]
        assert isinstance(renewed, SessionRenewed)
        assert renewed.next.chat == 81, "run again when the next session starts"
        listing = await recv(conn)
        assert isinstance(listing, ChatList) and listing.next_chat == 82
    finally:
        await conn.close()


async def test_a_failing_command_leaves_portico_s_counter(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await start_server(state_dir, factory, presentation="single", sessions={"next_number": "exit 2"})
    servers.append(srv)
    assert (await first_list(srv)).next_chat == 1
    conn = await attach(srv)
    try:
        assert await new_chat(conn, folder) == 1
    finally:
        await conn.close()


async def test_no_command_is_run_at_start_while_a_session_is_live(
    state_dir: StateDir, factory: EngineFactory, folder: Path, tmp_path: Path, servers: list[GatewayServer]
) -> None:
    ran = tmp_path / "ran"
    srv = await start_server(state_dir, factory, presentation="single")
    conn = await attach(srv)
    await new_chat(conn, folder)
    await conn.close()
    await srv.shutdown()
    srv = await start_server(
        state_dir, factory, presentation="single", sessions={"next_number": f"touch {ran}; echo 9"}
    )
    servers.append(srv)
    assert not ran.exists(), "the welcome continues the live session: nothing to number"
    assert (await first_list(srv)).next_chat == 2
