"""The engine behind a chat: an abstract ``Engine`` and the Claude Agent SDK adapter.

The gateway talks to one ``Engine`` per chat. ``SDKEngine`` wraps
``ClaudeSDKClient``; ``translate`` turns SDK messages into protocol events
and is a pure function so the rest of the gateway (and the tests) never
need a model. Permission and question requests from the SDK are routed to
``EngineCallbacks`` and the answers translated back into SDK results.

Nothing here names a model, a provider, or a credential: the SDK reads
those from the environment. ``verbatim_prompts`` is never set, so slash
text in a message keeps dispatching the folder's commands.
"""

from __future__ import annotations

import asyncio
import dataclasses
import logging
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Literal, Protocol, runtime_checkable

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    HookMatcher,
    Message,
    PermissionResultAllow,
    PermissionResultDeny,
    PermissionUpdate,
    ResultMessage,
    StreamEvent,
    SystemMessage,
    ToolPermissionContext,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
    get_session_messages,
)

from .messages import ServerMessage, TextDelta, ToolFinished, ToolStarted, TurnFinished

log = logging.getLogger(__name__)

QUESTION_TOOL = "AskUserQuestion"
DEFAULT_DENY_MESSAGE = "denied by the user"
SUMMARY_LIMIT = 80

# What ``on_permission`` returns. ``"allow"`` for once/chat (the chat layer
# remembers chat-wide allows itself), ``("allow", "always")`` persists the
# engine's local-settings suggestion, ``"deny"`` or ``("deny", note)`` refuses
# with the person's note as the message the agent sees.
PermissionDecision = (
    Literal["allow", "deny"] | tuple[Literal["allow"], Literal["always"]] | tuple[Literal["deny"], str | None]
)


class QuestionDeclined(Exception):
    """Raised by ``on_question`` when nobody answered (the card was cancelled or nobody was there).

    The adapter turns it into a deny with the message, so the engine's
    question tool is refused rather than answered with nothing.
    """


@runtime_checkable
class EngineCallbacks(Protocol):
    async def on_event(self, event: ServerMessage) -> None: ...

    async def on_permission(
        self, tool: str, input: dict[str, Any], suggestions: list[dict[str, Any]], tool_use_id: str
    ) -> PermissionDecision: ...

    async def on_question(self, questions: list[dict[str, Any]]) -> dict[str, str | list[str]]: ...


@runtime_checkable
class Engine(Protocol):
    """One conversation's engine. ``chat`` and ``turn`` label the events it emits.

    The owner sets ``chat`` to the chat number before ``start``; ``turn``
    advances on every ``send`` so events carry the turn they belong to.
    """

    chat: int
    turn: int
    session_id: str | None

    async def start(self, folder: Path, resume: str | None, setting_sources: list[str], callbacks: EngineCallbacks) -> str: ...

    async def send(self, text: str) -> None: ...

    async def interrupt(self) -> None: ...

    async def close(self) -> None: ...


# --- translation (pure) --------------------------------------------------------


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _first_line(text: str, limit: int = SUMMARY_LIMIT) -> str:
    line = text.strip().split("\n", 1)[0].strip()
    return line[:limit]


def summarize_tool(tool: str, input: dict[str, Any]) -> str:
    """The one-line summary shown on a tool row and a permission card."""
    if tool in ("Write", "Edit", "MultiEdit", "Read", "NotebookEdit"):
        path = input.get("file_path") or input.get("notebook_path")
        if isinstance(path, str) and path:
            return path
    elif tool == "Bash":
        command = input.get("command")
        if isinstance(command, str) and command:
            return _first_line(command)
    return tool


def _result_summary(content: str | list[dict[str, Any]] | None) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return _first_line(content)
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
            return _first_line(block["text"])
    return ""


def translate(msg: Message, chat: int, turn: int) -> list[ServerMessage]:
    """SDK message -> protocol events for ``chat``/``turn``. Pure; ``seq`` is left to the chat.

    Text arrives as ``text.delta`` from the stream events, so an
    ``AssistantMessage``'s text blocks are not re-emitted. Anything from a
    subagent (``parent_tool_use_id`` set) stays out of the conversation.
    """
    ts = _now()
    out: list[ServerMessage] = []
    if isinstance(msg, StreamEvent):
        if msg.parent_tool_use_id is not None:
            return out
        event = msg.event
        if event.get("type") == "content_block_delta":
            delta = event.get("delta") or {}
            if delta.get("type") == "text_delta" and isinstance(delta.get("text"), str):
                out.append(TextDelta(ts=ts, chat=chat, turn=turn, text=delta["text"]))
    elif isinstance(msg, AssistantMessage):
        if msg.parent_tool_use_id is not None:
            return out
        for block in msg.content:
            if isinstance(block, ToolUseBlock):
                out.append(
                    ToolStarted(
                        ts=ts,
                        chat=chat,
                        turn=turn,
                        tool_use_id=block.id,
                        tool=block.name,
                        summary=summarize_tool(block.name, block.input),
                        input=dict(block.input),
                    )
                )
    elif isinstance(msg, UserMessage):
        if msg.parent_tool_use_id is not None or isinstance(msg.content, str):
            return out
        for block in msg.content:
            if isinstance(block, ToolResultBlock):
                out.append(
                    ToolFinished(
                        ts=ts,
                        chat=chat,
                        turn=turn,
                        tool_use_id=block.tool_use_id,
                        ok=not bool(block.is_error),
                        summary=_result_summary(block.content),
                    )
                )
    elif isinstance(msg, ResultMessage):
        out.append(TurnFinished(ts=ts, chat=chat, turn=turn, outcome="error" if msg.is_error else "done"))
    # SystemMessage, RateLimitEvent, ConversationResetMessage and the rest carry nothing for the app.
    return out


# --- permissions and questions -------------------------------------------------


def to_permission_result(
    decision: PermissionDecision, suggestions: list[PermissionUpdate]
) -> PermissionResultAllow | PermissionResultDeny:
    """A callback's decision -> what the SDK's ``can_use_tool`` must return."""
    if decision == "allow":
        return PermissionResultAllow()
    if decision == "deny":
        return PermissionResultDeny(message=DEFAULT_DENY_MESSAGE)
    if isinstance(decision, tuple) and len(decision) == 2:
        kind, extra = decision
        if kind == "allow" and extra == "always":
            return PermissionResultAllow(
                updated_permissions=[s for s in suggestions if s.destination == "localSettings"]
            )
        if kind == "deny":
            return PermissionResultDeny(message=extra or DEFAULT_DENY_MESSAGE)
    raise ValueError(f"unknown permission decision: {decision!r}")


def build_can_use_tool(callbacks: EngineCallbacks):
    """The SDK ``can_use_tool`` closure: questions to ``on_question``, the rest to ``on_permission``."""

    async def can_use_tool(
        tool: str, input: dict[str, Any], context: ToolPermissionContext
    ) -> PermissionResultAllow | PermissionResultDeny:
        if tool == QUESTION_TOOL:
            questions = list(input.get("questions") or [])
            try:
                answers = await callbacks.on_question(questions)
            except QuestionDeclined as e:
                return PermissionResultDeny(message=str(e) or DEFAULT_DENY_MESSAGE)
            return PermissionResultAllow(updated_input={"questions": questions, "answers": answers})
        suggestions = list(context.suggestions or [])
        decision = await callbacks.on_permission(
            tool, dict(input), [s.to_dict() for s in suggestions], context.tool_use_id or ""
        )
        return to_permission_result(decision, suggestions)

    return can_use_tool


async def noop_hook(input: Any, tool_use_id: str | None, context: Any) -> dict[str, Any]:
    """Registered on ``PreToolUse`` for the question tool; without it the tool does not fire in streaming mode."""
    return {"continue_": True}


def build_options(
    folder: Path, resume: str | None, setting_sources: list[str], callbacks: EngineCallbacks
) -> ClaudeAgentOptions:
    """The SDK options for one chat. Never sets ``verbatim_prompts`` or a permission mode."""
    return ClaudeAgentOptions(
        cwd=str(folder),
        resume=resume,
        setting_sources=list(setting_sources),  # type: ignore[arg-type]
        can_use_tool=build_can_use_tool(callbacks),
        include_partial_messages=True,
        hooks={"PreToolUse": [HookMatcher(matcher=QUESTION_TOOL, hooks=[noop_hook])]},
    )


# --- the SDK adapter -------------------------------------------------------------


class SDKEngine:
    """``Engine`` on ``ClaudeSDKClient``.

    ``start`` connects and begins pumping SDK messages through ``translate``
    to ``callbacks.on_event``; it returns the session id as soon as the
    engine's ``init`` message names it (or ``resume`` when resuming), and
    keeps ``session_id`` current from later messages if ``init`` arrives
    only with the first turn.
    """

    def __init__(self, chat: int = 0, init_timeout: float = 5.0) -> None:
        self.chat = chat
        self.turn = 0
        self.session_id: str | None = None
        self.init_timeout = init_timeout
        self._client: ClaudeSDKClient | None = None
        self._callbacks: EngineCallbacks | None = None
        self._pump: asyncio.Task[None] | None = None
        self._init_seen = asyncio.Event()

    async def start(self, folder: Path, resume: str | None, setting_sources: list[str], callbacks: EngineCallbacks) -> str:
        if self._client is not None:
            raise RuntimeError("engine already started")
        self._callbacks = callbacks
        self.session_id = resume
        self._client = ClaudeSDKClient(build_options(folder, resume, setting_sources, callbacks))
        await self._client.connect()
        self._pump = asyncio.create_task(self._run_pump(), name=f"portico-engine-{self.chat}")
        try:
            await asyncio.wait_for(self._init_seen.wait(), self.init_timeout)
        except TimeoutError:
            log.debug("chat %s: no init message within %.1fs; session id follows the first turn", self.chat, self.init_timeout)
        return self.session_id or ""

    async def _run_pump(self) -> None:
        assert self._client is not None and self._callbacks is not None
        try:
            async for msg in self._client.receive_messages():
                self._note_session(msg)
                for event in translate(msg, self.chat, self.turn):
                    await self._callbacks.on_event(event)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("chat %s: engine pump stopped", self.chat)
            self._init_seen.set()

    def _note_session(self, msg: Message) -> None:
        sid: str | None = None
        if isinstance(msg, SystemMessage) and msg.subtype == "init":
            sid = msg.data.get("session_id")
            self._init_seen.set()
        else:
            sid = getattr(msg, "session_id", None)
        if isinstance(sid, str) and sid:
            self.session_id = sid

    async def send(self, text: str) -> None:
        if self._client is None:
            raise RuntimeError("engine not started")
        self.turn += 1
        await self._client.query(text)

    async def interrupt(self) -> None:
        if self._client is not None:
            await self._client.interrupt()

    async def close(self) -> None:
        pump, self._pump = self._pump, None
        client, self._client = self._client, None
        if client is not None:
            try:
                await client.disconnect()
            except Exception:
                log.exception("chat %s: disconnect failed", self.chat)
        if pump is not None and not pump.done():
            pump.cancel()
            try:
                await pump
            except (asyncio.CancelledError, Exception):
                pass


# --- history -------------------------------------------------------------------------


def read_history(session_id: str, folder: Path) -> list[dict[str, Any]]:
    """The engine's transcript for ``session_id`` under ``folder``, as plain dicts, oldest first."""
    messages = get_session_messages(session_id, directory=str(folder))
    return [dataclasses.asdict(m) for m in messages]
