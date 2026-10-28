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
    presentation: Presentation = "multiple"
    # Whether renewing can log the ending session first.
    can_log: bool = False


class ChatList(Envelope):
    type: Literal["chat.list"] = "chat.list"
    chats: list[ChatSummary] = []


class ChatState(Envelope):
    type: Literal["chat.state"] = "chat.state"
    chat: int
    state: ChatStateWord


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


class ToolFinished(Envelope):
    type: Literal["tool.finished"] = "tool.finished"
    chat: int
    turn: int
    tool_use_id: str
    ok: bool
    summary: str = ""


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


class CardAnswered(Envelope):
    """The card ``id`` was answered (``card.answer`` accepted); it is closed.

    Stamped and kept in the ring, so a replay that carries the ``card.ask``
    also carries its closing and the app does not pin the card again.
    """

    type: Literal["card.answered"] = "card.answered"
    chat: int
    id: str


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


class FilesResults(Envelope):
    type: Literal["files.results"] = "files.results"
    root: str
    query: str
    hits: list[Hit] = []


class Error(Envelope):
    type: Literal["error"] = "error"
    code: str
    message: str


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
        HelloClient(ts=_TS, app_version="0.1.0"),
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
        # gateway -> app
        HelloServer(
            ts=_TS,
            gateway_version="0.1.0",
            epoch="7f1c4a2e-3b5d-4c6e-9a8b-0d1e2f3a4b5c",
            brand=Brand(name="Portico", agent_name="Agent", accent="#3B6EF5", icon=None),
            actions=[Action(label="Review", text="/review")],
            roots=[Root(name="projects", path="/Users/someone/projects")],
            commands=[],
            capabilities=["cards.form", "files", "producer", "sessions", "files.search", "context"],
            presentation="single",
            can_log=True,
        ),
        ChatList(
            ts=_TS,
            chats=[
                ChatSummary(chat=1, folder=_FOLDER, alias="report draft", state="idle", created=_TS),
                ChatSummary(chat=2, folder=f"{_FOLDER}-two", alias=None, state="working", created=_TS),
            ],
        ),
        ChatState(ts=_TS, chat=1, seq=42, state="waiting on you"),
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
        ToolFinished(ts=_TS, chat=1, seq=46, turn=2, tool_use_id="toolu_01", ok=True, summary="read 120 lines"),
        TurnFinished(ts=_TS, chat=1, seq=47, turn=2, outcome="done"),
        CardAsk(
            ts=_TS,
            chat=1,
            id="card-7",
            seq=48,
            kind="permission",
            title="Write a file",
            permission=Permission(
                tool="Write",
                summary=f"{_FOLDER}/summary.md",
                input={"file_path": f"{_FOLDER}/summary.md", "content": "# Summary\n"},
            ),
            questions=None,
            form=None,
        ),
        CardAnswered(ts=_TS, chat=1, id="card-7", seq=49),
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
        ContextUsage(ts=_TS, chat=1, percent=62.4, model="claude-sonnet-5-5"),
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
