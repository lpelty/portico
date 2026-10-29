"""Lifecycle: the deployment's commands, one gateway per state directory, stop signals.

A deployment points ``before_first_chat`` and ``on_stop`` in ``config.toml``
at its own preflight and shutdown; the gateway runs them through the shell,
streams their output line by line (the server sends each as ``status.set``),
and bounds them with ``command_timeout_seconds``. Nothing here knows what a
deployment does in them.

``run_command`` gives the command its own process group so a timeout can
kill everything it started, and it stops reading once the command itself
has exited: a preflight that leaves a service running in the background
(which inherits the pipe) must not be held until the timeout for it. That
is why it drives a ``SubprocessProtocol`` directly rather than
``asyncio.subprocess.Process.wait()``, which only returns once every pipe
has closed.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import signal
import time
from collections.abc import Awaitable, Callable
from typing import Any

from .state import StateDir

log = logging.getLogger(__name__)

OnLine = Callable[[str], Awaitable[None]]

# After the command exits, how long its pipe is still read for trailing
# output before a background child holding it open is given up on.
DRAIN_SECONDS = 0.5
# After killing the group, how long to wait for the shell to be reaped.
REAP_SECONDS = 5.0
# Longest output line kept; anything longer is cut there.
LINE_LIMIT = 1 << 20


class AlreadyRunning(RuntimeError):
    """Another gateway holds the lock on this state directory."""


class CommandFailed(RuntimeError):
    """A lifecycle command finished non-zero or timed out; ``last_line`` is what it said last."""

    def __init__(self, message: str, last_line: str | None) -> None:
        super().__init__(message)
        self.last_line = last_line


class _LineProtocol(asyncio.SubprocessProtocol):
    """Splits the merged output into lines on a queue; ``exited`` is set when the process itself exits."""

    def __init__(self) -> None:
        self.lines: asyncio.Queue[str | None] = asyncio.Queue()
        self.exited = asyncio.Event()
        self._buf = bytearray()
        self._eof = False

    def pipe_data_received(self, fd: int, data: bytes) -> None:
        self._buf.extend(data)
        while True:
            cut = self._buf.find(b"\n")
            if cut < 0:
                break
            raw = bytes(self._buf[:cut])
            del self._buf[: cut + 1]
            self._put(raw)
        if len(self._buf) > LINE_LIMIT:
            self._put(bytes(self._buf[:LINE_LIMIT]))
            del self._buf[:]

    def pipe_connection_lost(self, fd: int, exc: Exception | None) -> None:
        if self._buf:
            self._put(bytes(self._buf))
            del self._buf[:]
        if not self._eof:
            self._eof = True
            self.lines.put_nowait(None)

    def process_exited(self) -> None:
        self.exited.set()

    def _put(self, raw: bytes) -> None:
        line = raw.decode("utf-8", errors="replace").rstrip("\r")
        if line.strip():
            self.lines.put_nowait(line)


def _kill_group(pid: int) -> None:
    """SIGKILL the command's process group (its pid, thanks to ``start_new_session``)."""
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(pid, signal.SIGKILL)


async def run_command(command: str, on_line: OnLine, timeout: float) -> int:
    """Run ``command`` through the shell; ``await on_line(line)`` for each output line; return its exit code.

    stdout and stderr are merged, in order. Blank lines are skipped. On
    ``timeout`` seconds the whole process group is killed and
    ``TimeoutError`` is raised; the lines already seen were delivered.
    """
    loop = asyncio.get_running_loop()
    transport: asyncio.SubprocessTransport
    protocol: _LineProtocol
    transport, protocol = await loop.subprocess_shell(  # type: ignore[assignment]
        _LineProtocol,
        command,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        start_new_session=True,
    )
    pid = transport.get_pid()

    async def pump() -> None:
        while True:
            line = await protocol.lines.get()
            if line is None:
                return
            await on_line(line)

    pump_task = asyncio.create_task(pump(), name="portico-command-output")
    try:
        async with asyncio.timeout(timeout):
            await protocol.exited.wait()
            try:
                await asyncio.wait_for(pump_task, DRAIN_SECONDS)
            except TimeoutError:
                # The command is done but something it started still holds the pipe.
                log.debug("lifecycle command exited; a background child kept its output open")
        code = transport.get_returncode()
        return code if code is not None else -1
    except BaseException:
        if not protocol.exited.is_set():
            _kill_group(pid)
            with contextlib.suppress(Exception):
                await asyncio.wait_for(protocol.exited.wait(), REAP_SECONDS)
        raise
    finally:
        if not pump_task.done():
            pump_task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await pump_task
        transport.close()


async def run_lifecycle_command(name: str, command: str, on_line: OnLine, timeout: float) -> None:
    """Run one of the deployment's commands; raise ``CommandFailed`` with the last line on non-zero or timeout."""
    last: str | None = None

    async def seen(line: str) -> None:
        nonlocal last
        last = line
        log.info("%s: %s", name, line)
        await on_line(line)

    try:
        code = await run_command(command, seen, timeout)
    except TimeoutError:
        raise CommandFailed(
            f"the {name} command did not finish within {timeout:g} seconds and was stopped"
            + (f"; its last line was: {last}" if last else ""),
            last,
        ) from None
    if code != 0:
        raise CommandFailed(
            f"the {name} command failed (exit code {code})" + (f": {last}" if last else ""),
            last,
        )


# A ``status`` probe takes the free lock for an instant; a gateway starting in
# that instant tries again this many times, this far apart, before it says
# another gateway runs.
LOCK_ATTEMPTS = 10
LOCK_RETRY_SECONDS = 0.05


def single_instance(state: StateDir, attempts: int = LOCK_ATTEMPTS, delay: float = LOCK_RETRY_SECONDS) -> None:
    """Take the gateway lock on ``state``; ``AlreadyRunning`` when another gateway holds it.

    A lock held only for a moment (``status`` probing it) is waited out:
    up to ``attempts`` tries, ``delay`` seconds apart.
    """
    for attempt in range(max(1, attempts)):
        if state.acquire_lock():
            return
        if attempt + 1 < attempts:
            time.sleep(delay)
    raise AlreadyRunning(f"another gateway is already running on {state.path}")


def install_stop_signals(loop: asyncio.AbstractEventLoop, on_signal: Callable[[str], Any]) -> None:
    """SIGINT and SIGTERM call ``on_signal(name)``; a second signal goes through the same (idempotent) path."""
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, on_signal, sig.name)
