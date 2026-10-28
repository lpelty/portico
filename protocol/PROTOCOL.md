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
shown in the app, not silently tolerated. `epoch` in the gateway's `hello`
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
Once it has passed, later `chat.new`s in the same launch skip it.

### `chat.open` — `ChatOpen`
`chat`, `since: integer | absent` (the last `seq` the app saw; absent means
from the beginning), `id` to correlate. Reply: `chat.history` carrying the
chat's events, then (after a transcript replay) the chat's stored
artifacts as `artifact.created` frames with `open: false` and no `seq`,
then `chat.live` with the chat's current `seq`, then the chat's open cards
again as `card.ask` frames exactly as first sent (same `id`, same `seq`,
so an app that already holds one de-duplicates by `id`; re-sending does
not advance `seq`). Opening a chat neither starts a turn nor advances `seq`; it
can be repeated at any time, including while a turn is running.

Where the history comes from: the gateway's ring buffer when it can serve
the request — `since` is inside the ring, or the chat was created in this
gateway launch and nothing has fallen off the ring yet. Otherwise — the
first open after a gateway restart (a new `epoch`), or `since` older than
the ring — the gateway reads the engine's transcript for the chat's
session and translates it into the same events a live turn produces,
with `user.text` for what the person sent; those events carry no `seq`
and `truncated` is false. A chat whose transcript cannot be found (no
session yet, or the engine's files are gone) opens with an empty history,
never an error. When the transcript is empty but the ring holds events,
the ring is sent with its own `truncated` flag.

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
chat's next `turn`), `chat.state working`, then streams the engine's events
(`text.delta`, `tool.started`, `tool.finished`, cards, artifacts) and ends
with `turn.finished` and `chat.state idle`. Slash text (`/review`) is passed
to the engine as typed and dispatches the folder's commands.

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
the gateway's grace period, 15 seconds, the gateway ends the turn itself)
and the chat returns to `idle`. The engine stays up for the next send. A
stop when nothing is running does nothing and answers nothing.

### `card.answer` — `CardAnswer`
`chat`, `id` (the card's id), `answer: object`, `scope: once | chat | always | absent`,
`note: string | absent`. A permission answer is
`{"decision": "allow" | "deny"}` with `scope`; a question answer is
`{"answers": {<question text>: <label> | [labels]}}` (a label list for a
`multi_select` question). An unknown, already-answered, or cancelled id is
refused with `error code=card.stale` and nothing else happens; an answer
whose shape does not fit the card's kind is refused with
`error code=card.invalid_answer` and the card stays open. The answer
resolves the engine's request: `allow` with scope `once` (or no scope)
allows this use; scope `chat` also allows the tool for the rest of this
chat, so later requests for it answer without a card (the gateway's
memory of that lasts as long as the gateway runs); scope `always` hands
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

## Messages: gateway → app

### `hello` — `HelloServer`
`protocol: 1`, `gateway_version`, `epoch`, `brand {name, agent_name, accent?, icon?}`,
`actions: [{label, text}]`, `roots: [{name, path}]`, `commands: [string]`
(reserved; empty in v0.1), `capabilities: [string]` (v0.1: `cards.form`,
`files`, `producer`). Always followed by `chat.list`, so the app has the
sidebar before anything else arrives.

### `chat.list` — `ChatList`
`chats: [{chat, folder, alias?, state, created}]`. Sent after `hello` and
after every change to the set of chats or their aliases (`chat.new`,
`chat.alias`, `chat.remove`). State changes alone travel as `chat.state`.
Not chat-scoped: no `seq`, not replayed in `chat.history`.

### `chat.state` — `ChatState`
`chat`, `seq`, `state`: exactly `idle`, `working`, `waiting on you`, `stopped`.
Stamped and kept in the ring like every chat-scoped event, so a replay
shows the state transitions in order. The one answering `chat.new` also
carries the request's `id`.

### `chat.history` — `ChatHistory`
`chat`, `id` (echoing `chat.open`), `events: [event]` (chat-scoped events,
oldest first; empty when the app is up to date), `truncated: bool` (true
when `since` fell behind the ring buffer and no transcript could fill the
gap, so the replay starts later than asked; the app should then refetch
from the beginning). Not itself stamped. Events from the ring carry their
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
followed by `chat.state working`.

### `user.text` — `UserText`
`chat`, `turn`, `text`. What the person sent to start `turn`, as the
engine's transcript keeps it (attachments appear in the exact
`message.send` form). Only inside a transcript replay (`chat.history`
after a gateway restart or past the ring); never sent live — a live
turn's text is what the app itself sent — so it carries no `seq`.

### `text.delta` — `TextDelta`
`chat`, `seq`, `turn`, `text`. A fragment of the agent's reply, in order;
the app appends.

### `tool.started` — `ToolStarted`
`chat`, `seq`, `turn`, `tool_use_id`, `tool`, `summary`, `input: object`. *(Task 4)*

### `tool.finished` — `ToolFinished`
`chat`, `seq`, `turn`, `tool_use_id`, `ok: bool`, `summary`. *(Task 4)*

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
A `permission` card's `title` is a plain phrase for the tool (`Write a
file`, `Run a command`, else `Use <tool>`), `summary` is the one-line
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

### `error` — `Error`
`chat?`, `id?` (the request it answers), `code`, `message`. Codes so far:
`protocol.invalid`, `protocol.unknown_type`, `protocol.hello_required`,
`protocol.unsupported` (a known type this gateway has no handler for),
`session.replaced`, `chat.unknown` (no chat with that number),
`chat.folder_invalid` (`chat.new` on a path that is not an existing
directory), `chat.busy`, `attachment.missing`, `engine.start_failed`
(the engine could not start in the folder), `engine.send_failed` (the
engine refused the message; the turn is finished with `outcome: error`),
`card.stale`, `card.invalid_answer`, `files.unknown_root`, `files.outside_root`,
`files.not_found`,
`lifecycle.before_first_chat_failed` (the deployment's preflight failed or timed out; the message
carries its last line and no chat was created),
`gateway.error` (a handler failed; the message says which).

An `error` that answers a request carries the request's `id` and `chat`
and is not stamped: refusals are replies, not history.

A bad frame after `hello` (unknown type, unknown field, not JSON) is
answered with an `error` and the connection stays open; only the first
frame is fatal.
