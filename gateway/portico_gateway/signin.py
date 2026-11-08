"""v0.25 §4 (PORT-3): a turn that fails on an expired sign-in waits, then carries on by itself.

This module knows the sign-in kinds (``aws-sso``, ``claude``), which one a
failed turn's error detail names, how each is known current again, and how
the card's Open sign-in page command runs. The server owns the wait itself.

Nothing here reads or prints a token. The SSO token cache is read for an
``accessToken``'s presence, its ``startUrl`` and its ``expiresAt``; the
sign-in command's output is read for a URL and a code, which go to the app
and are never logged. Neither is a check command's output.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import re
import shlex
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import TYPE_CHECKING, Literal

from .mcp_inventory import cli_path

if TYPE_CHECKING:
    from .config import Config

log = logging.getLogger(__name__)

__all__ = [
    "SIGNIN_EXPIRED",
    "SigninKind",
    "claude_status_current",
    "cli_path",
    "command_current",
    "is_current",
    "kinds_for",
    "match_kind",
    "parse_signin_link",
    "poll_interval",
    "sso_cache_current",
]

# ``turn.finished.reason`` for a turn that ended on an expired sign-in.
SIGNIN_EXPIRED = "signin.expired"

KindName = Literal["aws-sso", "claude"]

TITLE = "Sign in again to continue"
_CARRIES_ON = "Sign in in your browser; this conversation carries on by itself when you're done."
AWS_BODY = f"Your sign-in to AWS has run out. {_CARRIES_ON}"
CLAUDE_BODY = f"Your Claude sign-in has run out. {_CARRIES_ON}"

# Ruling 19: regular expressions, searched case-insensitively. ``cloud_credential_error``
# is the SDK's structured code for an AWS (or Google Cloud) credential failure.
AWS_PATTERNS: tuple[str, ...] = ("cloud_credential_error", "Could not load AWS credentials", "SSO session .* has expired")
# ``authentication_failed`` is ``AssistantMessage.error``'s own value, matched whole.
CLAUDE_PATTERNS: tuple[str, ...] = (
    "^authentication_failed$",
    "Login expired",
    "OAuth token revoked",
    "OAuth token has expired",
    "Not logged in",
)

SSO_CACHE_INTERVAL = 5.0
COMMAND_INTERVAL = 10.0
# How long one check command may run before it counts as "not yet".
CHECK_TIMEOUT = 30.0


@dataclass(frozen=True)
class SigninKind:
    """One kind of sign-in: what names it in an error, how it is known current again, how the card words it."""

    name: KindName
    patterns: tuple[str, ...]
    # A command that exits 0 when the sign-in is current; None: the AWS SSO token cache.
    check: str | None
    # The command the card's Open sign-in page runs; None: no button.
    open: str | None
    title: str
    body: str
    sso_start_url: str | None
    # Its open command reads a code pasted from the browser on its standard input.
    wants_code: bool


def kinds_for(config: Config) -> list[SigninKind]:
    """The sign-in kinds, ``aws-sso`` first (ruling 19), with ``[signin.*]`` over the defaults (ruling 9)."""
    aws = config.signin.aws_sso
    claude = config.signin.claude
    cli = shlex.quote(cli_path())
    return [
        SigninKind(
            name="aws-sso",
            patterns=tuple(aws.patterns) if aws.patterns is not None else AWS_PATTERNS,
            check=aws.check,
            open=aws.open,
            title=aws.title or TITLE,
            body=aws.body or AWS_BODY,
            sso_start_url=aws.sso_start_url,
            wants_code=False,
        ),
        SigninKind(
            name="claude",
            patterns=tuple(claude.patterns) if claude.patterns is not None else CLAUDE_PATTERNS,
            check=claude.check or f"{cli} auth status",
            open=claude.open or f"{cli} auth login",
            title=claude.title or TITLE,
            body=claude.body or CLAUDE_BODY,
            sso_start_url=None,
            wants_code=True,
        ),
    ]


def match_kind(detail: Sequence[str], kinds: Sequence[SigninKind]) -> SigninKind | None:
    """The first kind (in ``kinds`` order) one of whose patterns is found in a piece of ``detail``."""
    for kind in kinds:
        for pattern in kind.patterns:
            try:
                compiled = re.compile(pattern, re.IGNORECASE)
            except re.error:
                continue
            if any(compiled.search(piece) for piece in detail):
                return kind
    return None


def poll_interval(kind: SigninKind) -> float:
    """Seconds between checks while waiting: 5 for the SSO token cache, 10 for a command."""
    return COMMAND_INTERVAL if kind.check else SSO_CACHE_INTERVAL


# --- "current again" ----------------------------------------------------------------


def _expiry(value: object) -> datetime | None:
    """An SSO cache ``expiresAt`` (``2026-11-08T20:00:00Z`` or ``…UTC``) as an aware time; None if unreadable."""
    if not isinstance(value, str):
        return None
    text = value.strip()
    for suffix in ("UTC", "Z"):
        if text.endswith(suffix):
            text = text[: -len(suffix)] + "+00:00"
            break
    try:
        when = datetime.fromisoformat(text)
    except ValueError:
        return None
    return when if when.tzinfo is not None else when.replace(tzinfo=UTC)


def sso_cache_current(folder: Path, since: float, start_url: str | None, now: datetime) -> bool:
    """Whether the AWS SSO token cache holds a sign-in made after ``since`` that hasn't run out.

    A file counts when it has an ``accessToken`` (present, never read), its
    ``startUrl`` is ``start_url`` (any, when that is None), its ``expiresAt``
    is later than ``now``, and it was written after ``since`` (the error).
    Unreadable and non-JSON files are skipped.
    """
    try:
        files = sorted(Path(folder).glob("*.json"))
    except OSError:
        return False
    for path in files:
        try:
            if path.stat().st_mtime <= since:
                continue
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError, UnicodeDecodeError):
            continue
        if not isinstance(data, dict) or not data.get("accessToken"):
            continue
        if start_url is not None and data.get("startUrl") != start_url:
            continue
        expires = _expiry(data.get("expiresAt"))
        if expires is not None and expires > now:
            return True
    return False


async def _run_check(command: str) -> tuple[int, str]:
    """Run a check command in a shell; its exit code and standard output (never logged). -1 when it can't run or times out."""
    try:
        proc = await asyncio.create_subprocess_shell(
            command, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL
        )
    except OSError:
        return -1, ""
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), CHECK_TIMEOUT)
    except TimeoutError:
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        with contextlib.suppress(Exception):
            await proc.wait()
        return -1, ""
    return proc.returncode if proc.returncode is not None else -1, out.decode("utf-8", "replace")


async def command_current(command: str) -> bool:
    """Whether a check command exits 0."""
    code, _ = await _run_check(command)
    return code == 0


def claude_status_current(code: int, stdout: str) -> bool:
    """``claude auth status``: exit 0, and its JSON's ``authMethod`` is ``claude.ai`` (or the output isn't JSON) (ruling 20)."""
    if code != 0:
        return False
    try:
        data = json.loads(stdout)
    except ValueError:
        return True
    if not isinstance(data, dict):
        return True
    return data.get("authMethod") == "claude.ai"


async def is_current(kind: SigninKind, since: float, sso_folder: Path) -> bool:
    """Whether ``kind``'s sign-in is current again: its check command, or (none) the SSO token cache."""
    if kind.check:
        code, out = await _run_check(kind.check)
        if kind.name == "claude":
            return claude_status_current(code, out)
        return code == 0
    return await asyncio.to_thread(sso_cache_current, sso_folder, since, kind.sso_start_url, datetime.now(UTC))


# --- the link and code ----------------------------------------------------------------

_URL = re.compile(r"https://[^\s<>\"']+")
# A one-time code: two or more groups of capitals and digits, joined by hyphens ("QKXW-RTBN").
_CODE = re.compile(r"(?<![A-Za-z0-9-])[A-Z0-9]{4,}(?:-[A-Z0-9]{4,})+(?![A-Za-z0-9-])")


def parse_signin_link(lines: Sequence[str]) -> tuple[str | None, str | None]:
    """The first ``https://`` URL and the first code-shaped token in a sign-in command's output (§4.6)."""
    url: str | None = None
    code: str | None = None
    for line in lines:
        if url is None:
            found = _URL.search(line)
            if found:
                url = found.group(0).rstrip(".,;:)")
        if code is None:
            found_code = _CODE.search(_URL.sub(" ", line))
            if found_code:
                code = found_code.group(0)
    return url, code
