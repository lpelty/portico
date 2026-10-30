"""The engine behind a chat: an abstract ``Engine`` and the Claude Agent SDK adapter.

The gateway talks to one ``Engine`` per chat. ``SDKEngine`` wraps
``ClaudeSDKClient``; ``translate`` turns SDK messages into protocol events
and is a pure function so the rest of the gateway (and the tests) never
need a model. Permission and question requests from the SDK are routed to
``EngineCallbacks`` and the answers translated back into SDK results.

Nothing here names a model, a provider, or a credential: the SDK reads
those from the environment. ``verbatim_prompts`` is never set, so slash
text in a message keeps dispatching the folder's commands.

The viewer (v0.10 decision 6): every engine gets an in-process tool,
``show_in_viewer(path)``, and a ``PreToolUse`` hook on ``Bash`` that
catches a plain ``open <file>``; both hand the files to
``callbacks.on_show``, which decides whether they may be shown and shows
them. One line appended to the system prompt tells the agent to use it.

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
import re
import shlex
import warnings
from collections.abc import Iterable, Mapping
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Literal, Protocol, runtime_checkable

from claude_agent_sdk import (
    AssistantMessage,
    CanUseToolShadowedWarning,
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
    create_sdk_mcp_server,
    get_session_messages,
    tool,
)

from .agents import AgentTracker
from .messages import (
    AgentFinished,
    AgentProgress,
    AgentStarted,
    PermissionMode,
    ServerMessage,
    TextDelta,
    ToolFinished,
    ToolStarted,
    TurnFinished,
    TurnStarted,
    UserText,
)

log = logging.getLogger(__name__)

QUESTION_TOOL = "AskUserQuestion"
# The in-process tool that shows a file in the viewer, and the name the
# engine knows it by (``mcp__<server>__<tool>``).
SHOW_SERVER = "portico"
SHOW_TOOL = "show_in_viewer"

# v0.11 (item 56): set in every engine started for a person's chat (never for
# titles). The SDK marks its engines ``CLAUDE_CODE_ENTRYPOINT=sdk-py``, which a
# deployment's start-up checks may read as nobody present; this says someone is.
ATTENDED_ENV = "PORTICO_ATTENDED"
SHOW_TOOL_NAME = f"mcp__{SHOW_SERVER}__{SHOW_TOOL}"
SHOWN_TEXT = "Shown in the viewer."
# What the agent sees when its ``open <file>`` was shown instead of run.
OPEN_SHOWN_REASON = "Shown in Portico's viewer instead of opening it."
# Appended to the system prompt, never replacing it.
VIEWER_PROMPT = (
    "The person sees files in Portico's viewer beside this conversation. To show a file, "
    "call show_in_viewer with its path; don't open files with the `open` command or a browser."
)
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
        SHOW_TOOL_NAME,
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

    # Optional (v0.10), so not part of the checked protocol:
    # ``async def on_show(self, paths: list[str]) -> str | None`` shows the
    # files in the viewer, all or none, and answers ``None`` when shown,
    # else why not (a relative path is the chat folder's). An owner without
    # it gives the engine no show tool and no ``open`` hook.


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
    # The deployment's system prompt, set before ``start`` (v0.10 decision 7).
    system_prompt: Any

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
    elif tool == SHOW_TOOL_NAME:
        path = input.get("path")
        if isinstance(path, str) and path:
            return path
    elif tool == "Bash":
        command = input.get("command")
        if isinstance(command, str) and command:
            return _first_line(command)
    elif tool in ("Agent", "Task"):
        description = input.get("description")
        if isinstance(description, str) and description:
            return _first_line(description)
    elif tool == "ToolSearch":
        query = input.get("query")
        if isinstance(query, str) and query:
            return _first_line(query)
    elif tool == "Skill":
        skill = input.get("skill")
        if isinstance(skill, str) and skill:
            return _first_line(skill)
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
        out.extend(agents.overdue(msg, chat, ts))
        handled = agents.translate(msg, chat, turn, ts)
        if handled is not None and not isinstance(msg, ResultMessage):
            return out + handled
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


def opens_turn(msg: Message) -> bool:
    """Whether ``msg`` is the engine speaking in the conversation: its ``init``, or its own (not a subagent's) output.

    Arriving while no turn is in flight, it begins a turn nobody sent (the
    engine answering a background task that finished). A tool result, a
    task message or a result does not: none of them begins anything.
    """
    if isinstance(msg, SystemMessage):
        return msg.subtype == "init"
    if isinstance(msg, (AssistantMessage, StreamEvent)):
        return msg.parent_tool_use_id is None
    return False


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


# --- the viewer: show_in_viewer and a caught `open` (v0.10) -------------------

# Anything in a command beyond words separated by spaces: pipes, chains,
# redirections, substitutions, globs, quotes, escapes, home and variables.
_SHELL_SPECIAL = re.compile(r"[|&;<>()$`*?\[\]{}~\\'\"\n!#=]")
# A URL or any other ``scheme:`` argument (``http:``, ``file:``, ``x-man-page:``).
_SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
_OPEN_PROGRAMS = ("open", "/usr/bin/open")


def open_command_paths(command: Any) -> list[str] | None:
    """The paths of a plain macOS ``open <path> [<path> ...]``; ``None`` for any other command.

    Only the simple form is caught: no flags, no URLs, nothing the shell
    would expand or chain. Whether the paths may be shown is the owner's
    call (``on_show``).
    """
    if not isinstance(command, str) or _SHELL_SPECIAL.search(command):
        return None
    try:
        words = shlex.split(command)
    except ValueError:
        return None
    if len(words) < 2 or words[0] not in _OPEN_PROGRAMS:
        return None
    paths = words[1:]
    if any(p.startswith("-") or _SCHEME.match(p) for p in paths):
        return None
    return paths


def deployment_system_prompt(kind: str, append: str | None) -> Any:
    """The system prompt the deployment's config asks for, as ``ClaudeAgentOptions`` takes it.

    ``claude_code`` is Claude Code's own prompt with the text of ``append``
    after it; ``none`` is the SDK's empty prompt (``None``), or ``append``'s
    text alone when set. ``append`` is read here, at each engine start, so an
    edit applies to the next session; a file that can't be read is logged
    and left out (v0.10 decision 7).
    """
    text = ""
    if append:
        try:
            text = Path(append).read_text(encoding="utf-8").strip()
        except (OSError, UnicodeDecodeError) as e:
            log.error("system_prompt_append %s could not be read; starting without it: %s", append, e)
    if kind == "none":
        return text or None
    return {"type": "preset", "preset": "claude_code", **({"append": text} if text else {})}


def with_viewer_prompt(system_prompt: Any) -> Any:
    """``system_prompt`` (as ``ClaudeAgentOptions`` takes it) with ``VIEWER_PROMPT`` appended.

    ``None`` is the SDK's default, an empty prompt: the line becomes the
    prompt. A preset keeps its ``append`` and gets the line after it; a
    custom prompt gets the line after its text. A prompt file cannot be
    appended to and is left as it is.
    """
    if system_prompt is None:
        return VIEWER_PROMPT
    if isinstance(system_prompt, str):
        return f"{system_prompt}\n\n{VIEWER_PROMPT}" if system_prompt else VIEWER_PROMPT
    if isinstance(system_prompt, Mapping):
        kind = system_prompt.get("type")
        if kind == "preset":
            before = system_prompt.get("append") or ""
            return {**system_prompt, "append": f"{before}\n\n{VIEWER_PROMPT}" if before else VIEWER_PROMPT}
        if kind == "custom":
            before = system_prompt.get("prompt") or ""
            return {**system_prompt, "prompt": f"{before}\n\n{VIEWER_PROMPT}" if before else VIEWER_PROMPT}
    return system_prompt


def build_show_tool(callbacks: EngineCallbacks):
    """The ``show_in_viewer`` tool: the file goes to the viewer, or the agent hears why not."""

    @tool(
        SHOW_TOOL,
        "Show a file in the viewer beside this conversation, where the person sees it. "
        "The path may be relative to the session's folder.",
        {"path": str},
    )
    async def show_in_viewer(args: dict[str, Any]) -> dict[str, Any]:
        path = args.get("path")
        if not isinstance(path, str) or not path.strip():
            return {"content": [{"type": "text", "text": "Not shown: give the path of a file."}], "is_error": True}
        refusal = await callbacks.on_show([path.strip()])
        if refusal is not None:
            return {"content": [{"type": "text", "text": refusal}], "is_error": True}
        return {"content": [{"type": "text", "text": SHOWN_TEXT}]}

    return show_in_viewer


def resolve_open_paths(paths: list[str], cwd: Any) -> list[str] | None:
    """``open``'s paths as the shell would find them: a relative one against ``cwd``; ``None`` when that cannot be known.

    The Bash tool's working directory persists between calls (after ``cd
    build``, ``open report.html`` means ``build/report.html``), and the hook
    input's ``cwd`` is that directory. Without one, only absolute paths
    are caught: a relative ``open`` runs as before.
    """
    if isinstance(cwd, str) and cwd.strip() and Path(cwd).is_absolute():
        return [p if Path(p).is_absolute() else str(Path(cwd) / p) for p in paths]
    if all(Path(p).is_absolute() for p in paths):
        return paths
    return None


def build_open_hook(callbacks: EngineCallbacks):
    """The ``PreToolUse`` hook on ``Bash``: a plain ``open`` of files the owner may show is shown, not run.

    Runs in every permission mode (hooks come before the permission
    decision). A relative path is the shell's working directory's (the
    hook input's ``cwd``), never the chat folder's. Anything else, and any
    ``open`` the owner refuses, runs as before.
    """

    async def open_hook(input: Any, tool_use_id: str | None, context: Any) -> dict[str, Any]:
        tool_input = input.get("tool_input") if isinstance(input, Mapping) else None
        command = tool_input.get("command") if isinstance(tool_input, Mapping) else None
        paths = open_command_paths(command)
        if paths is not None:
            paths = resolve_open_paths(paths, input.get("cwd") if isinstance(input, Mapping) else None)
        if paths is None:
            return {"continue_": True}
        try:
            refusal = await callbacks.on_show(paths)
        except Exception:
            log.exception("showing %s in the viewer failed", paths)
            return {"continue_": True}
        if refusal is not None:
            return {"continue_": True}
        return {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": OPEN_SHOWN_REASON,
            }
        }

    return open_hook


# The show tool is allowed outright on purpose (it only shows a file), so the
# SDK's advisory that ``can_use_tool`` will not see it is expected.
warnings.filterwarnings(
    "ignore", message=rf"can_use_tool will not be invoked for: {re.escape(SHOW_TOOL_NAME)}\.", category=CanUseToolShadowedWarning
)


def build_options(
    folder: Path,
    resume: str | None,
    setting_sources: list[str],
    callbacks: EngineCallbacks,
    permission_mode: PermissionMode = "default",
    system_prompt: Any = None,
) -> ClaudeAgentOptions:
    """The SDK options for one chat. Never sets ``verbatim_prompts``.

    ``permission_mode`` is the session's: ``default`` asks (``can_use_tool``)
    for every step the engine's rules do not already allow, ``acceptEdits``
    allows file edits, ``auto`` lets the engine's classifier decide and only
    asks when it escalates. ``bypassPermissions`` and ``dontAsk`` are never
    passed: the protocol does not offer them.

    With an owner that can show files (``on_show``, v0.10): the
    ``show_in_viewer`` tool (allowed outright, so no card in any mode), the
    ``open`` hook on ``Bash``, and ``VIEWER_PROMPT`` appended to
    ``system_prompt`` (the deployment's, ``deployment_system_prompt``;
    ``None`` is the SDK's empty prompt).

    ``PORTICO_ATTENDED=1`` is always in the engine's environment: a person
    drives this chat (v0.11).
    """
    pre_tool_use = [HookMatcher(matcher=QUESTION_TOOL, hooks=[noop_hook])]
    extra: dict[str, Any] = {} if system_prompt is None else {"system_prompt": system_prompt}
    if callable(getattr(callbacks, "on_show", None)):
        pre_tool_use.append(HookMatcher(matcher="Bash", hooks=[build_open_hook(callbacks)]))
        extra = {
            "mcp_servers": {SHOW_SERVER: create_sdk_mcp_server(SHOW_SERVER, tools=[build_show_tool(callbacks)])},
            "allowed_tools": [SHOW_TOOL_NAME],
            "system_prompt": with_viewer_prompt(system_prompt),
        }
    return ClaudeAgentOptions(
        cwd=str(folder),
        resume=resume,
        permission_mode=permission_mode,
        setting_sources=list(setting_sources),  # type: ignore[arg-type]
        can_use_tool=build_can_use_tool(callbacks),
        include_partial_messages=True,
        env={ATTENDED_ENV: "1"},
        hooks={
            "PreToolUse": pre_tool_use,
            "PreCompact": [HookMatcher(matcher=None, hooks=[build_compact_hook(callbacks)])],
        },
        **extra,
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
    flight, so a chat is never left ``working`` with nothing on screen;
    whenever it dies, every agent and workflow still open is ended
    (``AgentTracker.close_all``) first. A deliberate ``close`` reports
    nothing: the owner ended the turn (and ends the work, v0.10).

    A turn nobody sent (v0.10): when the engine speaks (``opens_turn``)
    with no turn in flight, after a turn has run, it is answering on its
    own, typically a background task that finished. The adapter advances
    ``turn`` and reports ``turn.started`` for it before that message's
    events; the owner may renumber it (set ``turn``) while handling that
    event. Its result ends it like any turn.
    """

    def __init__(self, chat: int = 0, init_timeout: float = 5.0) -> None:
        self.chat = chat
        self.turn = 0
        self.session_id: str | None = None
        self.permission_mode: PermissionMode = "default"
        # The deployment's system prompt (``deployment_system_prompt``); ``None`` is empty.
        self.system_prompt: Any = None
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
        self._client = ClaudeSDKClient(
            build_options(folder, resume, setting_sources, callbacks, self.permission_mode, self.system_prompt)
        )
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
                if self._between_turns() and opens_turn(msg):
                    self.turn += 1
                    await self._callbacks.on_event(TurnStarted(ts=_now(), chat=self.chat, turn=self.turn))
                for event in translate(msg, self.chat, self.turn, self.agents):
                    if isinstance(event, TurnFinished):
                        self._finished_turn = event.turn
                    await self._callbacks.on_event(event)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("chat %s: engine pump stopped", self.chat)
        # The stream is gone, by failure or because the CLI exited: release a
        # waiting ``start``, end the work that died with it, and settle any
        # turn still in flight.
        self._init_seen.set()
        await self._report_lost_work()
        await self._report_lost_turn()

    def _between_turns(self) -> bool:
        """A turn has run and none is in flight (the last one's result has come)."""
        return not self._closing and 0 < self.turn <= self._finished_turn

    async def _report_lost_work(self) -> None:
        """The pump ended: the agents and workflows still open went with the engine."""
        if self._closing or self._callbacks is None:
            return
        try:
            for event in self.agents.close_all(self.chat, _now()):
                await self._callbacks.on_event(event)
        except Exception:
            log.exception("chat %s: could not report the lost agents", self.chat)

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
# The engine's note to itself that a background task ended (v0.10).
TASK_NOTIFICATION_PREFIX = "<task-notification>"
_HIDDEN_USER_TEXT_PREFIXES = (
    "<system-reminder>",
    "<local-command-",
    "<command-",
    "[Request interrupted by user",
    TASK_NOTIFICATION_PREFIX,
)


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


def _is_task_notification(blocks: list[dict[str, Any]]) -> bool:
    """Whether a user message is the engine telling itself a background task ended."""
    return any(
        block.get("type") == "text"
        and isinstance(block.get("text"), str)
        and block["text"].lstrip().startswith(TASK_NOTIFICATION_PREFIX)
        for block in blocks
    )


# The tools that start a subagent, and the start of the result a background
# one answers at once (it reports later, in a task notification).
AGENT_TOOLS = ("Agent", "Task")
ASYNC_AGENT_RESULT = "Async agent launched"
_NOTIFICATION_FIELD = re.compile(r"<(tool-use-id|status|summary|tool_uses|duration_ms)>(.*?)</\1>", re.DOTALL)
_NOTIFICATION_RESULT = re.compile(r"<result>.*?</result>", re.DOTALL)
_NOTIFICATION_OUTCOMES = {"completed": "done", "failed": "failed", "killed": "stopped", "stopped": "stopped"}


def _notification_fields(blocks: list[dict[str, Any]]) -> dict[str, str]:
    """The fields of a task notification's text that a replay uses (tool use id, status, summary, usage)."""
    for block in blocks:
        text = block.get("text")
        if block.get("type") == "text" and isinstance(text, str) and text.lstrip().startswith(TASK_NOTIFICATION_PREFIX):
            # Not inside the agent's own output: what it said may contain the
            # same tags (usage comes after it). The first of each wins.
            outside = _NOTIFICATION_RESULT.sub("", text)
            fields: dict[str, str] = {}
            for key, value in _NOTIFICATION_FIELD.findall(outside):
                fields.setdefault(key, value.strip())
            return fields
    return {}


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
    # Subagents started and not yet ended (v0.10): their record is rebuilt
    # from the calls that started them and the notifications that ended them.
    running: set[str] = set()

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
            elif _is_task_notification(blocks):
                # Background work reporting back (v0.10): the engine's own
                # message, never the person's; its reply is a turn nobody sent.
                end()
                begin()
                note = _notification_fields(blocks)
                agent = note.get("tool-use-id", "")
                if agent in running:
                    running.discard(agent)
                    steps, elapsed = note.get("tool_uses", ""), note.get("duration_ms", "")
                    if steps.isdigit() or elapsed.isdigit():
                        out.append(
                            AgentProgress(
                                ts=ts,
                                chat=chat,
                                id=agent,
                                steps=int(steps) if steps.isdigit() else 0,
                                elapsed=int(elapsed) / 1000 if elapsed.isdigit() else 0.0,
                            )
                        )
                    outcome = _NOTIFICATION_OUTCOMES.get(note.get("status", ""), "done")
                    out.append(AgentFinished(ts=ts, chat=chat, id=agent, outcome=outcome))  # type: ignore[arg-type]
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
                agent = str(block.get("tool_use_id") or "")
                summary = result_summary(block.get("content"))
                if agent in running and not summary.startswith(ASYNC_AGENT_RESULT):
                    running.discard(agent)
                    out.append(
                        AgentFinished(
                            ts=ts,
                            chat=chat,
                            id=agent,
                            outcome="failed" if block.get("is_error") else "done",
                            summary=summary or None,
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
                    elif isinstance(out[-1], TextDelta):
                        # Another message's text straight after this one's (the
                        # engine speaking twice in a turn): a paragraph apart,
                        # not run together.
                        text = "\n\n" + text
                    out.append(TextDelta(ts=ts, chat=chat, turn=turn, text=text))
                elif kind == "tool_use":
                    if not open_turn:
                        begin()
                    name = str(block.get("name") or "")
                    raw_input = block.get("input")
                    input: Mapping[str, Any] = raw_input if isinstance(raw_input, Mapping) else {}
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
                    if name in AGENT_TOOLS and block.get("id"):
                        agent = str(block["id"])
                        running.add(agent)
                        agent_type = input.get("subagent_type")
                        out.append(
                            AgentStarted(
                                ts=ts,
                                chat=chat,
                                turn=turn,
                                id=agent,
                                tool_use_id=agent,
                                description=summarize_tool(name, dict(input)),
                                kind=agent_type if isinstance(agent_type, str) and agent_type else "general-purpose",
                                background=True if input.get("run_in_background") else None,
                            )
                        )
                # thinking and anything else: not part of the conversation
    end()
    # Whatever the transcript never saw end is over: the engine that ran it
    # is gone (a replay from the transcript follows a gateway restart).
    for agent in sorted(running):
        out.append(AgentFinished(ts=ts, chat=chat, id=agent, outcome="done"))
    return out
