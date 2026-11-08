"""v0.25 §4.4 (PORT-3): a turn that fails on an expired sign-in waits, then carries on by itself.

The engine is the scripted ``FakeEngine``; "signed in again" is an injected
check, and the polling interval is 0.01 s. Nothing here runs the real
``claude`` CLI or touches AWS: the sign-in commands are scripts under
``tmp_path`` and ``tests/fixtures/fake_claude``.

Controller ruling (2026-11-08): after a wait the gateway always resumes the
same session with the short continue message, and never re-sends the
person's message (a re-send showed it twice in a replay after a restart).
"""

from __future__ import annotations

import asyncio
import json
import shlex
import time
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest
from claude_agent_sdk import AssistantMessage
from websockets.asyncio.client import ClientConnection, connect

from portico_gateway import __version__, signin
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import Config
from portico_gateway.engine import CONTINUE_TEXT, history_events
from portico_gateway.messages import (
    SIGNIN_CAPABILITY,
    ChatHistory,
    ChatList,
    ChatOpen,
    ChatRemove,
    ChatState,
    ChatStop,
    HelloClient,
    HelloServer,
    MessageSend,
    ServerMessage,
    ServicesStatus,
    SigninCode,
    SigninOpen,
    SigninStop,
    SigninWait,
    TextDelta,
    TurnFinished,
    TurnStarted,
    UserText,
    dump,
    parse_server,
)
from portico_gateway.server import GatewayServer
from portico_gateway.signin import SigninKind
from portico_gateway.state import StateDir
from tests.conftest import FakeEngine, fake_result, make_config
from tests.test_history import assistant, text, user, write_transcript
from tests.test_server import ws_url
from tests.test_turns import EngineFactory, new_chat, text_delta, tool_result, tool_use

TS = "2026-11-08T21:14:00Z"
FAKE_CLAUDE = Path(__file__).parent / "fixtures" / "fake_claude"
AWS_ERROR = ["cloud_credential_error"]
SESSION = "7d3c1f0a-2b4e-4c5d-8e9f-0a1b2c3d4e5f"


def aws_failure() -> list[Any]:
    """What the engine says when the AWS sign-in has run out before anything ran."""
    return [fake_result(is_error=True, errors=AWS_ERROR, result="Could not load AWS credentials")]


def claude_failure() -> list[Any]:
    return [
        AssistantMessage(content=[], model="m", error="authentication_failed"),
        fake_result(is_error=True, result="Login expired · Please run /login"),
    ]


class SignedIn:
    """The injected "is the sign-in current?" check: false until ``now()``; counts its calls."""

    def __init__(self) -> None:
        self.current = False
        self.calls = 0

    def now(self) -> None:
        self.current = True

    async def __call__(self, kind: SigninKind, since: float, folder: Path) -> bool:
        self.calls += 1
        return self.current


class UuidSessions(EngineFactory):
    """Fake engines whose session id is a UUID, as the real engine's is."""

    def __call__(self) -> FakeEngine:
        engine = FakeEngine(session_id=SESSION)
        self.engines.append(engine)
        return engine


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
def signed_in() -> SignedIn:
    return SignedIn()


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = tmp_path / "demo"
    path.mkdir()
    return path


async def make_server(state_dir: StateDir, factory: EngineFactory, signed_in: SignedIn, config: Config | None = None) -> GatewayServer:
    config = config or make_config(setting_sources=["project"])
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    srv.signin_is_current = signed_in
    srv.signin_interval = lambda kind: 0.01
    srv.sso_folder = state_dir.path / "no-sso-cache"
    srv.engine_environ = {}  # a claude.ai login, whatever this machine's own environment holds
    await srv.serve(0)
    return srv


@pytest.fixture
async def server(state_dir: StateDir, factory: EngineFactory, signed_in: SignedIn) -> AsyncIterator[GatewayServer]:
    srv = await make_server(state_dir, factory, signed_in)
    try:
        yield srv
    finally:
        await srv.shutdown()


async def attach_with(server: GatewayServer, capabilities: list[str]) -> ClientConnection:
    conn = await connect(ws_url(server, server.token))
    await conn.send(dump(HelloClient(ts=TS, app_version="0.25.0", capabilities=capabilities)))
    assert isinstance(parse_server(await conn.recv()), HelloServer)
    assert isinstance(parse_server(await conn.recv()), ChatList)
    assert isinstance(parse_server(await conn.recv()), ServicesStatus)
    return conn


async def recv(conn: ClientConnection, timeout: float = 5.0) -> ServerMessage:
    return parse_server(await asyncio.wait_for(conn.recv(), timeout))


async def until(conn: ClientConnection, match: Any, timeout: float = 5.0) -> tuple[list[ServerMessage], ServerMessage]:
    """Frames up to and including the first for which ``match(frame)`` is true."""
    seen: list[ServerMessage] = []
    while True:
        msg = await recv(conn, timeout)
        seen.append(msg)
        if match(msg):
            return seen, msg


def wait_in(state: str) -> Any:
    return lambda m: isinstance(m, SigninWait) and m.state == state


async def quiet(conn: ClientConnection, seconds: float = 0.15) -> list[ServerMessage]:
    """Every frame that arrives within ``seconds``."""
    got: list[ServerMessage] = []
    try:
        while True:
            got.append(await recv(conn, seconds))
    except TimeoutError:
        return got


async def send(conn: ClientConnection, chat: int, words: str) -> None:
    await conn.send(dump(MessageSend(ts=TS, chat=chat, text=words)))


async def failed_and_waiting(conn: ClientConnection) -> tuple[TurnFinished, SigninWait]:
    seen, finished = await until(conn, lambda m: isinstance(m, TurnFinished))
    assert isinstance(finished, TurnFinished)
    _, waiting = await until(conn, wait_in("waiting"))
    assert isinstance(waiting, SigninWait)
    return finished, waiting


# --- waiting, then carrying on --------------------------------------------------------


async def test_a_signin_error_before_anything_ran_continues_without_resending(
    server: GatewayServer, factory: EngineFactory, folder: Path, signed_in: SignedIn
) -> None:
    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*aws_failure())
        factory.last.script(text_delta("Here is the summary."), fake_result())
        await send(conn, chat, "Summarise the notes")
        finished, waiting = await failed_and_waiting(conn)
        assert (finished.outcome, finished.reason) == ("error", "signin.expired")
        assert (waiting.chat, waiting.turn, waiting.kind, waiting.can_open, waiting.wants_code) == (chat, 1, "aws-sso", False, False)
        assert waiting.title == "Sign in again to continue"
        assert waiting.body.startswith("Your sign-in to AWS has run out.")
        assert waiting.url is None and waiting.code is None

        signed_in.now()
        _, current = await until(conn, wait_in("current"))
        assert isinstance(current, SigninWait) and current.turn == 1
        started = await recv(conn)
        assert isinstance(started, TurnStarted) and started.turn == 2
        rest, _ = await until(conn, lambda m: isinstance(m, TurnFinished))
        assert not any(isinstance(m, UserText) for m in rest), "the continue draws no bubble"
        assert any(isinstance(m, TextDelta) and m.text == "Here is the summary." for m in rest)
        sends = [args for name, args in factory.last.calls if name == "send"]
        assert sends == ["Summarise the notes", CONTINUE_TEXT], "the person's message goes once; the continue resumes"
    finally:
        await conn.close()


async def test_a_signin_error_part_way_continues(
    server: GatewayServer, factory: EngineFactory, folder: Path, signed_in: SignedIn
) -> None:
    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(
            tool_use("t1", "Read", {"file_path": str(folder / "a.md")}),
            tool_result("t1", "text"),
            *aws_failure(),
        )
        await send(conn, chat, "Read a.md and summarise it")
        await failed_and_waiting(conn)
        signed_in.now()
        await until(conn, wait_in("current"))
        await until(conn, lambda m: isinstance(m, TurnFinished))
        sends = [args for name, args in factory.last.calls if name == "send"]
        assert sends == ["Read a.md and summarise it", CONTINUE_TEXT]
        assert server.registry.get(chat).session_id == factory.last.session_id, "the same session"
    finally:
        await conn.close()


async def test_the_wait_comes_back_once_then_the_turn_ends(
    server: GatewayServer, factory: EngineFactory, folder: Path, signed_in: SignedIn
) -> None:
    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        for _ in range(3):
            factory.last.script(*aws_failure())
        await send(conn, chat, "go")
        await failed_and_waiting(conn)
        signed_in.now()
        await until(conn, wait_in("current"))
        # The continued turn fails on the sign-in again: the card comes back once more.
        signed_in.current = False
        finished, again = await failed_and_waiting(conn)
        assert finished.turn == 2 and again.turn == 2
        signed_in.now()
        await until(conn, wait_in("current"))
        # And a third time: the turn ends with the reason, no wait.
        _, last = await until(conn, lambda m: isinstance(m, TurnFinished))
        assert isinstance(last, TurnFinished) and last.turn == 3 and last.reason == "signin.expired"
        assert not any(isinstance(m, SigninWait) for m in await quiet(conn))
        assert server.registry.get(chat).signin is None
    finally:
        await conn.close()


async def test_a_done_turn_resets_the_count(
    server: GatewayServer, factory: EngineFactory, folder: Path, signed_in: SignedIn
) -> None:
    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*aws_failure())
        factory.last.script(text_delta("ok"), fake_result())
        await send(conn, chat, "go")
        await failed_and_waiting(conn)
        signed_in.now()
        _, done = await until(conn, lambda m: isinstance(m, TurnFinished) and m.outcome == "done")
        assert server.registry.get(chat).signin_waits == 0
    finally:
        await conn.close()


async def test_a_new_message_stops_the_wait(
    server: GatewayServer, factory: EngineFactory, folder: Path, signed_in: SignedIn
) -> None:
    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*aws_failure())
        factory.last.script(text_delta("fine"), fake_result())
        await send(conn, chat, "first")
        await failed_and_waiting(conn)
        await send(conn, chat, "never mind, this instead")
        _, stopped = await until(conn, wait_in("stopped"))
        assert isinstance(stopped, SigninWait) and stopped.turn == 1
        seen, _ = await until(conn, lambda m: isinstance(m, TurnFinished))
        assert any(isinstance(m, UserText) and m.text == "never mind, this instead" for m in seen)
        record = server.registry.get(chat)
        assert record.signin is None and record.signin_waits == 0
        signed_in.now()
        await asyncio.sleep(0.05)
        sends = [args for name, args in factory.last.calls if name == "send"]
        assert sends == ["first", "never mind, this instead"], "nothing resumes after the wait stopped"
    finally:
        await conn.close()


async def test_dont_wait_stops(server: GatewayServer, factory: EngineFactory, folder: Path, signed_in: SignedIn) -> None:
    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*aws_failure())
        await send(conn, chat, "go")
        await failed_and_waiting(conn)
        await conn.send(dump(SigninStop(ts=TS, chat=chat)))
        _, stopped = await until(conn, wait_in("stopped"))
        assert isinstance(stopped, SigninWait)
        signed_in.now()
        assert not any(isinstance(m, (SigninWait, TurnStarted)) for m in await quiet(conn))
        assert [args for name, args in factory.last.calls if name == "send"] == ["go"]
        assert server.registry.get(chat).signin is None
    finally:
        await conn.close()


async def test_an_app_without_signin_v1_gets_the_reason_only(
    server: GatewayServer, factory: EngineFactory, folder: Path, signed_in: SignedIn
) -> None:
    conn = await attach_with(server, [])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*aws_failure())
        await send(conn, chat, "go")
        _, finished = await until(conn, lambda m: isinstance(m, TurnFinished))
        assert isinstance(finished, TurnFinished) and finished.reason == "signin.expired"
        assert not any(isinstance(m, SigninWait) for m in await quiet(conn))
        assert server.registry.get(chat).signin is None
    finally:
        await conn.close()


async def test_an_error_that_is_not_a_signin_has_no_reason(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(fake_result(is_error=True, errors=["rate_limit"]))
        await send(conn, chat, "go")
        _, finished = await until(conn, lambda m: isinstance(m, TurnFinished))
        assert isinstance(finished, TurnFinished) and finished.reason is None
        assert not any(isinstance(m, SigninWait) for m in await quiet(conn))
    finally:
        await conn.close()


async def test_a_second_error_while_waiting_adds_nothing(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*aws_failure())
        await send(conn, chat, "go")
        await failed_and_waiting(conn)
        record = server.registry.get(chat)
        before = (record.signin, record.signin_waits)
        # The engine reports a further sign-in failure (a turn nobody sent) while the wait runs.
        await server.engine_event_now(record, TurnStarted(ts=TS, chat=chat, turn=2))
        await server.engine_event_now(
            record, TurnFinished(ts=TS, chat=chat, turn=2, outcome="error").with_error_detail(AWS_ERROR)
        )
        frames = await quiet(conn)
        assert not any(isinstance(m, SigninWait) for m in frames)
        assert any(isinstance(m, TurnFinished) and m.reason == "signin.expired" for m in frames)
        assert (record.signin, record.signin_waits) == before
    finally:
        await conn.close()


# --- the sign-in command ------------------------------------------------------------------


def _script(tmp_path: Path, name: str, body: str) -> str:
    path = tmp_path / name
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)
    return shlex.quote(str(path))


async def test_open_runs_the_command_and_sends_the_link(
    state_dir: StateDir, factory: EngineFactory, signed_in: SignedIn, folder: Path, tmp_path: Path
) -> None:
    opener = _script(
        tmp_path, "aws_login",
        "echo 'Open https://device.sso.us-east-1.amazonaws.com/ and enter the code'\necho 'QKXW-RTBN'\nsleep 30\n",
    )
    config = make_config(setting_sources=["project"], signin={"aws-sso": {"open": opener}})
    srv = await make_server(state_dir, factory, signed_in, config)
    conn = await attach_with(srv, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*aws_failure())
        await send(conn, chat, "go")
        _, waiting = await failed_and_waiting(conn)
        assert waiting.can_open
        await conn.send(dump(SigninOpen(ts=TS, chat=chat)))
        _, linked = await until(conn, lambda m: isinstance(m, SigninWait) and m.code is not None)
        assert isinstance(linked, SigninWait) and linked.state == "waiting"
        assert (linked.url, linked.code) == ("https://device.sso.us-east-1.amazonaws.com/", "QKXW-RTBN")
        assert linked.started == waiting.started
    finally:
        await conn.close()
        await srv.shutdown()


async def test_a_pasted_code_goes_to_the_command(
    server: GatewayServer, factory: EngineFactory, folder: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    pasted = tmp_path / "pasted"
    monkeypatch.setenv("FAKE_CLAUDE_CODE_FILE", str(pasted))
    monkeypatch.setattr(signin, "cli_path", lambda: str(FAKE_CLAUDE))
    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*claude_failure())
        await send(conn, chat, "go")
        _, waiting = await failed_and_waiting(conn)
        assert (waiting.kind, waiting.can_open, waiting.wants_code) == ("claude", True, True)
        assert waiting.body.startswith("Your Claude sign-in has run out.")
        await conn.send(dump(SigninOpen(ts=TS, chat=chat)))
        _, linked = await until(conn, lambda m: isinstance(m, SigninWait) and m.url is not None)
        assert isinstance(linked, SigninWait) and linked.url == "https://claude.example/oauth/authorize?code=true"
        await conn.send(dump(SigninCode(ts=TS, chat=chat, code="abc-123")))
        deadline = time.monotonic() + 3
        while not (pasted.exists() and pasted.read_text() == "abc-123"):
            assert time.monotonic() < deadline, "the fake never got the code"
            await asyncio.sleep(0.02)
    finally:
        await conn.close()


async def test_open_command_is_killed_when_the_wait_ends(
    state_dir: StateDir, factory: EngineFactory, signed_in: SignedIn, folder: Path, tmp_path: Path
) -> None:
    opener = _script(tmp_path, "hang", "echo 'https://device.example/start'\nsleep 60\n")
    config = make_config(setting_sources=["project"], signin={"aws-sso": {"open": opener}})
    srv = await make_server(state_dir, factory, signed_in, config)
    conn = await attach_with(srv, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*aws_failure())
        await send(conn, chat, "go")
        await failed_and_waiting(conn)
        await conn.send(dump(SigninOpen(ts=TS, chat=chat)))
        await until(conn, lambda m: isinstance(m, SigninWait) and m.url is not None)
        state = srv.registry.get(chat).signin
        assert state is not None and state.command is not None and state.command.running
        command = state.command
        await conn.send(dump(SigninStop(ts=TS, chat=chat)))
        await until(conn, wait_in("stopped"))
        assert not command.running
        # And the same when the sign-in comes back while it runs.
        factory.last.script(*aws_failure())
        await send(conn, chat, "again")
        await failed_and_waiting(conn)
        await conn.send(dump(SigninOpen(ts=TS, chat=chat)))
        await until(conn, lambda m: isinstance(m, SigninWait) and m.url is not None)
        second = srv.registry.get(chat).signin
        assert second is not None and second.command is not None
        command = second.command
        signed_in.now()
        await until(conn, wait_in("current"))
        assert not command.running
    finally:
        await conn.close()
        await srv.shutdown()


async def test_stopping_or_removing_the_chat_ends_the_wait(
    server: GatewayServer, factory: EngineFactory, folder: Path, signed_in: SignedIn
) -> None:
    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*aws_failure())
        await send(conn, chat, "go")
        await failed_and_waiting(conn)
        task = server.registry.get(chat).signin.task  # type: ignore[union-attr]
        await conn.send(dump(ChatStop(ts=TS, chat=chat)))
        await until(conn, wait_in("stopped"))
        await until(conn, lambda m: isinstance(m, ChatState) and m.state == "stopped")
        await asyncio.sleep(0.02)
        assert task.done()
        engine = factory.last
        signed_in.now()
        await asyncio.sleep(0.05)
        assert [args for name, args in engine.calls if name == "send"] == ["go"]

        other = await new_chat(conn, folder, id="req-other")
        factory.last.script(*aws_failure())
        signed_in.current = False
        await send(conn, other, "go")
        await failed_and_waiting(conn)
        task = server.registry.get(other).signin.task  # type: ignore[union-attr]
        await conn.send(dump(ChatRemove(ts=TS, chat=other)))
        await until(conn, lambda m: isinstance(m, ChatList))
        await asyncio.sleep(0.02)
        assert task.done()
        signed_in.now()
        await asyncio.sleep(0.05)
        assert [args for name, args in factory.last.calls if name == "send"] == ["go"]
    finally:
        await conn.close()


async def test_a_running_wait_is_resent_on_attach(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    chat = await new_chat(conn, folder)
    factory.last.script(*aws_failure())
    await send(conn, chat, "go")
    _, waiting = await failed_and_waiting(conn)
    await conn.close()
    again = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        _, resent = await until(again, lambda m: isinstance(m, SigninWait))
        assert resent == waiting.model_copy(update={"ts": resent.ts})
        # Opening the chat sends it again too, after its history.
        await again.send(dump(ChatOpen(ts=TS, chat=chat, id="req-open")))
        seen, _ = await until(again, lambda m: isinstance(m, SigninWait))
        assert any(isinstance(m, ChatHistory) for m in seen)
    finally:
        await again.close()


async def test_shutdown_ends_a_wait(state_dir: StateDir, factory: EngineFactory, signed_in: SignedIn, folder: Path) -> None:
    srv = await make_server(state_dir, factory, signed_in)
    conn = await attach_with(srv, [SIGNIN_CAPABILITY])
    chat = await new_chat(conn, folder)
    factory.last.script(*aws_failure())
    await send(conn, chat, "go")
    await failed_and_waiting(conn)
    task = srv.registry.get(chat).signin.task  # type: ignore[union-attr]
    await conn.close()
    await srv.shutdown()
    assert task.done()


# --- replay -----------------------------------------------------------------------------


def test_replay_draws_no_bubble_for_the_continue_text() -> None:
    events = history_events([user("Summarise"), user(CONTINUE_TEXT), assistant(text("Done."))], chat=1)
    said = [e.text for e in events if isinstance(e, UserText)]
    assert said == ["Summarise"]


async def test_the_persons_message_appears_once_in_replay_after_a_continue(
    state_dir: StateDir, factory: EngineFactory, signed_in: SignedIn, folder: Path, tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Controller ruling: what the engine was sent, replayed after a gateway restart, shows the message once."""
    config_dir = tmp_path / "engine-home"
    config_dir.mkdir()
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config_dir))
    # The engine's session id is a UUID, as the real one's is (the SDK's reader looks only for those).
    factory = UuidSessions()
    srv = await make_server(state_dir, factory, signed_in)
    conn = await attach_with(srv, [SIGNIN_CAPABILITY])
    chat = await new_chat(conn, folder)
    factory.last.script(*aws_failure())
    factory.last.script(text_delta("Here is the summary."), fake_result())
    await send(conn, chat, "Summarise the notes")
    await failed_and_waiting(conn)
    signed_in.now()
    await until(conn, lambda m: isinstance(m, TurnFinished) and m.outcome == "done")
    session = srv.registry.get(chat).session_id
    # The engine's transcript: every message it was sent, the failure's words, and the reply.
    sent = [args for name, args in factory.last.calls if name == "send"]
    transcript = [user(sent[0]), assistant(text("Could not load AWS credentials")), user(sent[1]), assistant(text("Here is the summary."))]
    await conn.close()
    await srv.shutdown()
    assert session is not None
    write_transcript(config_dir, folder, session, transcript)

    restarted = await make_server(state_dir, EngineFactory(), signed_in)
    again = await attach_with(restarted, [SIGNIN_CAPABILITY])
    try:
        await again.send(dump(ChatOpen(ts=TS, chat=chat, id="req-open")))
        _, history = await until(again, lambda m: isinstance(m, ChatHistory))
        assert isinstance(history, ChatHistory)
        said = [e.text for e in history.events if isinstance(e, UserText)]
        assert said == ["Summarise the notes"], said
        assert json.dumps(dump(history)).count("Summarise the notes") == 1
    finally:
        await again.close()
        await restarted.shutdown()


# --- review fixes -------------------------------------------------------------------------


async def test_review_m1_a_bedrock_engine_never_waits_on_the_claude_sign_in(
    state_dir: StateDir, factory: EngineFactory, signed_in: SignedIn, folder: Path
) -> None:
    srv = await make_server(state_dir, factory, signed_in)
    srv.engine_environ = {"CLAUDE_CODE_USE_BEDROCK": "1", "AWS_REGION": "us-east-1"}
    conn = await attach_with(srv, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*claude_failure())
        await send(conn, chat, "go")
        _, finished = await until(conn, lambda m: isinstance(m, TurnFinished))
        assert isinstance(finished, TurnFinished) and finished.reason is None
        assert not any(isinstance(m, SigninWait) for m in await quiet(conn))
        assert srv.registry.get(chat).signin is None
    finally:
        await conn.close()
        await srv.shutdown()


async def test_renew_during_a_wait_ends_it(
    server: GatewayServer, factory: EngineFactory, folder: Path, signed_in: SignedIn
) -> None:
    """Review M3 (the reviewer's proof, now passing): Start a new session ends the wait; nothing says current."""
    from portico_gateway.messages import SessionRenew, SessionRenewed

    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*aws_failure())
        await send(conn, chat, "go")
        await failed_and_waiting(conn)
        task = server.registry.get(chat).signin.task  # type: ignore[union-attr]
        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=chat, log=False)))
        seen, _ = await until(conn, lambda m: isinstance(m, SessionRenewed))
        assert any(isinstance(m, SigninWait) and m.state == "stopped" for m in seen)
        assert server.registry.get(chat).signin is None
        await asyncio.sleep(0.02)
        assert task.done()
        signed_in.now()
        assert not any(isinstance(m, SigninWait) for m in await quiet(conn))
    finally:
        await conn.close()


async def test_a_log_step_ends_the_wait(
    state_dir: StateDir, factory: EngineFactory, signed_in: SignedIn, folder: Path
) -> None:
    from portico_gateway.messages import SessionLog

    srv = await make_server(state_dir, factory, signed_in, make_config(setting_sources=["project"], log_prompt="/log"))
    conn = await attach_with(srv, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*aws_failure())
        await send(conn, chat, "go")
        await failed_and_waiting(conn)
        await conn.send(dump(SessionLog(ts=TS, id="req-l", chat=chat)))
        _, stopped = await until(conn, wait_in("stopped"))
        assert isinstance(stopped, SigninWait)
        assert srv.registry.get(chat).signin is None
    finally:
        await conn.close()
        await srv.shutdown()


async def test_current_when_it_cannot_carry_on_says_stopped(
    server: GatewayServer, factory: EngineFactory, folder: Path, signed_in: SignedIn
) -> None:
    """Review M3: a busy chat at "current" hears ``stopped``, never ``current`` with nothing following."""
    from portico_gateway.server import TurnRun

    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*aws_failure())
        await send(conn, chat, "go")
        await failed_and_waiting(conn)
        record = server.registry.get(chat)
        server._runs[chat] = TurnRun(turn=99, collector=None)  # type: ignore[arg-type]  # a turn the engine began itself
        signed_in.now()
        _, stopped = await until(conn, lambda m: isinstance(m, SigninWait) and m.state != "waiting")
        assert isinstance(stopped, SigninWait) and stopped.state == "stopped"
        assert record.signin is None
        server._runs.pop(chat)
        assert [args for name, args in factory.last.calls if name == "send"] == ["go"]
    finally:
        await conn.close()


async def _code_refusal(conn: ClientConnection, chat: int, code: str) -> str:
    from portico_gateway.messages import Error

    await conn.send(dump(SigninCode(ts=TS, chat=chat, code=code)))
    _, error = await until(conn, lambda m: isinstance(m, Error))
    assert isinstance(error, Error)
    return error.code


async def test_review_l8_a_code_is_checked(
    server: GatewayServer, factory: EngineFactory, folder: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(signin, "cli_path", lambda: str(FAKE_CLAUDE))
    monkeypatch.setenv("FAKE_CLAUDE_CODE_FILE", str(tmp_path / "pasted"))
    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        # No wait yet.
        assert await _code_refusal(conn, chat, "abc") == "signin.not_waiting"
        factory.last.script(*claude_failure())
        await send(conn, chat, "go")
        await failed_and_waiting(conn)
        await conn.send(dump(SigninOpen(ts=TS, chat=chat)))
        await until(conn, lambda m: isinstance(m, SigninWait) and m.url is not None)
        assert await _code_refusal(conn, chat, "x" * 257) == "signin.invalid_code"
        assert await _code_refusal(conn, chat, "ab\ncd") == "signin.invalid_code"
        assert await _code_refusal(conn, chat, "café") == "signin.invalid_code"
        assert not (tmp_path / "pasted").exists()
        await conn.send(dump(SigninCode(ts=TS, chat=chat, code="y" * 256)))
        deadline = time.monotonic() + 3
        while not ((tmp_path / "pasted").exists() and (tmp_path / "pasted").read_text() == "y" * 256):
            assert time.monotonic() < deadline
            await asyncio.sleep(0.02)
    finally:
        await conn.close()


async def test_review_l8_aws_takes_no_pasted_code(
    state_dir: StateDir, factory: EngineFactory, signed_in: SignedIn, folder: Path, tmp_path: Path
) -> None:
    opener = _script(tmp_path, "aws_login", "echo 'https://device.example/start'\nread line\necho \"$line\" > got\nsleep 30\n")
    config = make_config(setting_sources=["project"], signin={"aws-sso": {"open": opener}})
    srv = await make_server(state_dir, factory, signed_in, config)
    conn = await attach_with(srv, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*aws_failure())
        await send(conn, chat, "go")
        await failed_and_waiting(conn)
        await conn.send(dump(SigninOpen(ts=TS, chat=chat)))
        await until(conn, lambda m: isinstance(m, SigninWait) and m.url is not None)
        assert await _code_refusal(conn, chat, "abc") == "signin.no_code"
    finally:
        await conn.close()
        await srv.shutdown()


# --- v0.26: the v0.25 review's leftovers (PORT-22) -------------------------------------


async def test_the_wait_counts_a_sign_in_from_the_turns_start(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    """L2: the wait's ``since`` is the failed turn's start, not the moment the wait began."""
    from tests.conftest import Pause

    conn = await attach_with(server, [SIGNIN_CAPABILITY])
    try:
        chat = await new_chat(conn, folder)
        pause = Pause()
        factory.last.script(pause, *aws_failure())
        await send(conn, chat, "go")
        await asyncio.wait_for(pause.reached.wait(), 5)
        mid_turn = time.time()  # the person signs in here, while the turn is still failing
        await asyncio.sleep(0.05)
        pause.go.set()
        await failed_and_waiting(conn)
        state = server.registry.get(chat).signin
        assert state is not None
        assert state.since < mid_turn, "a token written mid-turn counts"
    finally:
        await conn.close()


async def test_a_command_started_after_the_wait_ended_is_closed(
    state_dir: StateDir, factory: EngineFactory, signed_in: SignedIn, folder: Path, tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """L9: the wait ends while Open sign-in page's command is starting: the command is closed, not orphaned."""
    opener = _script(tmp_path, "aws_login", "sleep 30\n")
    config = make_config(setting_sources=["project"], signin={"aws-sso": {"open": opener}})
    srv = await make_server(state_dir, factory, signed_in, config)
    conn = await attach_with(srv, [SIGNIN_CAPABILITY])
    started: list[signin.SigninCommand] = []
    closed: list[signin.SigninCommand] = []
    real_start = signin.SigninCommand.start
    real_close = signin.SigninCommand.close

    async def start(self, command, on_link):  # type: ignore[no-untyped-def]
        # The wait ends while start() is still creating the process: close() finds none yet.
        await srv._end_signin(srv.registry.get(chat))
        await real_start(self, command, on_link)
        started.append(self)

    async def close(self):  # type: ignore[no-untyped-def]
        closed.append(self)
        await real_close(self)

    monkeypatch.setattr(signin.SigninCommand, "start", start)
    monkeypatch.setattr(signin.SigninCommand, "close", close)
    try:
        chat = await new_chat(conn, folder)
        factory.last.script(*aws_failure())
        await send(conn, chat, "go")
        await failed_and_waiting(conn)
        await conn.send(dump(SigninOpen(ts=TS, chat=chat)))
        await until(conn, wait_in("stopped"))
        for _ in range(100):
            if started and started[0] in closed and not started[0].running:
                break
            await asyncio.sleep(0.02)
        assert started and started[0] in closed
        assert not started[0].running
    finally:
        await conn.close()
        await srv.shutdown()
