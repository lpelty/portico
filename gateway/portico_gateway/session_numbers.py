"""The next session's number from the deployment (v0.11 decision 5, item 55).

A deployment that numbers its own sessions (a session log, a counter of
its own) sets ``[sessions] next_number`` to a command whose stdout is the
number the next session should have. The gateway runs it with ``/bin/sh
-c`` when a new session starts, bounded by ``NEXT_NUMBER_TIMEOUT`` seconds,
the same way it runs ``[deployment] status``.

Numbers are never reused, so a number below Portico's own next one is not
taken. Anything that does not give a usable number (the command fails, times
out, prints something that is not a whole number above zero, or a number
already passed) falls back to Portico's own counter, with one log line
saying why. Portico never knows what the number means.
"""

from __future__ import annotations

import logging

from .lifecycle import run_command

log = logging.getLogger(__name__)

# How long the command may take before Portico counts for itself.
NEXT_NUMBER_TIMEOUT = 2.0


class NoNumber(Exception):
    """The command gave no usable number; the message is why, one line."""


async def number_from_command(command: str, timeout: float = NEXT_NUMBER_TIMEOUT) -> int:
    """Run ``command``; its stdout as a whole number above zero, or ``NoNumber`` saying why."""
    out: list[str] = []
    err: list[str] = []

    async def seen(line: str) -> None:
        out.append(line)

    async def said(line: str) -> None:
        err.append(line)

    try:
        code = await run_command(command, seen, timeout, on_stderr=said)
    except TimeoutError:
        raise NoNumber(f"timed out after {timeout:g} s") from None
    except OSError as e:
        raise NoNumber(f"could not start: {e}") from None
    if code != 0:
        last = (err or out or [None])[-1]
        raise NoNumber(f"exited {code}" + (f": {last.strip()[:200]}" if last else ""))
    text = "\n".join(out).strip()
    try:
        number = int(text)
    except ValueError:
        raise NoNumber(f"printed {text[:80]!r}, not a whole number") from None
    if number < 1:
        raise NoNumber(f"printed {number}, not a number above zero")
    return number


async def next_session_number(command: str | None, portico_next: int, timeout: float = NEXT_NUMBER_TIMEOUT) -> int:
    """The number the next session gets: the command's, when it gives one at or above ``portico_next``; else ``portico_next``."""
    if not command:
        return portico_next
    try:
        number = await number_from_command(command, timeout)
    except NoNumber as e:
        log.warning("sessions.next_number %s; using Portico's own number %d", e, portico_next)
        return portico_next
    if number < portico_next:
        log.warning(
            "sessions.next_number printed %d, below Portico's next number %d (numbers are never reused); using %d",
            number, portico_next, portico_next,
        )
        return portico_next
    return number
