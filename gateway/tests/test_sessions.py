"""v0.2: sessions — the record's session facts, titles, ``session.renew``, single presentation.

A session is a chat (v0.1's numbered conversation). Renewing ends one and
opens the next number in the same folder with ``parent`` set; with a log
step the ending session first runs it as an ordinary turn. Real
``websockets`` client, ``FakeEngine`` behind every chat: no model.
"""

from __future__ import annotations

import asyncio
import json
import sys
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection

from portico_gateway import REPO_ROOT, __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import Config
from portico_gateway.messages import (
    CardAnswer,
    CardAsk,
    ChatList,
    ChatNew,
    ChatState,
    Error,
    HelloServer,
    MessageSend,
    SessionLog,
    SessionLogged,
    SessionRenew,
    SessionRenewed,
    ServerMessage,
    TurnFinished,
    TurnStarted,
    TurnStop,
    UserText,
    dump,
)
from portico_gateway.plugins import Plugins, load_plugins
from portico_gateway.server import GatewayServer
from portico_gateway.state import ChatRecord, StateDir
from tests.conftest import AskPermission, Block, fake_result, make_config
from tests.test_server import attach
from tests.test_turns import EngineFactory, new_chat, recv, recv_until

TS = "2026-10-28T12:00:00Z"

# A v0.1 index.json exactly as v0.1 wrote it: no session facts at all.
V01_INDEX = {
    "chats": [
        {
            "chat": 3,
            "folder": "/Users/someone/projects/demo",
            "session_id": "sess-3",
            "alias": "notes",
            "state": "idle",
            "created": "2026-10-27T12:00:00Z",
            "artifacts": [],
        }
    ],
    "next_chat": 4,
}


# --- fixtures -----------------------------------------------------------------


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = tmp_path / "demo"
    path.mkdir()
    return path


async def start_server(
    state_dir: StateDir, factory: EngineFactory, plugins: Plugins | None = None, **config: object
) -> GatewayServer:
    cfg: Config = make_config(**config)
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=cfg.history_buffer)
    srv = GatewayServer(
        config=cfg, state=state_dir, registry=registry, engine_factory=factory, version=__version__, plugins=plugins
    )
    await srv.serve(0)
    return srv


@pytest.fixture
async def server(state_dir: StateDir, factory: EngineFactory) -> AsyncIterator[GatewayServer]:
    srv = await start_server(state_dir, factory)
    try:
        yield srv
    finally:
        await srv.shutdown()


@pytest.fixture
async def logging_server(state_dir: StateDir, factory: EngineFactory) -> AsyncIterator[GatewayServer]:
    srv = await start_server(state_dir, factory, presentation="single", log_prompt="/session-close")
    try:
        yield srv
    finally:
        await srv.shutdown()


async def send_and_finish(conn: ClientConnection, chat: int, text: str) -> list[ServerMessage]:
    await conn.send(dump(MessageSend(ts=TS, chat=chat, text=text)))
    got = await recv_until(conn, TurnFinished)
    got.append(await recv(conn))  # chat.state idle
    return got


async def drain(conn: ClientConnection, timeout: float = 0.3) -> list[ServerMessage]:
    """Whatever arrives within ``timeout``."""
    got: list[ServerMessage] = []
    try:
        while True:
            got.append(await recv(conn, timeout))
    except TimeoutError:
        return got


# --- the record ---------------------------------------------------------------


def test_a_v01_index_loads_with_session_defaults(state_dir: StateDir) -> None:
    state_dir.index_path.write_text(json.dumps(V01_INDEX))
    index = state_dir.load_index()
    record = index.chats[0]
    assert record.title is None and record.ended is None and record.logged is None and record.parent is None
    assert record.compactions == 0 and record.context_percent is None
    registry = ChatRegistry(index=index, state=state_dir, history_buffer=10)
    summary = registry.summaries()[0]
    assert summary.chat == 3 and summary.alias == "notes" and summary.title is None and summary.compactions == 0


def test_session_facts_round_trip_through_the_index(state_dir: StateDir) -> None:
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=10)
    chat = registry.create(Path("/tmp"))
    chat.title = "Interview codebook"
    chat.ended = TS
    chat.logged = True
    chat.parent = 7
    chat.compactions = 2
    chat.context_percent = 71.5
    registry.persist()
    again = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=10)
    summary = again.summaries()[0]
    assert (summary.title, summary.ended, summary.logged, summary.parent, summary.compactions, summary.context_percent) == (
        "Interview codebook", TS, True, 7, 2, 71.5,
    )
    assert isinstance(state_dir.load_index().chats[0], ChatRecord)


# --- titles -------------------------------------------------------------------


async def test_title_is_the_first_line_of_the_first_message(server: GatewayServer, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        long_line = "Plan the interview codebook for the Q3 research synthesis, with themes and quotes"
        await send_and_finish(conn, number, f"  \n{long_line}\nmore detail here")
        chat = server.registry.get(number)
        assert chat.title == "Plan the interview codebook for the Q3 research synthesis…"
        assert server.registry.summaries()[0].title == "Plan the interview codebook for the Q3 research synthesis…"

        await send_and_finish(conn, number, "second message")
        assert chat.title == "Plan the interview codebook for the Q3 research synthesis…", "only the first message names the session"
    finally:
        await conn.close()


# --- session.renew --------------------------------------------------------------


async def test_renew_without_a_log_step_ends_and_opens_the_next(server: GatewayServer, factory: EngineFactory, folder: Path, state_dir: StateDir) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await send_and_finish(conn, number, "hello there")
        engine = factory.last

        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=number, log=True)))
        got = await recv_until(conn, SessionRenewed)
        renewed = got[-1]
        assert isinstance(renewed, SessionRenewed)
        assert renewed.id == "req-r"
        assert renewed.ended.chat == number and renewed.ended.ended is not None
        assert renewed.ended.logged is None, "no log step ran"
        assert renewed.ended.state == "stopped"
        assert renewed.next.chat == number + 1 and renewed.next.parent == number
        assert renewed.next.folder == str(folder) and renewed.next.ended is None
        states = [(m.chat, m.state) for m in got if isinstance(m, ChatState)]
        assert (number, "stopped") in states and (number + 1, "idle") in states
        assert not [m for m in got if isinstance(m, TurnStarted)], "no log turn without a log step"

        listing = await recv(conn)
        assert isinstance(listing, ChatList), "chat.list follows session.renewed"
        assert [c.chat for c in listing.chats] == [number, number + 1]
        assert engine.closed

        records = {r.chat: r for r in state_dir.load_index().chats}
        assert records[number].ended and records[number].state == "stopped"
        assert records[number + 1].parent == number
    finally:
        await conn.close()


async def test_renew_with_log_prompt_runs_it_as_a_turn_and_marks_logged(logging_server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(logging_server)
    try:
        number = await new_chat(conn, folder)
        await send_and_finish(conn, number, "work")
        engine = factory.last

        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=number)))
        got = await recv_until(conn, SessionRenewed)
        texts = [m.text for m in got if isinstance(m, UserText)]
        assert texts == ["/session-close"]
        assert ("send", "/session-close") in engine.calls
        finished = [m for m in got if isinstance(m, TurnFinished)]
        assert [f.outcome for f in finished] == ["done"]
        renewed = got[-1]
        assert isinstance(renewed, SessionRenewed)
        assert renewed.ended.logged is True
        # The log turn's message never becomes a title.
        assert renewed.ended.title == "work"
        assert isinstance(await recv(conn), ChatList)
    finally:
        await conn.close()


async def test_renew_with_log_false_skips_the_log_step(logging_server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(logging_server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=number, log=False)))
        got = await recv_until(conn, SessionRenewed)
        assert not [m for m in got if isinstance(m, TurnStarted)]
        assert got[-1].ended.logged is None  # type: ignore[union-attr]
        assert ("send", "/session-close") not in factory.last.calls
    finally:
        await conn.close()


async def test_a_log_turn_that_errors_is_not_logged(logging_server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(logging_server)
    try:
        number = await new_chat(conn, folder)
        factory.last.script(fake_result(is_error=True))
        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=number)))
        got = await recv_until(conn, SessionRenewed)
        assert [m.outcome for m in got if isinstance(m, TurnFinished)] == ["error"]
        renewed = got[-1]
        assert isinstance(renewed, SessionRenewed)
        assert renewed.ended.logged is False
        assert renewed.next.chat == number + 1, "the renewal still happens"
    finally:
        await conn.close()


async def test_a_card_during_the_log_turn_reaches_the_app_and_can_be_answered(
    logging_server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach(logging_server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        engine.script(AskPermission(tool="Write", input={"file_path": str(folder / "log.md")}), fake_result())
        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=number)))
        got = await recv_until(conn, CardAsk)
        card = got[-1]
        assert isinstance(card, CardAsk)
        await conn.send(dump(CardAnswer(ts=TS, chat=number, id=card.id, answer={"decision": "allow"}, scope="once")))
        got = await recv_until(conn, SessionRenewed)
        assert got[-1].ended.logged is True  # type: ignore[union-attr]
        assert engine.decisions == ["allow"]
    finally:
        await conn.close()


async def test_stopping_the_log_turn_still_renews_unlogged(logging_server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(logging_server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        engine.script(Block())
        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=number)))
        await engine.wait_blocked()
        await conn.send(dump(TurnStop(ts=TS, chat=number)))
        got = await recv_until(conn, SessionRenewed)
        assert [m.outcome for m in got if isinstance(m, TurnFinished)] == ["stopped"]
        assert got[-1].ended.logged is False  # type: ignore[union-attr]
    finally:
        await conn.close()


async def test_renew_errors(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        await conn.send(dump(SessionRenew(ts=TS, id="req-u", chat=99)))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "chat.unknown" and err.id == "req-u"

        number = await new_chat(conn, folder)
        factory.last.script(Block())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="long")))
        await recv_until(conn, ChatState)
        await factory.last.wait_blocked()
        await conn.send(dump(SessionRenew(ts=TS, id="req-b", chat=number)))
        err = (await recv_until(conn, Error))[-1]
        assert isinstance(err, Error) and err.code == "chat.busy" and err.id == "req-b"
        await conn.send(dump(TurnStop(ts=TS, chat=number)))
        await recv_until(conn, TurnFinished)
        await recv(conn)

        await conn.send(dump(SessionRenew(ts=TS, id="req-1", chat=number, log=False)))
        await recv_until(conn, SessionRenewed)
        await recv(conn)  # chat.list
        await conn.send(dump(SessionRenew(ts=TS, id="req-2", chat=number, log=False)))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "session.ended" and err.id == "req-2"
    finally:
        await conn.close()


async def test_a_message_to_an_ended_session_is_refused(server: GatewayServer, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(SessionRenew(ts=TS, id="req-1", chat=number, log=False)))
        await recv_until(conn, SessionRenewed)
        await recv(conn)
        await conn.send(dump(MessageSend(ts=TS, id="req-m", chat=number, text="still there?")))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "session.ended"
    finally:
        await conn.close()


async def test_the_next_session_starts_its_engine_on_first_send(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(SessionRenew(ts=TS, id="req-1", chat=number, log=False)))
        renewed = (await recv_until(conn, SessionRenewed))[-1]
        await recv(conn)
        assert len(factory.engines) == 1
        await send_and_finish(conn, renewed.next.chat, "fresh start")  # type: ignore[union-attr]
        assert len(factory.engines) == 2
        assert factory.last.calls[0] == ("start", (folder, None, ["project"]))
    finally:
        await conn.close()


# --- plug-in log step -----------------------------------------------------------


async def test_a_plugin_on_renew_replaces_the_log_prompt(
    state_dir: StateDir, factory: EngineFactory, folder: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(sys, "path", list(sys.path))
    monkeypatch.setattr(sys, "modules", dict(sys.modules))
    plugins = load_plugins(["portico_example_plugin"], [str(REPO_ROOT / "examples" / "plugin")])
    srv = await start_server(state_dir, factory, plugins=plugins, presentation="single", log_prompt="/session-close")
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        await send_and_finish(conn, number, "Draft the codebook")
        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=number)))
        got = await recv_until(conn, SessionRenewed)
        texts = [m.text for m in got if isinstance(m, UserText)]
        assert len(texts) == 1 and "SESSION-LOG.md" in texts[0] and "Draft the codebook" in texts[0]
        assert ("send", "/session-close") not in factory.last.calls
        assert got[-1].ended.logged is True  # type: ignore[union-attr]
    finally:
        await conn.close()
        await srv.shutdown()


async def test_hello_from_the_server_carries_presentation_and_plugin_changes(
    state_dir: StateDir, factory: EngineFactory, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(sys, "path", list(sys.path))
    monkeypatch.setattr(sys, "modules", dict(sys.modules))
    plugins = load_plugins(["portico_example_plugin"], [str(REPO_ROOT / "examples" / "plugin")])
    srv = await start_server(state_dir, factory, plugins=plugins, presentation="single")
    try:
        from websockets.asyncio.client import connect

        from portico_gateway.messages import HelloClient, parse_server
        from tests.test_server import ws_url

        conn = await connect(ws_url(srv, srv.token))
        await conn.send(dump(HelloClient(ts=TS, app_version="0.2.0")))
        hello = parse_server(await conn.recv())
        assert isinstance(hello, HelloServer)
        assert hello.presentation == "single" and hello.can_log is True
        assert "example.plugin" in hello.capabilities
        await conn.close()
    finally:
        await srv.shutdown()


# --- single presentation ----------------------------------------------------------


async def test_single_presentation_refuses_a_second_live_chat(logging_server: GatewayServer, folder: Path) -> None:
    conn = await attach(logging_server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(ChatNew(ts=TS, id="req-2", folder=str(folder))))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "session.live" and err.id == "req-2"
        assert f"{number}" in err.message and "session.renew" in err.message

        # Once it has ended, a new chat is fine again.
        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=number, log=False)))
        await recv_until(conn, SessionRenewed)
        await recv(conn)
        assert len(logging_server.registry) == 2
    finally:
        await conn.close()


async def test_multiple_presentation_allows_many_chats(server: GatewayServer, folder: Path) -> None:
    conn = await attach(server)
    try:
        await new_chat(conn, folder, id="a")
        await new_chat(conn, folder, id="b")
        assert len(server.registry) == 2
    finally:
        await conn.close()


# --- v0.4: session.log, logged_at, unlogged ------------------------------------------


async def log_and_finish(conn: ClientConnection, chat: int, id: str = "req-l") -> list[ServerMessage]:
    """``session.log`` and everything up to its ``chat.list``."""
    await conn.send(dump(SessionLog(ts=TS, id=id, chat=chat)))
    got = await recv_until(conn, SessionLogged)
    got.append(await recv(conn))
    assert isinstance(got[-1], ChatList), "chat.list follows session.logged"
    return got


async def test_session_log_runs_the_log_step_and_keeps_the_session_live(
    logging_server: GatewayServer, factory: EngineFactory, folder: Path, state_dir: StateDir
) -> None:
    conn = await attach(logging_server)
    try:
        number = await new_chat(conn, folder)
        before = logging_server.registry.get(number).summary()
        assert before.unlogged is False and before.logged_at is None, "no turn yet: nothing to lose"

        await send_and_finish(conn, number, "work")
        assert logging_server.registry.get(number).summary().unlogged is True

        got = await log_and_finish(conn, number)
        assert [m.text for m in got if isinstance(m, UserText)] == ["/session-close"]
        assert [m.outcome for m in got if isinstance(m, TurnFinished)] == ["done"]
        logged = next(m for m in got if isinstance(m, SessionLogged))
        assert logged.id == "req-l"
        assert logged.chat.chat == number and logged.chat.logged_at is not None and logged.chat.unlogged is False
        assert logged.chat.ended is None and logged.chat.state == "idle", "the session is not ended"
        assert logged.chat.logged is None, "logged stays the renewal's verdict"
        listing = got[-1]
        assert isinstance(listing, ChatList) and listing.chats[0].unlogged is False
        assert not factory.last.closed, "the engine stays up"

        # The record keeps it across a restart.
        record = state_dir.load_index().chats[0]
        assert record.logged_at == logged.chat.logged_at and record.work_since_log is False

        # Another turn: unlogged again; logged_at stays until the next log.
        await send_and_finish(conn, number, "more work")
        summary = logging_server.registry.get(number).summary()
        assert summary.unlogged is True and summary.logged_at == logged.chat.logged_at
        assert ("send", "more work") in factory.last.calls
    finally:
        await conn.close()


async def test_a_log_step_that_errors_answers_but_logs_nothing(
    logging_server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach(logging_server)
    try:
        number = await new_chat(conn, folder)
        await send_and_finish(conn, number, "work")
        factory.last.script(fake_result(is_error=True))
        got = await log_and_finish(conn, number)
        logged = next(m for m in got if isinstance(m, SessionLogged))
        assert logged.chat.logged_at is None and logged.chat.unlogged is True
    finally:
        await conn.close()


async def test_while_a_log_runs_sends_and_renewals_are_busy_and_stop_ends_it(
    logging_server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach(logging_server)
    try:
        number = await new_chat(conn, folder)
        await send_and_finish(conn, number, "work")
        engine = factory.last
        engine.script(Block())
        await conn.send(dump(SessionLog(ts=TS, id="req-l", chat=number)))
        await engine.wait_blocked()
        for refused in (
            MessageSend(ts=TS, id="req-m", chat=number, text="hello?"),
            SessionRenew(ts=TS, id="req-r", chat=number),
            SessionLog(ts=TS, id="req-2", chat=number),
        ):
            await conn.send(dump(refused))
            err = (await recv_until(conn, Error))[-1]
            assert isinstance(err, Error) and err.code == "chat.busy" and err.id == refused.id, refused.type
        await conn.send(dump(TurnStop(ts=TS, chat=number)))
        got = await recv_until(conn, SessionLogged)
        assert [m.outcome for m in got if isinstance(m, TurnFinished)] == ["stopped"]
        assert got[-1].chat.unlogged is True and got[-1].chat.logged_at is None  # type: ignore[union-attr]
        await recv(conn)  # chat.list
        # Free again: a send goes through.
        await send_and_finish(conn, number, "after")
    finally:
        await conn.close()


async def test_session_log_refusals(server: GatewayServer, logging_server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    # ``server`` has no log step.
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(SessionLog(ts=TS, id="req-c", chat=number)))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "session.cannot_log" and err.id == "req-c"
        assert server.registry.get(number).summary().unlogged is False
    finally:
        await conn.close()

    conn = await attach(logging_server)
    try:
        await conn.send(dump(SessionLog(ts=TS, id="req-u", chat=99)))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "chat.unknown" and err.id == "req-u"

        number = await new_chat(conn, folder)
        factory.last.script(Block())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="long")))
        await factory.last.wait_blocked()
        await conn.send(dump(SessionLog(ts=TS, id="req-b", chat=number)))
        err = (await recv_until(conn, Error))[-1]
        assert isinstance(err, Error) and err.code == "chat.busy" and err.id == "req-b"
        await conn.send(dump(TurnStop(ts=TS, chat=number)))
        await recv_until(conn, TurnFinished)
        await recv(conn)

        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=number, log=False)))
        await recv_until(conn, SessionRenewed)
        await recv(conn)
        await conn.send(dump(SessionLog(ts=TS, id="req-e", chat=number)))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "session.ended" and err.id == "req-e"
    finally:
        await conn.close()


async def test_a_renewal_that_logs_sets_logged_at(logging_server: GatewayServer, folder: Path) -> None:
    conn = await attach(logging_server)
    try:
        number = await new_chat(conn, folder)
        await send_and_finish(conn, number, "work")
        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=number)))
        renewed = (await recv_until(conn, SessionRenewed))[-1]
        assert isinstance(renewed, SessionRenewed)
        assert renewed.ended.logged is True and renewed.ended.logged_at is not None and renewed.ended.unlogged is False
        assert renewed.next.unlogged is False and renewed.next.logged_at is None
    finally:
        await conn.close()


async def test_hello_lists_log_only_when_the_deployment_can_log(server: GatewayServer, logging_server: GatewayServer) -> None:
    from portico_gateway.config import hello_for

    assert hello_for(server.config, "e", "0.4.0").commands == []
    assert hello_for(logging_server.config, "e", "0.4.0").commands == ["log"]
    assert "log" in logging_server.deployment_commands()


async def test_unlogged_from_an_older_index(state_dir: StateDir) -> None:
    # A v0.3 index has no logging facts: a session the engine named has had a
    # turn and nothing in v0.4 logged it; one that never ran a turn has nothing.
    index = {
        "chats": [
            {**V01_INDEX["chats"][0], "chat": 3, "session_id": "sess-3"},
            {**V01_INDEX["chats"][0], "chat": 4, "session_id": None},
            {**V01_INDEX["chats"][0], "chat": 5, "session_id": "sess-5", "ended": TS, "logged": True},
        ],
        "next_chat": 6,
    }
    state_dir.index_path.write_text(json.dumps(index))
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=10)
    assert [s.unlogged for s in registry.summaries()] == [False, False, False], "no log step: never unlogged"
    registry.can_log = True
    assert [s.unlogged for s in registry.summaries()] == [True, False, False]
    assert registry.create(Path("/tmp")).summary().unlogged is False


async def test_a_plugin_log_step_knows_whether_the_session_ends(
    state_dir: StateDir, factory: EngineFactory, folder: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(sys, "path", list(sys.path))
    monkeypatch.setattr(sys, "modules", dict(sys.modules))
    plugins = load_plugins(["portico_example_plugin"], [str(REPO_ROOT / "examples" / "plugin")])
    srv = await start_server(state_dir, factory, plugins=plugins, presentation="single")
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        await send_and_finish(conn, number, "Draft the codebook")
        got = await log_and_finish(conn, number)
        texts = [m.text for m in got if isinstance(m, UserText)]
        assert len(texts) == 1 and "carrying on" in texts[0] and "ending" not in texts[0]
        logged = next(m for m in got if isinstance(m, SessionLogged))
        assert logged.chat.logged_at is not None and logged.chat.ended is None

        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=number)))
        got = await recv_until(conn, SessionRenewed)
        texts = [m.text for m in got if isinstance(m, UserText)]
        assert len(texts) == 1 and "This session is ending." in texts[0]
    finally:
        await conn.close()
        await srv.shutdown()
