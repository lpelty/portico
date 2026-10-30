"""v0.11 decision 4 (item 54): the live session follows ``default_folder``.

In single presentation, when the deployment's ``default_folder`` changed
and the live session works elsewhere, the gateway's next start ends that
session and starts the next one in the new folder, saying why in the
conversation. ``sessions.clear`` drops the ended sessions from Portico's
list (single presentation only); their transcripts stay. Real
``websockets`` client, ``FakeEngine`` behind every chat: no model.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path

import pytest

from portico_gateway.config import hello_for
from portico_gateway.messages import ChatList, ChatNotice, Error, SessionsClear, dump, parse_client
from portico_gateway.server import GatewayServer, home_relative
from portico_gateway.state import StateDir
from tests.conftest import make_config
from tests.test_server import attach
from tests.test_sessions import start_server
from tests.test_turns import EngineFactory, new_chat, recv

TS = "2026-10-30T12:00:00Z"


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
def old(tmp_path: Path) -> Path:
    path = tmp_path / "old-vault"
    path.mkdir()
    return path


@pytest.fixture
def new(tmp_path: Path) -> Path:
    path = tmp_path / "new-vault"
    path.mkdir()
    return path


@pytest.fixture
async def servers() -> AsyncIterator[list[GatewayServer]]:
    started: list[GatewayServer] = []
    yield started
    for srv in started:
        await srv.shutdown()


async def first_session(state_dir: StateDir, factory: EngineFactory, folder: Path, **config: object) -> int:
    """Run a gateway with ``config``, start one session in ``folder``, stop it."""
    srv = await start_server(state_dir, factory, presentation="single", default_folder=str(folder), **config)
    conn = await attach(srv)
    try:
        return await new_chat(conn, folder)
    finally:
        await conn.close()
        await srv.shutdown()


def notices(srv: GatewayServer, number: int) -> list[str]:
    return [m.text for m in srv.registry.get(number).ring if isinstance(m, ChatNotice)]


# --- following the folder -------------------------------------------------------------


async def test_a_changed_default_folder_starts_a_new_session_there(
    state_dir: StateDir, factory: EngineFactory, old: Path, new: Path, servers: list[GatewayServer]
) -> None:
    first = await first_session(state_dir, factory, old)
    srv = await start_server(state_dir, factory, presentation="single", default_folder=str(new))
    servers.append(srv)
    ended = srv.registry.get(first)
    assert ended.ended is not None and ended.logged is None, "ended without a log step (no engine at start)"
    live = [c for c in srv.registry.chats() if c.ended is None]
    assert [c.folder for c in live] == [new]
    following = live[0]
    assert following.parent == first
    assert notices(srv, following.number) == [
        f"Started a new session in {home_relative(new)} — the deployment's folder changed"
    ]
    assert notices(srv, first) == [
        f"Session ended · the deployment's folder changed · continues in Session {following.number}"
    ]
    assert not factory.engines[1:], "no engine starts until the person sends"


async def test_the_same_folder_keeps_the_live_session(
    state_dir: StateDir, factory: EngineFactory, old: Path, servers: list[GatewayServer]
) -> None:
    first = await first_session(state_dir, factory, old)
    srv = await start_server(state_dir, factory, presentation="single", default_folder=str(old))
    servers.append(srv)
    assert [c.number for c in srv.registry.chats() if c.ended is None] == [first]


async def test_a_folder_the_person_chose_is_kept_while_default_folder_is_unchanged(
    state_dir: StateDir, factory: EngineFactory, old: Path, new: Path, servers: list[GatewayServer]
) -> None:
    # The gateway ran with default_folder = old; the person's session works in new.
    srv = await start_server(state_dir, factory, presentation="single", default_folder=str(old))
    conn = await attach(srv)
    number = await new_chat(conn, new)
    await conn.close()
    await srv.shutdown()
    srv = await start_server(state_dir, factory, presentation="single", default_folder=str(old))
    servers.append(srv)
    assert [c.number for c in srv.registry.chats() if c.ended is None] == [number], "only a change moves it"


async def test_an_index_from_before_v011_follows_the_folder_once(
    state_dir: StateDir, factory: EngineFactory, old: Path, new: Path, servers: list[GatewayServer]
) -> None:
    first = await first_session(state_dir, factory, old)
    index = state_dir.load_index()
    index.default_folder = None  # as a v0.10 gateway left it
    state_dir.save_index(index)
    srv = await start_server(state_dir, factory, presentation="single", default_folder=str(new))
    servers.append(srv)
    assert srv.registry.get(first).ended is not None
    assert state_dir.load_index().default_folder == str(new.resolve())


async def test_multiple_presentation_and_a_missing_folder_change_nothing(
    state_dir: StateDir, factory: EngineFactory, old: Path, tmp_path: Path, servers: list[GatewayServer]
) -> None:
    first = await first_session(state_dir, factory, old)
    srv = await start_server(state_dir, factory, presentation="single", default_folder=str(tmp_path / "gone"))
    assert srv.registry.get(first).ended is None, "a default_folder that is not there is not followed"
    await srv.shutdown()
    srv = await start_server(state_dir, factory, presentation="multiple", default_folder=str(tmp_path))
    servers.append(srv)
    assert srv.registry.get(first).ended is None


async def test_the_app_hears_the_new_session_and_its_notice_on_attach(
    state_dir: StateDir, factory: EngineFactory, old: Path, new: Path, servers: list[GatewayServer]
) -> None:
    await first_session(state_dir, factory, old)
    srv = await start_server(state_dir, factory, presentation="single", default_folder=str(new))
    servers.append(srv)
    listing = srv.chat_list()
    live = [c for c in listing.chats if c.ended is None]
    assert [c.folder for c in live] == [str(new)]


def test_home_relative_paths_read_with_a_tilde() -> None:
    assert home_relative(Path.home() / "vaults" / "acme") == "~/vaults/acme"
    assert home_relative(Path("/opt/acme")) == "/opt/acme"


# --- clearing earlier sessions --------------------------------------------------------


async def test_clear_drops_the_ended_sessions_and_keeps_the_live_one(
    state_dir: StateDir, factory: EngineFactory, old: Path, new: Path, servers: list[GatewayServer]
) -> None:
    first = await first_session(state_dir, factory, old)
    srv = await start_server(state_dir, factory, presentation="single", default_folder=str(new))
    servers.append(srv)
    live = next(c.number for c in srv.registry.chats() if c.ended is None)
    conn = await attach(srv)
    try:
        await conn.send(dump(SessionsClear(ts=TS, id="c1")))
        listing = await recv(conn)
        assert isinstance(listing, ChatList)
        assert [c.chat for c in listing.chats] == [live]
        assert first not in srv.registry
        assert [c.chat for c in state_dir.load_index().chats] == [live], "kept in the index too"
        assert listing.next_chat == live + 1, "numbers are not handed out again"
    finally:
        await conn.close()


async def test_clear_is_refused_in_multiple_presentation(
    state_dir: StateDir, factory: EngineFactory, servers: list[GatewayServer]
) -> None:
    srv = await start_server(state_dir, factory, presentation="multiple")
    servers.append(srv)
    conn = await attach(srv)
    try:
        await conn.send(dump(SessionsClear(ts=TS, id="c1")))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "sessions.not_single" and err.id == "c1"
    finally:
        await conn.close()


def test_clear_is_offered_in_single_presentation_only() -> None:
    assert "sessions.clear" in hello_for(make_config(presentation="single"), epoch="e", gateway_version="0.11.0").capabilities
    assert "sessions.clear" not in hello_for(make_config(presentation="multiple"), epoch="e", gateway_version="0.11.0").capabilities
    assert isinstance(parse_client(dump(SessionsClear(ts=TS))), SessionsClear)
