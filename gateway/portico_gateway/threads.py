"""Threads' copy and pure helpers (v0.16).

A thread is another conversation with the same agent, opened from Main.
Main's agent proposes one with the in-process ``open_thread`` tool; the
person starts it (or not) from the card the app draws. The words the agent
reads (its system-prompt line, the tool's description and answers) live
here, fixed by the spec and the plan's rulings.
"""

from __future__ import annotations


# Appended to Main's system prompt when threads are on.
MAIN_PROMPT = (
    "When the person wants work done separately, alongside this conversation, call open_thread with a brief "
    "of one or two sentences and any files it should start with. It proposes a thread; the person decides "
    "whether to start it, and you won't see what it does."
)

# Appended to a thread's system prompt; ``{n}`` is its slot (``thread_prompt``).
THREAD_PROMPT = (
    "This is Thread {n}, opened from the person's main conversation for the brief below. "
    "Work on it here; the person answers here."
)

TOOL_DESCRIPTION = (
    "Propose a thread: another conversation with the person, alongside this one, for work they want done "
    "separately. Give a brief of one or two sentences and the files it should start with. Returns at once; "
    "the person starts it or not."
)

# Every refusal the tool answers starts with this; the tool marks it ``is_error``.
REFUSAL_PREFIX = "Not proposed: "
EMPTY_BRIEF = f"{REFUSAL_PREFIX}give a brief of one or two sentences."

# The close routine's lines in the thread's conversation (plan ruling 13).
CLOSE_LOGGING = "Close — logging, then closing this thread"
CLOSE_PLAIN = "Close — closing this thread"
CLOSED = "Thread closed"
# A thread whose brief could not be sent (a file gone since the proposal) says so, then why.
BRIEF_NOT_SENT = "The brief wasn't sent"

# Refusals (``error.message``) whose words the plan fixes.


def _open_count(limit: int) -> str:
    """How many threads are open at the limit, in words: "a thread is" or "two threads are"."""
    return "a thread is" if limit == 1 else "two threads are"


def limit_message(limit: int) -> str:
    """``thread.limit``'s message at ``[threads] max`` = ``limit``."""
    return f"{_open_count(limit)} open; close {'it' if limit == 1 else 'one'} to start another"
RENEW_MESSAGE = "a thread closes rather than renews; close it with thread.close"


def use_key(brief: object, files: object) -> tuple[str, tuple[str, ...]]:
    """An ``open_thread`` call's input as both the hook and the tool see it (brief and files, trimmed).

    The hook hears the call's ``tool_use_id`` with its raw input; the tool's
    handler hears the input without the id. This key ties the two together.
    """
    text = brief.strip() if isinstance(brief, str) else ""
    paths = tuple(f.strip() for f in files if isinstance(f, str) and f.strip()) if isinstance(files, list) else ()
    return text, paths


def thread_label(slot: int) -> str:
    """"Thread 1", "Thread 2"."""
    return f"Thread {slot}"


def thread_prompt(slot: int) -> str:
    """``THREAD_PROMPT`` for the thread in ``slot``."""
    return THREAD_PROMPT.format(n=slot)


def proposed_text(slot: int | None, limit: int = 2) -> str:
    """What ``open_thread`` answers: the slot the thread would take, or (``None``) that the limit is reached."""
    if slot is None:
        return f"Proposed; {_open_count(limit)} open, so the person picks one to close before it starts."
    return f"Proposed as {thread_label(slot)}; it opens if the person starts it."


def not_a_file(path: str) -> str:
    """The tool's refusal for a ``files`` entry that is not a file."""
    return f"{REFUSAL_PREFIX}{path} isn't a file."
