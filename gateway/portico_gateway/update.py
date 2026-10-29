"""The deployment's update commands: ``[update] check`` and ``[update] run``.

Portico owns when they run (the gateway checks at start and every
``UPDATE_CHECK_SECONDS``; ``portico-gateway update`` runs the update after
stopping the gateway) and the app's window around them. The deployment owns
what they do: ``check`` exits 0 and prints the available version when there
is an update (its last non-blank line of output is the version); any other
exit, or no output, means none. Both run with ``/bin/sh -c``.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import signal

log = logging.getLogger(__name__)

SHELL = "/bin/sh"
UPDATE_CHECK_SECONDS = 6 * 60 * 60


async def check_for_update(command: str, timeout: float) -> str | None:
    """Run ``command``; the version it printed when it exited 0, else ``None``. Never raises for its failure."""
    try:
        proc = await asyncio.create_subprocess_exec(
            SHELL, "-c", command,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as e:
        log.warning("update check could not start: %s", e)
        return None
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except TimeoutError:
        _kill(proc.pid)
        await proc.wait()
        log.warning("update check did not finish within %gs and was stopped", timeout)
        return None
    except asyncio.CancelledError:
        _kill(proc.pid)  # the gateway is stopping: leave nothing behind
        raise
    if proc.returncode != 0:
        if proc.returncode != 1:
            tail = err.decode(errors="replace").strip().splitlines()[-1:] or [""]
            log.info("update check exited %s: %s", proc.returncode, tail[0])
        return None
    lines = [line.strip() for line in out.decode(errors="replace").splitlines() if line.strip()]
    return lines[-1] if lines else None


def _kill(pid: int) -> None:
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(pid, signal.SIGKILL)
