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

from pydantic import BaseModel, ConfigDict, Field, PrivateAttr, TypeAdapter, ValidationError
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
# v0.17: ``stuck`` is up but not working (a check's exit 75, a status row's
# ``"state": "stuck"``); only an app with ``services.stuck.v1`` is sent it.
ServiceState = Literal["up", "down", "stuck", "checking"]
# How a subagent ended (v0.10).
AgentOutcome = Literal["done", "failed", "stopped"]
# Where one workflow phase stands (v0.10).
PhaseState = Literal["pending", "running", "done", "failed"]
# v0.21: background work that is not an agent.
TaskKind = Literal["shell", "monitor"]
# Where a thread proposal stands (v0.16): ``pending`` until the person starts
# or dismisses it, or Main's session ends (then ``dismissed``).
ProposalState = Literal["pending", "started", "dismissed"]

# v0.10: the client capability an app lists in its ``hello`` when it
# shows subagents and workflows. Only such an app is sent the ``agent.*`` and
# ``workflow.*`` frames and the tool rows of a subagent's own steps.
AGENTS_CAPABILITY = "agents.v1"
# v0.21: the app can show background commands and Monitors (``agent.started.task``) in its tray.
TASKS_CAPABILITY = "tasks.v1"

# v0.22: the capability an app lists when it can dock a message from the
# deployment (``deployment.message``) above the message box. Only such an app
# is sent one; with none attached, the gateway keeps them for the next hello.
DEPLOYMENT_MESSAGE_CAPABILITY = "messages.deployment.v1"

# v0.23: the app shows and writes comments in Markdown files (comment format
# v1, protocol/COMMENTS.md). Declared for future use: the comment tools work
# without the app, since they write files.
COMMENTS_CAPABILITY = "comments.v1"

# v0.11 (item 74): the capability, on both sides, for messages typed while
# the agent works. A gateway that lists it queues a ``message.send`` that
# arrives during a turn (``chat.queued``) instead of refusing it, but only
# for an app that lists it too; only such an app is sent ``chat.queue``.
QUEUE_CAPABILITY = "queue.v1"

# v0.16: the capability, on both sides, for threads (more conversations with
# the same agent, opened from Main). A gateway lists it in single
# presentation with ``[threads] max`` above 0; only an app that lists it too
# is sent ``thread.proposal``.
THREADS_CAPABILITY = "threads.v1"

# v0.18 (ruling 20): the capability, on both sides, for MCP Apps. A gateway
# lists it when ``[apps] enabled``; only an app that lists it too is sent the
# ``app.*`` frames (any other app keeps the plain tool rows).
APPS_CAPABILITY = "apps.v1"

# v0.17: the capability an app lists when it can show a service as ``stuck``.
# Any other app is sent a stuck service as ``down`` (its decoder would refuse
# the whole ``services.status`` for a state it does not know).
SERVICES_STUCK_CAPABILITY = "services.stuck.v1"

# v0.19 (spec §8.3-8.4): a gateway lists it when an image attachment goes to
# the agent as an image, and ``user.text`` carries the typed ``text`` with the
# ``attachments`` apart. An older gateway's ``user.text`` has the attachment
# block inside ``text`` and no ``attachments``.
MESSAGES_ATTACHMENTS_CAPABILITY = "messages.attachments.v1"

# v0.19 (spec §4.2): a gateway lists it when it answers ``files.roots.set``
# with the folders a person added to the Files pane (``files.roots``).
FILES_EXTRA_CAPABILITY = "files.extra.v1"

# v0.20 (spec §2.7): a gateway lists it when it takes ``files.edited`` and tells
# the agent, ahead of the person's next message, which files they edited.
FILES_EDITED_CAPABILITY = "files.edited.v1"


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
    # v0.20.1: the deployment's version, which the About panel shows, and the
    # panel's text under it ({app_version} and {built} are filled in by the app).
    version: str | None = None
    about: str | None = None


class Action(Strict):
    label: str
    text: str


class Root(Strict):
    name: str
    path: str
    # v0.19 (``files.extra.v1``): a folder the person added (not the deployment's),
    # and one that is not a directory (any more); ``files.list`` on it is ``files.not_found``.
    extra: bool = False
    missing: bool = False


class ThreadInfo(Strict):
    """What makes a chat a thread (v0.16): opened from Main (``parent``) for ``brief``.

    ``label`` is "Thread 1" or "Thread 2"; ``slot`` is its number, the key
    that switches to it (a closed thread's slot is used again); ``files``
    are the paths it started with; ``opened_at`` when it was started.
    """

    label: str
    slot: int = Field(ge=1, le=2)
    parent: int
    brief: str
    files: list[str] = []
    opened_at: str


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
    # v0.16: set on a thread; absent on Main and every other chat. An app
    # without ``threads.v1`` ignores it and sees threads as chats.
    thread: ThreadInfo | None = None


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
    # v0.16: the option's preview, as the engine's question tool sends it
    # (Markdown); absent when the option has none.
    preview: str | None = None


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
    # v0.12: the id of the space this file is (a file in the spaces folder); the app switches to it.
    space: str | None = None


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


class ModelSet(Envelope):
    """v0.15: switch the model for this session and the ones after it (``models.v1``).

    ``value`` is a ``ModelChoice.value`` from ``models``; ``"default"`` or
    ``null`` is the deployment's default. Answered by ``models`` carrying the
    request's ``id`` and the new ``current``, or by ``error``: ``chat.busy``
    while a reply runs, ``model.unknown`` for a value the list lacks.
    """

    type: Literal["model.set"] = "model.set"
    chat: int
    value: str | None = None


class ThreadStart(Envelope):
    """v0.16: start the thread a proposal on Main (``chat``) describes (``threads.v1``).

    ``close`` names an open thread to close first when two are open (the
    limit card's Close and start). Starting does not change which chat is Main.
    """

    type: Literal["thread.start"] = "thread.start"
    chat: int
    proposal: str
    close: int | None = None


class ThreadDismiss(Envelope):
    """v0.16: "Not now" on a proposal on Main (``chat``); its record reads "Not started"."""

    type: Literal["thread.dismiss"] = "thread.dismiss"
    chat: int
    proposal: str


class ThreadClose(Envelope):
    """v0.16: close the thread ``chat``: its log step, then it ends into History.

    ``log`` false skips the log step (the thread ends ``logged: false``): the
    app's "Close without logging" after a close whose log step cannot start.
    """

    type: Literal["thread.close"] = "thread.close"
    chat: int
    log: bool = True


# --- MCP servers in Settings (v0.18 §3.1, ``mcp.v1``) ---------------------------
#
# Requests from the app (an older app never sends them), each answered with
# ``mcp.servers`` carrying the request's ``id``, or ``error`` with the ``id``.


class McpList(Envelope):
    """v0.18: the servers as Settings shows them."""

    type: Literal["mcp.list"] = "mcp.list"


class McpToggle(Envelope):
    """v0.18: turn a server off (``enabled`` false) or on again, for Settings' folder; from the next engine start."""

    type: Literal["mcp.toggle"] = "mcp.toggle"
    name: str
    enabled: bool


class McpReconnect(Envelope):
    """v0.18: reconnect a server in every live engine on Settings' folder."""

    type: Literal["mcp.reconnect"] = "mcp.reconnect"
    name: str


class McpRemove(Envelope):
    """v0.18: remove a user or local server (``claude mcp remove``); the app asks first."""

    type: Literal["mcp.remove"] = "mcp.remove"
    name: str


class McpAdd(Envelope):
    """v0.18: add a server (``claude mcp add``): by a web address (``url``) or a program on this Mac (``command``).

    ``where`` is ``user`` (All your projects) or ``local`` (this agent only).
    """

    type: Literal["mcp.add"] = "mcp.add"
    name: str
    transport: Literal["http", "stdio"]
    url: str | None = None
    command: str | None = None
    where: Literal["user", "local"]


class McpSignIn(Envelope):
    """v0.18: sign in to a server (``claude mcp login``): answered at once, then a fresh ``mcp.servers`` (no id) when done."""

    type: Literal["mcp.sign_in"] = "mcp.sign_in"
    name: str


class McpSignOut(Envelope):
    """v0.18: sign out of a server (``claude mcp logout``)."""

    type: Literal["mcp.sign_out"] = "mcp.sign_out"
    name: str


class McpToolPolicy(Envelope):
    """v0.18: whether one tool runs without asking (``allow``) or asks first (``ask``); ``null`` is back to the default."""

    type: Literal["mcp.tool_policy"] = "mcp.tool_policy"
    server: str
    tool: str
    policy: Literal["allow", "ask"] | None = None


# --- plugins in Settings (v0.18 §3, ``plugins.v1``) -----------------------------
#
# Requests from the app (an older app never sends them). ``plugin`` is the
# plugin's id as the CLI prints it (``name@marketplace``); ``id`` stays the
# request's id. The list and every change are answered with ``plugins.state``;
# details and options with their own frame; a refusal or failure with
# ``error`` carrying the id.


class PluginsList(Envelope):
    """v0.18: the installed plugins and the marketplaces; ``available`` true adds what the marketplaces offer."""

    type: Literal["plugins.list"] = "plugins.list"
    available: bool = False


class PluginsSetEnabled(Envelope):
    """v0.18: turn a plugin on or off (``claude plugin enable|disable <id> --scope <its scope>``)."""

    type: Literal["plugins.set_enabled"] = "plugins.set_enabled"
    plugin: str
    enabled: bool


class PluginsInstall(Envelope):
    """v0.18: install a plugin (``claude plugin install <id> --json``); one that installs by running a command is refused."""

    type: Literal["plugins.install"] = "plugins.install"
    plugin: str


class PluginsUninstall(Envelope):
    """v0.18: uninstall a plugin (``claude plugin uninstall <id> --scope <its scope>``); the app asks first."""

    type: Literal["plugins.uninstall"] = "plugins.uninstall"
    plugin: str


class PluginsUpdate(Envelope):
    """v0.18: update a plugin to its marketplace's version (``claude plugin update <id>``)."""

    type: Literal["plugins.update"] = "plugins.update"
    plugin: str


class PluginsMarketplaceAdd(Envelope):
    """v0.18: add a marketplace (``claude plugin marketplace add <source>``): owner/repo, a git address or a path."""

    type: Literal["plugins.marketplace_add"] = "plugins.marketplace_add"
    source: str


class PluginsMarketplaceUpdate(Envelope):
    """v0.18: check a marketplace for updates (``claude plugin marketplace update <name>``)."""

    type: Literal["plugins.marketplace_update"] = "plugins.marketplace_update"
    name: str


class PluginsDetailsRequest(Envelope):
    """v0.18: a plugin's inventory as text (``claude plugin details <id>``)."""

    type: Literal["plugins.details"] = "plugins.details"
    plugin: str


class PluginsOptionsRequest(Envelope):
    """v0.18: a plugin's options (``claude plugin configure <id> --json``)."""

    type: Literal["plugins.options"] = "plugins.options"
    plugin: str


class PluginsConfigure(Envelope):
    """v0.18: save option values (only the changed ones), piped to ``claude plugin configure <id> --values-stdin``."""

    type: Literal["plugins.configure"] = "plugins.configure"
    plugin: str
    values: dict[str, str]


# --- MCP Apps (v0.18 §2, ``apps.v1``) ------------------------------------------
#
# From the page of an app card, sent by the app on its behalf. ``tool_use_id``
# names the card (the agent's call that opened it). ``app.call_tool`` is
# answered with ``app.call_result`` carrying its ``id``; ``app.message`` and
# ``app.reload`` with an ``error`` carrying the ``id`` when refused.


class AppCallTool(Envelope):
    """v0.18: the page asks to run ``tool`` on its own server (a bare name means that server's)."""

    type: Literal["app.call_tool"] = "app.call_tool"
    chat: int
    tool_use_id: str
    tool: str
    arguments: dict[str, Any] = {}


class AppMessage(Envelope):
    """v0.18: the page's ``ui/message``: sent as the person's message, labelled ``via`` the app."""

    type: Literal["app.message"] = "app.message"
    chat: int
    tool_use_id: str
    text: str


class AppContext(Envelope):
    """v0.18: the page's ``ui/update-model-context``: kept (latest only) and put before the person's next message."""

    type: Literal["app.context"] = "app.context"
    chat: int
    tool_use_id: str
    text: str


class AppReload(Envelope):
    """v0.18: read the page again (starting the chat's engine if needed); answered ``app.open`` then ``app.result``."""

    type: Literal["app.reload"] = "app.reload"
    chat: int
    tool_use_id: str


class TurnStop(Envelope):
    type: Literal["turn.stop"] = "turn.stop"
    chat: int


class ViewerSettings(Envelope):
    """v0.12: the person's two viewer switches; sent after ``hello`` and when either changes. Not chat-scoped."""

    type: Literal["viewer.settings"] = "viewer.settings"
    can_see: bool
    check_html: bool


class SpaceRefresh(Envelope):
    """v0.12: run the deployment's refresh for a space; ``id`` is the space's id. Answered by ``spaces.list`` or ``error``."""

    type: Literal["space.refresh"] = "space.refresh"
    id: str


class SpaceAct(Envelope):
    """v0.22: run the deployment's ``[spaces] act`` for a space; ``id`` is the space's id.

    ``action`` and ``item`` (optional) match ``[A-Za-z0-9._:-]{1,128}``. Answered by
    ``spaces.list`` once the command has finished, or by ``error`` (``space.act_failed``,
    ``space.no_act``, ``space.not_found``, ``protocol.invalid``).
    """

    type: Literal["space.act"] = "space.act"
    id: str
    action: str
    item: str | None = None


class SpaceRename(Envelope):
    """v0.12: set a space's title (written into its front matter); ``id`` is the space's id."""

    type: Literal["space.rename"] = "space.rename"
    id: str
    title: str


class SpaceRemove(Envelope):
    """v0.12: move a space's file to the Trash and run the deployment's remove; ``id`` is the space's id."""

    type: Literal["space.remove"] = "space.remove"
    id: str


class ViewerImage(Strict):
    data: str  # base64 PNG
    media_type: Literal["image/png", "image/jpeg"]


class ViewerResult(Envelope):
    """v0.12: the app's answer to a ``viewer.act``."""

    type: Literal["viewer.result"] = "viewer.result"
    id: str
    ok: bool
    text: str
    image: ViewerImage | None = None
    error: str | None = None


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


class FilesRootsSet(Envelope):
    """v0.19 (``files.extra.v1``): the folders this connection adds to the Files pane; replaces the last list."""

    type: Literal["files.roots.set"] = "files.roots.set"
    paths: list[str] = []


class FilesEdited(Envelope):
    """v0.20 (``files.edited.v1``): the person saved ``path`` in the viewer's editor; no reply.

    The agent hears of it in a note ahead of the person's next message.
    """

    type: Literal["files.edited"] = "files.edited"
    chat: int
    path: str


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


class ViewerDefaults(Strict):
    """v0.12: the deployment's viewer settings (config ``[viewer]``), sent in ``hello``."""

    agent_can_see: bool = True
    agent_checks_html: bool = True
    act_hosts: list[str] = []
    # v0.17: how a front-matter Properties block first opens, until the person folds or unfolds one.
    properties: Literal["folded", "open"] = "folded"


class Person(Strict):
    """v0.23: the person using the app, by real name (config ``[person] name``, or a plug-in)."""

    name: str


class Voice(Strict):
    """v0.24: the deployment's voice settings for the app (config ``[voice]``)."""

    # Settings shows the Read aloud switch when true; the person's on/off stays in the app.
    read_aloud: bool = False


# v0.25: the key of the Read aloud Labs item (the app draws its controls for it).
READ_ALOUD_LAB = "voice.read_aloud"


class LabItem(Strict):
    """v0.25: one row in the app's Settings › Labs (``hello.labs``).

    ``tag`` is ``preview`` for a feature built into the app and not yet
    released, ``local`` for one this machine's plug-in added. ``source``
    says where it was turned on: ``config.toml``, ``config.local.toml`` or
    ``plugin:<module>``. ``home`` is the Settings tab it moves to when
    released, when known (``voice``, ``general``...).
    """

    key: str
    title: str
    detail: str
    tag: Literal["preview", "local"]
    source: str
    home: str | None = None


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
    # v0.19: the deployment fixes "Works in" (config ``[sessions] lock_folder``).
    lock_folder: bool = False
    # v0.19: host suffix to site name for link chips (config ``[links] sites``).
    link_sites: dict[str, str] = {}
    # v0.12: the deployment's viewer defaults; the app uses them until the
    # person changes a switch. Absent from an older gateway.
    viewer_defaults: ViewerDefaults | None = None
    # v0.16: how many threads may be open beside Main (config ``[threads] max``),
    # sent with ``threads.v1``; absent otherwise. The app's limit card follows it.
    threads_max: int | None = None
    # v0.23: the person's real name, written as the author of their comments.
    # Absent: the app uses the computer's full user name.
    person: Person | None = None
    # v0.24: config ``[voice]``; absent from an older gateway.
    voice: Voice | None = None
    # v0.25: the Labs items (built-in Preview features the config turned on,
    # then plug-ins' Local items). Absent when there are none, and from an older gateway.
    labs: list[LabItem] | None = None


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
    """What the person sent to start a turn (v0.19: as typed, with ``attachments`` apart).

    Live, right after ``turn.started`` (stamped, in the ring), and in a
    transcript replay (``chat.history``, unstamped): one rendering path
    for the person's words whichever way the conversation arrives.
    """

    type: Literal["user.text"] = "user.text"
    chat: int
    turn: int
    text: str
    # v0.18 (ruling 27): a message an MCP app sent (``app.message``) carries the
    # app's server title; the transcript shows "via <title>". Absent otherwise.
    via: str | None = None
    # v0.19 (spec §8.4, ``messages.attachments.v1``): the attached files' paths;
    # ``text`` is then what the person typed, without the "Attached files:" block.
    attachments: list[str] = []


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
    # v0.16: on an answered ``AskUserQuestion`` row, what the person chose
    # ({<question text>: <label> | [labels]}); absent on a decline.
    answers: dict[str, str | list[str]] | None = None
    # v0.18 (§2.6.1): the engine's ``tool_use_result`` for this call, live only.
    # Private: never on the wire, never in the schema; MCP Apps read it.
    _raw_result: dict[str, Any] | None = PrivateAttr(default=None)

    @property
    def raw_result(self) -> dict[str, Any] | None:
        return self._raw_result

    def with_raw_result(self, raw: dict[str, Any] | None) -> ToolFinished:
        """``self`` carrying ``raw`` (set in place; returned for chaining)."""
        self._raw_result = raw
        return self


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


class FilesRoots(Envelope):
    """v0.19: the roots this connection has: the deployment's, then the person's added folders in order."""

    type: Literal["files.roots"] = "files.roots"
    roots: list[Root] = []


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
    # v0.19: what the notice is about, when the app may treat it apart
    # (``attachment.not_image``); absent for a plain line.
    kind: str | None = None


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


class ThreadProposal(Envelope):
    """v0.16: a thread Main's agent proposed (``open_thread``), and where it stands.

    ``chat`` is Main's; ``proposal`` the proposal's id; ``tool_use_id`` the
    ``open_thread`` tool row the card is drawn in place of. ``thread`` is the
    chat it started, once ``state`` is ``started``. A state frame like
    ``chat.queue``: not in the ring, sent on every change and after
    ``chat.live`` on every ``chat.open``. Only to an app with ``threads.v1``.
    """

    type: Literal["thread.proposal"] = "thread.proposal"
    chat: int
    proposal: str
    tool_use_id: str | None = None
    brief: str
    files: list[str] = []
    state: ProposalState
    thread: int | None = None


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


class ModelChoice(Strict):
    """v0.15: one entry of the engine's model list, the CLI's ``/model`` list.

    ``value`` is what ``model.set`` sends back (``opus``, ``sonnet``,
    ``claude-fable-5-1[1m]``, ``default``); ``display_name`` and
    ``description`` are the engine's own words. ``resolved_model`` (11-02)
    is the model id the entry runs (the engine's ``resolvedModel``), so the
    app can name what Default resolves to; absent when the engine did not
    say, and an older app ignores it.
    """

    value: str
    display_name: str
    description: str = ""
    resolved_model: str | None = None


class Models(Envelope):
    """v0.15: the models the session can switch to and the one it runs on (``models.v1``).

    Sent after ``hello`` for each live session (from the list the gateway
    kept), after each engine start, and after a switch (with the
    ``model.set`` request's ``id``). ``current`` is the model this session
    runs on: its running engine's, else the stored choice it will start on;
    absent (``null``) is the deployment's default. A reading, not history:
    no ``seq``.
    """

    type: Literal["models"] = "models"
    chat: int
    current: str | None = None
    choices: list[ModelChoice] = []


# --- MCP servers in Settings (v0.18 §3.1) -------------------------------------------


class McpToolRow(Strict):
    """One tool of a server: ``policy`` is the effective one (the person's choice, else the default)."""

    name: str
    description: str = ""
    read_only: bool = False
    policy: Literal["allow", "ask"]


class McpServerRow(Strict):
    """One server as Settings shows it. ``detail`` is the status line; group titles and brand words are the app's."""

    name: str
    title: str
    group: Literal["user", "local", "shipped", "core", "account"]
    transport: Literal["stdio", "http", "sse", "sdk", "other"]
    status: Literal["connected", "needs_auth", "failed", "pending", "off", "signing_in", "unknown"]
    detail: str
    tool_count: int | None = None
    tools: list[McpToolRow] = []
    account: str | None = None
    can_toggle: bool
    can_remove: bool
    can_sign_out: bool


class McpServers(Envelope):
    """v0.18: the answer to every ``mcp.*`` request (with its ``id``), and after a sign-in finishes (no ``id``).

    ``live`` is whether status came from a running engine on Settings' folder;
    without one, rows carry no tools. A reading, not history: no ``seq``.
    """

    type: Literal["mcp.servers"] = "mcp.servers"
    servers: list[McpServerRow] = []
    live: bool = False


# --- plugins in Settings (v0.18 §3) -------------------------------------------------


class PluginRow(Strict):
    """One installed plugin. ``description`` and ``marketplace`` come from its marketplace entry, joined by id.

    ``update_to`` is the marketplace's version when it differs from the installed one.
    """

    id: str
    name: str
    version: str
    scope: str
    enabled: bool
    description: str = ""
    marketplace: str
    update_to: str | None = None


class AvailablePlugin(Strict):
    """One plugin a marketplace offers (Browse)."""

    id: str
    name: str
    description: str = ""
    marketplace: str
    version: str | None = None
    installed: bool = False


class PluginMarketplace(Strict):
    """One marketplace. ``source_label`` is its repo or path (``None`` for the official one); ``checked`` is
    "today", "yesterday" or a date like "Oct 24" (the newest change in its checkout), or "" when unknown."""

    name: str
    source_label: str | None = None
    plugin_count: int = 0
    checked: str = ""


class PluginOption(Strict):
    """One option of a plugin. A sensitive option's value is never sent: ``value`` is null and ``set`` says whether it has one."""

    key: str
    title: str
    description: str = ""
    sensitive: bool = False
    set: bool = False
    value: str | None = None


class PluginsState(Envelope):
    """v0.18: the answer to ``plugins.list`` and to every plugin change (with the request's ``id``).

    ``available`` is present only when the request was a ``plugins.list`` with
    ``available: true``. A reading, not history: no ``seq``.
    """

    type: Literal["plugins.state"] = "plugins.state"
    installed: list[PluginRow] = []
    available: list[AvailablePlugin] | None = None
    marketplaces: list[PluginMarketplace] = []


class PluginsDetails(Envelope):
    """v0.18: a plugin's ``claude plugin details`` text."""

    type: Literal["plugins.details"] = "plugins.details"
    plugin: str
    text: str


class PluginsOptions(Envelope):
    """v0.18: a plugin's options (empty: nothing to configure)."""

    type: Literal["plugins.options"] = "plugins.options"
    plugin: str
    options: list[PluginOption] = []


# --- MCP Apps (v0.18 §2) --------------------------------------------------------------
#
# Sent only to an app that declared ``apps.v1``. Live: ``tool.started`` →
# ``app.open`` → ``tool.finished`` → ``app.result`` (or ``app.cancelled``).
# Not stamped (no ``seq``) and not kept in the ring: ``chat.history`` brings
# each card back from its saved record, ``html`` null (frozen).


class AppOpen(Envelope):
    """v0.18: show the app card for the agent's call ``tool_use_id``.

    ``server`` is the configured name, ``server_title`` what to call it
    (``serverInfo.title``, else the name); ``tool`` is the bare tool name.
    ``html`` is the page (absent in a replay: the card comes back frozen).
    ``csp``, ``permissions`` and ``prefers_border`` are the resource's
    ``_meta.ui`` members, as the server gave them.
    """

    type: Literal["app.open"] = "app.open"
    chat: int
    tool_use_id: str
    server: str
    server_title: str
    tool: str
    resource_uri: str
    html: str | None = None
    csp: dict[str, Any] | None = None
    permissions: dict[str, Any] | None = None
    prefers_border: bool | None = None
    input: dict[str, Any] = {}


class AppResult(Envelope):
    """v0.18: the call's result for the page (``structured_content`` absent when it was over the cap)."""

    type: Literal["app.result"] = "app.result"
    chat: int
    tool_use_id: str
    content: list[dict[str, Any]] = []
    structured_content: dict[str, Any] | None = None
    is_error: bool = False


class AppCancelled(Envelope):
    """v0.18: the call ended with no result (stopped, or an error before one)."""

    type: Literal["app.cancelled"] = "app.cancelled"
    chat: int
    tool_use_id: str


class AppCallResult(Envelope):
    """v0.18: the answer to ``app.call_tool`` (its ``id``). ``ok`` false carries ``error``; the result is never the model's."""

    type: Literal["app.call_result"] = "app.call_result"
    tool_use_id: str
    ok: bool
    content: list[dict[str, Any]] = []
    structured_content: dict[str, Any] | None = None
    is_error: bool = False
    error: str | None = None


# The v0.18 frame types only an app that declared ``apps.v1`` is sent.
APP_FRAME_TYPES: frozenset[str] = frozenset({"app.open", "app.result", "app.cancelled", "app.call_result"})


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

    v0.21: ``task`` marks background work that is not an agent, a
    command (``shell``) or a Monitor (``monitor``); ``kind`` repeats it.
    Sent only to an app that names ``tasks.v1``. ``run`` (2, 3, …) is a
    resumed agent's new run: the same ``id``, running again in ``turn``.
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
    task: TaskKind | None = None
    run: int | None = None


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
        AppOpen,
        AppResult,
        AppCancelled,
        Error,
    ],
    Field(discriminator="type"),
]


class SpaceInfo(Strict):
    """One space in ``spaces.list``: ``updated`` is the file's modification time (UTC ISO 8601)."""

    id: str
    title: str
    icon: str
    order: int | None = None
    location: str
    media: Media
    updated: str
    # v0.22: the space's own wording for the notification its change raises
    # (``notice``; "" means none) and the fragment a click opens (``notice_target``);
    # left out when the page sets neither.
    notice: str | None = None
    notice_target: str | None = None
    # v0.22: ``false`` for a space that cannot be removed or renamed; left out (true) otherwise.
    removable: bool | None = None


class DeploymentMessage(Envelope):
    """v0.22: a message from the deployment for the open chat; ``id`` names it, ``ts`` is when it was written.

    Sent only to an app with ``messages.deployment.v1``. ``text`` is Markdown, ``title`` a short
    heading, ``notify`` asks for a system notification too, ``space`` is the id of a space the
    app may offer to open. Not part of the chat's history and never sent to the agent.
    """

    type: Literal["deployment.message"] = "deployment.message"
    id: str
    text: str
    title: str | None = None
    notify: bool | None = None
    space: str | None = None


class SpacesList(Envelope):
    """v0.12: the spaces as they are, after ``services.status`` on hello and whenever the folder changes."""

    type: Literal["spaces.list"] = "spaces.list"
    spaces: list[SpaceInfo] = []


class ViewerAct(Envelope):
    """v0.12: the agent acts in the viewer; the app answers with ``viewer.result`` carrying the same ``id``.

    v0.17: ``show`` (``{artifact, location}``), only to an app that declared
    ``viewer.show.v1``, is answered once the shown page has loaded.
    """

    type: Literal["viewer.act"] = "viewer.act"
    id: str
    chat: int
    action: Literal["look", "click", "type", "scroll", "back", "mark", "clear_marks", "show"]
    args: dict[str, Any] = {}


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
    FilesRootsSet,
    FilesEdited,
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
    ViewerSettings,
    ViewerResult,
    SpaceRefresh,
    SpaceAct,
    SpaceRename,
    SpaceRemove,
    ModelSet,
    ThreadStart,
    ThreadDismiss,
    ThreadClose,
    McpList,
    McpToggle,
    McpReconnect,
    McpRemove,
    McpAdd,
    McpSignIn,
    McpSignOut,
    McpToolPolicy,
    PluginsList,
    PluginsSetEnabled,
    PluginsInstall,
    PluginsUninstall,
    PluginsUpdate,
    PluginsMarketplaceAdd,
    PluginsMarketplaceUpdate,
    PluginsDetailsRequest,
    PluginsOptionsRequest,
    PluginsConfigure,
    AppCallTool,
    AppMessage,
    AppContext,
    AppReload,
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
    FilesRoots,
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
    ViewerAct,
    SpacesList,
    DeploymentMessage,
    Models,
    ThreadProposal,
    McpServers,
    PluginsState,
    PluginsDetails,
    PluginsOptions,
    AppOpen,
    AppResult,
    AppCancelled,
    AppCallResult,
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
        HelloClient(ts=_TS, app_version="0.23.0", capabilities=["agents.v1", "queue.v1", "viewer.v1", "spaces.v1", "viewer.marks.v1", "models.v1", "threads.v1", "viewer.show.v1", SERVICES_STUCK_CAPABILITY, "apps.v1", "messages.attachments.v1", "files.extra.v1", "files.edited.v1", TASKS_CAPABILITY, DEPLOYMENT_MESSAGE_CAPABILITY, COMMENTS_CAPABILITY]),
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
        FilesRootsSet(ts=_TS, id="req-6", paths=["/Users/someone/papers"]),
        FilesEdited(ts=_TS, chat=1, path=f"{_FOLDER}/notes.md"),
        ArtifactOpened(ts=_TS, chat=1, artifact_id="art-3"),
        GatewayStop(ts=_TS),
        SessionRenew(ts=_TS, id="req-4", chat=14, log=True),
        FilesSearch(ts=_TS, id="req-5", root="projects", query="synthesis"),
        SessionMode(ts=_TS, chat=14, mode="auto"),
        ModelSet(ts=_TS, chat=14, id="req-11", value="sonnet"),
        # At the limit: start p-7c21 after closing thread 15 (which p-3f9a started).
        ThreadStart(ts=_TS, chat=14, id="req-12", proposal="p-7c21", close=15),
        ThreadDismiss(ts=_TS, chat=14, id="req-13", proposal="p-7c21"),
        ThreadClose(ts=_TS, chat=15, id="req-14"),
        McpList(ts=_TS, id="req-20"),
        McpToggle(ts=_TS, id="req-21", name="acme-crm", enabled=False),
        McpReconnect(ts=_TS, id="req-22", name="docs"),
        McpRemove(ts=_TS, id="req-23", name="acme-tracker"),
        McpAdd(ts=_TS, id="req-24", name="acme-tracker", transport="http", url="https://mcp.acme.example/", where="user"),
        McpSignIn(ts=_TS, id="req-25", name="acme-calendar"),
        McpSignOut(ts=_TS, id="req-26", name="acme-tracker"),
        McpToolPolicy(ts=_TS, id="req-27", server="acme-tracker", tool="update_task", policy="allow"),
        PluginsList(ts=_TS, id="req-30", available=True),
        PluginsSetEnabled(ts=_TS, id="req-31", plugin="design-review@acme", enabled=False),
        PluginsInstall(ts=_TS, id="req-32", plugin="meeting-notes@claude-plugins-official"),
        PluginsUninstall(ts=_TS, id="req-33", plugin="release-helper@acme"),
        PluginsUpdate(ts=_TS, id="req-34", plugin="design-review@acme"),
        PluginsMarketplaceAdd(ts=_TS, id="req-35", source="acme/plugins"),
        PluginsMarketplaceUpdate(ts=_TS, id="req-36", name="acme"),
        PluginsDetailsRequest(ts=_TS, id="req-37", plugin="design-review@acme"),
        PluginsOptionsRequest(ts=_TS, id="req-38", plugin="design-review@acme"),
        PluginsConfigure(ts=_TS, id="req-39", plugin="design-review@acme", values={"region": "eu"}),
        AppCallTool(
            ts=_TS, id="req-40", chat=1, tool_use_id="toolu_01", tool="update_task",
            arguments={"task": "Launch email", "status": "done"},
        ),
        AppMessage(ts=_TS, id="req-41", chat=1, tool_use_id="toolu_01", text="Mark Launch email done"),
        AppContext(ts=_TS, chat=1, tool_use_id="toolu_01", text="Project: Acme launch. 3 of 4 tasks done."),
        AppReload(ts=_TS, id="req-42", chat=1, tool_use_id="toolu_01"),
        SessionLog(ts=_TS, id="req-6", chat=14),
        ServiceRestart(ts=_TS, id="req-7", service="memory"),
        ServicesRestartAll(ts=_TS, id="req-8"),
        SessionsClear(ts=_TS, id="req-9"),
        ChatUnqueue(ts=_TS, chat=1, id="req-10"),
        ViewerSettings(ts=_TS, can_see=True, check_html=True),
        SpaceRefresh(ts=_TS, id="meeting-prep"),
        SpaceAct(ts=_TS, id="meeting-prep", action="mark-done", item="task-3"),
        SpaceRename(ts=_TS, id="meeting-prep", title="Prep for Priya"),
        SpaceRemove(ts=_TS, id="brief"),
        ViewerResult(
            ts=_TS,
            id="act-1",
            ok=True,
            text="trail-detail.html. 12 elements.",
            image=ViewerImage(data="iVBORw0KGgo=", media_type="image/png"),
        ),
        # gateway -> app
        HelloServer(
            ts=_TS,
            gateway_version="0.1.0",
            epoch="7f1c4a2e-3b5d-4c6e-9a8b-0d1e2f3a4b5c",
            brand=Brand(name="Portico", agent_name="Agent", accent="#3B6EF5", icon=None),
            actions=[Action(label="Review", text="/review")],
            roots=[Root(name="projects", path="/Users/someone/projects")],
            commands=["log"],
            capabilities=[
                "cards.form", "files", "producer", "sessions", "files.search", "context", "spaces.v1", "spaces.refresh", "spaces.act",
                "threads.v1",
            ],
            presentation="single",
            can_log=True,
            config_stale=False,
            can_update=True,
            default_folder="/Users/someone/projects",
            permission_mode="auto",
            hide_session_folder=False,
            lock_folder=False,
            link_sites={"acme.example": "Acme"},
            viewer_defaults=ViewerDefaults(agent_can_see=True, agent_checks_html=True, act_hosts=["figma.com"]),
            threads_max=2,
            person=Person(name="Sam Rivera"),
            voice=Voice(read_aloud=True),
            labs=[
                LabItem(
                    key="voice.read_aloud", title="Read aloud",
                    detail="A Play button on each reply; replies are read as they arrive while it's on.",
                    tag="preview", source="config.local.toml", home="voice",
                ),
                LabItem(
                    key="digest.daily", title="Daily digest", detail="A summary of yesterday's sessions each morning.",
                    tag="local", source="plugin:digest",
                ),
            ],
        ),
        ChatList(
            ts=_TS,
            chats=[
                ChatSummary(
                    chat=1, folder=_FOLDER, alias="report draft", state="idle", created=_TS,
                    logged_at="2026-10-27T11:40:00Z", unlogged=True, last_reply="2026-10-27T11:52:00Z",
                ),
                ChatSummary(chat=2, folder=f"{_FOLDER}-two", alias=None, state="working", created=_TS),
                ChatSummary(
                    chat=3, folder=_FOLDER, state="idle", created=_TS, title="Acme pricing page", parent=1,
                    thread=ThreadInfo(
                        label="Thread 1", slot=1, parent=1, brief="Review the Acme pricing page on its own.",
                        files=[f"{_FOLDER}/pricing.html"], opened_at=_TS,
                    ),
                ),
            ],
            next_chat=4,
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
        UserText(ts=_TS, chat=1, turn=1, text="Compare these", attachments=[f"{_FOLDER}/before.png", f"{_FOLDER}/after.png"]),
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
        FilesRoots(
            ts=_TS,
            id="req-6",
            roots=[
                Root(name="projects", path="/Users/someone/projects"),
                Root(name="papers", path="/Users/someone/papers", extra=True),
                Root(name="old", path="/Users/someone/old", extra=True, missing=True),
            ],
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
        ViewerAct(ts=_TS, id="act-1", chat=1, action="click", args={"target": "e12"}),
        SpacesList(
            ts=_TS,
            spaces=[
                SpaceInfo(
                    id="meeting-prep",
                    title="Meeting prep",
                    icon="calendar-clock",
                    order=2,
                    location="/Users/sam/Spaces/meeting-prep.md",
                    media="markdown",
                    updated="2026-10-31T14:05:11.250000Z",
                    notice="Prep for your 10:00 meeting is ready",
                    notice_target="meeting-1000",
                ),
                SpaceInfo(
                    id="brief",
                    title="brief",
                    icon="doc.text",
                    location="/Users/sam/Spaces/brief.html",
                    media="html",
                    updated="2026-10-31T07:30:00.000000Z",
                    removable=False,
                ),
            ],
        ),
        DeploymentMessage(
            ts=_TS,
            id="msg-20261105-1",
            title="Standup moved",
            text="Today's standup is at **10:30**.",
            notify=True,
            space="meeting-prep",
        ),
        Models(
            ts=_TS,
            chat=14,
            id="req-11",
            current="sonnet",
            choices=[
                ModelChoice(
                    value="default",
                    display_name="Default (recommended)",
                    description="Opus for complex work",
                    resolved_model="claude-opus-5",
                ),
                ModelChoice(
                    value="opus", display_name="Opus", description="Opus for the hardest work", resolved_model="claude-opus-5"
                ),
                ModelChoice(value="sonnet", display_name="Sonnet", description="Efficient for routine tasks"),
                ModelChoice(value="haiku", display_name="Haiku", description="Fastest for quick answers"),
            ],
        ),
        ThreadProposal(
            ts=_TS,
            chat=14,
            proposal="p-3f9a",
            tool_use_id="toolu_09",
            brief="Review the Acme pricing page on its own.",
            files=[f"{_FOLDER}/pricing.html"],
            state="started",
            thread=15,
        ),
        McpServers(
            ts=_TS,
            id="req-20",
            live=True,
            servers=[
                McpServerRow(
                    name="portico", title="portico", group="core", transport="sdk", status="connected",
                    detail="Connected · the viewer, files and screen · 9 tools", tool_count=9,
                    can_toggle=False, can_remove=False, can_sign_out=False,
                ),
                McpServerRow(
                    name="acme-tracker", title="Acme Tracker", group="user", transport="http", status="connected",
                    detail="Connected · 2 tools", tool_count=2,
                    tools=[
                        McpToolRow(name="list_tasks", description="Lists tasks, with filters", read_only=True, policy="allow"),
                        McpToolRow(name="update_task", description="Changes a task's status or owner", policy="ask"),
                    ],
                    can_toggle=True, can_remove=True, can_sign_out=True,
                ),
                McpServerRow(
                    name="acme-calendar", title="acme-calendar", group="user", transport="http", status="needs_auth",
                    detail="Needs you to sign in", can_toggle=True, can_remove=True, can_sign_out=False,
                ),
                McpServerRow(
                    name="design-files", title="design-files", group="shipped", transport="stdio", status="off",
                    detail="Off for you · it stays off through updates", can_toggle=True, can_remove=False, can_sign_out=False,
                ),
            ],
        ),
        PluginsState(
            ts=_TS,
            id="req-30",
            installed=[
                PluginRow(
                    id="design-review@acme", name="design-review", version="1.4.0", scope="local", enabled=True,
                    description="Critiques a screen against your design system", marketplace="acme", update_to="1.5.0",
                ),
                PluginRow(
                    id="meeting-notes@claude-plugins-official", name="meeting-notes", version="2.1.0", scope="user", enabled=True,
                    description="Turns a recording into notes and follow-ups", marketplace="claude-plugins-official",
                ),
            ],
            available=[
                AvailablePlugin(
                    id="design-review@acme", name="design-review", description="Critiques a screen against your design system",
                    marketplace="acme", version="1.5.0", installed=True,
                ),
                AvailablePlugin(id="budget-watch@claude-plugins-official", name="budget-watch", marketplace="claude-plugins-official"),
            ],
            marketplaces=[
                PluginMarketplace(name="claude-plugins-official", plugin_count=42, checked="today"),
                PluginMarketplace(name="acme", source_label="github.com/acme/plugins", plugin_count=6, checked="Oct 24"),
            ],
        ),
        PluginsDetails(
            ts=_TS, id="req-37", plugin="design-review@acme",
            text="design-review@acme 1.4.0\nSkills (2): critique, compare-to-system\nCommands (1): /review-screen\n",
        ),
        PluginsOptions(
            ts=_TS,
            id="req-38",
            plugin="design-review@acme",
            options=[
                PluginOption(key="region", title="Region", description="Where your reviews are kept", set=True, value="us"),
                PluginOption(key="api_key", title="API key", description="Your Acme key", sensitive=True, set=True),
            ],
        ),
        AppOpen(
            ts=_TS,
            chat=1,
            tool_use_id="toolu_01",
            server="acme-tracker",
            server_title="Acme Tracker",
            tool="show_project",
            resource_uri="ui://tracker/project.html",
            html="<!doctype html><title>Acme launch</title><main id=\"tasks\"></main>",
            csp={"connectDomains": ["https://api.acme.example"]},
            prefers_border=True,
            input={"project": "Acme launch"},
        ),
        AppResult(
            ts=_TS,
            chat=1,
            tool_use_id="toolu_01",
            content=[{"type": "text", "text": "Acme launch: 3 of 4 tasks done."}],
            structured_content={"project": "Acme launch", "tasks": [{"title": "Launch email", "owner": "Sam", "status": "todo"}]},
        ),
        AppCancelled(ts=_TS, chat=1, tool_use_id="toolu_02"),
        AppCallResult(
            ts=_TS,
            id="req-40",
            tool_use_id="toolu_01",
            ok=True,
            content=[{"type": "text", "text": "Launch email is done."}],
            structured_content={"task": "Launch email", "status": "done"},
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
