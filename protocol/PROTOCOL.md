# Portico protocol, version 1

The contract between the Portico app and a gateway. The gateway's Pydantic
models (`gateway/portico_gateway/messages.py`) are the source of truth;
`schema/portico.schema.json` and one example per message under `examples/`
are exported from them with `portico-gateway export-schema` and
`portico-gateway export-examples`. Both test suites decode every example, so
a message added on one side without the other fails a test.

Sections marked *(filled in at Task N)* carry the field list now and gain
their behaviour notes when that task lands.

## Transport

- One WebSocket from the app to the gateway: `ws://127.0.0.1:<port>/v1?token=<token>`.
  The gateway binds loopback only and refuses a connect without the
  per-launch token (missing or wrong) with HTTP 401 before the upgrade; a
  path other than `/v1` is 404. The token is the content of the `token`
  file in the state directory, rewritten on every gateway launch.
- One app at a time: a second connection that completes `hello` replaces
  the first, which receives `error code=session.replaced` and is closed
  (close code 1008). Events sent while no app is attached are not queued
  on the socket; the app catches up through `chat.open` with `since`.
- One HTTP endpoint for artifact producers, `POST /v1/artifact`, with
  `Authorization: Bearer <token>` (the same token file) and a JSON body
  `{"chat": <number>, "location": "<path or URL>", "title": "<optional>"}`.
  Any hook, skill, or script on the agent side can call it to say "show
  this". The gateway reports the artifact to the app at once as
  `artifact.created` with `source: producer` and `open: true`, records it
  in the chat's history, and answers `201` with `{"artifact": {...}}`.
  A relative `location` is resolved against the chat's folder; `http://`
  and `https://` locations are URLs. Refusals: `401` without the token,
  `404` for an unknown chat, `400` when `chat` or `location` is missing
  or the body is not JSON — each as `{"error": "..."}`. The call works
  while no app is attached; the artifact waits in the ring for `chat.open`.
- `GET /v1/health` answers `{"epoch": "...", "protocol": 1}` without a token,
  so the app can tell a live gateway from a stale ledger. Plain HTTP shares
  the WebSocket port; an unknown route is 404 with `{"error": "..."}`.
- The gateway prints `PORTICO_READY port=<n>` on stdout once it is listening
  and writes `ledger.json` (`host`, `port`, `pid`, `epoch`) in the state
  directory; the ledger is removed on a clean stop (close code 1001 to the app).

## Envelope

Every frame is one JSON object:

| field | type | when |
|---|---|---|
| `type` | string | always; the message name, e.g. `message.send` |
| `chat` | integer | on every chat-scoped message; absent on `hello`, `chat.list`, and an `error` without a chat |
| `id` | string | where a reply must correlate (requests), and the card id on `card.ask` / `card.answer` / `card.cancel` |
| `seq` | integer | on every chat-scoped gateway → app event: the chat's sequence number, for gapless reattach |
| `ts` | string | always; ISO-8601 UTC, e.g. `2026-10-27T12:00:00Z` |

Chats are integers from 1 and are never named; an `alias` is optional.
Ids are opaque strings. The `null` form of an optional field is never sent;
the field is left out.

The reference gateway in this version is strict: a frame with an unknown
`type` is answered with `error code=protocol.unknown_type`, and a known type
with an unknown field with `error code=protocol.invalid`. The schema is the
inventory of what each side may send.

## Version

`protocol` is the integer `1`. Both sides send it in `hello`; a mismatch is
shown in the app, not silently tolerated: the gateway answers an app's
`hello` with another version with `error code=protocol.version` ("the app
speaks protocol N; this gateway speaks protocol 1") and closes, and the
app refuses a gateway `hello` with another version and says so in its
status strip ("the gateway speaks protocol N, this app speaks 1") rather
than opening chats. `epoch` in the gateway's `hello`
is a UUID minted per gateway launch; a changed epoch tells the app its
sequence numbers are stale and it must re-fetch history.

## Direction vocabulary

- **client** = the app (app → gateway). Example files: `examples/client.<type>.json`.
- **server** = the gateway (gateway → app). Example files: `examples/server.<type>.json`.

`hello` and `files.list` exist in both directions with different fields.

## Messages: app → gateway

### `hello` — `HelloClient`
First frame on every connection. `protocol: 1`, `app_version: string`.
Anything else first is answered with `error code=protocol.hello_required` and
the socket is closed (close code 1002); a first frame that does not parse
gets its `protocol.*` error and the same close. A second `hello` on an
open connection is `error code=protocol.invalid` and otherwise ignored.

### `chat.new` — `ChatNew`
`folder: string` (an absolute path to an existing directory; anything else
is `error code=chat.folder_invalid`), `id` to correlate. The gateway numbers
the chat, starts its engine in the folder with the configured
`setting_sources`, records it in the index, and replies `chat.state`
(`idle`, with the chat number and the request's `id`) followed by an
updated `chat.list`. If the engine cannot start the chat is dropped again
and the reply is `error code=engine.start_failed`.

When the deployment configures `before_first_chat`, the gateway runs that
command once per launch before honouring the first `chat.new`; each output
line (stdout and stderr, merged) is sent to the app as a chat-less
`status.set`. A non-zero exit, or no exit within `command_timeout_seconds`
(the whole process group is then killed), answers the request with
`error code=lifecycle.before_first_chat_failed` carrying the exit code or
the timeout and the command's last line, and no chat is created (no number
is consumed, no engine starts); the next `chat.new` runs the command again.
Once it has passed, later `chat.new`s in the same launch skip it. The
same preflight guards a `message.send` that starts an engine for a chat
restored from a previous launch (the first thing a person does after a
gateway restart is usually to continue a chat, not open one): it is
refused with the same `error code=lifecycle.before_first_chat_failed`,
carrying the send's `id`, and no turn starts. A `gateway.stop` (or a stop
signal) while the command is still running does not wait for it: the
command's process group is killed and the request waiting on it is
refused with the same error.

### `chat.open` — `ChatOpen`
`chat`, `since: integer | absent` (the last `seq` the app saw; absent, or
0, means from the beginning), `id` to correlate. Reply: `chat.history` carrying the
chat's events, then (after a transcript replay) the chat's stored
artifacts as `artifact.created` frames with `open: false` and no `seq`,
then `chat.live` with the chat's current `seq`, then the chat's open cards
again as `card.ask` frames exactly as first sent (same `id`, same `seq`,
so an app that already holds one de-duplicates by `id`; re-sending does
not advance `seq`). v0.3: right after `chat.live` comes a `chat.state`
with the chat's state word and `mode` — a direct reply carrying the
request's `id` and no `seq`, not kept in the ring. Opening a chat neither starts a turn nor advances `seq`; it
can be repeated at any time, including while a turn is running.

Where the history comes from: the gateway's ring buffer when it can serve
the request — `since` is inside the ring, or the chat was created in this
gateway launch and nothing has fallen off the ring yet. Otherwise — the
first open after a gateway restart (a new `epoch`), `since` older than
the ring, or a `since` beyond the chat's current `seq` (a number from an
earlier launch, which the ring cannot serve) — the gateway reads the
engine's transcript for the chat's
session and translates it into the same events a live turn produces,
with `user.text` for what the person sent; those events carry no `seq`
and `truncated` is false. User-role entries the engine writes for itself
(reminders, local command output, and the `[Request interrupted by user]`
marker it records after a stop) are not the person's words: they replay as
no event and start no turn, so turn numbers match the prompts the person
actually sent. A chat whose transcript cannot be found (no
session yet, or the engine's files are gone) opens with an empty history,
never an error. When the transcript is empty but the ring holds events,
the ring is sent; it is marked `truncated` only when the request named a
`since` the ring no longer reaches (the app then asks from the
beginning), never for a request from the beginning, which nothing could
serve better — so the app never loops.

### `chat.stop` — `ChatStop`
`chat`. Interrupts and closes the chat's engine. A turn in flight ends with
`turn.finished outcome=stopped` (emitted by the gateway), then the state
becomes `stopped`. The chat keeps its number, folder and session: the next
`message.send` starts a fresh engine that resumes the same session and the
chat goes `idle` → `working` as usual.

### `chat.alias` — `ChatAlias`
`chat`, `alias: string | absent` (absent or empty clears it). Reply: an
updated `chat.list`.

### `chat.remove` — `ChatRemove`
`chat`. Closes the engine, forgets the chat (its number is never reused),
and replies with an updated `chat.list`.

### `message.send` — `MessageSend`
`chat`, `text: string`, `attachments: [string]` (absolute paths, default
empty), `id` to correlate a refusal. The gateway emits `turn.started` (the
chat's next `turn`), `user.text` (the text as the engine receives it,
attachments included), `chat.state working`, then streams the engine's events
(`text.delta`, `tool.started`, `tool.finished`, cards, artifacts) and ends
with `turn.finished` and `chat.state idle`. Slash text (`/review`) is passed
to the engine as typed and dispatches the folder's commands.

v0.3: a message whose first word is a slash command (`/word`, or
`/plugin:word`; a path like `/Users/...` is not one) that nobody knows —
not Portico (`/new`), not the deployment (`hello.commands`, or the first
word of an action's text), not the engine — is **not** sent to the agent.
It is an empty turn: `turn.started`, `user.text`, `chat.notice` ("No
command /word here"), `turn.finished outcome=done`, `chat.state idle`
(never `working`); the gateway logs it. The engine's commands are what it
lists when it starts (its initialize answer, and the `slash_commands` of
its `init` message), so a chat without a running engine has it started
first, exactly as the send would. An engine that cannot say what it knows
gets the message as typed.

A send while a turn is running (state `working` or `waiting on you`) is
refused with `error code=chat.busy`. Every attachment must be an absolute
path to an existing file: a path that does not exist, or names a
directory, is refused with `error code=attachment.missing` and nothing is
sent to the engine. A send on a `stopped` chat restarts its engine first.

Attachments reach the engine as their paths, appended to the text in
exactly this form (one `- ` line per path, in the order given; the block
is omitted when there are no attachments):

```
<text>

Attached files:
- /abs/path
- /abs/other
```

### `turn.stop` — `TurnStop`
`chat`. Interrupts the running turn; it finishes with `outcome: stopped`
(the engine's own finish is reported as `stopped`; if none arrives within
the gateway's grace period, 15 seconds, the gateway ends the turn itself
and closes that engine, since one that ignored an interrupt is in no known
state; the next send then starts a fresh engine on the same session, as
after `chat.stop`) and the chat returns to `idle`. When the engine did
finish in time it stays up for the next send. A stop when nothing is
running does nothing and answers nothing.

### `card.answer` — `CardAnswer`
`chat`, `id` (the card's id), `answer: object`, `scope: once | chat | always | absent`,
`note: string | absent`. A permission answer is
`{"decision": "allow" | "deny"}` with `scope`; a question answer is
`{"answers": {<question text>: <label> | [labels]}}` (a label list for a
`multi_select` question). An unknown, already-answered, or cancelled id is
refused with `error code=card.stale` and nothing else happens; an answer
whose shape does not fit the card's kind is refused with
`error code=card.invalid_answer` and the card stays open. An accepted
answer is recorded in the chat's history as `card.answered`. The answer
resolves the engine's request: `allow` with scope `once` (or no scope)
allows this use; scope `chat` also allows it for the rest of this chat,
so later requests it covers answer without a card (the gateway's memory
of that lasts as long as the gateway runs). What "it" covers mirrors the
engine's own prompt: for a tool that names a file, the tool; for a tool
that runs a command, the engine's suggested rule for that command (a
prefix such as `git status:*`, matched as whole words, every part of a
compound command on its own) or, when the engine suggests none, that
exact command — so allowing `ls` for the chat never allows `rm -rf /`.
Scope `always` hands
the engine its own suggested permission rule, which lands in the folder's
local settings, the same place the engine's own prompt writes it — the
gateway keeps no permanent allow store. `deny` refuses the use, and
`note` is the message the agent sees (default `denied by the user`).

### `files.list` — `FilesListRequest`
`root: string` (a root name from `hello.roots`, or `chat` for the chat's
folder, with `chat` set), `path: string` (relative, default `""`), `id` to
correlate. Reply: `files.list` (server), or `error` with `files.unknown_root`
(no such root, or `chat` without a chat number), `files.outside_root` (the
path leaves the root once `..` and symlinks are resolved, or is absolute),
`files.not_found` (the path is not an existing directory under the root).

### `artifact.opened` — `ArtifactOpened`
`chat`, `artifact_id: string`. Optional telemetry: the app showed that
artifact. The gateway accepts it and answers nothing.

### `gateway.stop` — `GatewayStop`
No fields beyond the envelope. Stops the gateway: every running turn is
interrupted and reported (`turn.finished` with `outcome: stopped`, then
`chat.state idle`), after a chat-less `status.set` saying how many turns
are being interrupted when there are any; every engine is closed; the
deployment's `on_stop` command runs, if configured, with its lines as
chat-less `status.set` frames (a failure or timeout is one more
`status.set` line and does not block the stop); the index is persisted;
then the gateway closes the app's connection (close code 1001), removes
the ledger and exits 0. Quitting the app only detaches; this is the
explicit stop. SIGTERM or SIGINT to the gateway process takes the same
path. There is no reply frame: the close is the answer.

### `session.renew` — `SessionRenew`
`chat`, `log: bool` (default `true`), `id`. Ends session `chat` and opens
the next one in the same folder. With `log` and a log step configured
(`hello.can_log`), the gateway first runs it in the ending session as an
ordinary turn — `turn.started`, `user.text`, its events, any cards, and
`turn.finished` — and waits for it; the session is `logged` only when that
turn finished `done`. A failed or stopped log step still renews (`logged:
false`). Then the engine is closed, the session gets `ended` and `chat.state
stopped`, the next session (a new number, `parent` = the ended one) gets
`chat.state idle`, and the gateway answers `session.renewed` (with the
`id`) followed by `chat.list`. The next session's engine starts with its
first `message.send`. Errors: `chat.unknown`, `chat.busy` (a turn or another
renew is running), `session.ended` (already ended). While a renew runs,
`message.send` to that session is `chat.busy`; `turn.stop` stops the log
turn; `card.answer` answers its cards.

### `files.search` — `FilesSearch`
`root` (named as for `files.list`; `chat` with `chat` set), `query`, `id`.
Reply: `files.results`, or `error` with the `files.list` root codes or
`files.search_failed`. The reference gateway asks Spotlight (`mdfind
-onlyin`): at most 50 hits, 5 seconds, names matching the query first,
hidden entries and anything outside the root dropped; a blank query has no
hits. A deployment plug-in may search instead.

### `session.mode` — `SessionMode` *(v0.3)*
`chat`, `mode: default | acceptEdits | auto`. Changes how the engine
decides on tool use for this session, at once if its engine is running
(the SDK's `set_permission_mode`) and for every later turn: `default`
asks each time (a `card.ask` per request), `acceptEdits` allows file edits
without asking, `auto` lets the engine's classifier allow or block each
step. Answered with `chat.state` carrying `mode`; the mode is kept on the
chat record (`ChatSummary.mode`). A new session starts with the
deployment's `permission_mode` (default `auto`). `bypassPermissions` and
`dontAsk` are not offered. Errors: `chat.unknown`, `session.ended`.
The answering `chat.state` is stamped (it is history) and carries the
request's `id`. A chat with no running engine records the mode for its
next engine; no engine is started to change it.

## Messages: gateway → app

### `hello` — `HelloServer`
`protocol: 1`, `gateway_version`, `epoch`, `brand {name, agent_name, accent?, icon?}`
(`name` goes in the title bar and the About panel, `agent_name` is how
the app refers to the agent, `accent` is a CSS hex colour — `#RRGGBB`,
`#RGB` or `#RRGGBBAA` — for the app's controls, `icon` an absolute path
to an image file for the Dock, the About panel and the sidebar header;
absent or unreadable values fall back to "Portico" and the system
defaults), `actions: [{label, text}]`, `roots: [{name, path}]` (`path`
absolute, as configured with any `~` expanded), `commands: [string]`
(reserved; empty in v0.1), `capabilities: [string]` (v0.1: `cards.form`,
`files`, `producer`). Always followed by `chat.list`, so the app has the
sidebar before anything else arrives.

v0.2 added `presentation: single | multiple` and `can_log`. v0.3:
`presentation` defaults to `single`; `config_stale: bool` (the config file
changed after the gateway started, so a restart is needed to apply it);
`can_update: bool` (the deployment configured an update command, which
`portico-gateway update` runs).

### `chat.list` — `ChatList`
`chats: [{chat, folder, alias?, state, created}]`. Sent after `hello` and
after every change to the set of chats or their aliases (`chat.new`,
`chat.alias`, `chat.remove`). State changes alone travel as `chat.state`.
Not chat-scoped: no `seq`, not replayed in `chat.history`.

### `chat.state` — `ChatState`
`chat`, `seq`, `state`: exactly `idle`, `working`, `waiting on you`, `stopped`;
`mode?` (v0.3): the session's permission mode, sent when the chat opens
and whenever it changes.
Stamped and kept in the ring like every chat-scoped event, so a replay
shows the state transitions in order. The one answering `chat.new` also
carries the request's `id`.

### `chat.history` — `ChatHistory`
`chat`, `id` (echoing `chat.open`), `events: [event]` (chat-scoped events,
oldest first; empty when the app is up to date), `truncated: bool` (true
when `since` fell behind the ring buffer and no transcript could fill the
gap, so the replay starts later than asked; the app should then refetch
from the beginning. Never true for a request from the beginning, and an
app that asked from the beginning applies what it got rather than asking
again). Not itself stamped. Events from the ring carry their
original `seq`; events from a transcript replay carry none (see
`chat.open`) and are: `turn.started`, `user.text`, `text.delta`,
`tool.started`, `tool.finished`, `turn.finished outcome=done` per turn.
Transcript turns count from 1 over the whole session; when no turn has
run yet in this launch, live turns continue from the last replayed one.

### `chat.live` — `ChatLive`
`chat`, `id` (echoing `chat.open`), `seq` (the chat's current sequence
number, not a new one). History is complete; what follows is live.

### `turn.started` — `TurnStarted`
`chat`, `seq`, `turn: integer` (counts from 1 per gateway launch). Always
followed by `user.text` and then `chat.state working`.

### `user.text` — `UserText`
`chat`, `turn`, `text`, `seq` when live. What the person sent to start
`turn`, as the engine receives it (attachments appear in the exact
`message.send` form). Sent live right after `turn.started`, stamped and
kept in the ring, so a replay from the ring shows the person's side of
the conversation; a transcript replay (`chat.history` after a gateway
restart or past the ring) carries it too, without `seq`. The app renders
the one `user.text` per turn as the bubble and does not add a second from
the `message.send` it sent.

### `text.delta` — `TextDelta`
`chat`, `seq`, `turn`, `text`. A fragment of the agent's reply, in order;
the app appends.

### `tool.started` — `ToolStarted`
`chat`, `seq`, `turn`, `tool_use_id`, `tool`, `summary`, `input: object`. *(Task 4)*

### `tool.finished` — `ToolFinished`
`chat`, `seq`, `turn`, `tool_use_id`, `ok: bool`, `summary`;
`permission?` and `note?` (v0.3): what happened to this use's permission,
drawn on the tool row — `once` (allowed once), `session` (allowed for this
session, by this answer or an earlier one), `auto` (auto mode allowed it;
only for tools that would otherwise ask), `declined` (with the person's
`note`), `blocked` (auto mode's classifier refused it). Absent when
nothing was decided (a read in `default` mode).

How the reference gateway decides: `blocked` when the tool result is an
error saying it was denied by the engine's auto mode classifier; else the
answer to this use's card (`once`, `session`, `declined` with the note; a
card cancelled by a stop or by nobody being there is `declined` with the
reason as the note); else `session` when an earlier allow for this
session covered it (no card); else `auto` when the session's mode is
`auto` and the tool is not a read-only one (Read, Glob, Grep, LS,
TodoWrite, ToolSearch, Task and the like get nothing). Outcomes are kept
on the chat record by `tool_use_id`, so rows replayed from the transcript
after a gateway restart carry them too. An allow for this session is
kept on the chat record as well (it survives a gateway restart; a new
session starts with none); one given on any of `Write`, `Edit`,
`MultiEdit`, `NotebookEdit` covers all four (their cards ask the same
question); one given on a command covers that command (the engine's
suggested prefix rule, else the exact command), also after a `cd` into the
session's own folder.

### `turn.finished` — `TurnFinished`
`chat`, `seq`, `turn`, `outcome: done | stopped | error`. Exactly one per
turn: `done` when the engine finished, `stopped` after `turn.stop` or
`chat.stop`, `error` when the engine reported a failure or refused the
message. Always followed by `chat.state` (`idle`, or `stopped` after
`chat.stop`).

### `card.ask` — `CardAsk`
`chat`, `seq`, `id`, `kind: permission | question | form`, `title`, and one of
`permission {tool, summary, input}`,
`questions: [{question, header, options: [{label, description}], multi_select}]`,
`form: [{key, label, kind: text | choice | toggle, options?}]`.
A `permission` card's `title` is a plain question about the step (v0.3:
`Save changes to Q3-synthesis.md?`, `Run git status?`, else `Use <tool>?`;
the app shows `permission.tool` beside it as a tag), its `tool_use_id`
(v0.3) names the tool row the card belongs to, `summary` is the one-line
summary also shown on the tool row (a path, the first line of a command),
and `input` is the tool's full input. A `question` card maps the engine's
question tool field for field (`multiSelect` → `multi_select`) and its
`title` is the first question's `header`. `form` is defined for a
deployment's gateway; the reference gateway never sends one.

While a card is open the chat's state is `waiting on you` (sent right
after the `card.ask`); once it resolves with the turn still running the
state returns to `working`. Nothing is ever allowed by default: the only
way to an `allow` is a person's `card.answer`, or a chat-scoped allow a
person gave earlier in that chat.

Held while no app is attached: the card stays open and the hold clock
runs only while nobody is attached (`card_hold_seconds`, default 600; an
attached app may take as long as it likes). When the hold runs out the
gateway sends `card.cancel` with `reason: nobody was there to answer` and
the engine sees a deny with that message (a question is refused the same
way). An app that attaches while a card is open gets it again through
`chat.open`.

### `card.answered` — `CardAnswered`
`chat`, `seq`, `id`. The gateway accepted a `card.answer` for the card
`id`: the card is closed. Stamped and kept in the ring right after the
answer (before the `chat.state working` that follows), so a replay that
carries a `card.ask` also carries what became of it and the app does not
pin an answered card again after a relaunch. The app that answered has
already unpinned the card; for it this frame confirms. v0.3: a permission
card's closing carries `tool_use_id`, `outcome` (`once`, `session`,
`declined`) and the deny `note`, so the outcome is drawn on the tool row
at once and the card leaves no record of its own. The reference gateway
reports scope `always` as `session` (it covers this session at least).

### `card.cancel` — `CardCancel`
`chat`, `seq`, `id`, `reason?`. The card is closed and its answer is no
longer wanted; the engine's request resolved as a deny carrying the
reason. Sent on `turn.stop` (`turn stopped`), `chat.stop` (`chat
stopped`, before the `turn.finished`), `chat.remove` (`chat removed`), a
gateway stop (`gateway stopping`), and a timed-out hold (`nobody was there
to answer`). A `card.answer` that arrives afterwards is `card.stale`.

### `artifact.created` — `ArtifactCreated`
`chat`, `seq`, `artifact {id, kind: file | url, location, media, title, source, open}`.
`media` is one of `markdown`, `image`, `html`, `pdf`, `text`, `url`, `other`
(by file extension: `.md .markdown`, `.png .jpg .jpeg .gif .webp .svg`,
`.html .htm`, `.pdf`, `.txt`; a URL is `url`; anything else `other`).
`source` says where the gateway found it: `tool` (a file-writing tool —
`Write`, `Edit`, `MultiEdit`, `NotebookEdit` — named the path), `text`
(the agent's text printed a `http://localhost` / `http://127.0.0.1`
address, or named a viewable file that exists when the turn ends), or
`producer` (the HTTP endpoint). `title` is the file name or the URL
unless a producer gave one. A file is reported wherever it lives — a
scratch directory outside the chat's folder opens like any other.

Every artifact goes in the history. `open` is true on the artifact the
app should show now: the turn's artifacts are sent together just before
`turn.finished` (including a `stopped` finish), one per location, and
only the newest *viewable* one — `markdown`, `image`, `html`, `pdf`,
`url` — carries `open: true`; `text` and `other` are listed and never
auto-open, so scaffolding a project does not flap the viewer. A producer
artifact is sent at once with `open: true`. Artifacts are kept with the
chat in the index, so a later launch still lists them.

### `files.list` — `FilesList`
`root`, `path` (normalised relative path, `""` for the root itself),
`entries: [{name, dir, size?}]`, `id` and `chat` echoing the request.
Entries: directories first, then files, each group in case-insensitive
name order; names starting with `.` are skipped; `size` is bytes for a
file and absent for a directory. A direct reply, not a history event: no
`seq`.

### `status.set` — `StatusSet`
`chat?`, `seq?`, `text`. One line for the status strip, shown verbatim.
Without `chat` and `seq` it is gateway-wide and not part of any history:
the output lines of the deployment's `before_first_chat` and `on_stop`
commands arrive this way, as does the gateway's own "stopping" line.

### `session.renewed` — `SessionRenewed`
`id` (the `session.renew`'s), `ended: ChatSummary`, `next: ChatSummary`.
Not stamped. Sent after `chat.state` for both sessions and before the
`chat.list` that includes the new one.

### `context.usage` — `ContextUsage`
`chat`, `percent` (0–100), `model?`, `model_name?` (v0.3: the
deployment's display name for the model from
`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL_NAME` when the env names one,
e.g. `Claude Opus 5.5 via Bedrock`; the app shows it instead of the id). After a turn ends, how full the
session's context window is. Not stamped (a reading, not history); the
last value is the chat's `context_percent` in `chat.list`. Absent when the
engine cannot say.

### `chat.compacted` — `ChatCompacted`
`chat`, `trigger: "auto" | "manual"`, `seq`. The engine is summarizing
earlier conversation to make room. Stamped and replayed with the history;
counted in the chat's `compactions`.

### `chat.notice` — `ChatNotice` *(v0.3)*
`chat`, `seq`, `text`. A quiet line from the gateway in the conversation,
e.g. `No command /foo here` for a slash command that neither the
deployment nor the engine knows (the message is not sent to the agent).
Stamped and replayed with the history.

### `config.stale` — `ConfigStale` *(v0.3)*
No fields. The config file is newer than when the gateway started; the
app says "restart the gateway to apply". Sent once when the gateway
notices; `hello.config_stale` carries the same fact on connect.

### `update.available` — `UpdateAvailable` *(v0.3)*
`version`. The deployment's update check (config `update.check`) found a
newer version. The app offers the update; `portico-gateway update` runs
it (config `update.run`).

### `files.results` — `FilesResults`
`id`, `root`, `query`, `hits: [{path, snippet?}]` with `path` relative to
the root. A direct reply: no `seq`.

### `error` — `Error`
`chat?`, `id?` (the request it answers), `code`, `message`. Codes so far:
`protocol.invalid`, `protocol.unknown_type`, `protocol.hello_required`,
`protocol.version` (the app's `hello` names another protocol version;
the socket is closed),
`protocol.unsupported` (a known type this gateway has no handler for),
`session.replaced`, `chat.unknown` (no chat with that number),
`chat.folder_invalid` (`chat.new` on a path that is not an existing
directory), `chat.busy`, `attachment.missing`, `engine.start_failed`
(the engine could not start in the folder), `engine.send_failed` (the
engine refused the message; the turn is finished with `outcome: error`),
`card.stale`, `card.invalid_answer`, `files.unknown_root`, `files.outside_root`,
`files.not_found`, `files.search_failed` (Spotlight failed or timed out),
`session.ended` (`session.renew` or `message.send` on a session that has
ended), `session.live` (`chat.new` in single presentation while a session
is live; renew it instead),
`lifecycle.before_first_chat_failed` (the deployment's preflight failed or timed out; the message
carries its last line and no chat was created),
`gateway.error` (a handler failed; the message says which).

An `error` that answers a request carries the request's `id` and `chat`
and is not stamped: refusals are replies, not history.

A bad frame after `hello` (unknown type, unknown field, not JSON) is
answered with an `error` and the connection stays open; only the first
frame is fatal.

## Command line *(v0.3)*

Besides `run` and `doctor`, the reference gateway's CLI
(`bin/portico-gateway <command>`; `--state` and `--config` as for `run`)
offers what a deployment's own tools build on. These are behaviour notes
for the reference gateway, not protocol messages.

- `status [--json]` — whether a gateway runs on this state directory, and
  its live session. **This is the documented signal for "the app holds a
  session in this folder"** (a deployment's one-surface rule: terminal or app, never both); the lock and
  ledger files are internal and may change. `--json` prints one object:
  `{"version": 1, "running": bool, "pid", "port", "folder", "session",
  "state", "mode", "started_at", "config_stale"}`. Keys whose value is
  unknown are left out (no session yet: no `folder`, `session`, `state`,
  `mode`); `session` is the live session's number (the newest chat that
  has not ended), `state` its state word, `mode` its permission mode,
  `started_at` when the gateway started (UTC, ISO 8601), `config_stale`
  whether the config file changed since. `version` changes only if a key
  changes meaning. Exit 0 when a gateway runs, 3 when none does. Without
  `--json`, one line for a person.
- `stop` — stops the gateway running on this state directory through its
  own stop path (as `gateway.stop`: running turns reported as stopped,
  `on_stop`, index saved) and waits for it to exit. Exit 0 when one was
  stopped, 3 when none ran, 1 when it did not stop in time
  (`--timeout`, default `command_timeout_seconds` + 30).
- `update --check` — runs config `update.check` with `/bin/sh -c`: exit 0
  and the version on stdout when an update is available (the command's
  last non-blank line), 1 when none (any other exit, or no output), 2 when
  no check is configured.
- `update` — stops a running gateway (as `stop`), then runs config
  `update.run` with `/bin/sh -c`, its output (stdout and stderr) streamed
  to stdout; exits with its exit code, 2 when no update command is
  configured. It does not start the gateway again: the app does.
- `config-value <dotted.key>` — prints one config value (`brand.name`,
  `brand.app_icon`, `update.run`...) or nothing when it is unset or not a
  key; exit 0. A config file that does not load: its reason on stderr,
  exit 1. Lists and tables print as JSON.

The running gateway also checks for updates itself: `update.check` at
start and every 6 hours, in the background; a version found goes to the
attached app as `update.available`, and again to an app that attaches
later. It watches the config file's modification time every ~10 seconds
and sends `config.stale` once when the file is newer than at start.

