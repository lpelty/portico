"""Cards: the gateway's side of every question the engine puts to the person.

A permission request or a question from the engine becomes a ``card.ask``
on the chat; the engine's call blocks until the app answers, the card is
cancelled (``turn.stop``, ``chat.stop``, ``chat.remove``, gateway stop), or
nobody was there to answer. The ``CardBroker`` holds the open cards and
turns the app's ``card.answer`` into the decision the engine callbacks
expect:

- permission ``allow`` with scope ``once`` → ``"allow"``; scope ``chat`` (the
  app's "Allow for this session") →
  an allow key joins ``chat.chat_allows`` and later asks it covers in that
  chat answer ``"allow"`` without a card — the tool name; for a file edit
  inside the session folder all four file-editing tool names at once
  (their cards ask the same question), which cover edits inside the
  folder only, and outside it ``Edit(<real path>)``, that one file; for a
  command tool (``Bash``) the engine's own suggested rule
  (``Bash(git status:*)``) or, without one, the exact command, so one
  harmless command never allows every later one; scope ``always`` →
  ``("allow", "always")``, which the engine adapter hands to the engine's
  own settings (the gateway keeps no permanent allow store of its own);
  ``deny`` → ``("deny", note)``. The keys are kept on the chat record, so
  they last for the session, across gateway restarts (v0.3).
- question → ``{<question text>: <label> | [labels]}``, the answers the
  engine's question tool expects.

**Held cards.** While no app is attached the card stays open and the hold
clock runs; after ``hold_seconds`` the card is cancelled with the reason
``nobody was there to answer`` and the engine sees a deny (a question is
declined with that message). The clock only runs while nobody is
attached: an attached app may take as long as it likes. An app that
attaches while a card is open gets it again after ``chat.live`` on
``chat.open`` (unchanged, same id and ``seq``; the app de-duplicates by id).

Never allow by default: nothing in here answers ``allow`` without a
person's answer or a chat-scoped allow that a person gave earlier.

State words (``waiting on you`` while a card is open, ``working`` after)
are the server's business: it knows whether the turn is still running
when the card resolves.
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import shlex
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from .chats import Chat
from .engine import PermissionDecision, QuestionDeclined, summarize_tool
from .messages import CardAnswer, CardAsk, CardCancel, Option, Permission, ProtocolError, Question, ServerMessage

__all__ = [
    "NOBODY_ANSWERED",
    "CardBroker",
    "QuestionDeclined",
    "permission_card",
    "question_card",
    "title_for",
]

log = logging.getLogger(__name__)

# The reason on the ``card.cancel`` and the message the engine sees when a
# held card times out (spec §5.5; Global Constraints).
NOBODY_ANSWERED = "nobody was there to answer"

# ``send(chat, msg)`` stamps the message with the chat's next ``seq``, keeps
# it in the ring, sends it to the app if one is attached, and returns the
# stamped copy (the server's ``emit``).
Send = Callable[[Chat, ServerMessage], Awaitable[ServerMessage]]

# The longest a command may be in a card's question before it is cut.
TITLE_COMMAND_LIMIT = 60


# Tools whose input is a shell command: a chat-scoped allow for one of these
# is keyed on the command (the engine's suggested prefix rule, or the exact
# command), never on the bare tool name.
COMMAND_TOOLS: frozenset[str] = frozenset({"Bash"})

# Shell operators (and line breaks) that join commands; every part must be covered on its own.
_COMMAND_JOINERS = re.compile(r"\s*(?:&&|\|\||;|\||\n)\s*")

# What makes a part of a command more than the words a person read on the
# card: a background ``&`` (a second command), command or parameter
# substitution, backticks, and redirections (``<(…)`` too). A part holding
# any of these is never covered by a prefix rule: the card asks.
_UNSAFE_IN_PART = ("&", "$(", "${", "`", ">", "<")

# A ``cd`` argument with any of these is not a literal path: expansion,
# substitution, globbing, redirection or history. Never covered.
_UNSAFE_IN_CD = frozenset("$`<>(){}*?[~!&;|\n")

# Tools that change a file. They share one chat-scoped allow: every one of
# their cards reads "Save changes to <file>?" (or "Create <file>?"), so an
# allow for this session given on one must cover the others, or the next
# identical-looking question still shows a card.
EDIT_TOOLS: frozenset[str] = frozenset({"Write", "Edit", "MultiEdit", "NotebookEdit"})


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _new_id() -> str:
    return f"card-{uuid.uuid4().hex[:12]}"


# --- building cards --------------------------------------------------------------


def title_for(tool: str, input: dict[str, Any] | None = None, folder: Path | None = None) -> str:
    """The card title for a permission request: a plain question about the step (v0.3).

    ``Create notes.md?`` (a ``Write`` to a file that does not exist yet),
    ``Save changes to notes.md?`` (any other file edit), ``Run git status?``
    (a command's first line, cut at ``TITLE_COMMAND_LIMIT``), ``Open
    example.com?`` (a fetch), else ``Use <tool>?``. The app shows the tool
    name beside it as a tag. A relative file path is the session
    ``folder``'s (the engine works there), not the gateway's.
    """
    input = input or {}
    if tool in EDIT_TOOLS:
        path = _edit_path(input)
        if path is not None:
            name = Path(path).name or path
            target = _absolute(path, folder)
            if tool == "Write" and not target.exists():
                return f"Create {name}?"
            return f"Save changes to {name}?"
    elif tool in COMMAND_TOOLS:
        command = input.get("command")
        if isinstance(command, str) and command.strip():
            line = command.strip().split("\n", 1)[0].strip()
            if len(line) > TITLE_COMMAND_LIMIT:
                line = line[: TITLE_COMMAND_LIMIT - 1].rstrip() + "…"
            return f"Run {line}?"
    elif tool == "WebFetch":
        url = input.get("url")
        host = urlsplit(url).hostname if isinstance(url, str) else None
        if host:
            return f"Open {host}?"
    return f"Use {tool}?"


def permission_card(
    chat: int,
    tool: str,
    input: dict[str, Any],
    tool_use_id: str | None = None,
    folder: Path | None = None,
    suggestions: list[dict[str, Any]] | None = None,
) -> CardAsk:
    return CardAsk(
        ts=_now(),
        chat=chat,
        id=_new_id(),
        kind="permission",
        title=title_for(tool, input, folder),
        permission=Permission(tool=tool, summary=summarize_tool(tool, input), input=dict(input)),
        tool_use_id=tool_use_id or None,
        scope_note=scope_note_for(tool, input, folder, suggestions or []),
    )


def scope_note_for(
    tool: str, input: dict[str, Any], folder: Path | None, suggestions: list[dict[str, Any]]
) -> str | None:
    """What "Allow for this session" would cover, in words, for the line under the card's buttons.

    It says exactly what ``CardBroker.chat_allow_keys`` records, so the
    person reads the reach of the allow before giving it.
    """
    until = "until you start a new session"
    if tool in EDIT_TOOLS:
        path = _edit_path(input)
        if path is None or folder is None:
            return None
        if _inside(_absolute(path, folder), folder):
            return f"For this session: edits to files in {Path(folder).name or folder}, {until}."
        return f"For this session: changes to this file only ({_resolved(_absolute(path, folder))}), {until}."
    if tool in COMMAND_TOOLS:
        rules = _suggested_rules(tool, suggestions)
        prefixes = [rule[:-2].strip() for rule in rules if rule.endswith(":*") and rule[:-2].strip()]
        if prefixes:
            shown = ", ".join(prefixes)
            return f"For this session: commands that start with {shown}, {until}."
        return f"For this session: this exact command, {until}."
    return f"For this session: every use of {tool}, {until}."


def _edit_path(input: dict[str, Any]) -> str | None:
    path = input.get("file_path") or input.get("notebook_path")
    return path if isinstance(path, str) and path.strip() else None


def _absolute(path: str, folder: Path | None) -> Path:
    """``path`` as the engine reads it: ``~`` expanded, relative to the session folder."""
    target = Path(path).expanduser()
    if not target.is_absolute() and folder is not None:
        target = Path(folder) / target
    return target


def _resolved(path: Path) -> str:
    return os.path.realpath(path)


def _inside(target: Path, folder: Path) -> bool:
    """``target`` is the folder or below it, both lexically and with every symlink followed."""
    base_lexical = os.path.normpath(os.path.abspath(folder))
    base_real = os.path.realpath(folder)
    lexical = os.path.normpath(os.path.abspath(target))
    for path, base in ((lexical, base_lexical), (os.path.realpath(target), base_real), (os.path.realpath(lexical), base_real)):
        if path != base and not path.startswith(base.rstrip(os.sep) + os.sep):
            return False
    return True


def question_card(chat: int, questions: list[dict[str, Any]]) -> CardAsk:
    """The engine's question-tool input, mapped field for field (``multiSelect`` → ``multi_select``)."""
    mapped: list[Question] = []
    for q in questions:
        options = [
            Option(label=str(o.get("label", "")), description=str(o.get("description") or ""))
            for o in (q.get("options") or [])
            if isinstance(o, dict)
        ]
        mapped.append(
            Question(
                question=str(q.get("question", "")),
                header=str(q.get("header") or ""),
                options=options,
                multi_select=bool(q.get("multiSelect", q.get("multi_select", False))),
            )
        )
    title = next((q.header for q in mapped if q.header), None) or "A question"
    return CardAsk(ts=_now(), chat=chat, id=_new_id(), kind="question", title=title, questions=mapped)


def _rule_covers(rule: str, command: str) -> bool:
    """``prefix:*`` covers the prefix as whole words; any other rule covers exactly itself.

    A part with anything beyond plain words (``_UNSAFE_IN_PART``) is never
    covered by a prefix: ``git status $(rm -rf ~)`` is not ``git status``.
    """
    if any(mark in command for mark in _UNSAFE_IN_PART):
        return False
    if rule.endswith(":*"):
        prefix = rule[:-2].strip()
        return bool(prefix) and (command == prefix or command.startswith(prefix + " "))
    return command == rule


def _cd_inside(part: str, folder: Path) -> bool:
    """``cd <literal path>`` where the path is the folder or below it, symlinks followed.

    Only a literal path: any word with expansion, substitution, globbing,
    redirection or history characters (``_UNSAFE_IN_CD``, ``~`` included),
    an option or ``-`` (a leading ``-``), or no argument at all (``cd``
    goes home) is not covered. Quotes are fine.
    """
    if any(ch in _UNSAFE_IN_CD for ch in part):
        return False
    try:
        words = shlex.split(part)
    except ValueError:
        return False
    if len(words) != 2 or words[0] != "cd" or not words[1] or words[1].startswith("-"):
        return False
    target = Path(words[1])
    if not target.is_absolute():
        target = Path(folder) / target
    try:
        return _inside(target, Path(folder))
    except (ValueError, OSError):
        return False


def _suggested_rules(tool: str, suggestions: list[dict[str, Any]]) -> list[str]:
    """The engine's own allow-rule suggestions for ``tool`` (``git status:*`` or an exact command)."""
    rules: list[str] = []
    for suggestion in suggestions:
        if suggestion.get("type") != "addRules" or suggestion.get("behavior") != "allow":
            continue
        for rule in suggestion.get("rules") or []:
            content = rule.get("ruleContent") if isinstance(rule, dict) else None
            if rule.get("toolName") == tool and isinstance(content, str) and content.strip():
                rules.append(content.strip())
    return rules


# --- validating answers ----------------------------------------------------------


def _check_answer(card: CardAsk, answer: CardAnswer) -> None:
    """The answer must fit the card's kind; otherwise ``card.invalid_answer``."""
    body = answer.answer
    if card.kind == "permission":
        decision = body.get("decision")
        if decision not in ("allow", "deny"):
            raise ProtocolError("card.invalid_answer", 'a permission answer is {"decision": "allow" | "deny"}')
        return
    if card.kind == "question":
        answers = body.get("answers")
        if not isinstance(answers, dict) or not all(
            isinstance(k, str) and (isinstance(v, str) or (isinstance(v, list) and all(isinstance(x, str) for x in v)))
            for k, v in answers.items()
        ):
            raise ProtocolError(
                "card.invalid_answer", 'a question answer is {"answers": {<question>: <label> | [labels]}}'
            )
        return
    # form: a deployment defines the fields; the reference gateway only checks it is an object.
    if not isinstance(body, dict):
        raise ProtocolError("card.invalid_answer", "a form answer is an object of field values")


def _cancelled(card: CardAsk, reason: str) -> CardAnswer:
    """The synthetic answer a cancelled card resolves with: a deny carrying the reason."""
    return CardAnswer(ts=_now(), chat=card.chat, id=card.id, answer={"decision": "deny", "cancelled": True}, note=reason)


def _is_cancelled(answer: CardAnswer) -> bool:
    return answer.answer.get("cancelled") is True


# --- the broker ------------------------------------------------------------------


@dataclass
class _Pending:
    card: CardAsk  # the stamped card, as sent
    future: asyncio.Future[CardAnswer]


class CardBroker:
    """Open cards, their answers, and the hold while no app is attached."""

    def __init__(self, hold_seconds: float = 600) -> None:
        if hold_seconds < 0:
            raise ValueError("hold_seconds must not be negative")
        self.hold_seconds = float(hold_seconds)
        self.attached = False
        self._open: dict[int, dict[str, _Pending]] = {}
        self._attach_waiters: set[asyncio.Future[None]] = set()

    # --- attachment -----------------------------------------------------------

    def set_attached(self, attached: bool) -> None:
        """Tell the broker whether an app is attached; wakes every held card so its clock restarts or stops."""
        if attached == self.attached:
            return
        self.attached = attached
        waiters, self._attach_waiters = self._attach_waiters, set()
        for waiter in waiters:
            if not waiter.done():
                waiter.set_result(None)

    def _attach_change(self) -> asyncio.Future[None]:
        waiter: asyncio.Future[None] = asyncio.get_running_loop().create_future()
        self._attach_waiters.add(waiter)
        return waiter

    # --- open cards -----------------------------------------------------------

    def open_cards(self, chat: Chat) -> list[CardAsk]:
        """The chat's open cards, oldest first, as they were sent (stamped)."""
        return [p.card for p in self._open.get(chat.number, {}).values()]

    def allowed(self, chat: Chat, tool: str, input: dict[str, Any] | None = None) -> bool:
        """``True`` when a person's earlier chat-scoped allow covers this use of ``tool``.

        A file-editing tool (``EDIT_TOOLS``) is covered by the bare tool
        names only for a file inside the chat's folder (symlinks followed);
        a file outside it only by its own ``Edit(<real path>)`` key. Any
        other bare tool name covers every use. A command tool is covered
        when the whole command is exactly one of the chat's exact rules, or
        when every part of it (split on ``&&``, ``||``, ``;``, ``|`` and line
        breaks) matches one of its ``Tool(rule)`` keys: ``prefix:*`` matches
        the prefix as whole words, anything else the exact part; a part
        with a background ``&``, a substitution, backticks or a redirection
        is never covered. A ``cd <literal path>`` into the chat's own
        folder (or below it) is covered by any such key: it changes
        nothing a person is asked about.
        """
        input = input or {}
        if tool in EDIT_TOOLS:
            path = _edit_path(input)
            if path is None:
                return False
            target = _absolute(path, chat.folder)
            if _inside(target, chat.folder):
                return bool(EDIT_TOOLS & chat.chat_allows)
            return f"Edit({_resolved(target)})" in chat.chat_allows
        if tool in chat.chat_allows:
            return True
        if tool not in COMMAND_TOOLS:
            return False
        command = input.get("command")
        if not isinstance(command, str) or not command.strip():
            return False
        rules = [key[len(tool) + 1 : -1] for key in chat.chat_allows if key.startswith(f"{tool}(") and key.endswith(")")]
        if not rules:
            return False
        if command.strip() in rules:
            # Exactly the command a person allowed for the session, as they read it.
            return True
        parts = [part for part in _COMMAND_JOINERS.split(command.strip()) if part]
        return bool(parts) and all(
            _cd_inside(part, chat.folder) or any(_rule_covers(rule, part) for rule in rules) for part in parts
        )

    @staticmethod
    def chat_allow_keys(
        tool: str, input: dict[str, Any], suggestions: list[dict[str, Any]], folder: Path | None = None
    ) -> set[str]:
        """What a scope ``chat`` allow records for this use.

        A file edit inside ``folder``: the four file-editing tool names
        (which cover edits inside the folder only); outside it, or with no
        folder known: ``Edit(<real path>)``, that one file. A command tool:
        ``Tool(rule)`` keys. Any other tool: its name.
        """
        if tool in EDIT_TOOLS:
            path = _edit_path(input)
            if path is None:
                return set()
            target = _absolute(path, folder)
            if folder is not None and _inside(target, folder):
                return set(EDIT_TOOLS)
            return {f"Edit({_resolved(target)})"}
        if tool not in COMMAND_TOOLS:
            return {tool}
        rules = _suggested_rules(tool, suggestions)
        if not rules:
            command = input.get("command")
            if isinstance(command, str) and command.strip():
                rules.append(command.strip())
        return {f"{tool}({rule})" for rule in rules}

    # --- asking ---------------------------------------------------------------

    async def ask(self, chat: Chat, card: CardAsk, send: Send) -> CardAnswer:
        """Send ``card`` and wait for its answer; a cancel or a timed-out hold resolves as a deny."""
        future: asyncio.Future[CardAnswer] = asyncio.get_running_loop().create_future()
        stamped = await send(chat, card)
        assert isinstance(stamped, CardAsk)
        pending = _Pending(card=stamped, future=future)
        self._open.setdefault(chat.number, {})[card.id] = pending
        try:
            return await self._wait(chat, pending, send)
        finally:
            self._forget(chat.number, card.id)

    async def _wait(self, chat: Chat, pending: _Pending, send: Send) -> CardAnswer:
        future = pending.future
        while not future.done():
            change = self._attach_change()
            timeout = None if self.attached else self.hold_seconds
            done, _ = await asyncio.wait({future, change}, timeout=timeout, return_when=asyncio.FIRST_COMPLETED)
            if not change.done():
                change.cancel()
            self._attach_waiters.discard(change)
            if future in done:
                break
            if not done:
                # The hold ran out with nobody attached.
                log.info("chat %d: card %s held %.0fs with no app attached; denied", chat.number, pending.card.id, self.hold_seconds)
                self._forget(chat.number, pending.card.id)
                await send(chat, CardCancel(ts=_now(), chat=chat.number, id=pending.card.id, reason=NOBODY_ANSWERED))
                return _cancelled(pending.card, NOBODY_ANSWERED)
            # Attachment changed: loop, with the clock running or stopped accordingly.
        return future.result()

    def _forget(self, chat: int, id: str) -> None:
        cards = self._open.get(chat)
        if cards is not None:
            cards.pop(id, None)
            if not cards:
                del self._open[chat]

    async def ask_permission(
        self,
        chat: Chat,
        tool: str,
        input: dict[str, Any],
        suggestions: list[dict[str, Any]],
        tool_use_id: str,
        send: Send,
    ) -> PermissionDecision:
        """A permission card for ``tool``, unless the chat already allows it; returns the engine's decision."""
        if self.allowed(chat, tool, input):
            return "allow"
        card = permission_card(chat.number, tool, input, tool_use_id, chat.folder, suggestions)
        answer = await self.ask(chat, card, send)
        if _is_cancelled(answer) or answer.answer.get("decision") != "allow":
            return ("deny", answer.note)
        if answer.scope == "chat":
            chat.chat_allows.update(self.chat_allow_keys(tool, input, suggestions, chat.folder))
            return "allow"
        if answer.scope == "always":
            return ("allow", "always")
        return "allow"

    async def ask_question(
        self, chat: Chat, questions: list[dict[str, Any]], send: Send
    ) -> dict[str, str | list[str]]:
        """A question card; returns the answers, or raises ``QuestionDeclined`` when the card was cancelled."""
        answer = await self.ask(chat, question_card(chat.number, questions), send)
        if _is_cancelled(answer):
            raise QuestionDeclined(answer.note or "the question was not answered")
        answers = answer.answer.get("answers")
        assert isinstance(answers, dict)
        return dict(answers)

    # --- answering and cancelling ----------------------------------------------

    def answer(self, chat: int, id: str, answer: CardAnswer) -> None:
        """Resolve the open card ``id`` on ``chat``; unknown or already answered → ``card.stale``."""
        pending = self._open.get(chat, {}).get(id)
        if pending is None or pending.future.done():
            raise ProtocolError("card.stale", f"card {id} on chat {chat} is not open")
        _check_answer(pending.card, answer)
        self._forget(chat, id)
        pending.future.set_result(answer)

    async def cancel(self, chat: Chat, id: str, reason: str, send: Send) -> bool:
        """Cancel one open card: emits ``card.cancel`` and resolves it as a deny with ``reason``."""
        pending = self._open.get(chat.number, {}).get(id)
        if pending is None or pending.future.done():
            return False
        self._forget(chat.number, id)
        await send(chat, CardCancel(ts=_now(), chat=chat.number, id=id, reason=reason))
        pending.future.set_result(_cancelled(pending.card, reason))
        return True

    async def cancel_all(self, chat: Chat, reason: str, send: Send) -> int:
        """Cancel every open card on ``chat``; returns how many there were."""
        count = 0
        for card in self.open_cards(chat):
            if await self.cancel(chat, card.id, reason, send):
                count += 1
        return count
