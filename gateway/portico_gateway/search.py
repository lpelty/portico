"""``files.search``: Spotlight under a root, unless a plug-in searches instead.

The default asks Spotlight (``mdfind -onlyin <root> <query>``), so the
gateway keeps no index of its own. Every hit — Spotlight's or a
plug-in's — is cleaned the same way: made relative to the root, dropped
when it leaves the root or passes through a hidden entry, de-duplicated,
names that match the query first, at most ``SEARCH_LIMIT``.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import signal
from collections.abc import Awaitable, Callable, Iterable
from pathlib import Path

from .messages import Hit, ProtocolError

SEARCH_TIMEOUT_SECONDS = 5.0
SEARCH_LIMIT = 50

# ``runner(argv, timeout) -> stdout``; replaceable so tests never need Spotlight.
Runner = Callable[[list[str], float], Awaitable[str]]


async def run_command(argv: list[str], timeout: float) -> str:
    """Run ``argv`` (no shell) and return its stdout; ``files.search_failed`` on timeout or failure."""
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as e:
        raise ProtocolError("files.search_failed", f"search could not run {argv[0]}: {e}") from e
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout)
    except TimeoutError:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGKILL)
        await proc.wait()
        raise ProtocolError("files.search_failed", f"search timed out after {timeout:g}s") from None
    if proc.returncode != 0:
        raise ProtocolError("files.search_failed", f"{argv[0]} exited with code {proc.returncode}")
    return out.decode("utf-8", errors="replace")


def _relative(base: str, raw: str) -> str | None:
    """``raw`` (absolute, or relative to ``base``) as a clean path under ``base``; ``None`` when it is not one."""
    raw = raw.strip()
    if not raw:
        return None
    full = os.path.normpath(raw if os.path.isabs(raw) else os.path.join(base, raw))
    if not full.startswith(base.rstrip(os.sep) + os.sep):
        return None
    rel = full[len(base.rstrip(os.sep)) + 1 :]
    if not rel or any(part.startswith(".") for part in rel.split(os.sep)):
        return None
    return Path(rel).as_posix()


def _name_matches(rel: str, query: str) -> bool:
    name = rel.rsplit("/", 1)[-1].casefold()
    return all(word in name for word in query.casefold().split())


def clean_hits(base: Path, hits: Iterable[Hit], query: str) -> list[Hit]:
    """Hits under ``base`` only, relative, hidden entries dropped, name matches first, capped."""
    root = str(base)
    seen: set[str] = set()
    named: list[Hit] = []
    other: list[Hit] = []
    for hit in hits:
        rel = _relative(root, hit.path)
        if rel is None or rel in seen:
            continue
        seen.add(rel)
        (named if _name_matches(rel, query) else other).append(Hit(path=rel, snippet=hit.snippet))
    return (named + other)[:SEARCH_LIMIT]


async def search_files(root: Path, query: str, runner: Runner = run_command) -> list[Hit]:
    """Spotlight's hits for ``query`` under ``root``. A blank query finds nothing and runs nothing."""
    if not query.strip():
        return []
    base = Path(root).resolve()
    out = await runner(["mdfind", "-onlyin", str(base), query], SEARCH_TIMEOUT_SECONDS)
    return clean_hits(base, (Hit(path=line) for line in out.splitlines()), query)
