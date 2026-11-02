"""v0.16 Task 1: threads in the index, ``threads.v1``, and Main detection that ignores threads.

A thread is a chat with a ``thread`` record (label, slot, parent, brief,
files, opened_at). Main is the newest live chat without one, everywhere the
gateway looks Main up: ``status()``, the ``chat.new`` refusal, the welcome's
number preview and following ``default_folder``. Proposals live in the
index until started, dismissed, or Main's session ends. Real ``websockets``
client, ``FakeEngine`` behind every chat: no model.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path

import pytest

from portico_gateway.chats import ChatRegistry
from portico_gateway.config import ConfigError, hello_for, load_config
from portico_gateway.messages import ChatNew, Error, ThreadInfo, ThreadProposal, dump
from portico_gateway.server import GatewayServer, for_app
from portico_gateway.state import ProposalRecord, StateDir
from portico_gateway.status import describe
from tests.conftest import make_config
from tests.test_server import attach
from tests.test_sessions import start_server
from tests.test_turns import EngineFactory, new_chat, recv

TS = "2026-11-02T14:05:00Z"
BRIEF = "Review the Acme pricing page"


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = tmp_path / "acme"
    path.mkdir()
    return path


@pytest.fixture
async def servers() -> AsyncIterator[list[GatewayServer]]:
    started: list[GatewayServer] = []
    yield started
    for srv in started:
        await srv.shutdown()


def thread_info(slot: int = 1, parent: int = 3) -> ThreadInfo:
    return ThreadInfo(label=f"Thread {slot}", slot=slot, parent=parent, brief=BRIEF, files=[], opened_at=TS)


def registry_on(state_dir: StateDir) -> ChatRegistry:
    return ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=100)


def seed(state_dir: StateDir, folder: Path, *, main_ended: bool = False, threads: int = 1) -> ChatRegistry:
    """Chats 1 and 2 (ended), 3 (Main) and 4… (threads, newer), saved to the index."""
    registry = registry_on(state_dir)
    for _ in range(2):
        registry.create(folder).ended = TS
    main = registry.create(folder)
    assert main.number == 3
    if main_ended:
        main.ended = TS
    for slot in range(1, threads + 1):
        registry.create(folder, parent=3, thread=thread_info(slot))
    registry.persist()
    return registry


def proposal(id: str, chat: int = 3) -> ProposalRecord:
    return ProposalRecord(id=id, chat=chat, tool_use_id=f"toolu_{id}", brief=BRIEF, files=[], created=TS, state="pending")


# --- the model ------------------------------------------------------------------


def test_thread_round_trips_the_index(state_dir: StateDir, folder: Path) -> None:
    registry = seed(state_dir, folder)
    assert registry.get(4).thread == thread_info()
    reloaded = registry_on(state_dir)
    assert reloaded.get(4).thread == thread_info()
    assert reloaded.get(4).summary().thread == thread_info()
    assert reloaded.get(3).thread is None and reloaded.get(3).summary().thread is None


def test_main_ignores_threads(state_dir: StateDir, folder: Path) -> None:
    registry = seed(state_dir, folder)
    main = registry.main()
    assert main is not None and main.number == 3
    assert [c.number for c in registry.open_threads()] == [4]
    assert registry.free_slot(2) == 2
    registry.create(folder, parent=3, thread=thread_info(2))
    assert [c.thread.slot for c in registry.open_threads() if c.thread] == [1, 2]
    assert registry.free_slot(2) is None
    registry.get(4).ended = TS
    assert registry.free_slot(2) == 1, "a closed thread frees its slot"
    assert [c.number for c in registry.open_threads()] == [5]
    assert registry.main() is not None and registry.main().number == 3  # type: ignore[union-attr]


def test_no_main_when_only_threads_are_live(state_dir: StateDir, folder: Path) -> None:
    registry = seed(state_dir, folder, main_ended=True)
    assert registry.main() is None
    assert [c.number for c in registry.open_threads()] == [4]


def test_proposals_persist_and_prune(state_dir: StateDir, folder: Path) -> None:
    registry = seed(state_dir, folder)
    registry.add_proposal(proposal("p1"))
    registry.add_proposal(proposal("p2"))
    registry.add_proposal(proposal("p3"))
    started = registry.resolve_proposal("p1", "started", thread=4)
    assert started.state == "started" and started.thread == 4
    assert [p.id for p in registry.dismiss_pending(3)] == ["p2", "p3"]

    reloaded = registry_on(state_dir)
    assert reloaded.proposal("p1").state == "started" and reloaded.proposal("p1").thread == 4
    assert [p.state for p in reloaded.proposals_for(3)] == ["started", "dismissed", "dismissed"]
    with pytest.raises(KeyError):
        reloaded.proposal("nope")

    reloaded.remove(3)
    assert reloaded.proposals_for(3) == []
    assert registry_on(state_dir).proposals_for(3) == [], "the removal is saved"

    for n in range(101):
        reloaded.add_proposal(proposal(f"q{n}", chat=4))
    kept = registry_on(state_dir).proposals_for(4)
    assert len(kept) == 100
    assert kept[0].id == "q1" and kept[-1].id == "q100", "the newest 100 are kept"


# --- the protocol ----------------------------------------------------------------


def test_capability_by_config(tmp_path: Path) -> None:
    assert "threads.v1" in hello_for(make_config(presentation="single"), "e", "0.16.0").capabilities
    assert "threads.v1" not in hello_for(make_config(presentation="single", threads={"max": 0}), "e", "0.16.0").capabilities
    assert "threads.v1" not in hello_for(make_config(presentation="multiple"), "e", "0.16.0").capabilities
    path = tmp_path / "config.toml"
    path.write_text("[threads]\nmax = 1\n")
    assert load_config(path).threads.max == 1
    path.write_text("[threads]\nmax = 3\n")
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert "threads.max" in str(e.value)
    assert "threads" in e.value.keys


def test_thread_proposal_not_sent_to_old_app() -> None:
    msg = ThreadProposal(ts=TS, chat=3, proposal="p1", brief=BRIEF, state="pending")
    assert for_app(msg, frozenset()) is None
    assert for_app(msg, frozenset({"threads.v1"})) is msg


# --- Main detection in the server -----------------------------------------------


async def test_status_reports_main_and_threads(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    registry = seed(state_dir, folder)
    registry.get(4).title = "Acme pricing page"
    registry.persist()
    srv = await start_server(state_dir, factory, presentation="single")
    servers.append(srv)
    status = srv.status()
    assert status["session"] == 3
    assert status["threads"] == [{"label": "Thread 1", "title": "Acme pricing page", "state": "idle"}]
    line = describe(status, state_dir)
    assert "session 3 (idle" in line and line.endswith("; threads: Thread 1 (idle)")


async def test_status_without_threads_has_no_threads_key(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    seed(state_dir, folder, threads=0)
    srv = await start_server(state_dir, factory, presentation="single")
    servers.append(srv)
    assert srv.status()["session"] == 3 and "threads" not in srv.status()
    assert "; threads:" not in describe(srv.status(), state_dir)


async def test_chat_new_refusal_ignores_threads(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    seed(state_dir, folder)
    srv = await start_server(state_dir, factory, presentation="single")
    servers.append(srv)
    conn = await attach(srv)
    try:
        await conn.send(dump(ChatNew(ts=TS, id="req-1", folder=str(folder))))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "session.live"
        assert "session 3 is live" in err.message, "Main, not the newer thread"
    finally:
        await conn.close()


async def test_chat_new_starts_main_when_only_a_thread_is_live(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    seed(state_dir, folder, main_ended=True)
    srv = await start_server(state_dir, factory, presentation="single")
    servers.append(srv)
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
    finally:
        await conn.close()
    main = srv.registry.main()
    assert main is not None and main.number == number == 5
    assert srv.registry.get(4).ended is None, "the thread is untouched"


async def test_preview_next_number_ignores_threads(
    state_dir: StateDir, factory: EngineFactory, folder: Path, tmp_path: Path, servers: list[GatewayServer]
) -> None:
    seed(state_dir, folder, main_ended=True)
    ran = tmp_path / "ran"
    srv = await start_server(
        state_dir, factory, presentation="single", sessions={"next_number": f"touch {ran}; echo 40"}
    )
    servers.append(srv)
    assert ran.exists(), "only a thread is live: the welcome's number is asked"
    assert srv.chat_list().next_chat == 40


async def test_follow_default_folder_moves_main_not_a_thread(
    state_dir: StateDir, factory: EngineFactory, folder: Path, tmp_path: Path, servers: list[GatewayServer]
) -> None:
    registry = seed(state_dir, folder)
    registry.record_default_folder(str(folder.resolve()))
    new = tmp_path / "acme-two"
    new.mkdir()
    srv = await start_server(state_dir, factory, presentation="single", default_folder=str(new))
    servers.append(srv)
    assert srv.registry.get(3).ended is not None, "Main is the one ended"
    assert srv.registry.get(4).ended is None, "the newer thread is not"
    main = srv.registry.main()
    assert main is not None and main.number == 5 and main.parent == 3 and main.folder == new.resolve()
