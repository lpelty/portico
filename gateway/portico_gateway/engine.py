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
import json
import logging
import re
import shlex
import time
import warnings
from collections.abc import AsyncIterator, Iterable, Mapping
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
    TextBlock,
    ToolPermissionContext,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
    create_sdk_mcp_server,
    get_session_messages,
    tool,
)
from claude_agent_sdk._internal.sessions import _read_session_file

from .artifacts import paths_in
from .images import split_attachments, split_edited_note, user_message
from .agents import AgentTracker
from .threads import EMPTY_BRIEF, REFUSAL_PREFIX, TOOL_DESCRIPTION
from .comment_tools import COMMENT_TOOL_NAMES, build_comment_tools
from .viewer import QUEUE_NOTE, STOPPED, VIEWER_TOOL_NAMES, build_viewer_tools
from .messages import (
    AgentCommand,
    ModelChoice,
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
# v0.18 (ruling 20): set to ``1`` in an engine's environment when ``[apps] enabled``;
# the CLI then tells MCP servers it can show their ``ui://`` pages.
APPS_HOST_ENV = "CLAUDE_CODE_MCP_APPS_HOST"
# The SDK reads the CLI's stdout as JSON lines, 1 MiB at most by default; a look's base64 image is one line.
CLI_MAX_BUFFER_BYTES = 32 * 2**20
SHOW_TOOL_NAME = f"mcp__{SHOW_SERVER}__{SHOW_TOOL}"
# v0.16: the in-process tool Main's agent proposes a thread with, on the same server.
OPEN_THREAD_TOOL = "open_thread"
OPEN_THREAD_TOOL_NAME = f"mcp__{SHOW_SERVER}__{OPEN_THREAD_TOOL}"
SHOWN_TEXT = "Shown in the viewer."
# v0.17: the app did not say the page had loaded within the show's 10 s.
STILL_LOADING_TEXT = "Shown; still loading."


@dataclasses.dataclass(frozen=True)
class Shown:
    """``on_show``'s success with words of its own (v0.17); a plain ``None`` is ``SHOWN_TEXT``."""

    text: str


# What the agent sees when its ``open <file>`` was shown instead of run.
OPEN_SHOWN_REASON = "Shown in Portico's viewer instead of opening it."
# Appended to the system prompt, never replacing it.
VIEWER_PROMPT = (
    "The person sees files and web pages in Portico's viewer beside this conversation. To show one, "
    "call show_in_viewer with its path or its http(s) address; don't open files with the `open` command "
    "or a browser."
)
# v0.12: appended after the viewer line when the deployment has a spaces folder.
SPACES_PROMPT = (
    "The person's spaces are files in {folder}, one Markdown or HTML file each, named by front matter title. "
    "To show one, call show_in_viewer with its path. To create one, write a new file there with a title in front matter, "
    "then tell the person; how it is kept up to date is the deployment's."
)
# The longest the adapter waits for the engine's context reading.
CONTEXT_USAGE_TIMEOUT = 10.0
DEFAULT_DENY_MESSAGE = "denied by the user"
SUMMARY_LIMIT = 80
# v0.11 (item 66): the longest one-line description a command carries to the
# app's completion list; the app truncates further to fit its row.
COMMAND_DESCRIPTION_LIMIT = 160
# The source the engine appends to a command's description: "... (user)".
_COMMAND_SOURCE = re.compile(r"\s*\(([^()]+)\)\s*$")
# Where a description's first sentence ends: a stop, then a capital.
_SENTENCE_END = re.compile(r"(?<=[.!?])\s+(?=[A-Z])")

# Tools that only read (or keep the engine's own notes): auto mode never has
# anything to decide for them, so their rows carry no permission outcome.
_READ_ONLY_ENGINE_TOOLS: frozenset[str] = frozenset(
    {
        "Read", "Glob", "Grep", "LS", "NotebookRead", "TodoWrite", "TodoRead", "ToolSearch",
        "Task", "Agent", "TaskOutput", "BashOutput", "Skill", "AskUserQuestion",
        "ExitPlanMode", "EnterPlanMode", "ListMcpResourcesTool", "ReadMcpResourceTool",
    }
)

# Portico's own tools, allowed outright with no permission card in any mode:
# ``show_in_viewer`` only shows a file; the viewer tools include ones that act
# (click, type) but the person watches each action and has Stop; (v0.16)
# ``open_thread`` only proposes, and the person decides. Not read-only, yet
# auto mode has nothing to decide for them either. (v0.23) The comment tools
# only touch comment markup in .md files inside the session's folders.
ALLOWED_OUTRIGHT_TOOLS: frozenset[str] = frozenset(
    {SHOW_TOOL_NAME, OPEN_THREAD_TOOL_NAME, *VIEWER_TOOL_NAMES, *COMMENT_TOOL_NAMES}
)

# What the permission row treats as "nothing to decide" (see server.py).
READ_ONLY_TOOLS: frozenset[str] = _READ_ONLY_ENGINE_TOOLS | ALLOWED_OUTRIGHT_TOOLS

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
    """Raised by ``on_question`` when the question was not answered.

    Nobody answered (the card was cancelled or nobody was there), or (v0.16)
    the person declined it: ``declined`` is then the decline's key
    (``skipped``, ``dismissed``, ``replied``). The adapter turns it into a
    deny with the message, so the engine's question tool is refused rather
    than answered with nothing.
    """

    def __init__(self, message: str = "", declined: str | None = None) -> None:
        super().__init__(message)
        self.declined = declined


@runtime_checkable
class EngineCallbacks(Protocol):
    async def on_event(self, event: ServerMessage) -> None: ...

    async def on_permission(
        self, tool: str, input: dict[str, Any], suggestions: list[dict[str, Any]], tool_use_id: str
    ) -> PermissionDecision: ...

    # ``tool_use_id`` (v0.16): the question tool's row, so its outcome can be
    # recorded for ``tool.finished``.
    async def on_question(
        self, questions: list[dict[str, Any]], tool_use_id: str = ""
    ) -> dict[str, str | list[str]]: ...

    async def on_compacted(self, trigger: str) -> None: ...

    # Optional (v0.10), so not part of the checked protocol:
    # ``async def on_show(self, paths: list[str]) -> str | Shown | None``
    # shows the files (v0.17: or http(s) addresses) in the viewer, all or
    # none, and answers ``None`` (or a ``Shown`` with its own words) when
    # shown, else why not (a relative path is the chat folder's). An owner without
    # it gives the engine no show tool and no ``open`` hook.
    # Optional (v0.16), Main's owner only: ``async def on_open_thread(self,
    # brief: str, files: list[str]) -> str`` proposes a thread and answers
    # what the agent reads (a refusal starts "Not proposed: "), and
    # ``note_thread_use(tool_use_id, tool_input)`` hears the call's id and
    # input first (the handler is matched to it by input). An owner
    # without them gives the engine no ``open_thread`` tool.


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
    # v0.15: the model to start on (a ``ModelChoice.value``; ``None``: the
    # deployment's default), set before ``start``; ``set_model`` changes it.
    model: str | None

    # v0.18: whether this engine can show MCP Apps (its CLI reported
    # ``mcp_call_result_not_for_model_v1``), set by ``start``.
    apps_capable: bool
    # v0.18 (ruling 20): whether to start as an MCP Apps host (``[apps] enabled``),
    # set by the owner before ``start``.
    apps_host: bool

    async def start(
        self,
        folder: Path,
        resume: str | None,
        setting_sources: list[str],
        callbacks: EngineCallbacks,
        *,
        extra_servers: dict[str, dict] | None = None,
        plugin_paths: list[str] | None = None,
    ) -> str:
        """Connect in ``folder``. v0.18: ``extra_servers`` (the person's MCP servers,
        ``mcp_inventory.servers_for_engine``) go in beside ``portico``; ``plugin_paths``
        are local plugin directories to load."""
        ...

    async def send(self, text: str, images: list[dict[str, Any]] | None = None) -> None:
        """Send ``text`` as the next turn; v0.19: ``images`` (``images.image_block``) go after it as content blocks."""
        ...

    async def inject(self, text: str, images: list[dict[str, Any]] | None = None) -> None:
        """Write a person's message into the turn in flight (v0.11, item 74); ``turn`` does not move.

        The engine reads it at its next step, inside the same turn; written
        after its last step, it may run it as a further turn of its own.
        """
        ...

    async def interrupt(self) -> None: ...

    async def set_permission_mode(self, mode: PermissionMode) -> None:
        """Change the permission mode now (when running) and for every later turn."""
        ...

    def slash_commands(self) -> set[str] | None:
        """The slash commands the running engine knows (names without ``/``); ``None`` when it cannot say."""
        ...

    def command_list(self) -> list[AgentCommand] | None:
        """The running engine's commands and skills with descriptions (v0.11 item 66); ``None`` when it cannot say."""
        ...

    def models(self) -> list[ModelChoice] | None:
        """The models the running engine offers, its ``/model`` list (v0.15); ``None`` when it cannot say."""
        ...

    async def set_model(self, value: str | None) -> None:
        """Switch the model now (when running) and for a later ``start``; ``None`` is the default (v0.15)."""
        ...

    async def close(self) -> None: ...

    async def context_usage(self) -> tuple[float, str | None] | None:
        """How full the context window is, as ``(percent 0-100, model)``; ``None`` when unavailable."""
        ...

    # v0.18 (ruling 29): the MCP seam. Each raises before ``start``.

    async def mcp_status(self) -> list[dict[str, Any]]:
        """The live servers, the ``mcpServers`` list of the CLI's MCP status."""
        ...

    async def mcp_toggle(self, name: str, enabled: bool) -> None: ...

    async def mcp_reconnect(self, name: str) -> None: ...

    async def mcp_app_read(self, server: str, uri: str) -> dict[str, Any]:
        """``mcp_read_resource``: the reply carries ``contents``."""
        ...

    async def mcp_app_call(self, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        """``mcp_call`` with ``result_not_for_model``: the server's result, kept from the model."""
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


def error_detail(msg: Message) -> list[str]:
    """v0.25 §4.3: what an engine message says about an error, as strings, for the sign-in rule. Never logged.

    From a failed ``ResultMessage``: its ``errors``, ``result``,
    ``api_error_status`` and ``terminal_reason``. From an ``AssistantMessage``
    with ``error`` set: the error, then the message's own words (the engine
    puts "Login expired · Please run /login" there). Anything else: nothing.
    """
    out: list[str] = []
    if isinstance(msg, ResultMessage):
        if not msg.is_error:
            return out
        out += [str(e) for e in (getattr(msg, "errors", None) or []) if e is not None]
        for name in ("result", "api_error_status", "terminal_reason"):
            value = getattr(msg, name, None)
            if value is not None and str(value):
                out.append(str(value))
    elif isinstance(msg, AssistantMessage):
        if not getattr(msg, "error", None):
            return out
        out.append(str(msg.error))
        out += [block.text for block in msg.content if isinstance(block, TextBlock) and block.text]
    return out


class TurnErrors:
    """A turn's error detail as the engine's messages arrive; attached to the turn's ``turn.finished`` (v0.25)."""

    def __init__(self) -> None:
        self.detail: list[str] = []

    def reset(self) -> None:
        self.detail = []

    def note(self, msg: Message) -> None:
        self.detail += error_detail(msg)

    def attach(self, event: ServerMessage) -> ServerMessage:
        """``event``, and when it is a ``turn.finished``, carrying the detail so far (which then starts afresh)."""
        if isinstance(event, TurnFinished):
            event.with_error_detail(self.detail)
            self.detail = []
        return event


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
        results = [block for block in msg.content if isinstance(block, ToolResultBlock)]
        # v0.18 (§2.6.1): the message's ``tool_use_result`` (``{content, structuredContent}``) is
        # one call's; it rides on that call's row, privately, when the message carries one result.
        raw = msg.tool_use_result if len(results) == 1 and isinstance(msg.tool_use_result, dict) else None
        for block in results:
            out.append(
                ToolFinished(
                    ts=ts,
                    chat=chat,
                    turn=turn,
                    tool_use_id=block.tool_use_id,
                    ok=not bool(block.is_error),
                    summary=result_summary(block.content),
                    permission="blocked" if blocked_by_auto_mode(block.is_error, block.content) else None,
                ).with_raw_result(raw)
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
                answers = await callbacks.on_question(questions, context.tool_use_id or "")
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
    text = _read_append(append)
    if kind == "none":
        return text or None
    return {"type": "preset", "preset": "claude_code", **({"append": text} if text else {})}


# v0.24: the first line ``capture-prompt`` writes, and the comment it puts before a machine-specific line.
HEADER_RE = re.compile(
    r"^<!-- captured from Claude Code (?P<version>\S+) · model (?P<model>\S+) · (?P<date>\d{4}-\d{2}-\d{2}) -->$"
)
MARKER_PREFIX = "<!-- machine-specific:"
# A capture whose engine version couldn't be read: no version recorded (``HEADER_RE`` doesn't match it).
UNKNOWN_HEADER_RE = re.compile(r"^<!-- captured from Claude Code \(version unknown\) · model \S+ · \d{4}-\d{2}-\d{2} -->$")
# The engine's own request-accounting line, never prompt text.
BILLING_PREFIX = "x-anthropic-billing-header:"


def custom_prompt_text(raw: str) -> str:
    """A custom prompt file's text as sent: the capture header and machine-specific markers removed (v0.24 ruling 3)."""
    def note(line: str) -> bool:
        bare = line.strip()
        return (
            bool(HEADER_RE.match(bare) or UNKNOWN_HEADER_RE.match(bare))
            or (bare.startswith(MARKER_PREFIX) and bare.endswith("-->"))
            or bare.startswith(BILLING_PREFIX)
        )

    lines = [line for line in raw.splitlines() if not note(line)]
    return "\n".join(lines).strip()


def prompt_header_version(path: Path | str) -> str | None:
    """The Claude Code version a captured prompt file's header records, or ``None`` (no header, unreadable)."""
    try:
        with open(path, encoding="utf-8") as f:
            first = f.readline().strip()
    except (OSError, UnicodeDecodeError):
        return None
    match = HEADER_RE.match(first)
    return match.group("version") if match else None


def prompt_header_unknown(path: Path | str) -> bool:
    """Whether a captured file's header says the engine's version couldn't be read."""
    try:
        with open(path, encoding="utf-8") as f:
            return bool(UNKNOWN_HEADER_RE.match(f.readline().strip()))
    except (OSError, UnicodeDecodeError):
        return False


@dataclasses.dataclass
class SessionPrompt:
    """v0.24: the prompt one engine start uses, and what the session records about it.

    ``source`` is the custom file's path, or ``claude_code`` / ``none``;
    ``fell_back`` is set when a custom file could not be read and Claude
    Code's prompt is used instead.
    """

    prompt: Any
    mode: str
    source: str
    fell_back: bool = False


def session_prompt(kind: str, append: str | None, file: str | None, out: Path) -> SessionPrompt:
    """The system prompt for one engine start, as the config asks (v0.24 §3).

    ``custom`` reads ``file`` now (an edit applies to the next start) and
    gives ``{"type": "file", "path": out, "text": …}``: the file's text,
    then ``append``'s; Portico's lines are added to ``text`` and
    ``materialize_prompt`` writes it to ``out`` (rulings 1 and 2). A file
    that can't be read is logged, and Claude Code's prompt is used, never
    an empty one. Other kinds are ``deployment_system_prompt``.
    """
    if kind == "custom" and file:
        try:
            text = custom_prompt_text(Path(file).read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError) as e:
            log.error("system_prompt_file %s could not be read; this session uses Claude Code's prompt: %s", file, e)
            return SessionPrompt(deployment_system_prompt("claude_code", append), "claude_code", "claude_code", fell_back=True)
        if not text.strip():
            log.error("system_prompt_file %s is empty (after its notes); this session uses Claude Code's prompt", file)
            return SessionPrompt(deployment_system_prompt("claude_code", append), "claude_code", "claude_code", fell_back=True)
        extra = _read_append(append)
        if extra:
            text = f"{text}\n\n{extra}" if text else extra
        return SessionPrompt({"type": "file", "path": str(out), "text": text}, "custom", str(file))
    mode = "none" if kind == "none" else "claude_code"
    return SessionPrompt(deployment_system_prompt(mode, append), mode, mode)


def _read_append(append: str | None) -> str:
    if not append:
        return ""
    try:
        return Path(append).read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError) as e:
        log.error("system_prompt_append %s could not be read; starting without it: %s", append, e)
        return ""


def materialize_prompt(system_prompt: Any) -> Any:
    """A composed custom prompt written to its file (0600) and returned as the SDK's file prompt; others as they are."""
    if isinstance(system_prompt, Mapping) and system_prompt.get("type") == "file" and "text" in system_prompt:
        path = Path(system_prompt["path"])
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(system_prompt["text"], encoding="utf-8")
        tmp.chmod(0o600)
        tmp.replace(path)
        return {"type": "file", "path": str(path)}
    return system_prompt


def prompt_text(system_prompt: Any) -> str:
    """The prompt text Portico controls (v0.24 ruling 4): a preset is ``claude_code`` plus its append."""
    if system_prompt is None:
        return ""
    if isinstance(system_prompt, str):
        return system_prompt
    if isinstance(system_prompt, Mapping):
        kind = system_prompt.get("type")
        if kind == "preset":
            append = system_prompt.get("append") or ""
            return f"claude_code\n{append}"
        if kind == "custom":
            return system_prompt.get("prompt") or ""
        if kind == "file":
            if "text" in system_prompt:
                return system_prompt["text"]
            try:
                return Path(system_prompt["path"]).read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                return ""
    return ""


def prompt_fingerprint(system_prompt: Any) -> str:
    """The first 8 hex digits of a SHA-256 of ``prompt_text``: what the session records (v0.24 §3)."""
    import hashlib

    return hashlib.sha256(prompt_text(system_prompt).encode("utf-8")).hexdigest()[:8]


def final_system_prompt(system_prompt: Any, callbacks: Any) -> Any:
    """``system_prompt`` with the viewer line ``build_options`` adds for an owner that can show files."""
    if callable(getattr(callbacks, "on_show", None)):
        return with_viewer_prompt(system_prompt, getattr(callbacks, "spaces_folder", None))
    return system_prompt


def append_prompt_line(system_prompt: Any, line: str) -> Any:
    """``system_prompt`` (as ``ClaudeAgentOptions`` takes it) with ``line`` appended, never replacing it.

    ``None`` is the SDK's default, an empty prompt: the line becomes the
    prompt. A preset keeps its ``append`` and gets the line after it; a
    custom prompt gets the line after its text, as does a composed custom
    prompt file (v0.24, one with ``text``). Any other prompt file cannot be
    appended to and is left as it is.
    """
    if system_prompt is None:
        return line
    if isinstance(system_prompt, str):
        return f"{system_prompt}\n\n{line}" if system_prompt else line
    if isinstance(system_prompt, Mapping):
        kind = system_prompt.get("type")
        if kind == "preset":
            before = system_prompt.get("append") or ""
            return {**system_prompt, "append": f"{before}\n\n{line}" if before else line}
        if kind == "custom":
            before = system_prompt.get("prompt") or ""
            return {**system_prompt, "prompt": f"{before}\n\n{line}" if before else line}
        if kind == "file" and "text" in system_prompt:
            # v0.24: a composed custom prompt (``session_prompt``), not yet written.
            before = system_prompt.get("text") or ""
            return {**system_prompt, "text": f"{before}\n\n{line}" if before else line}
    return system_prompt


def with_viewer_prompt(system_prompt: Any, spaces_folder: Path | str | None = None) -> Any:
    """``system_prompt`` with ``VIEWER_PROMPT`` appended (``append_prompt_line``).

    With a ``spaces_folder`` (v0.12) the spaces line follows the viewer line.
    """
    line = VIEWER_PROMPT
    if spaces_folder:
        line = f"{VIEWER_PROMPT} {SPACES_PROMPT.format(folder=spaces_folder)}"
    return append_prompt_line(system_prompt, line)


def build_show_tool(callbacks: EngineCallbacks):
    """The ``show_in_viewer`` tool: the file goes to the viewer, or the agent hears why not."""

    @tool(
        SHOW_TOOL,
        "Show a file or a web page in the viewer beside this conversation, where the person sees it. "
        "path is a file's path (relative to the session's folder, or absolute) or an http:// or https:// "
        "address. Answers once the page has loaded." + QUEUE_NOTE,
        {"path": str},
    )
    async def show_in_viewer(args: dict[str, Any]) -> dict[str, Any]:
        path = args.get("path")
        if not isinstance(path, str) or not path.strip():
            return {"content": [{"type": "text", "text": "Not shown: give the path of a file."}], "is_error": True}
        answer = await callbacks.on_show([path.strip()])
        if isinstance(answer, str):
            return {"content": [{"type": "text", "text": answer}], "is_error": True}
        text = answer.text if isinstance(answer, Shown) else SHOWN_TEXT
        return {"content": [{"type": "text", "text": text}]}

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
            answer = await callbacks.on_show(paths)
        except Exception:
            log.exception("showing %s in the viewer failed", paths)
            return {"continue_": True}
        if isinstance(answer, str) and answer != STOPPED:  # refused: the command runs as before
            return {"continue_": True}
        return {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                # v0.17: an `open` that waited in the viewer queue through a stop is not run either.
                "permissionDecisionReason": STOPPED if answer == STOPPED else OPEN_SHOWN_REASON,
            }
        }

    return open_hook


def _written_lately(path: Path, seconds: float = 30.0) -> bool:
    """Whether ``path`` was modified within the last ``seconds``."""
    try:
        return time.time() - path.stat().st_mtime <= seconds
    except OSError:
        return False


def build_check_html_hook(bridge: Any, folder: Path, roots: list[Path]):
    """The ``PostToolUse`` hook on ``Write|Edit|MultiEdit|Bash`` (v0.12): look at the HTML you just made.

    After a write to an ``.html``/``.htm`` file inside the chat's folder or a
    root, ``additionalContext`` tells the agent to show it and look at it.
    Both ``bridge.can_see`` and ``bridge.check_html`` are read on every call,
    so a change in Settings applies within the session. With no app that can
    act on it (none declared ``viewer.v1`` and sent ``viewer.settings``) it
    adds nothing: the agent would be told to look with a viewer it cannot reach.
    """
    allowed = [Path(p).expanduser() for p in (folder, *roots)]

    async def check_html_hook(input: Any, tool_use_id: str | None, context: Any) -> dict[str, Any]:
        if not (bridge.has_target and bridge.can_see and bridge.check_html):
            return {}
        tool_input = input.get("tool_input") if isinstance(input, Mapping) else None
        if not isinstance(tool_input, Mapping):
            return {}
        cwd = input.get("cwd") if isinstance(input, Mapping) else None
        base = Path(cwd) if isinstance(cwd, str) and cwd else folder
        if input.get("tool_name") == "Bash":
            # A shell write: the same detection the artifact list uses, the files the command names that now exist.
            command = tool_input.get("command")
            candidates = paths_in(command, base) if isinstance(command, str) else []
            # Only files the command just wrote: a read of an old page names it too.
            candidates = [c for c in candidates if _written_lately(c if c.is_absolute() else base / c)]
        else:
            raw = tool_input.get("file_path")
            candidates = [Path(raw)] if isinstance(raw, str) else []
        found: list[Path] = []
        for candidate in candidates:
            if candidate.suffix.lower() not in (".html", ".htm"):
                continue
            path = candidate.expanduser()
            if not path.is_absolute():
                path = base / path
            try:
                path = path.resolve()
                inside = any(path.is_relative_to(a.resolve()) for a in allowed)
            except (OSError, RuntimeError):
                continue
            if inside and path not in found:
                found.append(path)
        if not found:
            return {}
        names = found[0] if len(found) == 1 else ", ".join(map(str, found[:-1])) + f" and {found[-1]}"
        return {
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": (
                    f"Before you reply, show {names} in the viewer and look at it with viewer_look; "
                    "tell the person what you saw and fix what's broken."
                ),
            }
        }

    return check_html_hook


def build_mark_hook(bridge: Any, chat: int):
    """The ``PreToolUse`` hook on ``viewer_mark``: note the call's id so the app can tie its marks to the tool row."""

    async def mark_hook(input: Any, tool_use_id: str | None, context: Any) -> dict[str, Any]:
        tool_input = input.get("tool_input") if isinstance(input, Mapping) else None
        use_id = input.get("tool_use_id") if isinstance(input, Mapping) else None
        if isinstance(tool_input, Mapping) and isinstance(use_id or tool_use_id, str):
            bridge.note_mark_use(chat, use_id or tool_use_id, dict(tool_input))
        return {}

    return mark_hook


def build_thread_tool(callbacks: Any):
    """The ``open_thread`` tool (v0.16): Main's agent proposes a thread; the person starts it or not.

    Returns at once with what the owner answers; a refusal (an empty brief,
    a path that is not a file) is ``is_error``.
    """

    @tool(
        OPEN_THREAD_TOOL,
        TOOL_DESCRIPTION,
        {
            "type": "object",
            "properties": {
                "brief": {"type": "string", "description": "What the thread is for, in one or two sentences."},
                "files": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Files the thread should start with; a path may be relative to this session's folder.",
                },
            },
            "required": ["brief"],
        },
    )
    async def open_thread(args: dict[str, Any]) -> dict[str, Any]:
        brief = args.get("brief")
        raw = args.get("files") or []
        if not isinstance(brief, str) or not brief.strip():
            return {"content": [{"type": "text", "text": EMPTY_BRIEF}], "is_error": True}
        files = [f for f in raw if isinstance(f, str) and f.strip()] if isinstance(raw, list) else []
        text = await callbacks.on_open_thread(brief.strip(), [f.strip() for f in files])
        if text.startswith(REFUSAL_PREFIX):
            return {"content": [{"type": "text", "text": text}], "is_error": True}
        return {"content": [{"type": "text", "text": text}]}

    return open_thread


def build_thread_hook(callbacks: Any):
    """The ``PreToolUse`` hook on ``open_thread``: the owner notes the call's id and input, which the proposal carries."""

    async def thread_hook(input: Any, tool_use_id: str | None, context: Any) -> dict[str, Any]:
        tool_input = input.get("tool_input") if isinstance(input, Mapping) else None
        use_id = input.get("tool_use_id") if isinstance(input, Mapping) else None
        if isinstance(tool_input, Mapping) and isinstance(use_id or tool_use_id, str):
            callbacks.note_thread_use(use_id or tool_use_id, dict(tool_input))
        return {}

    return thread_hook


# The show tool is allowed outright on purpose (it only shows a file), so the
# SDK's advisory that ``can_use_tool`` will not see it is expected.
# The v0.12 viewer tools are allowed outright the same way (the person watches
# each action and has Stop), so the advisory is expected for them too, and
# (v0.16) for ``open_thread``, which only proposes.
warnings.filterwarnings(
    "ignore",
    message=rf"can_use_tool will not be invoked for: (?:(?:{'|'.join(re.escape(n) for n in (SHOW_TOOL_NAME, OPEN_THREAD_TOOL_NAME, *VIEWER_TOOL_NAMES, *COMMENT_TOOL_NAMES))})(?:, )?)+\.",
    category=CanUseToolShadowedWarning,
)


def build_options(
    folder: Path,
    resume: str | None,
    setting_sources: list[str],
    callbacks: EngineCallbacks,
    permission_mode: PermissionMode = "default",
    system_prompt: Any = None,
    model: str | None = None,
    extra_servers: Mapping[str, dict] | None = None,
    plugin_paths: list[str] | None = None,
    apps_host: bool = False,
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

    With an owner that can propose threads (``on_open_thread``, v0.16,
    Main's only): the ``open_thread`` tool on the same server, allowed
    outright, and a ``PreToolUse`` hook that notes its call's id. The
    owner's prompt line (``MAIN_PROMPT``) is already in ``system_prompt``.

    ``PORTICO_ATTENDED=1`` is always in the engine's environment: a person
    drives this chat (v0.11). ``CLAUDE_CODE_MCP_APPS_HOST=1`` is too when
    ``apps_host`` (v0.18, ``[apps] enabled``).

    ``model`` (v0.15) is the stored ``model.set`` choice, passed only when
    set; without it the engine starts on the deployment's default.

    v0.18 (§3.2): ``extra_servers`` are the person's own MCP servers, passed
    in ``mcp_servers`` after ``portico`` (with or without Portico's tools; a
    ``portico`` key among them is ignored), and ``plugin_paths`` local plugin
    directories, passed as ``plugins``. ``setting_sources`` is never changed
    for them.
    """
    pre_tool_use = [HookMatcher(matcher=QUESTION_TOOL, hooks=[noop_hook])]
    post_tool_use: list[Any] = []
    extra: dict[str, Any] = {} if system_prompt is None else {"system_prompt": materialize_prompt(system_prompt)}
    # v0.12: the spaces folder is one of the agent's own places (an extra directory), so writing a space
    # has the permissions of writing in the chat's folder.
    spaces_folder = getattr(callbacks, "spaces_folder", None)
    add_dirs: list[str | Path] = [spaces_folder] if spaces_folder else []
    tools: list[Any] = []
    allowed: list[str] = []
    prompt = system_prompt
    if callable(getattr(callbacks, "on_show", None)):
        pre_tool_use.append(HookMatcher(matcher="Bash", hooks=[build_open_hook(callbacks)]))
        tools.append(build_show_tool(callbacks))
        allowed.append(SHOW_TOOL_NAME)
        bridge = getattr(callbacks, "viewer_bridge", None)
        if bridge is not None:
            # v0.12: the agent sees and uses the viewer; the tools answer "not available" when no app can.
            tools += build_viewer_tools(bridge, callbacks.viewer_chat)  # type: ignore[attr-defined]
            allowed += VIEWER_TOOL_NAMES
            # v0.23: the comment tools sit beside the viewer tools, available whenever they are.
            tools += build_comment_tools(callbacks)
            allowed += COMMENT_TOOL_NAMES
            pre_tool_use.append(
                HookMatcher(matcher="mcp__portico__viewer_mark", hooks=[build_mark_hook(bridge, callbacks.viewer_chat)])  # type: ignore[attr-defined]
            )
            roots = list(getattr(callbacks, "viewer_roots", []))
            post_tool_use.append(
                HookMatcher(matcher="Write|Edit|MultiEdit|Bash", hooks=[build_check_html_hook(bridge, folder, roots)])
            )
        prompt = final_system_prompt(system_prompt, callbacks)
    if callable(getattr(callbacks, "on_open_thread", None)):
        # v0.16: Main's owner only (the server gives a thread's engine no such owner).
        tools.append(build_thread_tool(callbacks))
        allowed.append(OPEN_THREAD_TOOL_NAME)
        pre_tool_use.append(HookMatcher(matcher=OPEN_THREAD_TOOL_NAME, hooks=[build_thread_hook(callbacks)]))
    if tools:
        extra = {
            "mcp_servers": {SHOW_SERVER: create_sdk_mcp_server(SHOW_SERVER, tools=tools)},
            "allowed_tools": allowed,
            **({} if prompt is None else {"system_prompt": materialize_prompt(prompt)}),
        }
    servers = {name: dict(cfg) for name, cfg in (extra_servers or {}).items() if name != SHOW_SERVER}
    if servers:
        extra["mcp_servers"] = {**extra.get("mcp_servers", {}), **servers}
    if plugin_paths:
        extra["plugins"] = [{"type": "local", "path": p} for p in plugin_paths]
    if model is not None:
        extra["model"] = model
    return ClaudeAgentOptions(
        cwd=str(folder),
        add_dirs=add_dirs,
        resume=resume,
        permission_mode=permission_mode,
        setting_sources=list(setting_sources),  # type: ignore[arg-type]
        can_use_tool=build_can_use_tool(callbacks),
        include_partial_messages=True,
        max_buffer_size=CLI_MAX_BUFFER_BYTES,
        env={ATTENDED_ENV: "1", **({APPS_HOST_ENV: "1"} if apps_host else {})},
        hooks={
            "PreToolUse": pre_tool_use,
            "PreCompact": [HookMatcher(matcher=None, hooks=[build_compact_hook(callbacks)])],
            **({"PostToolUse": post_tool_use} if post_tool_use else {}),
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


def without_price(description: str) -> str:
    """``description`` without its price parts (Larry 11-02: no pricing shown).

    API-key logins append `` · $4/$20 per Mtok`` (sometimes with a long-prompt
    rate); it is wrong for other providers and not for display. Any `` · `` part
    holding a ``$`` amount or "per Mtok" goes; the others stay in order.
    """
    parts = [p for p in description.split(" · ") if not re.search(r"\$\d|per Mtok", p)]
    return " · ".join(parts).strip()


def model_choices(raw: Any) -> list[ModelChoice] | None:
    """The engine's ``models`` (``get_server_info()``) as ``ModelChoice``s (v0.15); ``None`` when not a list.

    Each entry is ``{value, displayName, description, resolvedModel, ...}``;
    an entry without a usable ``value`` is skipped, a missing
    ``displayName`` falls back to the value, and ``resolvedModel`` is kept
    as ``resolved_model`` when it is a non-empty string. Order is kept.
    Prices are dropped from descriptions (``without_price``).
    """
    if not isinstance(raw, list):
        return None
    out: list[ModelChoice] = []
    for entry in raw:
        if not isinstance(entry, Mapping):
            continue
        value = entry.get("value")
        if not isinstance(value, str) or not value.strip():
            continue
        name = entry.get("displayName")
        text = entry.get("description")
        resolved = entry.get("resolvedModel")
        out.append(
            ModelChoice(
                value=value,
                display_name=name if isinstance(name, str) and name.strip() else value,
                description=without_price(text) if isinstance(text, str) else "",
                resolved_model=resolved if isinstance(resolved, str) and resolved.strip() else None,
            )
        )
    return out


def agent_commands(raw: Any) -> list[AgentCommand]:
    """The engine's ``commands`` (``get_server_info()``) as the composer's list (v0.11 item 66).

    Each entry is ``{name, description, argumentHint}``; the description
    ends in its source in parentheses ("... (user)"), which becomes
    ``source``. The description keeps its first line and first sentence,
    at most ``COMMAND_DESCRIPTION_LIMIT`` characters. Entries without a
    usable name, and repeats of a name, are skipped; order is kept. So are
    the engine's internal commands (a name starting ``__``) and ones it
    marks "(removed)": neither is something a person can usefully pick.
    """
    if not isinstance(raw, list):
        return []
    out: list[AgentCommand] = []
    seen: set[str] = set()
    for entry in raw:
        if not isinstance(entry, Mapping):
            continue
        name = entry.get("name")
        if not isinstance(name, str) or not name.strip().lstrip("/"):
            continue
        name = name.strip().lstrip("/")
        if name in seen or name.startswith("__"):
            continue
        seen.add(name)
        text = entry.get("description")
        text = text.strip() if isinstance(text, str) else ""
        if text.lower().startswith("(removed)"):
            continue
        source: str | None = None
        m = _COMMAND_SOURCE.search(text)
        if m:
            source = m.group(1).strip() or None
            text = text[: m.start()]
        text = text.strip().split("\n", 1)[0].strip()
        text = _SENTENCE_END.split(text, 1)[0]
        if len(text) > COMMAND_DESCRIPTION_LIMIT:
            text = text[: COMMAND_DESCRIPTION_LIMIT - 1].rstrip() + "…"
        out.append(AgentCommand(name=name, description=text, source=source))
    return out


# --- the SDK adapter -------------------------------------------------------------


def with_hooks_disabled(settings: str | None) -> str:
    """``settings`` (the SDK's JSON string, or none) with ``disableAllHooks`` on, for the model probe only.

    The SDK's ``settings`` is a JSON string or a settings file path; either
    is read and merged, so the setting is added rather than replacing them.
    """
    merged: dict[str, Any] = {}
    if settings:
        try:
            loaded = json.loads(settings)
        except ValueError:
            try:
                loaded = json.loads(Path(settings).expanduser().read_text())
            except (OSError, ValueError):
                loaded = {}
        if isinstance(loaded, dict):
            merged.update(loaded)
    merged["disableAllHooks"] = True
    return json.dumps(merged)


class _ProbeCallbacks:
    """The owner of a model probe: it sends no message, so nothing reaches here; anything that did is refused."""

    async def on_event(self, event: ServerMessage) -> None:
        return None

    async def on_permission(
        self, tool: str, input: dict[str, Any], suggestions: list[dict[str, Any]], tool_use_id: str
    ) -> PermissionDecision:
        return "deny"

    async def on_question(self, questions: list[dict[str, Any]], tool_use_id: str = "") -> dict[str, str | list[str]]:
        raise QuestionDeclined("no session")

    async def on_compacted(self, trigger: str) -> None:
        return None


# v0.18 (ruling 21): the CLI capability that says MCP Apps can work.
APPS_CAPABILITY = "mcp_call_result_not_for_model_v1"


def apps_capable(info: Any) -> bool:
    """Whether ``get_server_info()``'s ``capabilities`` list ``APPS_CAPABILITY``."""
    caps = info.get("capabilities") if isinstance(info, Mapping) else None
    return isinstance(caps, list) and APPS_CAPABILITY in caps


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
        # v0.15: the model to start on (``None``: the deployment's default).
        self.model: str | None = None
        self.init_timeout = init_timeout
        self._client: ClaudeSDKClient | None = None
        self._callbacks: EngineCallbacks | None = None
        self._pump: asyncio.Task[None] | None = None
        self._init_seen = asyncio.Event()
        # The last turn a result message closed; ``turn`` beyond it is in flight.
        self._finished_turn = 0
        self._closing = False
        # v0.25: the turn's error detail, attached to its ``turn.finished``.
        self._errors = TurnErrors()
        # Slash command names (no ``/``) from the engine's initialize answer
        # and its ``init`` message; ``None`` until either has said.
        self._commands: set[str] | None = None
        # v0.11 (item 66): the same commands with descriptions, from the
        # initialize answer only (``init`` carries names alone).
        self._command_list: list[AgentCommand] | None = None
        # v0.15: the ``/model`` list from the initialize answer.
        self._models: list[ModelChoice] | None = None
        # v0.10: this engine's subagents and workflows.
        self.agents = AgentTracker()
        # v0.18: set by ``start`` from the CLI's capabilities.
        self.apps_capable = False
        # v0.18: the owner sets it from ``[apps] enabled`` before ``start``.
        self.apps_host = False

    async def start(
        self,
        folder: Path,
        resume: str | None,
        setting_sources: list[str],
        callbacks: EngineCallbacks,
        *,
        extra_servers: dict[str, dict] | None = None,
        plugin_paths: list[str] | None = None,
    ) -> str:
        if self._client is not None:
            raise RuntimeError("engine already started")
        self._callbacks = callbacks
        self.session_id = resume
        self._client = ClaudeSDKClient(
            build_options(
                folder,
                resume,
                setting_sources,
                callbacks,
                self.permission_mode,
                self.system_prompt,
                model=self.model,
                extra_servers=extra_servers,
                plugin_paths=plugin_paths,
                apps_host=self.apps_host,
            )
        )
        await self._client.connect()
        info = await self._client.get_server_info()
        self._note_commands_from_server_info(info)
        self._note_models_from_server_info(info)
        self.apps_capable = apps_capable(info)
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
                    self._errors.reset()
                    await self._callbacks.on_event(TurnStarted(ts=_now(), chat=self.chat, turn=self.turn))
                self._errors.note(msg)
                for event in translate(msg, self.chat, self.turn, self.agents):
                    if isinstance(event, TurnFinished):
                        self._finished_turn = event.turn
                    await self._callbacks.on_event(self._errors.attach(event))
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
            await self._callbacks.on_event(
                self._errors.attach(TurnFinished(ts=_now(), chat=self.chat, turn=turn, outcome="error"))
            )
        except Exception:
            log.exception("chat %s: could not report the lost turn", self.chat)

    def _note_commands_from_server_info(self, info: Any) -> None:
        commands = info.get("commands") if isinstance(info, Mapping) else None
        if isinstance(commands, list):
            self._add_commands(c.get("name") if isinstance(c, Mapping) else c for c in commands)
            self._command_list = agent_commands(commands)

    def _note_models_from_server_info(self, info: Any) -> None:
        models = model_choices(info.get("models") if isinstance(info, Mapping) else None)
        if models is not None:
            self._models = models

    def models(self) -> list[ModelChoice] | None:
        return list(self._models) if self._models is not None else None

    @staticmethod
    async def probe_models(folder: Path, setting_sources: list[str]) -> list[ModelChoice] | None:
        """The ``/model`` list without a session (v0.15 amendment 11-02): connect, read the server info, disconnect.

        Built with the same ``build_options`` an engine uses, so the CLI reads
        the same settings and provider environment; no message is sent. The
        owner bounds the time; a failure raises, after disconnecting.

        Unlike an engine, the probe runs with ``disableAllHooks`` (merged into
        any ``settings``): connecting and disconnecting would otherwise fire
        the deployment's ``SessionStart`` and ``SessionEnd`` hooks for a
        session nobody opened (verified 11-02; the list still comes back).
        """
        options = build_options(folder, None, setting_sources, _ProbeCallbacks())
        options.settings = with_hooks_disabled(options.settings)
        client = ClaudeSDKClient(options)
        try:
            await client.connect()
            info = await client.get_server_info()
        finally:
            try:
                await client.disconnect()
            except Exception as e:
                log.debug("model probe: disconnect failed: %s", e)
        return model_choices(info.get("models") if isinstance(info, Mapping) else None)

    async def set_model(self, value: str | None) -> None:
        """The SDK's ``set_model`` while connected; remembered for a later ``start`` either way."""
        if self._client is not None:
            await self._client.set_model(value)
        self.model = value

    def _add_commands(self, names: Iterable[Any]) -> None:
        found = {n.strip().lstrip("/") for n in names if isinstance(n, str) and n.strip()}
        self._commands = (self._commands or set()) | found

    def slash_commands(self) -> set[str] | None:
        return set(self._commands) if self._commands is not None else None

    def command_list(self) -> list[AgentCommand] | None:
        return list(self._command_list) if self._command_list is not None else None

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

    async def send(self, text: str, images: list[dict[str, Any]] | None = None) -> None:
        if self._client is None:
            raise RuntimeError("engine not started")
        self.turn += 1
        self._errors.reset()
        await self._client.query(_prompt(text, images))

    async def inject(self, text: str, images: list[dict[str, Any]] | None = None) -> None:
        """``query`` mid-turn: checked live 10-30, the engine takes it at its next step, in the same turn."""
        if self._client is None:
            raise RuntimeError("engine not started")
        await self._client.query(_prompt(text, images))

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

    # --- v0.18: the MCP seam (ruling 29) -------------------------------------------
    # Status, toggle and reconnect use the SDK's public calls. Reading an app's
    # HTML and calling a tool for an app have no public call in SDK 0.2.174
    # (pinned): they go through the private ``Query._send_control_request``,
    # here only (``tests/test_sdk_seam.py`` fails if it goes away).

    def _connected(self) -> ClaudeSDKClient:
        if self._client is None:
            raise RuntimeError("engine not started")
        return self._client

    async def mcp_status(self) -> list[dict[str, Any]]:
        status = await self._connected().get_mcp_status()
        servers = status.get("mcpServers") if isinstance(status, Mapping) else None
        return [dict(s) for s in servers if isinstance(s, Mapping)] if isinstance(servers, list) else []

    async def mcp_toggle(self, name: str, enabled: bool) -> None:
        await self._connected().toggle_mcp_server(name, enabled)

    async def mcp_reconnect(self, name: str) -> None:
        await self._connected().reconnect_mcp_server(name)

    async def _control(self, request: dict[str, Any]) -> dict[str, Any]:
        query = getattr(self._connected(), "_query", None)
        if query is None:
            raise RuntimeError("engine not connected")
        return await query._send_control_request(request)

    async def mcp_app_read(self, server: str, uri: str) -> dict[str, Any]:
        return await self._control({"subtype": "mcp_read_resource", "serverName": server, "uri": uri})

    async def mcp_app_call(self, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        return await self._control(
            {"subtype": "mcp_call", "tool": tool, "arguments": dict(arguments), "result_not_for_model": True}
        )

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
# v0.25 §4.4: what the gateway sends to carry a turn on after the person signed
# in again. Never the person's words: a replay draws no bubble for it.
CONTINUE_TEXT = "Your sign-in was renewed. Continue where you left off; don't repeat steps that already finished."
_HIDDEN_USER_TEXT_PREFIXES = (
    "<system-reminder>",
    "<local-command-",
    "<command-",
    "[Request interrupted by user",
    TASK_NOTIFICATION_PREFIX,
    CONTINUE_TEXT,
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


def transcript_times(session_id: str | None, folder: Path) -> dict[str, str]:
    """v0.25 §3.2: each transcript entry's time by its ``uuid``, in the gateway's format; ``{}`` on any failure.

    The transcript is found the way the SDK finds it for ``get_session_messages``
    (ruling 7), so the ``uuid`` of a session message is its entry's. If the
    SDK changes its layout, the lookup fails quietly and the times are left
    out: the app then shows none, never a wrong one.
    """
    if not session_id:
        return {}
    try:
        content = _read_session_file(session_id, str(folder))
    except Exception:
        return {}
    if not content:
        return {}
    times: dict[str, str] = {}
    for line in content.splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue
        uid, stamp = entry.get("uuid"), entry.get("timestamp")
        if not isinstance(uid, str) or not isinstance(stamp, str):
            continue
        normal = _normal_time(stamp)
        if normal is not None:
            times[uid] = normal
    return times


def _normal_time(stamp: str) -> str | None:
    """A transcript ``timestamp`` (``2026-11-06T21:42:10.123Z``) as ``_now()`` writes one (ruling 8); None if unreadable."""
    try:
        when = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=UTC)
    return when.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _blocks(content: Any) -> list[dict[str, Any]]:
    """A message's content as a list of block dicts (a plain string is one text block)."""
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return [b for b in content if isinstance(b, dict)]
    return []


def _prompt(text: str, images: list[dict[str, Any]] | None) -> str | AsyncIterator[dict[str, Any]]:
    """What ``query`` gets: ``text`` as today, or (v0.19, spec §8.3) with images, one user message of blocks."""
    if not images:
        return text
    message = user_message(text, list(images))

    async def one() -> AsyncIterator[dict[str, Any]]:
        yield message

    return one()


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


def history_events(
    messages: Iterable[Mapping[str, Any]], chat: int, first_turn: int = 1, times: Mapping[str, str] | None = None
) -> list[ServerMessage]:
    """Transcript messages (``read_history``'s dicts, or ``SessionMessage``-like) -> replay events. Pure.

    Each user message with text starts a turn (``turn.started``, ``user.text``);
    assistant text becomes ``text.delta``, tool calls and results
    ``tool.started`` / ``tool.finished``; every turn ends with
    ``turn.finished outcome=done``. Turns count from ``first_turn``. Nothing
    is stamped: ``seq`` is left unset. The SDK's session messages carry no
    time, so the events carry today's ``ts`` unless ``times`` (v0.25,
    ``transcript_times``) gives the message's: then each event takes its
    message's entry time (``turn.finished`` the last event's), and a
    ``user.text`` or ``text.delta`` with no match gets ``no_time``.
    """
    now = _now()
    ts = now
    no_time: bool | None = None
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
        if times is not None:
            found = times.get(str(m.get("uuid") or ""))
            ts, no_time = (found, None) if found else (now, True)
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
                # v0.19 (spec §8.4): the words typed, and the attachments apart.
                typed, attachments = split_attachments(split_edited_note(text))
                out.append(UserText(ts=ts, chat=chat, turn=turn, text=typed, attachments=attachments, no_time=no_time))
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
                    out.append(TextDelta(ts=ts, chat=chat, turn=turn, text=text, no_time=no_time))
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
