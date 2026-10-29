"""Task 11: lifecycle — deployment commands, single instance, gateway stop, signals.

``before_first_chat`` runs once per gateway launch before the first
``chat.new``; its lines stream to the status strip and a failure refuses
the chat in plain words. ``gateway.stop`` interrupts every running turn,
runs ``on_stop``, persists the index and exits. A second gateway on the
same state directory is refused. SIGTERM takes the same path as
``gateway.stop`` and exits 0.

Model-free: FakeEngine behind every chat; the subprocess test starts the
real CLI but never opens a chat, so no engine is created.
"""

from __future__ import annotations

import asyncio
import os
import signal
import sys
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from pathlib import Path
from typing import Any

import pytest
from websockets.exceptions import ConnectionClosed

from portico_gateway import REPO_ROOT, __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.lifecycle import AlreadyRunning, run_command, single_instance
from portico_gateway.messages import (
    ChatList,
    ChatNew,
    ChatState,
    Error,
    GatewayStop,
    MessageSend,
    ServerMessage,
    StatusSet,
    TextDelta,
    TurnFinished,
    TurnStarted,
    UserText,
    dump,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import ChatRecord, Index, StateDir
from tests.conftest import Block, make_config
from tests.test_server import attach
from tests.test_turns import EngineFactory, new_chat, recv, recv_until, text_delta

TS = "2026-10-27T12:00:00Z"


# --- fixtures -----------------------------------------------------------------


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = tmp_path / "demo"
    path.mkdir()
    return path


class Served:
    """Starts servers with a custom config and shuts every one of them down."""

    def __init__(self, state_dir: StateDir, factory: EngineFactory) -> None:
        self.state_dir = state_dir
        self.factory = factory
        self.servers: list[GatewayServer] = []

    async def __call__(self, **overrides: Any) -> GatewayServer:
        config = make_config(**overrides)
        registry = ChatRegistry(index=self.state_dir.load_index(), state=self.state_dir, history_buffer=config.history_buffer)
        srv = GatewayServer(config=config, state=self.state_dir, registry=registry, engine_factory=self.factory, version=__version__)
        await srv.serve(0)
        self.servers.append(srv)
        return srv

    async def close(self) -> None:
        for srv in self.servers:
            await srv.shutdown()


@pytest.fixture
async def served(state_dir: StateDir, factory: EngineFactory) -> AsyncIterator[Served]:
    s = Served(state_dir, factory)
    try:
        yield s
    finally:
        await s.close()


def _collect() -> tuple[list[str], Callable[[str], Awaitable[None]]]:
    lines: list[str] = []

    async def on_line(line: str) -> None:
        lines.append(line)

    return lines, on_line


async def _wait_gone(pid: int, timeout: float = 5.0) -> bool:
    """True once ``pid`` no longer exists (a zombie counts as gone once reaped)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        await asyncio.sleep(0.05)
    return False


# --- run_command --------------------------------------------------------------


async def test_run_command_streams_merged_lines_and_returns_exit_code() -> None:
    lines, on_line = _collect()
    code = await run_command("echo one; echo two >&2; echo three; exit 4", on_line, timeout=10)
    assert code == 4
    assert lines == ["one", "two", "three"]


async def test_run_command_times_out_and_kills_the_process_group(tmp_path: Path) -> None:
    pid_file = tmp_path / "sleep.pid"
    lines, on_line = _collect()
    started = time.monotonic()
    with pytest.raises(TimeoutError):
        await run_command(f"echo hanging; sleep 30 & echo $! > {pid_file}; wait", on_line, timeout=0.5)
    assert time.monotonic() - started < 5
    assert lines == ["hanging"]
    # The whole group died, not just the shell: the background sleep is gone too.
    sleep_pid = int(pid_file.read_text().strip())
    assert await _wait_gone(sleep_pid)


async def test_run_command_does_not_wait_on_a_background_child_that_keeps_the_pipe() -> None:
    # A preflight that starts a service in the background and exits must not
    # be held until the timeout just because the service inherited stdout.
    lines, on_line = _collect()
    started = time.monotonic()
    code = await run_command("echo started; sleep 20 & exit 0", on_line, timeout=10)
    assert code == 0
    assert lines == ["started"]
    assert time.monotonic() - started < 5


# --- before_first_chat --------------------------------------------------------


async def test_before_first_chat_streams_lines_then_chat_opens(
    served: Served, factory: EngineFactory, folder: Path
) -> None:
    server = await served(before_first_chat="echo checking services; echo all good")
    conn = await attach(server)
    try:
        await conn.send(dump(ChatNew(ts=TS, id="req-1", folder=str(folder))))
        frames = await recv_until(conn, ChatList)
        kinds = [type(m) for m in frames]
        assert kinds == [StatusSet, StatusSet, ChatState, ChatList]
        one, two, state, listing = frames
        assert isinstance(one, StatusSet) and one.text == "checking services"
        assert isinstance(two, StatusSet) and two.text == "all good"
        # Lifecycle lines belong to no chat and are not stamped.
        assert one.chat is None and one.seq is None
        assert isinstance(state, ChatState) and state.state == "idle" and state.id == "req-1"
        assert isinstance(listing, ChatList) and [c.chat for c in listing.chats] == [state.chat]
        assert factory.last.started

        # Once per gateway launch: the second chat opens without the preflight.
        await conn.send(dump(ChatNew(ts=TS, id="req-2", folder=str(folder))))
        frames = await recv_until(conn, ChatList)
        assert [type(m) for m in frames] == [ChatState, ChatList]
    finally:
        await conn.close()


async def test_before_first_chat_nonzero_refuses_chat_with_last_line(
    served: Served, factory: EngineFactory, folder: Path, state_dir: StateDir
) -> None:
    server = await served(before_first_chat="echo starting; echo 'memory service is down' >&2; exit 3")
    conn = await attach(server)
    try:
        await conn.send(dump(ChatNew(ts=TS, id="req-1", folder=str(folder))))
        frames = await recv_until(conn, Error)
        assert [type(m) for m in frames] == [StatusSet, StatusSet, Error]
        err = frames[-1]
        assert isinstance(err, Error)
        assert err.code == "lifecycle.before_first_chat_failed"
        assert err.id == "req-1" and err.chat is None
        assert "memory service is down" in err.message
        assert "3" in err.message

        # No chat was created, no number consumed, no engine started.
        assert len(server.registry) == 0
        assert factory.engines == []
        index = state_dir.load_index()
        assert index.chats == [] and index.next_chat == 1
    finally:
        await conn.close()


async def test_before_first_chat_times_out_and_refuses_chat(
    served: Served, factory: EngineFactory, folder: Path, tmp_path: Path
) -> None:
    # Review Focus 5: a hanging preflight means a bounded wait and a plain failure.
    pid_file = tmp_path / "sleep.pid"
    server = await served(
        before_first_chat=f"echo waiting for services; sleep 30 & echo $! > {pid_file}; wait",
        command_timeout_seconds=1,
    )
    conn = await attach(server)
    try:
        started = time.monotonic()
        await conn.send(dump(ChatNew(ts=TS, id="req-1", folder=str(folder))))
        frames = await recv_until(conn, Error, timeout=10)
        assert time.monotonic() - started < 8
        assert [type(m) for m in frames] == [StatusSet, Error]
        err = frames[-1]
        assert isinstance(err, Error)
        assert err.code == "lifecycle.before_first_chat_failed"
        assert err.id == "req-1"
        assert "1" in err.message and "waiting for services" in err.message
        assert len(server.registry) == 0 and factory.engines == []
        assert await _wait_gone(int(pid_file.read_text().strip()))
    finally:
        await conn.close()


async def test_before_first_chat_is_retried_after_a_failure(
    served: Served, factory: EngineFactory, folder: Path, tmp_path: Path
) -> None:
    # Fails the first time, passes the second: the person fixes the deployment and tries again.
    flag = tmp_path / "ready"
    server = await served(before_first_chat=f"test -e {flag} || {{ echo not yet; exit 1; }}; echo ready")
    conn = await attach(server)
    try:
        await conn.send(dump(ChatNew(ts=TS, id="a", folder=str(folder))))
        frames = await recv_until(conn, Error)
        assert isinstance(frames[-1], Error) and frames[-1].code == "lifecycle.before_first_chat_failed"

        flag.write_text("")
        await conn.send(dump(ChatNew(ts=TS, id="b", folder=str(folder))))
        frames = await recv_until(conn, ChatList)
        assert [type(m) for m in frames] == [StatusSet, ChatState, ChatList]
        assert isinstance(frames[0], StatusSet) and frames[0].text == "ready"
        assert len(server.registry) == 1
    finally:
        await conn.close()


async def test_before_first_chat_runs_for_a_restored_chat_continued_after_restart(
    served: Served, factory: EngineFactory, folder: Path, state_dir: StateDir, tmp_path: Path
) -> None:
    # The common path after a gateway restart is "continue yesterday's chat":
    # its engine starts from message.send, not chat.new, and the deployment's
    # preflight must run there too (spec section 5.5, D19).
    state_dir.save_index(
        Index(
            chats=[ChatRecord(chat=1, folder=str(folder), session_id=None, alias=None, state="idle", created=TS, artifacts=[])],
            next_chat=2,
        )
    )
    flag = tmp_path / "ready"
    server = await served(before_first_chat=f"echo checking; test -e {flag} || {{ echo 'memory service is down' >&2; exit 3; }}")
    conn = await attach(server)
    try:
        await conn.send(dump(MessageSend(ts=TS, chat=1, id="req-send", text="go on")))
        frames = await recv_until(conn, Error)
        # v0.7: the echo goes first; the refused preflight ends that turn with an error.
        assert [type(m) for m in frames] == [
            TurnStarted, UserText, ChatState, StatusSet, StatusSet, TurnFinished, ChatState, Error
        ]
        assert isinstance(frames[5], TurnFinished) and frames[5].outcome == "error"
        assert isinstance(frames[6], ChatState) and frames[6].state == "idle"
        err = frames[-1]
        assert isinstance(err, Error)
        assert err.code == "lifecycle.before_first_chat_failed" and err.id == "req-send" and err.chat == 1
        assert "memory service is down" in err.message
        # No engine; the chat is idle again.
        assert factory.engines == []
        chat = server.registry.get(1)
        assert chat.engine is None and chat.turn == 1 and chat.state == "idle"

        # Fixed: the preflight passes once, the turn runs, and a chat.new afterwards skips it.
        flag.write_text("")
        await conn.send(dump(MessageSend(ts=TS, chat=1, text="go on")))
        frames = await recv_until(conn, TurnFinished)
        assert [type(m) for m in frames][:4] == [TurnStarted, UserText, ChatState, StatusSet]
        assert isinstance(frames[3], StatusSet) and frames[3].text == "checking"
        assert factory.last.started
        await recv(conn)  # idle
        await conn.send(dump(ChatNew(ts=TS, id="req-2", folder=str(folder))))
        frames = await recv_until(conn, ChatList)
        assert [type(m) for m in frames] == [ChatState, ChatList]
    finally:
        await conn.close()


async def test_no_before_first_chat_means_no_status_lines(served: Served, folder: Path) -> None:
    server = await served()
    conn = await attach(server)
    try:
        await new_chat(conn, folder)
    finally:
        await conn.close()


# --- gateway.stop -------------------------------------------------------------


async def test_gateway_stop_runs_on_stop_and_interrupts(
    served: Served, factory: EngineFactory, folder: Path, state_dir: StateDir
) -> None:
    server = await served(on_stop="echo services stopped")
    conn = await attach(server)
    number = await new_chat(conn, folder)
    engine = factory.last
    engine.script(text_delta("working away"), Block())
    await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
    await recv_until(conn, TextDelta)  # turn.started, chat.state working, the delta
    await engine.wait_blocked()

    await conn.send(dump(GatewayStop(ts=TS)))
    # The gateway says it is stopping, interrupts the running turn, then on_stop's lines arrive.
    frames: list[ServerMessage] = []
    while True:
        msg = await recv(conn)
        frames.append(msg)
        if isinstance(msg, StatusSet) and msg.text == "services stopped":
            break
    kinds = [type(m) for m in frames]
    assert isinstance(frames[0], StatusSet) and "interrupting 1 running turn" in frames[0].text
    assert TurnFinished in kinds
    finished = next(m for m in frames if isinstance(m, TurnFinished))
    assert finished.outcome == "stopped" and finished.chat == number and finished.turn == 1
    idle = frames[kinds.index(TurnFinished) + 1]
    assert isinstance(idle, ChatState) and idle.state == "idle"
    # Interrupt first, on_stop second: the deployment tears down after the agent has stopped.
    assert kinds.index(TurnFinished) < len(frames) - 1

    assert ("interrupt", None) in engine.calls and engine.closed
    await asyncio.wait_for(server.stopping.wait(), 5)
    assert state_dir.load_index().chats[0].state == "idle"

    # The main loop then shuts the server down: the app is told goodbye.
    await server.shutdown()
    with pytest.raises(ConnectionClosed) as closed:
        await asyncio.wait_for(conn.recv(), 5)
    assert closed.value.rcvd is not None and closed.value.rcvd.code == 1001
    assert state_dir.read_ledger() is None


async def test_gateway_stop_during_a_hung_preflight_is_honoured_at_once(
    served: Served, factory: EngineFactory, folder: Path, tmp_path: Path
) -> None:
    # A person who hits Stop while before_first_chat hangs must not wait for
    # the command's timeout: the stop (gateway.stop here; SIGTERM takes the
    # same stop()) kills the command, the waiting chat.new is refused in
    # plain words, and shutdown does not wait on the command either.
    pid_file = tmp_path / "sleep.pid"
    server = await served(
        before_first_chat=f"sleep 30 & echo $! > {pid_file}; echo preflight; wait",
        command_timeout_seconds=60,
    )
    conn = await attach(server)
    try:
        await conn.send(dump(ChatNew(ts=TS, id="req-1", folder=str(folder))))
        first = await recv(conn)
        assert isinstance(first, StatusSet) and first.text == "preflight"
        sleep_pid = int(pid_file.read_text().strip())

        started = time.monotonic()
        await conn.send(dump(GatewayStop(ts=TS)))
        await asyncio.wait_for(server.stopping.wait(), 5)
        assert time.monotonic() - started < 5

        frames = await recv_until(conn, Error, timeout=5)
        err = frames[-1]
        assert isinstance(err, Error)
        assert err.code == "lifecycle.before_first_chat_failed" and err.id == "req-1"
        assert "stopping" in err.message
        assert len(server.registry) == 0 and factory.engines == []
        assert await _wait_gone(sleep_pid)

        started = time.monotonic()
        await asyncio.wait_for(server.shutdown(), 5)
        assert time.monotonic() - started < 5
    finally:
        await conn.close()


async def test_gateway_stop_without_on_stop_still_stops(served: Served, factory: EngineFactory, folder: Path) -> None:
    server = await served()
    conn = await attach(server)
    try:
        await new_chat(conn, folder)
        await conn.send(dump(GatewayStop(ts=TS)))
        await asyncio.wait_for(server.stopping.wait(), 5)
        assert factory.last.closed
        # Stopping twice is harmless.
        await server.stop("again")
    finally:
        await conn.close()


async def test_on_stop_failure_does_not_block_the_stop(served: Served, folder: Path) -> None:
    server = await served(on_stop="echo tearing down; exit 7")
    conn = await attach(server)
    try:
        await conn.send(dump(GatewayStop(ts=TS)))
        frames = await recv_until(conn, StatusSet)
        assert isinstance(frames[-1], StatusSet) and frames[-1].text == "tearing down"
        warning = await recv(conn)
        assert isinstance(warning, StatusSet) and "7" in warning.text
        await asyncio.wait_for(server.stopping.wait(), 5)
    finally:
        await conn.close()


# --- single instance ----------------------------------------------------------


def test_second_instance_refused(state_dir: StateDir) -> None:
    single_instance(state_dir)
    other = StateDir(state_dir.path)
    with pytest.raises(AlreadyRunning) as e:
        single_instance(other)
    assert str(state_dir.path) in str(e.value)
    state_dir.release_lock()
    single_instance(other)  # free again once the first holder lets go
    other.release_lock()


# --- the real CLI: SIGTERM, on_stop, second copy --------------------------------


async def _spawn_gateway(home: Path) -> asyncio.subprocess.Process:
    env = {**os.environ, "PORTICO_HOME": str(home)}
    return await asyncio.create_subprocess_exec(
        sys.executable,
        "-m",
        "portico_gateway",
        "run",
        cwd=str(REPO_ROOT / "gateway"),
        env=env,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )


async def test_sigterm_runs_on_stop_persists_index_clears_ledger_and_exits_zero(tmp_path: Path) -> None:
    home = tmp_path / "home"
    home.mkdir()
    marker = tmp_path / "stopped.txt"
    (home / "config.toml").write_text(f'on_stop = "echo services stopped > {marker}"\n', encoding="utf-8")

    first = await _spawn_gateway(home)
    try:
        assert first.stdout is not None
        ready = await asyncio.wait_for(first.stdout.readline(), 30)
        assert ready.startswith(b"PORTICO_READY port="), ready
        assert (home / "ledger.json").exists()

        # A second copy on the same state directory is refused, exit 1, in plain words.
        second = await _spawn_gateway(home)
        _, err = await asyncio.wait_for(second.communicate(), 30)
        assert second.returncode == 1
        assert b"already running" in err

        first.send_signal(signal.SIGTERM)
        _, err = await asyncio.wait_for(first.communicate(), 30)
        assert first.returncode == 0, err.decode(errors="replace")
    finally:
        if first.returncode is None:
            first.kill()
            await first.wait()

    assert marker.read_text().strip() == "services stopped"
    assert not (home / "ledger.json").exists()
    assert (home / "index.json").exists()


def test_single_instance_waits_out_a_status_probe_holding_the_lock_for_an_instant(state_dir: StateDir) -> None:
    import fcntl
    import threading

    # What ``status`` does while probing: take the free lock on its own descriptor, briefly.
    fd = os.open(state_dir.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    release = threading.Timer(0.12, lambda: (fcntl.flock(fd, fcntl.LOCK_UN), os.close(fd)))
    release.start()
    try:
        single_instance(state_dir)  # would be refused without the retry
    finally:
        release.join()
        state_dir.release_lock()


def test_single_instance_still_refuses_a_lock_that_stays_held(state_dir: StateDir) -> None:
    import fcntl

    fd = os.open(state_dir.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        with pytest.raises(AlreadyRunning):
            single_instance(state_dir, attempts=3, delay=0.01)
    finally:
        os.close(fd)
