"""v0.16: threads in the index, ``threads.v1``, Main detection, and (Task 2) opening, starting and closing threads.

A thread is a chat with a ``thread`` record (label, slot, parent, brief,
files, opened_at). Main is the newest live chat without one, everywhere the
gateway looks Main up: ``status()``, the ``chat.new`` refusal, the welcome's
number preview and following ``default_folder``. Proposals live in the
index until started, dismissed, or Main's session ends. Main's agent
proposes a thread with ``open_thread`` (called here through
``MainChatCallbacks.on_open_thread`` directly, as ``Show`` goes through
``on_show``); ``thread.start`` / ``thread.dismiss`` / ``thread.close``
start, dismiss and close them. Real ``websockets`` client, ``FakeEngine``
behind every chat: no model.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest
from websockets.asyncio.client import ClientConnection, connect

from portico_gateway.chats import ChatRegistry
from portico_gateway.config import ConfigError, hello_for, load_config
from portico_gateway.engine import OPEN_THREAD_TOOL_NAME, build_options, build_thread_hook, build_thread_tool
from portico_gateway.messages import (
    ChatList,
    ChatNew,
    ChatNotice,
    ChatOpen,
    ChatQueue,
    ChatQueued,
    ChatState,
    Error,
    HelloClient,
    HelloServer,
    MessageSend,
    ServerMessage,
    ServicesStatus,
    SessionLog,
    SessionMode,
    SessionRenew,
    SessionRenewed,
    ThreadClose,
    ThreadDismiss,
    ThreadInfo,
    ThreadProposal,
    ThreadStart,
    TurnFinished,
    dump,
    parse_server,
)
from portico_gateway.plugins import Plugins
from portico_gateway.server import GatewayServer, MainChatCallbacks, for_app, with_attachments
from portico_gateway.state import ProposalRecord, StateDir
from portico_gateway.status import describe
from portico_gateway.threads import MAIN_PROMPT, files_phrase, proposed_text, thread_prompt
from tests.conftest import Block, Pause, fake_result, make_config
from tests.test_server import attach, ws_url
from tests.test_sessions import start_server
from tests.test_turns import EngineFactory, new_chat, recv, recv_until

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
    assert srv.registry.get(4).parent == 3, "the newer thread is not followed as the live session"
    main = srv.registry.main()
    assert main is not None and main.number == 5 and main.parent == 3 and main.folder == new.resolve()


# --- Task 2: the tool, start, dismiss, close ----------------------------------------

LOG = "/log-it"


async def attach_threads(srv: GatewayServer) -> ClientConnection:
    """``attach`` for an app that lists ``threads.v1`` (and ``queue.v1``)."""
    conn = await connect(ws_url(srv, srv.token))
    await conn.send(dump(HelloClient(ts=TS, app_version="0.16.0", capabilities=["threads.v1", "queue.v1"])))
    assert isinstance(parse_server(await conn.recv()), HelloServer)
    assert isinstance(parse_server(await conn.recv()), ChatList)
    assert isinstance(parse_server(await conn.recv()), ServicesStatus)
    return conn


async def threads_server(state_dir: StateDir, factory: EngineFactory, servers: list[GatewayServer], **config: Any) -> GatewayServer:
    srv = await start_server(state_dir, factory, presentation="single", **config)
    servers.append(srv)
    return srv


async def propose(srv: GatewayServer, main: int, conn: ClientConnection, files: list[str] | None = None, use: str = "tu-1") -> tuple[str, ThreadProposal]:
    """Main's agent calls ``open_thread``; returns its answer and the ``thread.proposal`` the app got."""
    callbacks = srv.registry.get(main).engine.callbacks  # type: ignore[union-attr]
    assert isinstance(callbacks, MainChatCallbacks)
    callbacks.note_thread_use(use, {"brief": BRIEF, "files": list(files or [])})
    answer = await callbacks.on_open_thread(BRIEF, list(files or []))
    frame = (await recv_until(conn, ThreadProposal))[-1]
    assert isinstance(frame, ThreadProposal)
    return answer, frame


async def start_thread(conn: ClientConnection, main: int, proposal: str, id: str = "req-s", close: int | None = None) -> list[ServerMessage]:
    """``thread.start`` and everything up to the thread's first turn finishing."""
    await conn.send(dump(ThreadStart(ts=TS, id=id, chat=main, proposal=proposal, close=close)))
    got = await recv_until(conn, ThreadProposal, timeout=10)
    got += await recv_until(conn, TurnFinished)
    got.append(await recv(conn))  # the thread's chat.state idle
    return got


def thread_notices(frames: list[ServerMessage], chat: int) -> list[str]:
    return [m.text for m in frames if isinstance(m, ChatNotice) and m.chat == chat]


def test_proposed_text_and_files_phrase() -> None:
    assert proposed_text(1) == "Proposed as Thread 1; it opens if the person starts it."
    assert proposed_text(None) == "Proposed; two threads are open, so the person picks one to close before it starts."
    assert files_phrase([]) == ""
    assert files_phrase(["/x/a.html", "b.md"]) == "a.html and b.md"
    assert files_phrase(["a", "b", "/y/c.md"]) == "a, b and c.md"
    assert thread_prompt(2) == (
        "This is Thread 2, opened from the person's main conversation for the brief below. "
        "Work on it here; the person answers here."
    )


async def test_the_tool_answers_and_refuses() -> None:
    class Owner:
        def __init__(self) -> None:
            self.calls: list[tuple[str, list[str]]] = []

        async def on_open_thread(self, brief: str, files: list[str]) -> str:
            self.calls.append((brief, files))
            return "Not proposed: gone.md isn't a file." if "gone.md" in files else proposed_text(1)

    owner = Owner()
    tool = build_thread_tool(owner)
    ok = await tool.handler({"brief": BRIEF, "files": ["pricing.html"]})
    assert ok == {"content": [{"type": "text", "text": proposed_text(1)}]}
    refused = await tool.handler({"brief": BRIEF, "files": ["gone.md"]})
    assert refused["is_error"] is True
    empty = await tool.handler({"brief": "  "})
    assert empty == {
        "content": [{"type": "text", "text": "Not proposed: give a brief of one or two sentences."}],
        "is_error": True,
    }
    assert owner.calls == [(BRIEF, ["pricing.html"]), (BRIEF, ["gone.md"])], "an empty brief never reaches the owner"


async def test_only_main_gets_the_tool(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await threads_server(state_dir, factory, servers)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        engine = factory.last
        options = build_options(folder, None, [], engine.callbacks, system_prompt=engine.system_prompt)  # type: ignore[arg-type]
        assert OPEN_THREAD_TOOL_NAME in (options.allowed_tools or [])
        assert MAIN_PROMPT in options.system_prompt["append"]  # type: ignore[index]
        _, frame = await propose(srv, main, conn)
        await start_thread(conn, main, frame.proposal)
        thread = factory.last
        assert thread is not engine
        options = build_options(folder, None, [], thread.callbacks, system_prompt=thread.system_prompt)  # type: ignore[arg-type]
        assert OPEN_THREAD_TOOL_NAME not in (options.allowed_tools or [])
        append = options.system_prompt["append"]  # type: ignore[index]
        assert MAIN_PROMPT not in append and thread_prompt(1) in append
    finally:
        await conn.close()


async def test_no_tool_with_max_zero(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await threads_server(state_dir, factory, servers, threads={"max": 0})
    conn = await attach(srv)
    try:
        await new_chat(conn, folder)
        engine = factory.last
        assert not isinstance(engine.callbacks, MainChatCallbacks)
        options = build_options(folder, None, [], engine.callbacks, system_prompt=engine.system_prompt)  # type: ignore[arg-type]
        assert OPEN_THREAD_TOOL_NAME not in (options.allowed_tools or [])
        assert MAIN_PROMPT not in options.system_prompt["append"]  # type: ignore[index]
    finally:
        await conn.close()


async def test_open_thread_stores_and_shows(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    (folder / "pricing.html").write_text("<p>Acme</p>")
    srv = await threads_server(state_dir, factory, servers)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        answer, frame = await propose(srv, main, conn, ["pricing.html"])
        assert answer == "Proposed as Thread 1; it opens if the person starts it."
        [record] = srv.registry.proposals_for(main)
        assert record.tool_use_id == "tu-1" and record.state == "pending" and record.brief == BRIEF
        assert record.files == [str(folder / "pricing.html")]
        assert frame.proposal == record.id and frame.tool_use_id == "tu-1" and frame.state == "pending"
        assert frame.chat == main and frame.files == record.files
        assert registry_on(state_dir).proposal(record.id).state == "pending", "stored in the index"

        callbacks = srv.registry.get(main).engine.callbacks  # type: ignore[union-attr]
        assert await callbacks.on_open_thread(BRIEF, ["missing.html"]) == "Not proposed: missing.html isn't a file."
        assert await callbacks.on_open_thread(BRIEF, [str(folder)]) == f"Not proposed: {folder} isn't a file."
        assert await callbacks.on_open_thread(" ", []) == "Not proposed: give a brief of one or two sentences."
        assert len(srv.registry.proposals_for(main)) == 1, "a refusal stores nothing"
    finally:
        await conn.close()


async def test_start_opens_a_thread(
    state_dir: StateDir, factory: EngineFactory, folder: Path, tmp_path: Path, servers: list[GatewayServer]
) -> None:
    (folder / "pricing.html").write_text("<p>Acme</p>")
    counter = tmp_path / "next"
    counter.write_text("3")
    srv = await threads_server(state_dir, factory, servers, sessions={"next_number": f"cat {counter}"})
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        assert main == 3
        await conn.send(dump(SessionMode(ts=TS, id="req-m", chat=main, mode="acceptEdits")))
        assert isinstance(await recv(conn), ChatState)
        _, frame = await propose(srv, main, conn, ["pricing.html"])
        counter.write_text("14")
        got = await start_thread(conn, main, frame.proposal, id="req-s")
        state, listing, started = got[0], got[1], got[2]
        assert isinstance(state, ChatState) and state.state == "idle" and state.id == "req-s" and state.chat == 14
        assert isinstance(listing, ChatList) and 14 in [c.chat for c in listing.chats]
        assert isinstance(started, ThreadProposal) and started.state == "started" and started.thread == 14
        thread = srv.registry.get(14)
        assert thread.thread is not None
        assert thread.thread.label == "Thread 1" and thread.thread.slot == 1 and thread.thread.parent == main
        assert thread.thread.brief == BRIEF and thread.thread.files == [str(folder / "pricing.html")]
        assert thread.folder == srv.registry.get(main).folder and thread.mode == "acceptEdits"
        engine = factory.last
        assert engine.started_mode == "acceptEdits"
        sends = [arg for call, arg in engine.calls if call == "send"]
        assert sends[0] == with_attachments(BRIEF, [str(folder / "pricing.html")])
        assert srv.registry.proposal(frame.proposal).state == "started"
        assert srv.registry.proposal(frame.proposal).thread == 14
        assert srv.registry.main() is srv.registry.get(main), "starting a thread never changes Main"
        assert [m.turn for m in got if isinstance(m, TurnFinished) and m.chat == 14] == [1]
    finally:
        await conn.close()


async def test_start_twice(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await threads_server(state_dir, factory, servers)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        _, frame = await propose(srv, main, conn)
        # A double click: both go before either is answered.
        await conn.send(dump(ThreadStart(ts=TS, id="req-1", chat=main, proposal=frame.proposal)))
        await conn.send(dump(ThreadStart(ts=TS, id="req-2", chat=main, proposal=frame.proposal)))
        got = await recv_until(conn, TurnFinished)
        errors = [m for m in got if isinstance(m, Error)]
        assert [(e.code, e.id) for e in errors] == [("thread.proposal_resolved", "req-2")]
        await recv(conn)  # idle
        # And again once it has started (Start after a restart re-sent the card).
        await conn.send(dump(ThreadStart(ts=TS, id="req-3", chat=main, proposal=frame.proposal)))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "thread.proposal_resolved" and err.id == "req-3"
        assert len(srv.registry.open_threads()) == 1
        await conn.send(dump(ThreadStart(ts=TS, id="req-4", chat=main, proposal="p-nope")))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "thread.proposal_unknown" and err.id == "req-4"
    finally:
        await conn.close()


async def test_dismiss(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await threads_server(state_dir, factory, servers)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        _, frame = await propose(srv, main, conn)
        await conn.send(dump(ThreadDismiss(ts=TS, id="req-d", chat=main, proposal=frame.proposal)))
        dismissed = await recv(conn)
        assert isinstance(dismissed, ThreadProposal) and dismissed.state == "dismissed" and dismissed.id == "req-d"
        assert registry_on(state_dir).proposal(frame.proposal).state == "dismissed", "persisted"
        await conn.send(dump(ThreadStart(ts=TS, id="req-s", chat=main, proposal=frame.proposal)))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "thread.proposal_resolved" and err.id == "req-s"
        assert srv.registry.open_threads() == []
    finally:
        await conn.close()


async def test_limit(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await threads_server(state_dir, factory, servers, log_prompt=LOG)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        for n in (1, 2):
            _, frame = await propose(srv, main, conn, use=f"tu-{n}")
            await start_thread(conn, main, frame.proposal, id=f"req-{n}")
        first, second = srv.registry.open_threads()
        answer, frame = await propose(srv, main, conn, use="tu-3")
        assert answer == "Proposed; two threads are open, so the person picks one to close before it starts."
        await conn.send(dump(ThreadStart(ts=TS, id="req-3", chat=main, proposal=frame.proposal)))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "thread.limit" and err.id == "req-3"
        assert err.message == "two threads are open; close one to start another"
        await conn.send(dump(ThreadStart(ts=TS, id="req-4", chat=main, proposal=frame.proposal, close=main)))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "thread.not_open" and err.id == "req-4"

        await conn.send(dump(ThreadStart(ts=TS, id="req-5", chat=main, proposal=frame.proposal, close=first.number)))
        got = await recv_until(conn, ThreadProposal, timeout=10)
        assert thread_notices(got, first.number) == ["Close — logging, then closing this thread", "Thread closed"]
        assert first.ended is not None and first.logged is True
        assert ("send", LOG) in factory.engines[1].calls, "Thread 1's own engine ran the log step"
        new = srv.registry.get(got[-1].thread)  # type: ignore[attr-defined]
        assert new.thread is not None and new.thread.slot == 1 and new.thread.label == "Thread 1"
        assert [t.number for t in srv.registry.open_threads()] == [new.number, second.number]
        await recv_until(conn, TurnFinished)
    finally:
        await conn.close()


async def test_close_and_start_when_the_log_step_cannot_start(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    async def on_renew(ctx: Any, chat: Any) -> bool:
        return await ctx.send("log this thread") == "done"

    plugins = Plugins.none()
    plugins.renew = on_renew
    srv = await start_server(state_dir, factory, plugins=plugins, presentation="single")
    servers.append(srv)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        for n in (1, 2):
            _, frame = await propose(srv, main, conn, use=f"tu-{n}")
            await start_thread(conn, main, frame.proposal, id=f"req-{n}")
        first, _ = srv.registry.open_threads()
        engine = first.engine
        assert engine is not None
        real_send = engine.send

        async def refuse(text: str) -> None:
            raise RuntimeError("the engine is gone")

        engine.send = refuse  # type: ignore[method-assign]
        _, frame = await propose(srv, main, conn, use="tu-3")
        await conn.send(dump(ThreadStart(ts=TS, id="req-3", chat=main, proposal=frame.proposal, close=first.number)))
        got = await recv_until(conn, Error, timeout=10)
        assert got[-1].code == "engine.send_failed" and got[-1].id == "req-3"  # type: ignore[attr-defined]
        assert first.ended is None, "Thread 1 stays open"
        assert len(srv.registry.open_threads()) == 2, "nothing new started"
        assert srv.registry.proposal(frame.proposal).state == "pending"
        assert not any(isinstance(m, ThreadProposal) for m in got)

        # The limit card is usable again.
        engine.send = real_send  # type: ignore[method-assign]
        await conn.send(dump(ThreadStart(ts=TS, id="req-4", chat=main, proposal=frame.proposal, close=first.number)))
        got = await recv_until(conn, ThreadProposal, timeout=10)
        assert got[-1].state == "started" and first.ended is not None  # type: ignore[attr-defined]
    finally:
        await conn.close()


async def test_close_runs_the_log_step(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await threads_server(state_dir, factory, servers, log_prompt=LOG)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        _, frame = await propose(srv, main, conn)
        await start_thread(conn, main, frame.proposal)
        [thread] = srv.registry.open_threads()
        await conn.send(dump(ThreadClose(ts=TS, id="req-c", chat=thread.number)))
        got = await recv_until(conn, ChatList, timeout=10)
        assert thread_notices(got, thread.number) == ["Close — logging, then closing this thread", "Thread closed"]
        state, closed = got[-3], got[-2]
        assert isinstance(state, ChatState) and state.state == "stopped" and state.id == "req-c"
        assert isinstance(closed, ChatNotice) and closed.text == "Thread closed", "chat.state, then the notice"
        assert thread.ended is not None and thread.logged is True
        assert srv.registry.free_slot(2) == 1 and srv.registry.open_threads() == []
        assert ("send", LOG) in factory.last.calls
        await conn.send(dump(ThreadClose(ts=TS, id="req-again", chat=thread.number)))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "thread.not_open" and err.id == "req-again"
        await conn.send(dump(ThreadClose(ts=TS, id="req-main", chat=main)))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "thread.not_open"
    finally:
        await conn.close()


async def test_close_without_a_log_step(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await threads_server(state_dir, factory, servers)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        _, frame = await propose(srv, main, conn)
        await start_thread(conn, main, frame.proposal)
        [thread] = srv.registry.open_threads()
        await conn.send(dump(ThreadClose(ts=TS, id="req-c", chat=thread.number)))
        got = await recv_until(conn, ChatList)
        assert thread_notices(got, thread.number) == ["Close — closing this thread", "Thread closed"]
        assert thread.ended is not None and thread.logged is None
    finally:
        await conn.close()


async def test_close_a_working_thread(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await threads_server(state_dir, factory, servers, log_prompt=LOG)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        _, frame = await propose(srv, main, conn)
        await start_thread(conn, main, frame.proposal)
        [thread] = srv.registry.open_threads()
        engine = factory.last
        engine.script(Block())
        await conn.send(dump(MessageSend(ts=TS, id="req-w", chat=thread.number, text="keep going")))
        await engine.wait_blocked()
        await conn.send(dump(ThreadClose(ts=TS, id="req-c", chat=thread.number)))
        got = await recv_until(conn, ChatList, timeout=10)
        kinds = [
            ("finished", m.turn, m.outcome) if isinstance(m, TurnFinished) else ("notice", m.text)
            for m in got
            if isinstance(m, (TurnFinished, ChatNotice))
        ]
        assert kinds == [
            ("finished", 2, "stopped"),
            ("notice", "Close — logging, then closing this thread"),
            ("finished", 3, "done"),
            ("notice", "Thread closed"),
        ]
        assert thread.ended is not None and thread.logged is True and engine.closed
    finally:
        await conn.close()


async def test_new_leaves_threads_and_dismisses_proposals(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await threads_server(state_dir, factory, servers)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        _, frame = await propose(srv, main, conn, use="tu-1")
        await start_thread(conn, main, frame.proposal)
        [thread] = srv.registry.open_threads()
        engine = factory.last
        engine.script(Block())
        await conn.send(dump(MessageSend(ts=TS, id="req-w", chat=thread.number, text="keep going")))
        await engine.wait_blocked()
        _, pending = await propose(srv, main, conn, use="tu-2")

        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=main, log=False)))
        got = await recv_until(conn, SessionRenewed)
        dismissed = [m for m in got if isinstance(m, ThreadProposal)]
        assert [(m.proposal, m.state) for m in dismissed] == [(pending.proposal, "dismissed")]
        assert srv.registry.proposal(pending.proposal).state == "dismissed"
        assert srv.registry.proposal(frame.proposal).state == "started", "a started one stays started"
        assert thread.ended is None and thread.number in srv._runs, "the thread keeps working"
        following = srv.registry.main()
        assert following is not None and following.number == got[-1].next.chat  # type: ignore[attr-defined]
        await recv(conn)  # chat.list
        await conn.send(dump(ThreadStart(ts=TS, id="req-s", chat=main, proposal=pending.proposal)))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "thread.proposal_resolved"
        await engine.interrupt()
    finally:
        await conn.close()


async def test_renew_refused_on_a_thread(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await threads_server(state_dir, factory, servers)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        _, frame = await propose(srv, main, conn)
        await start_thread(conn, main, frame.proposal)
        [thread] = srv.registry.open_threads()
        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=thread.number)))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "thread.renew" and err.id == "req-r"
        assert err.message == "a thread closes rather than renews; close it with thread.close"
        assert thread.ended is None
    finally:
        await conn.close()


async def test_start_refused_with_threads_off(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await threads_server(state_dir, factory, servers, threads={"max": 0})
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        await conn.send(dump(ThreadStart(ts=TS, id="req-s", chat=main, proposal="p-1")))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "threads.off" and err.id == "req-s"
    finally:
        await conn.close()


async def test_threads_survive_a_restart(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await start_server(state_dir, factory, presentation="single")
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        _, frame = await propose(srv, main, conn)
        await start_thread(conn, main, frame.proposal)
        [thread] = srv.registry.open_threads()
    finally:
        await conn.close()
        await srv.shutdown()

    again = await threads_server(state_dir, factory, servers)
    restored = again.registry.get(thread.number)
    assert restored.thread == thread.thread and restored.ended is None
    conn = await attach_threads(again)
    try:
        await conn.send(dump(MessageSend(ts=TS, id="req-m", chat=thread.number, text="carry on")))
        await recv_until(conn, TurnFinished)
        assert thread_prompt(1) in factory.last.system_prompt["append"]
        assert not isinstance(factory.last.callbacks, MainChatCallbacks)
        await recv(conn)  # idle
        await conn.send(dump(ChatOpen(ts=TS, id="req-o", chat=main)))
        got = await recv_until(conn, ThreadProposal)
        assert isinstance(got[-2], ChatQueue), "after the queue, the chat's proposals"
        assert got[-1].proposal == frame.proposal and got[-1].state == "started"  # type: ignore[attr-defined]
        assert got[-1].thread == thread.number  # type: ignore[attr-defined]
    finally:
        await conn.close()


async def test_folder_change_closes_threads(
    state_dir: StateDir, factory: EngineFactory, folder: Path, tmp_path: Path, servers: list[GatewayServer]
) -> None:
    registry = seed(state_dir, folder)
    registry.add_proposal(proposal("p1"))
    registry.record_default_folder(str(folder.resolve()))
    new = tmp_path / "acme-two"
    new.mkdir()
    srv = await threads_server(state_dir, factory, servers, default_folder=str(new), log_prompt=LOG)
    assert srv.startup_closes is not None
    await srv.startup_closes
    thread = srv.registry.get(4)
    assert thread.ended is not None and thread.logged is True, "closed with its log step"
    assert [("send", LOG)] == [c for c in factory.last.calls if c[0] == "send"]
    assert [m.text for m in thread.ring if isinstance(m, ChatNotice)] == [
        "Close — logging, then closing this thread",
        "Thread closed",
    ]
    assert srv.registry.proposal("p1").state == "dismissed", "Main's session ended"
    main = srv.registry.main()
    assert main is not None and main.number == 5 and main.folder == new.resolve()


async def test_no_closes_at_start_without_cause(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    seed(state_dir, folder).record_default_folder(str(folder.resolve()))
    srv = await threads_server(state_dir, factory, servers, default_folder=str(folder))
    assert srv.startup_closes is None
    assert srv.registry.get(4).ended is None


async def test_max_zero_closes_open_threads(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    seed(state_dir, folder)
    srv = await threads_server(state_dir, factory, servers, threads={"max": 0}, log_prompt=LOG)
    assert srv.startup_closes is not None
    await srv.startup_closes
    assert srv.registry.get(4).ended is not None and srv.registry.get(4).logged is True
    conn = await attach(srv)
    try:
        await conn.send(dump(MessageSend(ts=TS, id="req-m", chat=3, text="hello")))
        await recv_until(conn, TurnFinished)
        engine = factory.last
        assert not isinstance(engine.callbacks, MainChatCallbacks), "no tool for Main"
        assert MAIN_PROMPT not in engine.system_prompt.get("append", "")
    finally:
        await conn.close()


def test_a_thread_slot_is_1_or_2() -> None:
    from pydantic import ValidationError

    for slot in (0, 3):
        with pytest.raises(ValidationError):
            ThreadInfo(label="Thread 3", slot=slot, parent=1, brief=BRIEF, opened_at=TS)


# --- Task 2, fix round 1 ------------------------------------------------------------


def refusing_plugins() -> Plugins:
    async def on_renew(ctx: Any, chat: Any) -> bool:
        return await ctx.send("log this") == "done"

    plugins = Plugins.none()
    plugins.renew = on_renew
    return plugins


def refuse_once(engine: Any) -> None:
    """The engine's next ``send`` is refused (the log step cannot start); later ones go through."""
    real = engine.send

    async def refuse(text: str) -> None:
        engine.send = real
        raise RuntimeError("the engine is gone")

    engine.send = refuse


async def test_thread_use_ids_match_by_input(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await threads_server(state_dir, factory, servers)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        callbacks = factory.last.callbacks
        tool, hook = build_thread_tool(callbacks), build_thread_hook(callbacks)

        async def call(use: str, args: dict[str, Any]) -> dict[str, Any]:
            await hook({"tool_name": OPEN_THREAD_TOOL_NAME, "tool_input": args, "tool_use_id": use}, use, None)
            return await tool.handler(args)

        assert (await call("tu-empty", {"brief": " "}))["is_error"] is True
        await call("tu-ok", {"brief": BRIEF})
        # Side by side: both hooks before either handler, answered in the other order.
        await hook({"tool_input": {"brief": "Draft A"}, "tool_use_id": "tu-a"}, "tu-a", None)
        await hook({"tool_input": {"brief": "Draft B", "files": []}, "tool_use_id": "tu-b"}, "tu-b", None)
        await tool.handler({"brief": "Draft B", "files": []})
        await tool.handler({"brief": "Draft A"})
        uses = {p.brief: p.tool_use_id for p in srv.registry.proposals_for(main)}
        assert uses == {BRIEF: "tu-ok", "Draft B": "tu-b", "Draft A": "tu-a"}
    finally:
        await conn.close()


async def test_new_during_a_close_and_start_starts_nothing(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await threads_server(state_dir, factory, servers, log_prompt=LOG)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        for n in (1, 2):
            _, frame = await propose(srv, main, conn, use=f"tu-{n}")
            await start_thread(conn, main, frame.proposal, id=f"req-{n}")
        first, second = srv.registry.open_threads()
        _, frame = await propose(srv, main, conn, use="tu-3")
        pause = Pause()
        first.engine.script(pause, fake_result())  # type: ignore[union-attr]
        await conn.send(dump(ThreadStart(ts=TS, id="req-3", chat=main, proposal=frame.proposal, close=first.number)))
        await asyncio.wait_for(pause.reached.wait(), 5)
        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=main, log=False)))
        await recv_until(conn, SessionRenewed)
        pause.go.set()
        got = await recv_until(conn, Error, timeout=10)
        assert got[-1].code == "thread.proposal_resolved" and got[-1].id == "req-3"  # type: ignore[attr-defined]
        assert first.ended is not None, "the close itself went through"
        assert srv.registry.open_threads() == [second], "no thread was created"
        assert srv.registry.proposal(frame.proposal).state == "dismissed", "the card reads Not started"
        assert not any(isinstance(m, ThreadProposal) and m.state == "started" for m in got)
    finally:
        await conn.close()


async def test_close_and_start_refused_while_the_thread_logs(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await threads_server(state_dir, factory, servers, log_prompt=LOG)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        for n in (1, 2):
            _, frame = await propose(srv, main, conn, use=f"tu-{n}")
            await start_thread(conn, main, frame.proposal, id=f"req-{n}")
        first, _ = srv.registry.open_threads()
        engine = first.engine
        engine.script(Block())  # type: ignore[union-attr]
        await conn.send(dump(SessionLog(ts=TS, id="req-l", chat=first.number)))
        await engine.wait_blocked()  # type: ignore[union-attr]
        _, frame = await propose(srv, main, conn, use="tu-3")
        await conn.send(dump(ThreadStart(ts=TS, id="req-3", chat=main, proposal=frame.proposal, close=first.number)))
        err = (await recv_until(conn, Error))[-1]
        assert err.code == "chat.busy" and err.id == "req-3"  # type: ignore[attr-defined]
        await conn.send(dump(ThreadClose(ts=TS, id="req-c", chat=first.number)))
        err = (await recv_until(conn, Error))[-1]
        assert err.code == "chat.busy" and err.id == "req-c"  # type: ignore[attr-defined]
        assert first.ended is None and srv.registry.proposal(frame.proposal).state == "pending"
        await engine.interrupt()  # type: ignore[union-attr]
    finally:
        await conn.close()


async def test_new_with_a_refusing_plugin_renews_unlogged_as_before(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    srv = await start_server(state_dir, factory, plugins=refusing_plugins(), presentation="single")
    servers.append(srv)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        refuse_once(factory.last)
        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=main)))
        got = await recv_until(conn, SessionRenewed, timeout=10)
        assert not any(isinstance(m, Error) for m in got)
        assert got[-1].ended.logged is False  # type: ignore[attr-defined]
    finally:
        await conn.close()


async def test_close_with_a_refusing_plugin_stays_open_then_closes_without_logging(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    gate = asyncio.Event()

    async def on_renew(ctx: Any, chat: Any) -> bool:
        await gate.wait()
        return await ctx.send("log this") == "done"

    plugins = Plugins.none()
    plugins.renew = on_renew
    srv = await start_server(state_dir, factory, plugins=plugins, presentation="single")
    servers.append(srv)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        _, frame = await propose(srv, main, conn)
        await start_thread(conn, main, frame.proposal)
        [thread] = srv.registry.open_threads()
        engine = factory.last
        refuse_once(engine)
        await conn.send(dump(ThreadClose(ts=TS, id="req-c", chat=thread.number)))
        await recv_until(conn, ChatNotice)  # "Close — logging, then closing this thread"
        await conn.send(dump(MessageSend(ts=TS, id="req-held", chat=thread.number, text="held for later")))
        assert isinstance((await recv_until(conn, ChatQueued))[-1], ChatQueued)
        gate.set()
        got = await recv_until(conn, Error, timeout=10)
        assert got[-1].code == "engine.send_failed" and got[-1].id == "req-c"  # type: ignore[attr-defined]
        assert thread.ended is None, "the thread stays open"
        await recv_until(conn, TurnFinished)  # the held message went as the next turn
        assert ("send", "held for later") in engine.calls
        await recv(conn)  # idle

        await conn.send(dump(ThreadClose(ts=TS, id="req-c2", chat=thread.number, log=False)))
        got = await recv_until(conn, ChatList, timeout=10)
        assert thread_notices(got, thread.number)[-2:] == ["Close — closing this thread", "Thread closed"]
        assert thread.ended is not None and thread.logged is False
        assert ("send", "log this") not in engine.calls
    finally:
        await conn.close()


async def test_a_brief_that_cannot_go_is_said_in_the_thread(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]
) -> None:
    gone = folder / "pricing.html"
    gone.write_text("<p>Acme</p>")
    srv = await threads_server(state_dir, factory, servers)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        _, frame = await propose(srv, main, conn, ["pricing.html"])
        gone.unlink()
        await conn.send(dump(ThreadStart(ts=TS, id="req-s", chat=main, proposal=frame.proposal)))
        got = await recv_until(conn, ChatNotice)
        [thread] = srv.registry.open_threads()
        assert got[-1].chat == thread.number  # type: ignore[attr-defined]
        assert got[-1].text == f"The brief wasn't sent: attachment does not exist: {gone}"  # type: ignore[attr-defined]
        assert [type(m) for m in got] == [ChatState, ChatList, ThreadProposal, ChatNotice]
        assert got[0].id == "req-s", "the request is answered once, by chat.state"  # type: ignore[attr-defined]
    finally:
        await conn.close()
