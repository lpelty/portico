"""The Portico protocol, version 1, as Pydantic models.

These models are the source of truth. The JSON Schema under ``protocol/schema``
and the examples under ``protocol/examples`` are exported from here, and the
app's Swift types are tested against every example.

Direction vocabulary: ``client`` is the app (app -> gateway), ``server`` is the
gateway (gateway -> app). ``hello`` and ``files.list`` exist in both directions
with different fields, so each direction has its own discriminated union.
"""

from __future__ import annotations

import json
from typing import Annotated, Any, Literal, Union

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, ValidationError
from pydantic.json_schema import models_json_schema

PROTOCOL_VERSION = 1

ChatStateWord = Literal["idle", "working", "waiting on you", "stopped"]
Scope = Literal["once", "chat", "always"]
Media = Literal["markdown", "image", "html", "pdf", "text", "url", "other"]
Outcome = Literal["done", "stopped", "error"]
Presentation = Literal["single", "multiple"]
# How the engine decides on tool use: ``default`` asks each time, ``acceptEdits``
# allows file edits, ``auto`` lets the engine's classifier decide.
PermissionMode = Literal["default", "acceptEdits", "auto"]
# What happened to one tool use's permission, drawn on its tool row.
PermissionOutcome = Literal["once", "session", "auto", "declined", "blocked"]
# A deployment service's state (v0.4): ``checking`` until its first check answers.
ServiceState = Literal["up", "down", "checking"]
# How a subagent ended (v0.10).
AgentOutcome = Literal["done", "failed", "stopped"]
# Where one workflow phase stands (v0.10).
PhaseState = Literal["pending", "running", "done", "failed"]

# v0.10: the client capability an app lists in its ``hello`` when it
# shows subagents and workflows. Only such an app is sent the ``agent.*`` and
# ``workflow.*`` frames and the tool rows of a subagent's own steps.
AGENTS_CAPABILITY = "agents.v1"

# v0.11 (item 74): the capability, on both sides, for messages typed while
# the agent works. A gateway that lists it queues a ``message.send`` that
# arrives during a turn (``chat.queued``) instead of refusing it, but only
# for an app that lists it too; only such an app is sent ``chat.queue``.
QUEUE_CAPABILITY = "queue.v1"


class ProtocolError(Exception):
    """A frame the gateway cannot accept; ``code`` goes out as ``error.code``."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


# --- building blocks ---------------------------------------------------------


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Brand(Strict):
    name: str
    agent_name: str
    accent: str | None = None
    icon: str | None = None
    # v0.7: an image (absolute path) the toolbar shows in place of the mark
    # and the name, e.g. the deployment's lockup.
    header_image: str | None = None


class Action(Strict):
    label: str
    text: str


class Root(Strict):
    name: str
    path: str


class ChatSummary(Strict):
    chat: int
    folder: str
    alias: str | None = None
    state: ChatStateWord
    created: str
    # Session facts (v0.2). ``title`` is the first line of the first message
    # until something better is known; ``ended`` is set when the session was
    # renewed; ``logged`` says whether its log step finished cleanly (absent
    # when none ran); ``parent`` is the session this one followed.
    title: str | None = None
    ended: str | None = None
    logged: bool | None = None
    parent: int | None = None
    compactions: int = 0
    context_percent: float | None = None
    mode: PermissionMode | None = None
    # v0.4: when the session was last logged (``session.log`` or a renewal's
    # log step that finished cleanly), and whether it has work since that
    # the deployment could log (computed by the gateway; false when the
    # deployment has no log step).
    logged_at: str | None = None
    unlogged: bool = False
    # v0.6: when a turn last finished in the session (any outcome), so the
    # app can say how long ago the agent last answered.
    last_reply: str | None = None


class Service(Strict):
    """One of the deployment's services (v0.4), as its check last found it.

    ``since`` is when the current state began (ISO 8601 UTC); ``detail`` one
    line for the menu; ``can_restart`` whether the deployment gave it a
    ``restart`` command.
    """

    id: str
    name: str
    state: ServiceState
    detail: str | None = None
    since: str | None = None
    can_restart: bool = False


class Permission(Strict):
    tool: str
    summary: str
    input: dict[str, Any]


class Option(Strict):
    label: str
    description: str


class Question(Strict):
    question: str
    header: str
    options: list[Option]
    multi_select: bool = False


class FormField(Strict):
    key: str
    label: str
    kind: Literal["text", "choice", "toggle"]
    options: list[str] | None = None


class Artifact(Strict):
    id: str
    kind: Literal["file", "url"]
    location: str
    media: Media
    title: str
    source: Literal["tool", "text", "producer"]
    open: bool


class Entry(Strict):
    name: str
    dir: bool
    size: int | None = None


class Hit(Strict):
    """One search result: ``path`` is relative to the searched root."""

    path: str
    snippet: str | None = None


class QueuedMessage(Strict):
    """A message the person sent during a turn, held by the gateway until it goes (v0.11).

    ``id`` is the ``message.send`` request's ``id`` (one the gateway made
    up when the request had none); ``text`` and ``attachments`` are as sent.
    """

    id: str
    text: str
    attachments: list[str] = []


# --- envelope ----------------------------------------------------------------


class Envelope(Strict):
    """Every message: ``type``, optional ``chat``/``id``/``seq``, and ``ts``."""

    type: str
    chat: int | None = None
    id: str | None = None
    seq: int | None = None
    ts: str


# --- app -> gateway (client) -------------------------------------------------


class HelloClient(Envelope):
    type: Literal["hello"] = "hello"
    protocol: Literal[1] = PROTOCOL_VERSION
    app_version: str
    # v0.10: what this app can show beyond protocol 1's first version, e.g.
    # ``agents.v1``. Absent from an older app, which is sent nothing it
    # did not declare.
    capabilities: list[str] | None = None


class ChatNew(Envelope):
    type: Literal["chat.new"] = "chat.new"
    folder: str


class ChatOpen(Envelope):
    type: Literal["chat.open"] = "chat.open"
    chat: int
    since: int | None = None


class ChatStop(Envelope):
    type: Literal["chat.stop"] = "chat.stop"
    chat: int


class ChatAlias(Envelope):
    type: Literal["chat.alias"] = "chat.alias"
    chat: int
    alias: str | None = None


class ChatRemove(Envelope):
    type: Literal["chat.remove"] = "chat.remove"
    chat: int


class MessageSend(Envelope):
    type: Literal["message.send"] = "message.send"
    chat: int
    text: str
    attachments: list[str] = []


class ChatUnqueue(Envelope):
    """Take a queued message (``id``, as ``chat.queued`` named it) off the queue before it goes (v0.11).

    Answered with the ``chat.queue`` that follows, or ``error
    code=chat.not_queued`` when it has already gone to the agent (or was
    never queued). An edit is this, then a new ``message.send``.
    """

    type: Literal["chat.unqueue"] = "chat.unqueue"
    chat: int
    id: str


class SessionMode(Envelope):
    """Change the session's permission mode; answered with ``chat.state`` carrying ``mode``."""

    type: Literal["session.mode"] = "session.mode"
    chat: int
    mode: PermissionMode


class TurnStop(Envelope):
    type: Literal["turn.stop"] = "turn.stop"
    chat: int


class CardAnswer(Envelope):
    type: Literal["card.answer"] = "card.answer"
    chat: int
    id: str
    answer: dict[str, Any]
    scope: Scope | None = None
    note: str | None = None


class FilesListRequest(Envelope):
    type: Literal["files.list"] = "files.list"
    root: str
    path: str = ""


class ArtifactOpened(Envelope):
    type: Literal["artifact.opened"] = "artifact.opened"
    chat: int
    artifact_id: str


class SessionRenew(Envelope):
    """End the session ``chat`` and start the next one in the same folder.

    With ``log`` the gateway first runs the deployment's log step in the
    ending session and waits for it. Answered with ``session.renewed``.
    """

    type: Literal["session.renew"] = "session.renew"
    chat: int
    log: bool = True


class SessionLog(Envelope):
    """Run the deployment's log step in the live session ``chat`` without ending it (v0.4).

    Answered with ``session.logged`` then ``chat.list``.
    """

    type: Literal["session.log"] = "session.log"
    chat: int


class ServiceRestart(Envelope):
    """Run a service's ``restart`` command, then check it again (v0.4).

    Answered by the ``services.status`` that follows. v0.8: refused with
    ``services.busy`` while a ``services.restart_all`` runs.
    """

    type: Literal["service.restart"] = "service.restart"
    service: str


class ServicesRestartAll(Envelope):
    """Restart all the deployment's services with its one restart command (v0.8).

    Only when ``hello.capabilities`` has ``services.restart_all``. No
    ``services.status`` goes out while it runs; the one read after the
    restart is the answer. A restart that fails also answers, after that
    status, with ``error code=services.restart_failed`` carrying the
    request's ``id``.
    """

    type: Literal["services.restart_all"] = "services.restart_all"


class SessionsClear(Envelope):
    """Forget the ended sessions, keeping the live one (v0.11, single presentation only).

    Only when ``hello.capabilities`` has ``sessions.clear``. Only Portico's
    list is cleared: the engine's transcripts on disk stay, and the numbers
    are never handed out again. Answered with ``chat.list``; refused with
    ``sessions.not_single`` in multiple presentation.
    """

    type: Literal["sessions.clear"] = "sessions.clear"


class FilesSearch(Envelope):
    """Search names and text under a root; answered with ``files.results``."""

    type: Literal["files.search"] = "files.search"
    root: str
    query: str


class GatewayStop(Envelope):
    """Stop the gateway: interrupt every running turn, run ``on_stop``, exit.

    Distinct from quitting the app, which only detaches.
    """

    type: Literal["gateway.stop"] = "gateway.stop"


# --- gateway -> app (server) -------------------------------------------------


class HelloServer(Envelope):
    type: Literal["hello"] = "hello"
    protocol: Literal[1] = PROTOCOL_VERSION
    gateway_version: str
    epoch: str
    brand: Brand
    actions: list[Action] = []
    roots: list[Root] = []
    commands: list[str] = []
    capabilities: list[str] = []
    # How the app presents chats: one live session at a time, or a list.
    presentation: Presentation = "single"
    # Whether renewing can log the ending session first.
    can_log: bool = False
    # The config file changed after the gateway started; restart to apply.
    config_stale: bool = False
    # The deployment has an update command (``portico-gateway update`` runs it).
    can_update: bool = False
    # Where a new session works when the person has not chosen a folder.
    default_folder: str | None = None
    # The mode a new session starts in (config ``permission_mode``), so the
    # start screen shows the mode the session will really run in (v0.3).
    permission_mode: PermissionMode | None = None
    # v0.11: the Files pane leaves out the session's own folder (the
    # ``chat`` root); it still resolves (config ``[files] hide_session_folder``).
    hide_session_folder: bool = False


class ChatList(Envelope):
    type: Literal["chat.list"] = "chat.list"
    chats: list[ChatSummary] = []
    # v0.11: the number the next new session will have, so the welcome
    # names it ("Session 42") before it exists. Absent from an older gateway.
    next_chat: int | None = None


class ChatState(Envelope):
    type: Literal["chat.state"] = "chat.state"
    chat: int
    state: ChatStateWord
    mode: PermissionMode | None = None
    # v0.4: ``ChatSummary.unlogged`` as of this state. The gateway sets it on
    # every ``chat.state`` it sends, so the app learns of new unlogged work
    # when a turn finishes (``chat.state idle``) without waiting for a
    # ``chat.list``. Absent from a gateway before v0.4.
    unlogged: bool | None = None


class ChatLive(Envelope):
    type: Literal["chat.live"] = "chat.live"
    chat: int


class TurnStarted(Envelope):
    type: Literal["turn.started"] = "turn.started"
    chat: int
    turn: int


class UserText(Envelope):
    """What the person sent to start a turn, as the engine received it.

    Live, right after ``turn.started`` (stamped, in the ring), and in a
    transcript replay (``chat.history``, unstamped): one rendering path
    for the person's words whichever way the conversation arrives.
    """

    type: Literal["user.text"] = "user.text"
    chat: int
    turn: int
    text: str


class TextDelta(Envelope):
    type: Literal["text.delta"] = "text.delta"
    chat: int
    turn: int
    text: str


class ToolStarted(Envelope):
    type: Literal["tool.started"] = "tool.started"
    chat: int
    turn: int
    tool_use_id: str
    tool: str
    summary: str
    input: dict[str, Any] = {}
    # v0.10: set when a subagent made the call (``agent.started``'s ``id``);
    # sent only to an app that declared ``agents.v1``.
    agent_id: str | None = None


class ToolFinished(Envelope):
    type: Literal["tool.finished"] = "tool.finished"
    chat: int
    turn: int
    tool_use_id: str
    ok: bool
    summary: str = ""
    permission: PermissionOutcome | None = None
    note: str | None = None
    # v0.10: as on ``tool.started``.
    agent_id: str | None = None


class TurnFinished(Envelope):
    type: Literal["turn.finished"] = "turn.finished"
    chat: int
    turn: int
    outcome: Outcome


class CardAsk(Envelope):
    type: Literal["card.ask"] = "card.ask"
    chat: int
    id: str
    kind: Literal["permission", "question", "form"]
    title: str
    permission: Permission | None = None
    questions: list[Question] | None = None
    form: list[FormField] | None = None
    tool_use_id: str | None = None
    # A permission card: what "Allow for this session" would cover, in words
    # (v0.3). The app shows it under the buttons; absent, it says something general.
    scope_note: str | None = None


class CardAnswered(Envelope):
    """The card ``id`` was answered (``card.answer`` accepted); it is closed.

    Stamped and kept in the ring, so a replay that carries the ``card.ask``
    also carries its closing and the app does not pin the card again.
    """

    type: Literal["card.answered"] = "card.answered"
    chat: int
    id: str
    tool_use_id: str | None = None
    outcome: PermissionOutcome | None = None
    note: str | None = None


class CardCancel(Envelope):
    type: Literal["card.cancel"] = "card.cancel"
    chat: int
    id: str
    reason: str | None = None


class ArtifactCreated(Envelope):
    type: Literal["artifact.created"] = "artifact.created"
    chat: int
    artifact: Artifact


class FilesList(Envelope):
    type: Literal["files.list"] = "files.list"
    root: str
    path: str
    entries: list[Entry] = []


class StatusSet(Envelope):
    type: Literal["status.set"] = "status.set"
    text: str


class ContextUsage(Envelope):
    """How full the session's context window is, after each turn."""

    type: Literal["context.usage"] = "context.usage"
    chat: int
    percent: float
    model: str | None = None
    model_name: str | None = None


class ChatCompacted(Envelope):
    """The engine summarized earlier conversation to make room."""

    type: Literal["chat.compacted"] = "chat.compacted"
    chat: int
    trigger: Literal["auto", "manual"]


class SessionRenewed(Envelope):
    """The session ``ended`` was closed and ``next`` is the live one now."""

    type: Literal["session.renewed"] = "session.renewed"
    ended: ChatSummary
    next: ChatSummary


class SessionLogged(Envelope):
    """The log step ``session.log`` asked for has run; ``chat`` is the session's summary now (v0.4)."""

    type: Literal["session.logged"] = "session.logged"
    chat: ChatSummary  # type: ignore[assignment]


class ServicesStatus(Envelope):
    """Every deployment service and its state, down ones first (v0.4)."""

    type: Literal["services.status"] = "services.status"
    services: list[Service] = []


class FilesResults(Envelope):
    type: Literal["files.results"] = "files.results"
    root: str
    query: str
    hits: list[Hit] = []


class ChatNotice(Envelope):
    """A quiet line in the conversation from the gateway, e.g. an unknown command."""

    type: Literal["chat.notice"] = "chat.notice"
    chat: int
    text: str


class ChatQueued(Envelope):
    """The answer to a ``message.send`` that arrived during a turn or the log step (v0.11).

    The message is held, not refused: ``id`` is the request's (the queued
    message's id from now on). Only to an app that declared ``queue.v1``;
    an older app still gets ``error code=chat.busy``.
    """

    type: Literal["chat.queued"] = "chat.queued"
    chat: int
    id: str


class ChatQueue(Envelope):
    """The messages a chat holds for the agent, oldest first, after every change (v0.11).

    Sent when one is queued, unqueued, or goes to the agent, and after
    ``chat.live`` on every ``chat.open`` (an empty list too), so a
    reconnecting app sees what is still waiting. Not in the ring: the list
    as it stands replaces whatever the app had.

    ``returned`` (v0.11, Larry 10-30): messages taken out of the queue by
    ``turn.stop``, oldest first, for the app to put back in the composer
    (text and attachments) to send again or delete. Absent otherwise.
    """

    type: Literal["chat.queue"] = "chat.queue"
    chat: int
    items: list[QueuedMessage] = []
    returned: list[QueuedMessage] | None = None


class ConfigStale(Envelope):
    """The config file changed after the gateway started; restart the gateway to apply it."""

    type: Literal["config.stale"] = "config.stale"


class UpdateAvailable(Envelope):
    """The deployment's update check found a newer version."""

    type: Literal["update.available"] = "update.available"
    version: str


class AgentCommand(Strict):
    """One of the agent's slash commands or skills (v0.11 item 66), for the composer's list.

    ``name`` has no ``/`` (``standup``, ``acme:review``); ``description`` is
    one line (its first sentence); ``source`` is where the engine says it
    comes from (``user``, ``project``, a plug-in's name), when it says.
    """

    name: str
    description: str = ""
    source: str | None = None


class ChatCommands(Envelope):
    """The agent's commands and skills in ``folder``, for slash completion (v0.11 item 66).

    Sent with ``chat`` after that chat's engine starts; sent without it on
    connect, from the list the gateway kept for the folder, so the welcome
    has one before any engine runs. A reading, not history: no ``seq``.
    """

    type: Literal["chat.commands"] = "chat.commands"
    folder: str
    commands: list[AgentCommand] = []


class Error(Envelope):
    type: Literal["error"] = "error"
    code: str
    message: str


# --- subagents and workflows (v0.10) -------------------------------------------
#
# Sent only to an app whose ``hello`` declared ``agents.v1``; stamped and kept
# in the ring like every other turn event, so they replay.


class AgentStarted(Envelope):
    """A subagent started (v0.10).

    ``id`` names the agent in the frames that follow; ``tool_use_id`` is the
    call that started it (a workflow's agents share the workflow's call).
    ``kind`` is the agent type the engine names (e.g. ``general-purpose``),
    or ``workflow`` for one of a workflow's agents, which also carries
    ``workflow_id`` and ``phase`` (an index into ``workflow.started``'s
    ``phases``). ``background`` is set when the agent runs on after its
    turn finishes.
    """

    type: Literal["agent.started"] = "agent.started"
    chat: int
    turn: int
    id: str  # type: ignore[assignment]
    tool_use_id: str
    description: str
    kind: str
    workflow_id: str | None = None
    phase: int | None = None
    background: bool | None = None


class AgentProgress(Envelope):
    """What a subagent is doing now (v0.10): its current ``step``, its tool calls so far, seconds since it started."""

    type: Literal["agent.progress"] = "agent.progress"
    chat: int
    id: str  # type: ignore[assignment]
    step: str | None = None
    steps: int = 0
    elapsed: float = 0.0


class AgentFinished(Envelope):
    """A subagent ended (v0.10); ``summary`` is the first line of what it reported."""

    type: Literal["agent.finished"] = "agent.finished"
    chat: int
    id: str  # type: ignore[assignment]
    outcome: AgentOutcome
    summary: str | None = None


class WorkflowStarted(Envelope):
    """A workflow started (v0.10). Sent again with the same ``id`` when its phases become known or change."""

    type: Literal["workflow.started"] = "workflow.started"
    chat: int
    turn: int
    id: str  # type: ignore[assignment]
    name: str
    phases: list[str] = []


class WorkflowPhase(Envelope):
    """One workflow phase changed state (v0.10); ``index`` is into ``workflow.started``'s ``phases``."""

    type: Literal["workflow.phase"] = "workflow.phase"
    chat: int
    id: str  # type: ignore[assignment]
    index: int
    state: PhaseState


class WorkflowFinished(Envelope):
    """A workflow ended (v0.10)."""

    type: Literal["workflow.finished"] = "workflow.finished"
    chat: int
    id: str  # type: ignore[assignment]
    outcome: AgentOutcome
    summary: str | None = None


# The v0.10 frame types only an app that declared ``agents.v1`` is sent.
AGENT_FRAME_TYPES: frozenset[str] = frozenset(
    {"agent.started", "agent.progress", "agent.finished", "workflow.started", "workflow.phase", "workflow.finished"}
)


# Chat-scoped events the gateway stamps with ``seq`` and keeps in the ring;
# ``chat.history`` replays a list of these.
HistoryEvent = Annotated[
    Union[
        ChatState,
        TurnStarted,
        UserText,
        TextDelta,
        ToolStarted,
        ToolFinished,
        TurnFinished,
        CardAsk,
        CardAnswered,
        CardCancel,
        ArtifactCreated,
        StatusSet,
        ChatCompacted,
        ChatNotice,
        AgentStarted,
        AgentProgress,
        AgentFinished,
        WorkflowStarted,
        WorkflowPhase,
        WorkflowFinished,
        Error,
    ],
    Field(discriminator="type"),
]


class ChatHistory(Envelope):
    type: Literal["chat.history"] = "chat.history"
    chat: int
    events: list[HistoryEvent] = []
    truncated: bool = False


# --- unions ------------------------------------------------------------------

CLIENT_TYPES: tuple[type[Envelope], ...] = (
    HelloClient,
    ChatNew,
    ChatOpen,
    ChatStop,
    ChatAlias,
    ChatRemove,
    MessageSend,
    TurnStop,
    CardAnswer,
    FilesListRequest,
    ArtifactOpened,
    GatewayStop,
    SessionRenew,
    FilesSearch,
    SessionMode,
    SessionLog,
    ServiceRestart,
    ServicesRestartAll,
    SessionsClear,
    ChatUnqueue,
)

SERVER_TYPES: tuple[type[Envelope], ...] = (
    HelloServer,
    ChatList,
    ChatState,
    ChatHistory,
    ChatLive,
    TurnStarted,
    UserText,
    TextDelta,
    ToolStarted,
    ToolFinished,
    TurnFinished,
    CardAsk,
    CardAnswered,
    CardCancel,
    ArtifactCreated,
    FilesList,
    StatusSet,
    ContextUsage,
    ChatCompacted,
    SessionRenewed,
    FilesResults,
    ChatNotice,
    ConfigStale,
    UpdateAvailable,
    SessionLogged,
    ServicesStatus,
    AgentStarted,
    AgentProgress,
    AgentFinished,
    WorkflowStarted,
    WorkflowPhase,
    WorkflowFinished,
    ChatQueued,
    ChatQueue,
    ChatCommands,
    Error,
)

ClientMessage = Annotated[Union[CLIENT_TYPES], Field(discriminator="type")]  # type: ignore[valid-type]
ServerMessage = Annotated[Union[SERVER_TYPES], Field(discriminator="type")]  # type: ignore[valid-type]

_client_adapter: TypeAdapter[Any] = TypeAdapter(ClientMessage)
_server_adapter: TypeAdapter[Any] = TypeAdapter(ServerMessage)


def _type_of(model: type[Envelope]) -> str:
    return model.model_fields["type"].default


CLIENT_TYPE_NAMES: frozenset[str] = frozenset(_type_of(m) for m in CLIENT_TYPES)
SERVER_TYPE_NAMES: frozenset[str] = frozenset(_type_of(m) for m in SERVER_TYPES)


def _parse(raw: str | bytes, adapter: TypeAdapter[Any], known: frozenset[str]) -> Any:
    try:
        obj = json.loads(raw)
    except RecursionError:
        # A frame nested deeper than the interpreter's stack is still just a
        # bad frame: the dispatch loop relies on every bad frame being a
        # ``ProtocolError``, never an escaping exception.
        raise ProtocolError("protocol.invalid", "not valid JSON: nested too deeply") from None
    except (ValueError, TypeError) as e:
        raise ProtocolError("protocol.invalid", f"not valid JSON: {e}") from e
    if not isinstance(obj, dict):
        raise ProtocolError("protocol.invalid", "a message must be a JSON object")
    type_name = obj.get("type")
    if not isinstance(type_name, str) or type_name not in known:
        raise ProtocolError("protocol.unknown_type", f"unknown message type: {type_name!r}")
    try:
        return adapter.validate_python(obj)
    except ValidationError as e:
        detail = "; ".join(
            f"{'.'.join(str(p) for p in err['loc']) or '<root>'}: {err['msg']}" for err in e.errors()
        )
        raise ProtocolError("protocol.invalid", f"invalid {type_name}: {detail}") from e


def parse_client(raw: str | bytes) -> ClientMessage:
    """Parse one app -> gateway frame; raises ``ProtocolError``."""
    return _parse(raw, _client_adapter, CLIENT_TYPE_NAMES)


def parse_server(raw: str | bytes) -> ServerMessage:
    """Parse one gateway -> app frame; raises ``ProtocolError``."""
    return _parse(raw, _server_adapter, SERVER_TYPE_NAMES)


def dump(msg: BaseModel) -> str:
    """One compact JSON object; ``None`` fields are left out of the wire form."""
    return msg.model_dump_json(exclude_none=True)


def to_json_obj(msg: BaseModel) -> dict[str, Any]:
    return json.loads(dump(msg))


# --- export -------------------------------------------------------------------


def export_schema() -> dict[str, Any]:
    """One JSON Schema with a ``$defs`` entry per message and the two unions."""
    _, schema = models_json_schema(
        [(m, "validation") for m in (*CLIENT_TYPES, *SERVER_TYPES)],
        title="Portico protocol",
        description="Messages between the Portico app (client) and a gateway (server).",
    )
    defs = schema.setdefault("$defs", {})
    defs["ClientMessage"] = {
        "description": "Any app -> gateway message, discriminated on type.",
        "oneOf": [{"$ref": f"#/$defs/{m.__name__}"} for m in CLIENT_TYPES],
    }
    defs["ServerMessage"] = {
        "description": "Any gateway -> app message, discriminated on type.",
        "oneOf": [{"$ref": f"#/$defs/{m.__name__}"} for m in SERVER_TYPES],
    }
    schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
    schema["protocol"] = PROTOCOL_VERSION
    return schema


_TS = "2026-10-27T12:00:00Z"
_FOLDER = "/Users/someone/projects/demo"


def example_messages() -> dict[str, BaseModel]:
    """One hand-filled example per message type, keyed ``<direction>.<type>``."""
    examples: list[BaseModel] = [
        # app -> gateway
        HelloClient(ts=_TS, app_version="0.11.0", capabilities=["agents.v1", "queue.v1"]),
        ChatNew(ts=_TS, id="req-1", folder=_FOLDER),
        ChatOpen(ts=_TS, chat=1, since=41),
        ChatStop(ts=_TS, chat=1),
        ChatAlias(ts=_TS, chat=1, alias="report draft"),
        ChatRemove(ts=_TS, chat=2),
        MessageSend(
            ts=_TS,
            chat=1,
            id="req-2",
            text="Summarise the attached notes.",
            attachments=[f"{_FOLDER}/notes.md"],
        ),
        TurnStop(ts=_TS, chat=1),
        CardAnswer(
            ts=_TS,
            chat=1,
            id="card-7",
            answer={"decision": "allow"},
            scope="chat",
            note="fine for this chat",
        ),
        FilesListRequest(ts=_TS, chat=1, id="req-3", root="chat", path="src"),
        ArtifactOpened(ts=_TS, chat=1, artifact_id="art-3"),
        GatewayStop(ts=_TS),
        SessionRenew(ts=_TS, id="req-4", chat=14, log=True),
        FilesSearch(ts=_TS, id="req-5", root="projects", query="synthesis"),
        SessionMode(ts=_TS, chat=14, mode="auto"),
        SessionLog(ts=_TS, id="req-6", chat=14),
        ServiceRestart(ts=_TS, id="req-7", service="memory"),
        ServicesRestartAll(ts=_TS, id="req-8"),
        SessionsClear(ts=_TS, id="req-9"),
        ChatUnqueue(ts=_TS, chat=1, id="req-10"),
        # gateway -> app
        HelloServer(
            ts=_TS,
            gateway_version="0.1.0",
            epoch="7f1c4a2e-3b5d-4c6e-9a8b-0d1e2f3a4b5c",
            brand=Brand(name="Portico", agent_name="Agent", accent="#3B6EF5", icon=None),
            actions=[Action(label="Review", text="/review")],
            roots=[Root(name="projects", path="/Users/someone/projects")],
            commands=["log"],
            capabilities=["cards.form", "files", "producer", "sessions", "files.search", "context"],
            presentation="single",
            can_log=True,
            config_stale=False,
            can_update=True,
            default_folder="/Users/someone/projects",
            permission_mode="auto",
            hide_session_folder=False,
        ),
        ChatList(
            ts=_TS,
            chats=[
                ChatSummary(
                    chat=1, folder=_FOLDER, alias="report draft", state="idle", created=_TS,
                    logged_at="2026-10-27T11:40:00Z", unlogged=True, last_reply="2026-10-27T11:52:00Z",
                ),
                ChatSummary(chat=2, folder=f"{_FOLDER}-two", alias=None, state="working", created=_TS),
            ],
            next_chat=3,
        ),
        ChatState(ts=_TS, chat=1, seq=42, state="waiting on you", mode="default", unlogged=True),
        ChatHistory(
            ts=_TS,
            chat=1,
            events=[
                TurnStarted(ts=_TS, chat=1, seq=1, turn=1),
                TextDelta(ts=_TS, chat=1, seq=2, turn=1, text="Hello."),
                TurnFinished(ts=_TS, chat=1, seq=3, turn=1, outcome="done"),
            ],
            truncated=False,
        ),
        ChatLive(ts=_TS, chat=1, seq=42),
        UserText(ts=_TS, chat=1, turn=1, text="Say hello."),
        TurnStarted(ts=_TS, chat=1, seq=43, turn=2),
        TextDelta(ts=_TS, chat=1, seq=44, turn=2, text="Looking at the notes now."),
        ToolStarted(
            ts=_TS,
            chat=1,
            seq=45,
            turn=2,
            tool_use_id="toolu_01",
            tool="Read",
            summary=f"{_FOLDER}/notes.md",
            input={"file_path": f"{_FOLDER}/notes.md"},
        ),
        ToolFinished(
            ts=_TS, chat=1, seq=46, turn=2, tool_use_id="toolu_01", ok=True, summary="read 120 lines", permission="auto"
        ),
        TurnFinished(ts=_TS, chat=1, seq=47, turn=2, outcome="done"),
        CardAsk(
            ts=_TS,
            chat=1,
            id="card-7",
            seq=48,
            kind="permission",
            title="Save changes to summary.md?",
            permission=Permission(
                tool="Write",
                summary=f"{_FOLDER}/summary.md",
                input={"file_path": f"{_FOLDER}/summary.md", "content": "# Summary\n"},
            ),
            questions=None,
            form=None,
            tool_use_id="toolu_02",
            scope_note="For this session: edits to files in demo, until you start a new session.",
        ),
        CardAnswered(ts=_TS, chat=1, id="card-7", seq=49, tool_use_id="toolu_02", outcome="declined", note="not yet"),
        CardCancel(ts=_TS, chat=1, id="card-7", seq=49, reason="turn stopped"),
        ArtifactCreated(
            ts=_TS,
            chat=1,
            seq=50,
            artifact=Artifact(
                id="art-3",
                kind="file",
                location=f"{_FOLDER}/summary.md",
                media="markdown",
                title="summary.md",
                source="tool",
                open=True,
            ),
        ),
        FilesList(
            ts=_TS,
            chat=1,
            id="req-3",
            root="chat",
            path="src",
            entries=[Entry(name="lib", dir=True, size=None), Entry(name="main.py", dir=False, size=1204)],
        ),
        StatusSet(ts=_TS, chat=1, seq=51, text="Preparing the workspace..."),
        ContextUsage(
            ts=_TS, chat=1, percent=62.4, model="claude-opus-5-5", model_name="Claude Opus 5.5 (work)"
        ),
        ChatCompacted(ts=_TS, chat=1, seq=52, trigger="auto"),
        SessionRenewed(
            ts=_TS,
            id="req-4",
            ended=ChatSummary(
                chat=13, folder=_FOLDER, state="stopped", created=_TS, title="Interview codebook",
                ended=_TS, logged=True, parent=12, compactions=1, context_percent=71.0,
            ),
            next=ChatSummary(chat=14, folder=_FOLDER, state="idle", created=_TS, parent=13),
        ),
        FilesResults(
            ts=_TS,
            id="req-5",
            root="projects",
            query="synthesis",
            hits=[Hit(path="demo/Q3-synthesis.md", snippet="Across twelve customer interviews…")],
        ),
        ChatNotice(ts=_TS, chat=1, seq=53, text="No command /foo here"),
        ConfigStale(ts=_TS),
        UpdateAvailable(ts=_TS, version="0.3.1"),
        SessionLogged(
            ts=_TS,
            id="req-6",
            chat=ChatSummary(
                chat=14, folder=_FOLDER, state="idle", created=_TS, title="Interview codebook",
                parent=13, logged_at=_TS, unlogged=False,
            ),
        ),
        ServicesStatus(
            ts=_TS,
            services=[
                Service(
                    id="memory",
                    name="Memory (recall server)",
                    state="down",
                    detail="not responding since 11:52 · curl: (7) Failed to connect to localhost port 8888",
                    since="2026-10-27T11:52:00Z",
                    can_restart=True,
                ),
                Service(
                    id="search",
                    name="Search index",
                    state="up",
                    detail="indexing the vault",
                    since="2026-10-27T09:00:00Z",
                    can_restart=False,
                ),
            ],
        ),
        AgentStarted(
            ts=_TS,
            chat=1,
            seq=54,
            turn=3,
            id="a4f1c2e9b7d3",
            tool_use_id="toolu_07",
            description="Check quotes in the transcripts",
            kind="general-purpose",
        ),
        AgentProgress(ts=_TS, chat=1, seq=55, id="a4f1c2e9b7d3", step="Read transcripts/p11.md", steps=4, elapsed=12.5),
        AgentFinished(ts=_TS, chat=1, seq=56, id="a4f1c2e9b7d3", outcome="done", summary="6 quotes confirmed"),
        WorkflowStarted(ts=_TS, chat=1, seq=57, turn=3, id="w9k2m4", name="audit-quotes", phases=["find", "verify", "report"]),
        WorkflowPhase(ts=_TS, chat=1, seq=58, id="w9k2m4", index=1, state="running"),
        WorkflowFinished(ts=_TS, chat=1, seq=59, id="w9k2m4", outcome="done", summary="Workflow audit-quotes completed"),
        ChatQueued(ts=_TS, chat=1, id="req-9"),
        ChatQueue(
            ts=_TS,
            chat=1,
            items=[QueuedMessage(id="req-9", text="Also check that uvx resolves — the search server needs it too.")],
        ),
        ChatCommands(
            ts=_TS,
            chat=1,
            folder=_FOLDER,
            commands=[
                AgentCommand(name="standup", description="Draft a standup from today's log.", source="user"),
                AgentCommand(name="acme:review", description="Review a change before it ships", source="acme-tools"),
            ],
        ),
        Error(ts=_TS, chat=1, id="req-2", code="chat.busy", message="a turn is already running in chat 1"),
    ]
    out: dict[str, BaseModel] = {}
    for msg in examples:
        direction = "client" if type(msg) in CLIENT_TYPES else "server"
        key = f"{direction}.{msg.type}"
        if key in out:
            raise RuntimeError(f"duplicate example for {key}")
        out[key] = msg
    return out


def canonical_json(obj: Any) -> str:
    """Deterministic text (sorted keys, 2-space indent, trailing newline)."""
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
