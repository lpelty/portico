"""The deployment's update commands: ``[update] check`` and ``[update] run``.

Portico owns when they run (the gateway checks at start and every
``UPDATE_CHECK_SECONDS``; ``portico-gateway update`` runs the update after
stopping the gateway) and the app's window around them. The deployment owns
what they do: ``check`` exits 0 and prints the available version when there
is an update (its last non-blank line of output is the version); exit 1,
or exit 0 with no output, means none; any other exit, a timeout, or a
command that cannot start is a failed check. Both run with ``/bin/sh -c``.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import signal
from dataclasses import dataclass

log = logging.getLogger(__name__)

SHELL = "/bin/sh"
UPDATE_CHECK_SECONDS = 6 * 60 * 60


@dataclass(frozen=True)
class CheckResult:
    """What one run of the check said: a ``version`` (an update), ``error`` (the check failed), or neither (none)."""

    version: str | None = None
    error: str | None = None


async def run_check(command: str, timeout: float) -> CheckResult:
    """Run ``command`` and say what it meant. Never raises for its failure.

    Exit 0 with output: an update (the last non-blank line is the version);
    exit 0 without output, or exit 1: none. Anything else — another exit
    code, a timeout, a check that cannot start — is a failed check, with
    the reason in ``error``.
    """
    try:
        proc = await asyncio.create_subprocess_exec(
            SHELL, "-c", command,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as e:
        return CheckResult(error=f"the update check could not start: {e}")
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except TimeoutError:
        _kill(proc.pid)
        await proc.wait()
        return CheckResult(error=f"the update check did not finish within {timeout:g}s and was stopped")
    except asyncio.CancelledError:
        _kill(proc.pid)  # the gateway is stopping: leave nothing behind
        raise
    if proc.returncode == 1:
        return CheckResult()
    if proc.returncode != 0:
        tail = err.decode(errors="replace").strip().splitlines()[-1:] or [""]
        reason = f"the update check exited {proc.returncode}" + (f": {tail[0]}" if tail[0] else "")
        return CheckResult(error=reason)
    lines = [line.strip() for line in out.decode(errors="replace").splitlines() if line.strip()]
    return CheckResult(version=lines[-1] if lines else None)


async def check_for_update(command: str, timeout: float) -> str | None:
    """Run ``command``; the version it printed when it exited 0, else ``None``. A failure is logged, never raised."""
    result = await run_check(command, timeout)
    if result.error is not None:
        log.warning("%s", result.error)
    return result.version


def _kill(pid: int) -> None:
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(pid, signal.SIGKILL)
