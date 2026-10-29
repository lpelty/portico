"""The engine behind a chat: an abstract ``Engine`` and the Claude Agent SDK adapter.

The gateway talks to one ``Engine`` per chat. ``SDKEngine`` wraps
``ClaudeSDKClient``; ``translate`` turns SDK messages into protocol events
and is a pure function so the rest of the gateway (and the tests) never
need a model. Permission and question requests from the SDK are routed to
``EngineCallbacks`` and the answers translated back into SDK results.

Nothing here names a model, a provider, or a credential: the SDK reads
those from the environment. ``verbatim_prompts`` is never set, so slash
text in a message keeps dispatching the folder's commands.

History (Task 10): ``read_history`` reads a session's transcript through
the SDK's ``get_session_messages`` and ``history_events`` translates it
into the same events a live turn produces (plus ``user.text`` for what the
person said), so the app has one rendering path for live and replayed
conversation.
"""

from __future__ import annotations

import asyncio
import dataclasses
import logging
from collections.abc import Iterable, Mapping
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

from .agents import AgentTracker
from .messages import PermissionMode, ServerMessage, TextDelta, ToolFinished, ToolStarted, TurnFinished, TurnStarted, UserText

log = logging.getLogger(__name__)

QUESTION_TOOL = "AskUserQuestion"
# The longest the adapter waits for the engine's context reading.
CONTEXT_USAGE_TIMEOUT = 10.0
DEFAULT_DENY_MESSAGE = "denied by the user"
SUMMARY_LIMIT = 80

# Tools that only read (or keep the engine's own notes): auto mode never has
# anything to decide for them, so their rows carry no permission outcome.
READ_ONLY_TOOLS: frozenset[str] = frozenset(
    {
        "Read", "Glob", "Grep", "LS", "NotebookRead", "TodoWrite", "TodoRead", "ToolSearch",
        "Task", "Agent", "TaskOutput", "BashOutput", "Skill", "AskUserQuestion",
        "ExitPlanMode", "EnterPlanMode", "ListMcpResourcesTool", "ReadMcpResourceTool",
    }
)

# What the engine's tool result says when auto mode's classifier refused a
# step ("Permission for this action was denied by the Claude Code auto mode
# classifier. Reason: ..."); matched case-insensitively.
AUTO_MODE_BLOCK_MARK = "auto mode classifier"

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

    async def on_compacted(self, trigger: str) -> None: ...


@runtime_checkable
class Engine(Protocol):
    """One conversation's engine. ``chat`` and ``turn`` label the events it emits.

    The owner sets ``chat`` to the chat number before ``start``; ``turn``
    advances on every ``send`` so events carry the turn they belong to.
    """

    chat: int
    turn: int
    session_id: str | None
    # How the engine decides on tool use; the owner sets it before ``start``
    # and changes it while running with ``set_permission_mode``.
    permission_mode: PermissionMode

    async def start(self, folder: Path, resume: str | None, setting_sources: list[str], callbacks: EngineCallbacks) -> str: ...

    async def send(self, text: str) -> None: ...

    async def interrupt(self) -> None: ...

    async def set_permission_mode(self, mode: PermissionMode) -> None:
        """Change the permission mode now (when running) and for every later turn."""
        ...

    def slash_commands(self) -> set[str] | None:
        """The slash commands the running engine knows (names without ``/``); ``None`` when it cannot say."""
        ...

    async def close(self) -> None: ...

    async def context_usage(self) -> tuple[float, str | None] | None:
        """How full the context window is, as ``(percent 0-100, model)``; ``None`` when unavailable."""
        ...


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


def result_summary(content: str | list[dict[str, Any]] | None) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return _first_line(content)
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
            return _first_line(block["text"])
    return ""


def _result_text(content: str | list[dict[str, Any]] | None) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    return "\n".join(
        block["text"] for block in content if isinstance(block, dict) and isinstance(block.get("text"), str)
    )


def blocked_by_auto_mode(is_error: bool | None, content: str | list[dict[str, Any]] | None) -> bool:
    """Whether a tool result is auto mode's classifier refusing the step."""
    return bool(is_error) and AUTO_MODE_BLOCK_MARK in _result_text(content).lower()


def translate(msg: Message, chat: int, turn: int, agents: AgentTracker | None = None) -> list[ServerMessage]:
    """SDK message -> protocol events for ``chat``/``turn``; ``seq`` is left to the chat.

    Text arrives as ``text.delta`` from the stream events, so an
    ``AssistantMessage``'s text blocks are not re-emitted. A subagent's
    text (``parent_tool_use_id`` set) stays out of the conversation. With
    ``agents`` (v0.10), the engine's task messages and a subagent's own tool
    calls go through that tracker (``agents.py``): ``agent.*`` and
    ``workflow.*`` events, and tool rows carrying ``agent_id``; a turn's
    result first ends any foreground subagent still open. Without it, as
    before v0.10, they are dropped and the function is pure.
    """
    ts = _now()
    out: list[ServerMessage] = []
    if agents is not None:
        handled = agents.translate(msg, chat, turn, ts)
        if handled is not None and not isinstance(msg, ResultMessage):
            return handled
        if handled:
            out.extend(handled)
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
                        summary=result_summary(block.content),
                        permission="blocked" if blocked_by_auto_mode(block.is_error, block.content) else None,
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


def build_compact_hook(callbacks: EngineCallbacks):
    """The ``PreCompact`` hook: tell the owner the engine is summarizing, then let it.

    A failure to report is logged and never stops the compaction.
    """

    async def pre_compact(input: Any, tool_use_id: str | None, context: Any) -> dict[str, Any]:
        trigger = input.get("trigger") if isinstance(input, Mapping) else None
        try:
            await callbacks.on_compacted(trigger if isinstance(trigger, str) else "auto")
        except Exception:
            log.exception("reporting a compaction failed")
        return {"continue_": True}

    return pre_compact


def build_options(
    folder: Path,
    resume: str | None,
    setting_sources: list[str],
    callbacks: EngineCallbacks,
    permission_mode: PermissionMode = "default",
) -> ClaudeAgentOptions:
    """The SDK options for one chat. Never sets ``verbatim_prompts``.

    ``permission_mode`` is the session's: ``default`` asks (``can_use_tool``)
    for every step the engine's rules do not already allow, ``acceptEdits``
    allows file edits, ``auto`` lets the engine's classifier decide and only
    asks when it escalates. ``bypassPermissions`` and ``dontAsk`` are never
    passed: the protocol does not offer them.
    """
    return ClaudeAgentOptions(
        cwd=str(folder),
        resume=resume,
        permission_mode=permission_mode,
        setting_sources=list(setting_sources),  # type: ignore[arg-type]
        can_use_tool=build_can_use_tool(callbacks),
        include_partial_messages=True,
        hooks={
            "PreToolUse": [HookMatcher(matcher=QUESTION_TOOL, hooks=[noop_hook])],
            "PreCompact": [HookMatcher(matcher=None, hooks=[build_compact_hook(callbacks)])],
        },
    )


# --- the model's display name ---------------------------------------------------

MODEL_FAMILIES = ("OPUS", "SONNET", "HAIKU")


def friendly_model_name(model: str | None, environ: Mapping[str, str]) -> str | None:
    """The deployment's display name for ``model``, or ``None``.

    ``ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL_NAME`` names the model
    when ``model`` is that family's ``ANTHROPIC_DEFAULT_*_MODEL`` (a
    trailing ``[1m]``-style tag is ignored on either side) or its alias
    (``opus``, ``sonnet``, ``haiku``).
    """
    if not model:
        return None

    def bare(value: str) -> str:
        value = value.strip()
        if value.endswith("]") and "[" in value:
            value = value[: value.rindex("[")]
        return value.strip()

    wanted = bare(model)
    for family in MODEL_FAMILIES:
        name = (environ.get(f"ANTHROPIC_DEFAULT_{family}_MODEL_NAME") or "").strip()
        if not name:
            continue
        configured = environ.get(f"ANTHROPIC_DEFAULT_{family}_MODEL") or ""
        if (configured and bare(configured) == wanted) or wanted.lower() == family.lower():
            return name
    return None


# --- the SDK adapter -------------------------------------------------------------


class SDKEngine:
    """``Engine`` on ``ClaudeSDKClient``.

    ``start`` connects and begins pumping SDK messages through ``translate``
    to ``callbacks.on_event``; it returns the session id as soon as the
    engine's ``init`` message names it (or ``resume`` when resuming), and
    keeps ``session_id`` current from later messages if ``init`` arrives
    only with the first turn.

    If the pump dies mid-turn (the CLI process exits, the stream raises),
    the owner hears ``turn.finished outcome=error`` for the turn in
    flight, so a chat is never left ``working`` with nothing on screen.
    A deliberate ``close`` reports nothing: the owner ended the turn.
    """

    def __init__(self, chat: int = 0, init_timeout: float = 5.0) -> None:
        self.chat = chat
        self.turn = 0
        self.session_id: str | None = None
        self.permission_mode: PermissionMode = "default"
        self.init_timeout = init_timeout
        self._client: ClaudeSDKClient | None = None
        self._callbacks: EngineCallbacks | None = None
        self._pump: asyncio.Task[None] | None = None
        self._init_seen = asyncio.Event()
        # The last turn a result message closed; ``turn`` beyond it is in flight.
        self._finished_turn = 0
        self._closing = False
        # Slash command names (no ``/``) from the engine's initialize answer
        # and its ``init`` message; ``None`` until either has said.
        self._commands: set[str] | None = None
        # v0.10: this engine's subagents and workflows.
        self.agents = AgentTracker()

    async def start(self, folder: Path, resume: str | None, setting_sources: list[str], callbacks: EngineCallbacks) -> str:
        if self._client is not None:
            raise RuntimeError("engine already started")
        self._callbacks = callbacks
        self.session_id = resume
        self._client = ClaudeSDKClient(build_options(folder, resume, setting_sources, callbacks, self.permission_mode))
        await self._client.connect()
        self._note_commands_from_server_info(await self._client.get_server_info())
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
                for event in translate(msg, self.chat, self.turn, self.agents):
                    if isinstance(event, TurnFinished):
                        self._finished_turn = event.turn
                    await self._callbacks.on_event(event)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("chat %s: engine pump stopped", self.chat)
        # The stream is gone, by failure or because the CLI exited: release a
        # waiting ``start`` and settle any turn still in flight.
        self._init_seen.set()
        await self._report_lost_turn()

    async def _report_lost_turn(self) -> None:
        """The pump ended mid-turn: tell the owner the turn ended in error."""
        if self._closing or self._callbacks is None or self.turn <= self._finished_turn:
            return
        turn = self.turn
        self._finished_turn = turn
        log.warning("chat %s: engine went away during turn %d; reporting the turn as an error", self.chat, turn)
        try:
            await self._callbacks.on_event(TurnFinished(ts=_now(), chat=self.chat, turn=turn, outcome="error"))
        except Exception:
            log.exception("chat %s: could not report the lost turn", self.chat)

    def _note_commands_from_server_info(self, info: Any) -> None:
        commands = info.get("commands") if isinstance(info, Mapping) else None
        if isinstance(commands, list):
            self._add_commands(c.get("name") if isinstance(c, Mapping) else c for c in commands)

    def _add_commands(self, names: Iterable[Any]) -> None:
        found = {n.strip().lstrip("/") for n in names if isinstance(n, str) and n.strip()}
        self._commands = (self._commands or set()) | found

    def slash_commands(self) -> set[str] | None:
        return set(self._commands) if self._commands is not None else None

    def _note_session(self, msg: Message) -> None:
        sid: str | None = None
        if isinstance(msg, SystemMessage) and msg.subtype == "init":
            sid = msg.data.get("session_id")
            commands = msg.data.get("slash_commands")
            if isinstance(commands, list):
                self._add_commands(commands)
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

    async def set_permission_mode(self, mode: PermissionMode) -> None:
        """The SDK's ``set_permission_mode`` while connected; remembered for a later ``start`` either way."""
        if self._client is not None:
            await self._client.set_permission_mode(mode)
        self.permission_mode = mode

    async def context_usage(self) -> tuple[float, str | None] | None:
        """The SDK's ``get_context_usage``: ``percentage`` and ``model``; ``None`` before ``start``."""
        client = self._client
        if client is None:
            return None
        usage = await asyncio.wait_for(client.get_context_usage(), CONTEXT_USAGE_TIMEOUT)
        percent = usage.get("percentage")
        if not isinstance(percent, (int, float)) or isinstance(percent, bool):
            return None
        model = usage.get("model")
        return float(percent), model if isinstance(model, str) and model else None

    async def close(self) -> None:
        self._closing = True
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

# User text blocks the engine's CLI adds around a person's message and never
# shows as the message itself: local command output, skill loads, reminders,
# and the "[Request interrupted by user]" marker (also its "... for tool use]"
# form) the CLI writes as a user message after a stop. The SDK's own session
# reader classes the same strings as scaffolding.
_HIDDEN_USER_TEXT_PREFIXES = ("<system-reminder>", "<local-command-", "<command-", "[Request interrupted by user")


def read_history(session_id: str | None, folder: Path) -> list[dict[str, Any]]:
    """The engine's transcript for ``session_id`` under ``folder``, as plain dicts, oldest first.

    Empty — never an error — when there is no session id, the id is not one
    the engine knows, the transcript is missing, or it cannot be read: a
    chat whose history is gone still opens.
    """
    if not session_id:
        return []
    try:
        messages = get_session_messages(session_id, directory=str(folder))
    except Exception:
        log.exception("could not read the transcript for session %s in %s", session_id, folder)
        return []
    return [dataclasses.asdict(m) for m in messages]


def _blocks(content: Any) -> list[dict[str, Any]]:
    """A message's content as a list of block dicts (a plain string is one text block)."""
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return [b for b in content if isinstance(b, dict)]
    return []


def _user_text(blocks: list[dict[str, Any]]) -> str:
    """The person's own words from a user message: text blocks, minus the engine's scaffolding."""
    parts: list[str] = []
    for block in blocks:
        if block.get("type") != "text" or not isinstance(block.get("text"), str):
            continue
        text = block["text"].strip()
        if not text or text.startswith(_HIDDEN_USER_TEXT_PREFIXES):
            continue
        parts.append(text)
    return "\n\n".join(parts)


def history_events(messages: Iterable[Mapping[str, Any]], chat: int, first_turn: int = 1) -> list[ServerMessage]:
    """Transcript messages (``read_history``'s dicts, or ``SessionMessage``-like) -> replay events. Pure.

    Each user message with text starts a turn (``turn.started``, ``user.text``);
    assistant text becomes ``text.delta``, tool calls and results
    ``tool.started`` / ``tool.finished``; every turn ends with
    ``turn.finished outcome=done``. Turns count from ``first_turn``. Nothing
    is stamped: ``seq`` is left unset, and the events carry today's ``ts``
    because the SDK's session messages carry none.
    """
    ts = _now()
    out: list[ServerMessage] = []
    turn = first_turn - 1
    open_turn = False

    def begin() -> None:
        nonlocal turn, open_turn
        turn += 1
        open_turn = True
        out.append(TurnStarted(ts=ts, chat=chat, turn=turn))

    def end() -> None:
        nonlocal open_turn
        if open_turn:
            out.append(TurnFinished(ts=ts, chat=chat, turn=turn, outcome="done"))
            open_turn = False

    for raw in messages:
        m = raw if isinstance(raw, Mapping) else dataclasses.asdict(raw)
        if m.get("parent_tool_use_id"):
            continue  # a subagent's message, never shown in the conversation
        message = m.get("message")
        if not isinstance(message, Mapping):
            continue
        role = m.get("type") or message.get("role")
        blocks = _blocks(message.get("content"))
        if role == "user":
            text = _user_text(blocks)
            if text:
                end()
                begin()
                out.append(UserText(ts=ts, chat=chat, turn=turn, text=text))
            for block in blocks:
                if block.get("type") != "tool_result":
                    continue
                if not open_turn:
                    begin()
                out.append(
                    ToolFinished(
                        ts=ts,
                        chat=chat,
                        turn=turn,
                        tool_use_id=str(block.get("tool_use_id") or ""),
                        ok=not bool(block.get("is_error")),
                        summary=result_summary(block.get("content")),
                        permission="blocked"
                        if blocked_by_auto_mode(block.get("is_error"), block.get("content"))
                        else None,
                    )
                )
        elif role == "assistant":
            for block in blocks:
                kind = block.get("type")
                if kind == "text":
                    text = block.get("text")
                    if not isinstance(text, str) or not text:
                        continue
                    if not open_turn:
                        begin()
                    out.append(TextDelta(ts=ts, chat=chat, turn=turn, text=text))
                elif kind == "tool_use":
                    if not open_turn:
                        begin()
                    name = str(block.get("name") or "")
                    input = block.get("input") if isinstance(block.get("input"), Mapping) else {}
                    out.append(
                        ToolStarted(
                            ts=ts,
                            chat=chat,
                            turn=turn,
                            tool_use_id=str(block.get("id") or ""),
                            tool=name,
                            summary=summarize_tool(name, dict(input)),
                            input=dict(input),
                        )
                    )
                # thinking and anything else: not part of the conversation
    end()
    return out
