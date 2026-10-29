"""Generated session titles (v0.8): a few words from a small model after the first turn.

After a session's first turn finishes ``done`` the gateway asks for a
title of at most ``TITLE_WORDS`` words, from the first message and the
first ``REPLY_CHARS`` characters of the first reply. The session keeps its
first-line title (``chats.title_from``) until the answer arrives, and for
good when the call fails or takes longer than ``TITLE_TIMEOUT`` seconds.

The call goes through the Agent SDK's one-shot ``query``, so it reaches the
same provider with the same credentials as the agent (the environment's):
no tools, one turn, no settings files (so none of a folder's instructions,
hooks or servers run for it), from the state directory (so the call's own
transcript never shows among a folder's sessions). The model is
``title_model`` when the config sets one, else the alias ``haiku``, which
the engine resolves to the provider's small model (a hosted provider maps
it with ``ANTHROPIC_DEFAULT_HAIKU_MODEL``).

``Titler`` is the seam: ``(prompt, model) -> raw text``. The server is
handed ``sdk_titler``; tests hand it a function, so no test needs a model.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from pathlib import Path

log = logging.getLogger(__name__)

TITLE_WORDS = 6
TITLE_TIMEOUT = 10.0
REPLY_CHARS = 500
# The longest first message the prompt carries.
MESSAGE_CHARS = 2000
DEFAULT_TITLE_MODEL = "haiku"

Titler = Callable[[str, str], Awaitable[str]]

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
) -> str | None:
    """A title for the session, or ``None`` (logged) when the call fails, times out or says nothing usable."""
    try:
        raw = await asyncio.wait_for(titler(title_prompt(first_message, reply), model or DEFAULT_TITLE_MODEL), timeout)
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


def sdk_titler(cwd: Path) -> Titler:
    """A ``Titler`` on the Agent SDK's one-shot ``query``, run from ``cwd`` (the state directory)."""

    async def titler(prompt: str, model: str) -> str:
        from claude_agent_sdk import AssistantMessage, ClaudeAgentOptions, ResultMessage, TextBlock, query

        options = ClaudeAgentOptions(
            model=model,
            system_prompt=SYSTEM_PROMPT,
            tools=[],
            max_turns=1,
            setting_sources=[],
            mcp_servers={},
            strict_mcp_config=True,
            cwd=str(cwd),
        )
        parts: list[str] = []
        result: str | None = None
        async for message in query(prompt=prompt, options=options):
            if isinstance(message, AssistantMessage):
                parts.extend(block.text for block in message.content if isinstance(block, TextBlock))
            elif isinstance(message, ResultMessage):
                if message.is_error:
                    raise RuntimeError(f"the model answered with an error ({message.subtype})")
                result = message.result
        return "".join(parts) or (result or "")

    return titler
