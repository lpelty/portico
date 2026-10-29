"""Generated session titles (v0.8): a few words from a small model after the first turn.

After a session's first turn finishes ``done`` the gateway asks for a
title of at most ``TITLE_WORDS`` words, from the first message and the
first ``REPLY_CHARS`` characters of the first reply. The session keeps its
first-line title (``chats.title_from``) until the answer arrives, and for
good when the call fails or takes longer than ``TITLE_TIMEOUT`` seconds.

The call goes through the Agent SDK's one-shot ``query``, so it reaches the
same provider with the same credentials as the agent: the gateway's
environment, plus the ``env`` blocks of the settings files the agent reads
(``setting_sources``: user, then the session folder's project and local
settings, later ones winning), passed as the call's own environment. The
settings files themselves are not loaded (``setting_sources=[]``), so none
of a folder's instructions, hooks or servers run for it; no tools, one
turn, from the state directory (so the call's own transcript never shows
among a folder's sessions). Only ``env`` is carried over: a provider set up
through another settings key (an API key helper, a cloud credential
refresh) reaches the agent but not the title call. The model is
``title_model`` when the config sets one, else the alias ``haiku``, which
the engine resolves to the provider's small model (a hosted provider maps
it with ``ANTHROPIC_DEFAULT_HAIKU_MODEL``).

``Titler`` is the seam: ``(prompt, model, folder) -> raw text``. The server
is handed ``sdk_titler``; tests hand it a function, so no test needs a model.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
from collections.abc import Awaitable, Callable, Iterable
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

TITLE_WORDS = 6
TITLE_TIMEOUT = 20.0
REPLY_CHARS = 500
# The longest first message the prompt carries.
MESSAGE_CHARS = 2000
DEFAULT_TITLE_MODEL = "haiku"

# ``(prompt, model, the session's folder or None) -> raw text``.
Titler = Callable[[str, str, Path | None], Awaitable[str]]

SYSTEM_PROMPT = (
    "You name conversations. Answer with a title only: at most six words, "
    "no quotes, no trailing punctuation, nothing else."
)

_QUOTES = "\"'`“”‘’«»"
_TRAILING = " .,;:!?-–—…" + _QUOTES


def title_prompt(first_message: str, reply: str) -> str:
    """What the model is asked: the first message and the start of the first reply."""
    message = first_message.strip()[:MESSAGE_CHARS]
    answer = reply.strip()[:REPLY_CHARS]
    return (
        f"Write a title of at most {TITLE_WORDS} words for this conversation.\n\n"
        f"<first_message>\n{message}\n</first_message>\n\n"
        f"<first_reply_start>\n{answer}\n</first_reply_start>\n\n"
        "Title:"
    )


def clean_title(raw: str) -> str | None:
    """The model's answer as a title: its first non-blank line, unquoted, at most ``TITLE_WORDS`` words.

    A leading ``Title:``, Markdown emphasis or heading marks, surrounding
    quotes and trailing punctuation go; ``None`` when nothing is left.
    """
    for line in raw.splitlines():
        line = line.strip().lstrip("#").strip()
        if line.lower().startswith("title:"):
            line = line[len("title:") :].strip()
        line = line.replace("**", "").replace("__", "").strip()
        line = line.strip(_QUOTES).strip()
        words = line.split()
        if not words:
            continue
        title = " ".join(words[:TITLE_WORDS]).rstrip(_TRAILING).lstrip(_QUOTES).strip()
        if title:
            return title
    return None


async def generate_title(
    titler: Titler,
    first_message: str,
    reply: str,
    model: str | None = None,
    timeout: float = TITLE_TIMEOUT,
    folder: Path | None = None,
) -> str | None:
    """A title for the session, or ``None`` (logged) when the call fails, times out or says nothing usable."""
    try:
        raw = await asyncio.wait_for(
            titler(title_prompt(first_message, reply), model or DEFAULT_TITLE_MODEL, folder), timeout
        )
    except TimeoutError:
        log.warning("title: no answer within %g s; keeping the first line", timeout)
        return None
    except Exception as e:
        log.warning("title: the call failed (%s: %s); keeping the first line", type(e).__name__, e)
        return None
    title = clean_title(raw or "")
    if title is None:
        log.warning("title: the answer had no title in it; keeping the first line")
    return title


def _settings_files(sources: Iterable[str], folder: Path | None) -> list[Path]:
    """The settings files ``sources`` name, lowest precedence first: user, then project, then local."""
    home = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude").expanduser()
    wanted = set(sources)
    files: list[Path] = []
    if "user" in wanted:
        files.append(home / "settings.json")
    if folder is not None:
        if "project" in wanted:
            files.append(folder / ".claude" / "settings.json")
        if "local" in wanted:
            files.append(folder / ".claude" / "settings.local.json")
    return files


def settings_env(sources: Iterable[str], folder: Path | None) -> dict[str, str]:
    """The ``env`` the agent's settings files give it, merged (a later file wins); text values only.

    ``sources`` is the config's ``setting_sources``; project and local are
    read from ``folder`` (none without one). A file that is missing or not
    a JSON object is skipped.
    """
    env: dict[str, str] = {}
    for path in _settings_files(sources, folder):
        try:
            data: Any = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            continue
        except (OSError, ValueError) as e:
            log.warning("title: %s could not be read for its env (%s); skipping it", path, e)
            continue
        block = data.get("env") if isinstance(data, dict) else None
        if isinstance(block, dict):
            env.update({k: v for k, v in block.items() if isinstance(k, str) and isinstance(v, str)})
    return env


def sdk_titler(cwd: Path, setting_sources: Iterable[str] = (), query: Callable[..., Any] | None = None) -> Titler:
    """A ``Titler`` on the Agent SDK's one-shot ``query``, run from ``cwd`` (the state directory).

    Each call carries the ``env`` of the agent's ``setting_sources`` for the
    session's folder (``settings_env``) and loads no settings file itself.
    ``query`` is the SDK's unless a test hands in its own.
    """
    sources = list(setting_sources)

    async def titler(prompt: str, model: str, folder: Path | None) -> str:
        from claude_agent_sdk import AssistantMessage, ClaudeAgentOptions, ResultMessage, TextBlock
        from claude_agent_sdk import query as sdk_query

        options = ClaudeAgentOptions(
            model=model,
            system_prompt=SYSTEM_PROMPT,
            tools=[],
            max_turns=1,
            setting_sources=[],
            mcp_servers={},
            strict_mcp_config=True,
            cwd=str(cwd),
            env=settings_env(sources, folder),
        )
        parts: list[str] = []
        result: str | None = None
        # Closed on every way out (an error answer, a timeout's cancel), so
        # the engine process is not left to the garbage collector.
        async with contextlib.aclosing((query or sdk_query)(prompt=prompt, options=options)) as messages:
            async for message in messages:
                if isinstance(message, AssistantMessage):
                    parts.extend(block.text for block in message.content if isinstance(block, TextBlock))
                elif isinstance(message, ResultMessage):
                    if message.is_error:
                        raise RuntimeError(f"the model answered with an error ({message.subtype})")
                    result = message.result
                    break
        return "".join(parts) or (result or "")

    return titler
