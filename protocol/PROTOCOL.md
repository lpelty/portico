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
First frame on every connection. `protocol: 1`, `app_version: string`;
v0.10: `capabilities?: [string]`, what the app can show beyond the
messages every app reads: `agents.v1` (see Subagents and
workflows): without it the gateway sends none of those frames; v0.11:
`queue.v1` (see Messages while the agent works); v0.12: `viewer.v1`
(the app can carry out `viewer.act`; see The viewer and spaces) and
`spaces.v1` (it shows `spaces.list`); v0.14: `viewer.marks.v1` (it
can draw the agent's marks; see The viewer and spaces); v0.17:
`viewer.show.v1` (it answers `viewer.act` `show` once the page has
loaded; see The viewer and spaces); v0.18: `apps.v1` (it shows
`app.*` frames as cards; see [MCP Apps](#mcp-apps-v018)); v0.19:
`messages.attachments.v1` (it sends `attachments` apart from the text and
reads them in `user.text`) and `files.extra.v1` (it sends
`files.roots.set` and shows the added folders); v0.20: `files.edited.v1`
(it sends `files.edited` after each save in the viewer's editor); v0.21:
`tasks.v1` (it shows background commands and Monitors, `agent.started`
with `task`; see Subagents and workflows). Absent
(an older app) is the empty list. A gateway before v0.10 is strict about
fields and refuses a `hello` carrying `capabilities` with
`error code=protocol.invalid`; an app that may meet one sends it only to a
gateway it knows is v0.10 or later, or connects again without it after
that refusal.
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

v0.7: the first three go out **before** the gateway starts or resumes the
chat's engine (a chat restored after a restart, or one whose engine was
closed, starts it with its next send), so the person's message shows at
once. An engine that cannot start then ends the turn: `turn.finished
outcome=error`, `chat.state idle`, and the refusal (`error
code=engine.start_failed`, or `lifecycle.before_first_chat_failed` when the
deployment's preflight refuses). The engine start and the send run after
the echo, while the gateway goes on reading frames, so a refusal from
them (`engine.start_failed`, `lifecycle.before_first_chat_failed`,
`engine.send_failed`) arrives later than the echo, still carrying the
`message.send`'s `id`. A `turn.stop` that arrives while the engine starts
ends the turn `stopped` without sending it; a `chat.stop` or `chat.remove`
then ends or removes it, and an engine that fails to start afterwards
adds nothing. A turn that never reached the engine is not a reply: it
leaves `last_reply` and `unlogged` as they were. A slash command
that only the engine might know is still checked against a started engine
first (below), so its echo waits for the engine.

v0.3: a message whose first word is a slash command (`/word`, or
`/plugin:word`; a path like `/Users/...` is not one) that nobody knows —
not Portico (`/new`, and `/log` from v0.4), not the deployment (`hello.commands`, or the first
word of an action's text), not the engine — is **not** sent to the agent.
It is an empty turn: `turn.started`, `user.text`, `chat.notice` ("No
command /word here"), `turn.finished outcome=done`, `chat.state idle`
(never `working`); the gateway logs it. The engine's commands are what it
lists when it starts (its initialize answer, and the `slash_commands` of
its `init` message), so a chat without a running engine has it started
first, exactly as the send would. An engine that cannot say what it knows
gets the message as typed.

A send while a turn is running (state `working` or `waiting on you`) is
refused with `error code=chat.busy` — v0.11: unless both sides list
`queue.v1`, when it is queued instead (see Messages while the agent works). Every attachment must be an absolute
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

v0.19 (`messages.attachments.v1` in the gateway's `hello.capabilities`): an
attachment that is a png, jpeg, gif or webp (by its bytes, not its name) of
at most 3,000,000 bytes also goes to the engine as a base64 `image` content
block after the text; its path stays in the block above. One message carries
at most 4 images and 12,000,000 bytes of their base64. An image that goes as
a path only gets a `chat.notice` of `kind: "attachment.not_image"` in the
turn: "<name> is too large to show the agent as an image; it can still open
the file.", "<name> can't be read as an image; it can still open the file.",
or, past the message's caps, "<name> is past what one message can show the
agent as images; it can still open the file." Other files are paths only, and
a slash command's attachments are paths only (the command goes as a string).

### `turn.stop` — `TurnStop`
`chat`. Interrupts the running turn; it finishes with `outcome: stopped`
(the engine's own finish is reported as `stopped`; if none arrives within
the gateway's grace period, 15 seconds, the gateway ends the turn itself
and closes that engine, since one that ignored an interrupt is in no known
state; the next send then starts a fresh engine on the same session, as
after `chat.stop`) and the chat returns to `idle`. When the engine did
finish in time it stays up for the next send. A stop when nothing is
running does nothing and answers nothing. v0.11: messages queued for the
chat come back to the app (`chat.queue` with `returned`; see Messages
while the agent works), running or not.

### `card.answer` — `CardAnswer`
`chat`, `id` (the card's id), `answer: object`, `scope: once | chat | always | absent`,
`note: string | absent`. A permission answer is
`{"decision": "allow" | "deny"}` with `scope`; a question answer is
`{"answers": {<question text>: <label> | [labels]}}` (a label list for a
`multi_select` question; a question the person skipped is left out). A
question card may instead be declined (v0.16) with
`{"declined": "skipped" | "dismissed" | "replied"}`: every question
skipped, the card's ×, or a reply sent from the composer while the card
was up. The engine's question tool is then denied with, in turn, "The
person skipped the question.", "The person dismissed the question.", or
"The person replied in the conversation instead." For `replied` the app
sends the reply as an ordinary `message.send` first; it is queued
(`queue.v1`) and written into the turn right after the question's
`tool.finished`, so the agent reads the decline and then the reply. An
`answers` map with nothing in it is treated as `skipped`. Any
other `declined` value is `card.invalid_answer`. *Plug-in and engine
authors:* `EngineCallbacks.on_question` now receives the question tool's
`tool_use_id` (`on_question(questions, tool_use_id="")`), so an owner with the
old one-argument signature must add the parameter. An unknown, already-answered, or cancelled id is
refused with `error code=card.stale` and nothing else happens; an answer
whose shape does not fit the card's kind is refused with
`error code=card.invalid_answer` and the card stays open. An accepted
answer is recorded in the chat's history as `card.answered`. The answer
resolves the engine's request: `allow` with scope `once` (or no scope)
allows this use; scope `chat` also allows it for the rest of this chat,
so later requests it covers answer without a card (kept on the chat
record: it lasts as long as the session). It never covers more than the
person could read from the card, and the card's `scope_note` says what
it covers: for a file edit (`Write`, `Edit`, `MultiEdit`, `NotebookEdit`)
inside the session's folder, edits to files in that folder (symlinks
followed); outside it, that one file only; for a tool that runs a
command, the engine's suggested rule for that command (a prefix such as
`git status:*`, matched as whole words, every part of a compound command
on its own) or, when the engine suggests none, that exact command — so
allowing `ls` for the chat never allows `rm -rf /`. A part with a
background `&`, a `$(…)` or `${…}` substitution, backticks or a `<`/`>`
redirection is never covered by a prefix (the card asks); a `cd` alongside
covered parts is covered only as `cd <literal path>` into the session's
folder; for any other tool, the tool.
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

### `files.roots.set` — `FilesRootsSet`
v0.19 (`files.extra.v1` in the gateway's `hello.capabilities`): `paths:
[string]` (absolute; `~` is expanded), `id` to correlate. The folders the
person added to the Files pane; each send replaces the last list, and they
belong to the connection: they are gone when it closes, so the app sends
the list again on every connect. Reply: `files.roots`, or `error` with
`files.invalid_root` (a relative path; nothing is changed).

### `files.edited` — `FilesEdited`
v0.20 (`files.edited.v1` in the gateway's `hello.capabilities`): `chat`,
`path: string` (absolute; a relative one is taken from the chat's folder).
The person saved that file in the viewer's editor. No reply. The gateway
keeps the paths per chat, in the order first saved, each once, and tells the
agent with the person's next message: the engine receives

```
(Edited in the viewer since your last message: a.md, b.md)

<text>

Attached files:
- /abs/path
```

that is, the note, a blank line, the typed text, then the attachment block
(the apps' kept context, v0.18, still goes before all of it). A path inside
the chat's folder is named relative to it, any other absolute. The note goes
to the engine only: `user.text` stays what the person typed. A queued message
written into the running turn gets the note too. Either way the list is
cleared once the note is made. A slash command gets no note and leaves the
list for the next message. A path with a control character, a parenthesis or more than 1024
characters is dropped without a reply; paths are normalised, and the list
holds the 20 most recent. If the message never reaches the engine the paths
stay for the next one. The list lives in the gateway's memory (gone at
restart) and for an unknown `chat` the answer is `error` `chat.unknown`.

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
first `message.send`.

v0.7: the renewal is recorded in both conversations as `chat.notice`
lines. In the ending session, at once (before any log turn): "New —
logging, then ending this session" when the log step runs, else "New —
ending this session"; once it has ended, "Session ended · continues in
Session M". (v0.17: the next session no longer gets a "Continues Session N"
line; the divider already says it.) All are sent before `session.renewed`. A refused renewal writes none. Errors: `chat.unknown`, `chat.busy` (a turn or another
renew is running), `session.ended` (already ended), `thread.renew` (v0.16:
`chat` is a thread, which closes instead). v0.16: open threads stay open,
and the ending session's pending thread proposals become `dismissed`. While a renew runs,
`message.send` to that session is `chat.busy` (v0.11: queued, for an app
with `queue.v1`; one still held when the session ends goes to the next
session); `turn.stop` stops the log turn; `card.answer` answers its cards.

A log step that finishes `done` also sets the ending session's
`logged_at` (v0.4).

### `session.log` — `SessionLog` *(v0.4)*
`chat`, `id`. Runs the deployment's log step in the **live** session
without ending it — the same step `session.renew` runs with `log: true`:
a plug-in's `on_renew` (its `ctx.ending` is `false`), else `log_prompt`
sent as an ordinary turn (`turn.started`, `user.text`, its events, any
cards, `turn.finished`). When it finishes `done` the session's
`logged_at` is set to now and `unlogged` clears; a log step that errors
or is stopped still answers, with `logged_at` where it was. The session
is not ended, its engine stays up, and `logged` (the renewal's verdict)
is untouched. Answered with `chat.state` (carrying `unlogged`), then
`session.logged` (with the `id`), then `chat.list`. v0.7: recorded in the
conversation as `chat.notice` lines — "Log session — running the log step"
at once (before the log turn), and after it, before `session.logged`,
"Session logged" or "The log step didn't finish; the session isn't
logged". A refused `session.log` writes none. Errors: `chat.unknown`, `session.ended` (the session has
ended), `session.cannot_log` (the deployment has no log step:
`hello.can_log` is false), `chat.busy` (a turn, a renewal or another log
is running). While a log runs, `message.send`, `session.renew` and
`session.log` to that session are `chat.busy` (v0.11: `message.send` is
queued for an app with `queue.v1`, and can go into the log turn itself); `turn.stop` stops the log
turn; `card.answer` answers its cards. The app turns a typed `/log` into
this request; should `/log` arrive as message text, the gateway treats it
as a known command (like `/new`) and passes it to the engine as typed.

A plug-in's `on_renew` is the deployment's whole log step, and the
gateway (never the plug-in) ends a session, so the same hook serves both
requests. `RenewContext.ending` tells it which: `true` for a renewal (the
session ends afterwards), `false` for `session.log` (it carries on), so
its message to the agent can say so. Plug-ins written before v0.4 run
unchanged; they simply do not look at `ending`.

### `service.restart` — `ServiceRestart` *(v0.4)*
`service` (a service `id` from `services.status`), `id`. Runs that
service's `restart` command (with `/bin/sh -c`, in its own process
group, killed after `command_timeout_seconds`), then checks the service
again. The answer is the `services.status` frames that follow: the
service goes to `checking` (detail `restarting`) while the command runs,
then to what the check finds. A restart command that fails or times out
is logged; the re-check says how the service is, and (v0.8) after that
status an `error` with code `services.restart_failed`, the request's
`id` and the reason follows. Errors:
`service.unknown` (no service with that id), `service.no_restart` (the
service has no `restart` command: `can_restart` is false), v0.8:
`services.busy` (a `services.restart_all` is running: try again once its
`services.status` came).

v0.8: with a deployment status (see Services), the service is read
again through that status after its restart command, not through a check.

### `services.restart_all` — `ServicesRestartAll` *(v0.8)*
`id`. Only when `hello.capabilities` has `services.restart_all`. Runs the
deployment's one restart for all its services (a plug-in's
`restart_services`, else config `[deployment] restart`, with
`/bin/sh -c`, killed after `command_timeout_seconds`), then reads every
service again. No `services.status` goes out between the request and the
end of the command (neither the periodic checks nor a `service.restart`):
the next `services.status` is the answer, sent once the services were
read again, changed or not. A restart that fails (a non-zero exit, a
timeout, a hook that raises or returns `false`) is answered by that
`services.status` and then `error code=services.restart_failed` with the
request's `id` and the reason. Errors before anything runs:
`services.no_restart_all` (the deployment has no restart for all its
services), `services.busy` (one is already running). An app that never
sends it is unaffected.

### `sessions.clear` — `SessionsClear` *(v0.11)*
Since 0.12 the reference app no longer sends it (the admin command
`portico-gateway sessions clear` does the same on a stopped gateway; see
Command line), and the message stays for compatibility.
`id`. Only when `hello.capabilities` has `sessions.clear` (the reference
gateway lists it in single presentation). The gateway forgets every ended
session, keeping the live one, and answers with `chat.list`. Only the
gateway's list is cleared: the engine's transcripts on disk stay, and the
numbers are never handed out again (`chat.list.next_chat` does not go
back). In multiple presentation it is refused with
`error code=sessions.not_single`. An app that never sends it is
unaffected.

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
`protocol: 1`, `gateway_version`, `epoch`, `brand {name, agent_name, accent?, icon?, header_image?, version?, about?}`
(`name` goes in the title bar and the About panel, `agent_name` is how
the app refers to the agent, `accent` is a CSS hex colour — `#RRGGBB`,
`#RGB` or `#RRGGBBAA` — for the app's controls, `icon` an absolute path
to an image file for the Dock, the About panel, the sidebar header and
the mark beside the start screen's greeting, `header_image` (v0.7) an
absolute path to an image the toolbar shows in place of the mark and the
name, 28 points tall with its own proportions (an older app ignores it),
`version` (v0.20.1) the deployment's version, which the About panel shows
in place of the app's own (macOS adds "Version" before it only when it
looks like a number), and `about` (v0.20.1) the About panel's text
under it, in which the app fills in `{app_version}` and `{built}` (an
older app ignores both);
absent or unreadable values fall back to the app bundle's own name (else "Portico") and the system
defaults), `actions: [{label, text}]`, `roots: [{name, path, extra?, missing?}]` (`path`
absolute, as configured with any `~` expanded; v0.19: `extra` and `missing`
are `false` in `hello` (the deployment's own roots) and are meaningful in
`files.roots`, where an added folder is `extra: true` and a path that is not a
directory is `missing: true`), `commands: [string]`
(Portico's own commands the deployment offers, without the `/`; empty in
v0.1–v0.3; v0.4: `["log"]` when the deployment can log, i.e. `can_log`),
`capabilities: [string]` (v0.1: `cards.form`,
`files`, `producer`; v0.8: `services.restart_all` when the deployment can
restart all its services at once, so the app offers Restart all
services; v0.10: `agents.v1` when the gateway sends subagent and workflow
frames to an app that lists the same in its own `hello`; v0.11:
`sessions.clear` in single presentation, so the app offers Clear earlier
sessions…; v0.11: `queue.v1` when it queues a send made during a turn for
an app that lists the same; v0.12: `spaces.v1` always (v0.14: with no
`[spaces] folder` the folder is `<state dir>/spaces`), and `spaces.refresh` as well when `[spaces] refresh` is, so the app
offers Refresh on a space; v0.15: `models.v1` always, for the model menu,
see [Models](#models-v015); v0.16: `threads.v1` in single presentation with
`[threads] max` above 0, see [Threads](#threads-v016); v0.18: `mcp.v1`
always, see [MCP servers](#mcp-servers-v018), `plugins.v1` always, see
[Plugins](#plugins-v018), and `apps.v1` when `[apps] enabled` (the
default), see [MCP Apps](#mcp-apps-v018); v0.19: `messages.attachments.v1`
always, so the app may send `attachments` on `message.send` and reads them in
`user.text`, and `files.extra.v1` always, so the app may send
`files.roots.set`; v0.20: `files.edited.v1` always, so the app may send
`files.edited`). Always followed by `chat.list`, so the app has the
sidebar before anything else arrives, and then (v0.4) `services.status`,
(v0.11) any kept `chat.commands` and (v0.15) a kept `models` per live session.

v0.2 added `presentation: single | multiple` and `can_log`. v0.3:
`presentation` defaults to `single`; `config_stale: bool` (the config file
changed after the gateway started, so a restart is needed to apply it);
`can_update: bool` (the deployment configured an update command, which
`portico-gateway update` runs); `default_folder?` (config `default_folder`,
`~` expanded: where a new session works when the person has not chosen a
folder; after the folder the person last used, before the first root);
`permission_mode?` (config `permission_mode`: the mode a new session
starts in — the start screen shows it, and a new session the person did
not pick a mode for runs in it).

v0.12: `viewer_defaults?: {agent_can_see: bool, agent_checks_html: bool,
act_hosts: [string]}` (config `[viewer]`): the deployment's defaults for
the app's two viewer switches, used until the person changes one, and the
outside sites the agent may click and type on (host names; each matches
that host and its subdomains; empty by default, so every outside site is
look and scroll only). `act_hosts` is the deployment's alone: no
`viewer.settings` field changes it. Local pages (`file://`, `localhost`,
`127.0.0.1`, `::1`) are always usable. Absent from an older gateway: the
app then uses `true` for both switches and an empty list.

v0.17: `viewer_defaults.properties?: "folded" | "open"` (config
`[viewer] properties`, default `"folded"`): how a front-matter Properties
block first opens, until the person folds or unfolds one (the app then
remembers the person's choice). Absent from an older gateway: `"folded"`.

v0.16: `threads_max?: int` (config `[threads] max`, 1 or 2): how many
threads may be open beside Main, sent with `threads.v1` and absent
otherwise. The app's proposal card asks to close a thread at this limit;
an app that gets none (an older v0.16 gateway) assumes 2.

v0.11: `hide_session_folder: bool` (default `false`; config `[files]
hide_session_folder`): the app's Files pane leaves out the chat's own
folder (the `chat` root) when the deployment has roots of its own to show.
The `chat` root still resolves for `files.list` and paths in it still show.

v0.19: `lock_folder: bool` (default `false`; config `[sessions] lock_folder`):
the deployment fixes "Works in". The app shows the folder with a lock, offers
no picker, and ignores a folder saved earlier; sessions start in
`default_folder`, else the first root.

v0.19: `link_sites: {host suffix: name}` (default `{}`; config `[links] sites`):
the name a link chip shows for a site, added to the app's built-in names
(Slack, Google Docs, Sheets and Slides, GitHub, Figma, Notion); a deployment's
entry wins. The app matches the URL's host by suffix.

### `chat.list` — `ChatList`
`chats: [ChatSummary]`, each `{chat, folder, alias?, state, created}`
plus the session facts (v0.2: `title?`, `ended?`, `logged?`, `parent?`,
`compactions`, `context_percent?`; v0.3: `mode?`; v0.4: `logged_at?`,
`unlogged`; v0.6: `last_reply?`). Sent after `hello` and after every
change to the set of chats or their aliases (`chat.new`, `chat.alias`, `chat.remove`,
`session.renew`, `session.log`), and (v0.8) when a session's generated
title arrives. State changes alone travel as
`chat.state`. Not chat-scoped: no `seq`, not replayed in `chat.history`.

`next_chat?` *(v0.11)* is the number the next new session will have, so
the app's welcome can name it ("Session 17") before it exists: the
gateway's own counter, or (reference gateway) the number its `[sessions]
next_number` command gave when the gateway started with no live session,
when that is not below the counter. The session's real number is the one
`chat.state` and `chat.list` report once it exists. Absent from an older
gateway.

`ChatSummary.logged_at?` *(v0.4)* is when the session was last logged
(UTC, ISO 8601): a `session.log`, or a renewal's log step, that finished
`done`. `ChatSummary.unlogged` *(v0.4, default `false`)* is computed by the
gateway: `true` when the deployment can log (`hello.can_log`) **and** a
turn finished after `logged_at` — or, never logged, at least one turn
finished. A turn counts however it finished (done, stopped, error),
including a log turn that did not finish `done`; an unknown command's
empty turn does not (nothing reached the agent), nor (v0.7) a turn
whose engine could not start or that was stopped before its send. The app asks "log
first?" before New only when `unlogged` is true. Both are kept on the
chat record, so they survive a gateway restart; a session recorded before
v0.4 counts as unlogged when the engine had named it (it has had a turn)
and it was not logged by a renewal.

`ChatSummary.last_reply?` *(v0.6)* is when a turn last finished in the
session (UTC, ISO 8601), however it finished; absent before the first.
v0.7: a turn that never reached the engine (its engine could not start,
or a stop came first) does not move it.
Kept on the chat record, so it survives a gateway restart — unlike the
`ts` of events replayed from a transcript, which is the time of the
replay. The app's welcome says "last reply 12 min ago" from it.

`ChatSummary.title?` *(v0.2; generated in v0.8)* is the first line of the
session's first message (cut to 60 characters). v0.8: with config
`titles = "generated"` (the default), once the session's first turn
finishes `done` the gateway asks a small model for a title of at most six
words and, when one comes back within twenty seconds, replaces the first
line with it and sends `chat.list`. No new field or frame: an older app
simply shows the better title. Only a `message.send`'s first turn counts
(never a log step's turn, nor an unknown command's empty turn); a session
with an alias is not titled, an alias given meanwhile is kept, a
generated title is never replaced, and a session restored from the index
keeps the title it had. A failed or slow call leaves the first line.

### `chat.state` — `ChatState`
`chat`, `seq`, `state`: exactly `idle`, `working`, `waiting on you`, `stopped`;
`mode?` (v0.3): the session's permission mode, sent when the chat opens
and whenever it changes.
`unlogged?` *(v0.4)*: the session's `ChatSummary.unlogged` as of this
state. The gateway sets it on **every** `chat.state` it sends (always
present from a v0.4 gateway; absent from an older one), so the app learns
of unlogged work the moment a turn finishes: the turn's `chat.state idle`
already carries `unlogged: true`. After `session.log` the gateway sends
one more `chat.state` (the current word) with `unlogged` as the log step
left it, before `session.logged`: `false` when it finished `done`, `true`
when it errored or was stopped (the log turn itself counts as work).
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
v0.10: ring events include the subagent and workflow frames and the rows
with `agent_id`, for an app that declared `agents.v1`; for any other app
they are left out of the replay as they were left out live (its `seq`
numbers then skip; nothing else changes). A transcript replay carries
none of them: after a gateway restart a past fan-out shows as its
`Agent` tool rows only.

### `chat.live` — `ChatLive`
`chat`, `id` (echoing `chat.open`), `seq` (the chat's current sequence
number, not a new one). History is complete; what follows is live.

### `turn.started` — `TurnStarted`
`chat`, `seq`, `turn: integer` (counts from 1 per gateway launch). Always
followed by `user.text` and then `chat.state working` (v0.7: before the
engine starts, when it has to; see `message.send`) — except a turn
nobody sent.

*A turn nobody sent (v0.10).* The engine can speak on its own between
turns, typically when background work it started (a workflow, a
background subagent) finishes and it answers with what came of it. The
gateway gives that output a turn of its own: `turn.started` with the
chat's next `turn`, **no `user.text`**, `chat.state working`, then the
turn's events, its artifacts and `turn.finished`, then `chat.state idle`,
as for any turn. An app draws such a turn without a bubble (a transcript
replay already produces turns that begin with the agent's own output).
While it runs, `message.send` is refused with `chat.busy` as during any
turn, and `turn.stop` / `chat.stop` end it as any turn. A send echoed just
before the engine began speaking keeps its turn: what the engine says
joins it.

### `user.text` — `UserText`
`chat`, `turn`, `text`, `seq` when live. What the person sent to start
`turn`, as the engine receives it (attachments appear in the exact
`message.send` form). Sent live right after `turn.started`, stamped and
kept in the ring, so a replay from the ring shows the person's side of
the conversation; a transcript replay (`chat.history` after a gateway
restart or past the ring) carries it too, without `seq`. The app renders
the one `user.text` per turn as the bubble and does not add a second from
the `message.send` it sent. v0.11: a queued message written into a
running turn is a further `user.text` in that turn, at the point it went
(see Messages while the agent works); a transcript replay shows it as the
start of a turn of its own. v0.18: `via?: string` — the message came from an
MCP app's page (`app.message`); it is the app's server title, and the app
shows "via <title>" under the bubble. Absent for what the person typed, and
in a transcript replay. An older app ignores it. v0.19
(`messages.attachments.v1`): `attachments: [string]` (default empty), the
attached files' paths, and `text` is what the person typed, without the
"Attached files:" block, live and in a transcript replay (which recovers the
paths from the block's trailing form). Only to an app whose `hello` declared
`messages.attachments.v1`: any other app, and any older gateway, has the block
inside `text` and no `attachments`.

### `text.delta` — `TextDelta`
`chat`, `seq`, `turn`, `text`. A fragment of the agent's reply, in order;
the app appends.

### `tool.started` — `ToolStarted`
`chat`, `seq`, `turn`, `tool_use_id`, `tool`, `summary`, `input: object`. *(Task 4)*
v0.10: `agent_id?` — set when a subagent made the call (the `id` of its
`agent.started`), so the row belongs in that agent's steps, not in the
conversation. Rows with `agent_id` go only to an app that declared
`agents.v1`; their `turn` is the agent's.

### `tool.finished` — `ToolFinished`
`chat`, `seq`, `turn`, `tool_use_id`, `ok: bool`, `summary`; `agent_id?` (v0.10, as on
`tool.started`);
`permission?` and `note?` (v0.3): what happened to this use's permission,
drawn on the tool row — `once` (allowed once), `session` (allowed for this
session, by this answer or an earlier one), `auto` (auto mode allowed it;
only for tools that would otherwise ask), `declined` (with the person's
`note`), `blocked` (auto mode's classifier refused it). Absent when
nothing was decided (a read in `default` mode).
`answers?` (v0.16): on an answered `AskUserQuestion` row, what the person
chose, `{<question text>: <label> | [labels]}` as in the question card's
`card.answer` (skipped questions left out). Absent on any other row and
on a declined question, whose row has `ok: false` and the decline's
message as its `summary`. The gateway records each question's outcome by
`tool_use_id` on the chat record (the transcript's tool input holds only
the questions), so a row replayed from the transcript after a restart
carries its `answers` too; a session from before v0.16 has none.

How the reference gateway decides, by the session's mode when the tool
started: `blocked` when the tool started in `auto` mode, no person's
answer or allow was recorded for it, and the tool result is an error
saying it was denied by the engine's auto mode classifier; else the
answer to this use's card (`once`, `session`, `declined` with the note; a
card cancelled by a stop or by nobody being there is `declined` with the
reason as the note); else `session` when an earlier allow for this
session covered it (no card); else `auto` when the session's mode was
`auto` when the tool started and the tool is not a read-only one (Read, Glob, Grep, LS,
TodoWrite, ToolSearch, Task and the like get nothing). Outcomes are kept
on the chat record by `tool_use_id`, so rows replayed from the transcript
after a gateway restart carry them too. An allow for this session is
kept on the chat record as well (it survives a gateway restart; a new
session starts with none); what it covers is in `card.answer` and the
card's `scope_note`.

### `turn.finished` — `TurnFinished`
`chat`, `seq`, `turn`, `outcome: done | stopped | error`. Exactly one per
turn: `done` when the engine finished, `stopped` after `turn.stop` or
`chat.stop`, `error` when the engine reported a failure or refused the
message. Always followed by `chat.state` (`idle`, or `stopped` after
`chat.stop`).

### `card.ask` — `CardAsk`
`chat`, `seq`, `id`, `kind: permission | question | form`, `title`, and one of
`permission {tool, summary, input}`,
`questions: [{question, header, options: [{label, description, preview?}], multi_select}]`,
`form: [{key, label, kind: text | choice | toggle, options?}]`.
A `permission` card's `title` is a plain question about the step (v0.3:
`Save changes to Q3-synthesis.md?`, `Run git status?`, else `Use <tool>?`;
the app shows `permission.tool` beside it as a tag), its `tool_use_id`
(v0.3) names the tool row the card belongs to, `scope_note?` (v0.3) is
one line saying what "Allow for this session" would cover (the app shows
it under the buttons; without it, something general), `summary` is the one-line
summary also shown on the tool row (a path, the first line of a command),
and `input` is the tool's full input. A `question` card maps the engine's
question tool field for field (`multiSelect` → `multi_select`) and its
`title` is the first question's `header`; its `tool_use_id` (v0.16) names
the question tool's row. An option's `preview?` (v0.16) is the option's
preview string as the engine sent it, Markdown (the app renders it as
Markdown, never HTML); a non-string preview is dropped. The engine does
not offer previews to an SDK agent unless asked, so most cards have none. `form` is defined for a
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
`chat`, `seq`, `artifact {id, kind: file | url, location, media, title, source, open, space?}`.
`media` is one of `markdown`, `image`, `html`, `pdf`, `text`, `url`, `other`
(by file extension: `.md .markdown`, `.png .jpg .jpeg .gif .webp .svg`,
`.html .htm`, `.pdf`; a URL is `url`; anything else `other`).
`text` is plain text and code: `.txt .log .csv .tsv`, `.json .jsonl .yaml
.yml .toml .ini .cfg .conf .xml .plist`, `.py .js .mjs .cjs .jsx .ts .tsx
.swift .rb .go .rs .java .kt .c .h .cpp .hpp .m .cs .php .pl .lua .r`,
`.sh .bash .zsh .fish .css .scss .sql .diff .patch` (since 0.5; before it,
only `.txt`, and the rest were `other`). The app draws `text` monospaced,
and a `.csv` or `.tsv` that parses as a table as a table. There is no
separate media word for code or tables, so an older app still decodes
every artifact. `text` never auto-opens.
`source` says where the gateway found it: `tool` (a file-writing tool —
`Write`, `Edit`, `MultiEdit`, `NotebookEdit` — named the path), `text`
(the agent's text printed a `http://localhost` / `http://127.0.0.1`
address, or named a viewable file that exists when the turn ends), or
`producer` (the HTTP endpoint). `title` is the file name or the URL
unless a producer gave one. A file is reported wherever it lives — a
scratch directory outside the chat's folder is listed like any other (and,
since 0.11, never opens; see below).

Every artifact goes in the history. `open` is true on the artifact the
app should show now: the turn's artifacts are sent together just before
`turn.finished` (including a `stopped` finish), one per location, and
only the newest *viewable* one — `markdown`, `image`, `html`, `pdf`,
`url` — carries `open: true`; `text` and `other` are listed and never
auto-open, so scaffolding a project does not flap the viewer. A producer
artifact is sent at once with `open: true`. Artifacts are kept with the
chat in the index, so a later launch still lists them.

Since 0.10 (gateway behaviour; no new frame or field): a file the turn's
text only names, unchanged since the turn began (an earlier file the reply
mentions), is listed with `open: false` and never takes `open` from what
the turn made. The agent can also show a file during the turn: its
`show_in_viewer` tool, or a plain `open <path>` in its shell that the
gateway catches, sends the file at once as `artifact.created` with
`source: tool` and `open: true` — only a viewable file inside the chat's
folder or a configured root (v0.17: or, through `show_in_viewer` only, an
`http://` or `https://` address, sent as `kind: url`; one with no host
name, such as `https://` alone, is refused "Not shown: '<address>' is not
a web address."; a caught `open` of an address still runs as before). Such a file is not reported again at the end
of the turn. A relative path given to `show_in_viewer` is the chat
folder's; a relative path in a caught `open` is the shell's working
directory's (the Bash tool's directory persists between calls, so after
`cd build`, `open report.html` is `build/report.html`); a gateway that
cannot learn that directory catches only absolute paths. A file a
background subagent writes while no turn is running is reported when the
write finishes, as a turn would report that one file (`open: true` when
it is viewable). The app shows the newest artifact that opens (or that the
person picks) over the one it remembered from the last quit.

Since 0.11 (gateway behaviour; no new frame or field): a file the turn
wrote or named takes `open: true` only when it is inside the chat's folder
or a configured root, the rule `show_in_viewer` keeps. A file outside them
is listed with `open: false`, and the newest viewable file inside them
opens instead. URLs and producer artifacts are unchanged.

Since 0.12: `artifact.space?` (a string) is the id of the space the file
is, when it is a file in the spaces folder (see The viewer and spaces);
the app switches to that space. Absent otherwise.

### `files.list` — `FilesList`
`root`, `path` (normalised relative path, `""` for the root itself),
`entries: [{name, dir, size?}]`, `id` and `chat` echoing the request.
Entries: directories first, then files, each group in case-insensitive
name order; names starting with `.` are skipped; `size` is bytes for a
file and absent for a directory. A direct reply, not a history event: no
`seq`.

### `files.roots` — `FilesRoots`
v0.19: `roots: [{name, path, extra, missing}]`, `id` echoing the request: the
deployment's `hello.roots` first, then the added folders in the order sent.
An added folder is `extra: true`; its name is the folder's last path
component, with " 2", " 3" and so on after a clash with any other root
(or `chat`). A path that is not a directory is still listed, `missing:
true`, and `files.list` on it is `error files.not_found`. A direct reply,
not a history event: no `seq`.

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
e.g. `Claude Opus 5.5 (work)`; the app shows it instead of the id). After a turn ends, how full the
session's context window is. Not stamped (a reading, not history); the
last value is the chat's `context_percent` in `chat.list`. Absent when the
engine cannot say.

### `chat.compacted` — `ChatCompacted`
`chat`, `trigger: "auto" | "manual"`, `seq`. The engine is summarizing
earlier conversation to make room. Stamped and replayed with the history;
counted in the chat's `compactions`.

### `chat.notice` — `ChatNotice` *(v0.3)*
`chat`, `seq`, `text`, v0.19 `kind?: string` (`attachment.not_image`; absent
for a plain line). A quiet line from the gateway in the conversation,
e.g. `No command /foo here` for a slash command that neither the
deployment nor the engine knows (the message is not sent to the agent).
v0.7: also the session commands' lines (`session.log`, `session.renew`).
No clock in the text. Stamped and replayed with the history. A chat
replayed from the engine's transcript (one restored after a gateway
restart) gets the notices of the current gateway run put back in, after
the turn each followed and without `seq`; only notices from before the
restart are lost.

### `config.stale` — `ConfigStale` *(v0.3)*
No fields. The config file is newer than when the gateway started; the
app says "restart the gateway to apply". Sent once when the gateway
notices; `hello.config_stale` carries the same fact on connect.

### `update.available` — `UpdateAvailable` *(v0.3)*
`version`. The deployment's update check (config `update.check`) found a
newer version. The app offers the update; `portico-gateway update` runs
it (config `update.run`).

### `session.logged` — `SessionLogged` *(v0.4)*
`id` (the `session.log`'s), `chat: ChatSummary` — the session as it is
after its log step (`logged_at`, `unlogged`; `ended` absent). Note that
`chat` here is the summary, not a number. Not stamped. Followed by
`chat.list`.

### `services.status` — `ServicesStatus` *(v0.4)*
`services: [Service]`, each `{id, name, state: "up" | "down" | "stuck" |
"checking", detail?, since?, can_restart}`: `detail` one line for the
menu, `since` when the current state began (UTC, ISO 8601),
`can_restart` whether the service has a `restart` command (default
`false`). Down services first, then stuck ones, then the rest in config order. Sent right
after `hello` and `chat.list` on every connection (an empty list when the
deployment lists no services: the app draws its own Gateway row either
way), and broadcast whenever any service's state or detail changes. Not
chat-scoped: no `seq`.

`checking` is a service's state from gateway start until its first check
answers, and while a `service.restart` runs. `up` carries the service's
`up_detail`, or no detail. `down` carries `not responding since H:MM`
(local time, 24-hour) plus ` · <the check's last non-empty output line>`
when it printed one (cut to 80 characters), or ` · check timed out after
N s` when it printed nothing and was killed. An outage's `since` and
`H:MM` are when the service was first seen down: a restart that does not
bring it back keeps them.

v0.17: `stuck` is a service that is running but not working. A check that
exits 75 (`EX_TEMPFAIL`) is `stuck`; its `detail` is the check's first non-empty output
line (cut to 240 characters), or none when it printed nothing. A stuck
service is not an outage: no `not responding since`, and it neither starts
nor ends one. `stuck` goes only to an app whose `hello` lists
`services.stuck.v1` in its `capabilities`; any other app is sent that
service as `down`, detail kept, because its decoder refuses a state it
does not know. The app offers Restart on a row only when it is `down` or
`stuck` and `can_restart`.

v0.8: with a deployment status (see Services) the rows are the status's,
in its order (down first): `up` with the row's `detail`, or `down` with
`not responding since H:MM` plus ` · <detail>`; v0.17: or `stuck`, with
the row's `detail` as given. A status that cannot be
read is one `down` row, id `status`, name `Services status`, detail
`status command failed · <reason>` (`status plug-in failed · ...` for a
plug-in's). Rows appear with the first reading; there are no `checking`
rows before it. `can_restart` is true for a row whose id matches a
`[[services]]` entry with a `restart`.

### `chat.commands` — `ChatCommands` *(v0.11)*
`chat?`, `folder`, `commands: [{name, description, source?}]`. The
agent's slash commands and skills in `folder`, for the composer's slash
list: `name` without the `/` (`standup`, `acme:review`), `description`
one line (default empty), `source` where the engine says the command
comes from (`user`, `project`, a plug-in's name), when it says.

Sent with `chat` after that chat's engine starts, when the engine can
list its commands; an engine that cannot sends nothing, and a failure to
read them is logged, never fatal. The gateway keeps the last list per
folder (`commands.json` in the state directory, the newest 20 folders),
and on every connection sends, after `services.status`, the kept list for
the default folder and for each live session's folder, without `chat`, so
the welcome has one before any engine of this launch has started. Not
stamped (a reading, not history). An older app ignores it.

Reference gateway: the list is the SDK's `get_server_info()["commands"]`
(`{name, description, argumentHint}`). The description's trailing source
in parentheses ("... (user)") becomes `source`; the rest keeps its first
line and first sentence, at most 160 characters (cut with `…`); the app
truncates further to fit a row. Repeated names keep the first.
`argumentHint` is not sent (argument completion is not in v0.11).

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
directory), `chat.busy`, `chat.not_queued` (v0.11: `chat.unqueue` for a
message that has gone to the agent, or was never queued), `attachment.missing`, `engine.start_failed`
(the engine could not start in the folder), `engine.send_failed` (the
engine refused the message; the turn is finished with `outcome: error`),
`card.stale`, `card.invalid_answer`, `files.unknown_root`, `files.outside_root`,
`files.not_found`, `files.invalid_root` (v0.19: `files.roots.set` with a path that is not absolute, or a `~user` that does not exist), `files.search_failed` (Spotlight failed or timed out),
`session.ended` (`session.renew`, `session.log` or `message.send` on a
session that has ended), `session.cannot_log` (v0.4: `session.log` and the
deployment has no log step), `service.unknown` (v0.4: `service.restart`
names no configured service), `service.no_restart` (v0.4: the service has
no `restart` command), `services.no_restart_all`, `services.busy`,
`services.restart_failed` (v0.8: `services.restart_all`; see there;
`services.busy` also answers a `service.restart` sent while a restart of
all services runs),
`session.live` (`chat.new` in single presentation while a session
is live; renew it instead),
`lifecycle.before_first_chat_failed` (the deployment's preflight failed or timed out; the message
carries its last line and no chat was created),
`space.not_configured`, `space.not_found`, `space.invalid`,
`space.no_refresh`, `space.refresh_failed`, `space.rename_failed`,
`space.remove_failed` (v0.12: see The viewer and spaces),
`threads.off`, `thread.proposal_unknown`, `thread.proposal_resolved`,
`thread.limit`, `thread.not_open`, `thread.renew` (v0.16: `session.renew`
on a thread: "a thread closes rather than renews; close it with
thread.close"; see Threads),
`gateway.error` (a handler failed; the message says which).

An `error` that answers a request carries the request's `id` and `chat`
and is not stamped: refusals are replies, not history.

A bad frame after `hello` (unknown type, unknown field, not JSON) is
answered with an `error` and the connection stays open; only the first
frame is fatal.

## Messages while the agent works *(v0.11)*

A person can type while the agent works, as in a terminal. When the
gateway's `hello` and the app's both list `queue.v1`, a `message.send`
that arrives while a turn or a log step runs is held instead of refused:

- The gateway answers `chat.queued` (the request's `id`, which names the
  message from now on; the gateway makes one up when the request had
  none) and sends `chat.queue` with the chat's list. Attachments are
  checked at once (`attachment.missing`), as for any send.
- At the main agent's next tool result (`tool.finished` without
  `agent_id`: a subagent's step does not count) the gateway writes the
  held messages, oldest first, into the running turn. Each becomes a
  `user.text` in **that turn**, stamped, right after a `chat.queue`
  without it; the engine reads it at its next step and answers within the
  same turn. A message that starts with a slash command is never written
  mid-turn: it, and everything queued behind it, waits for the turn's end.
- One still held when the turn ends (`done` or `error`) is sent
  as the next turn — `turn.started`, `user.text`, … as for a
  `message.send` — one message at a time, in order; the rest wait for
  that turn's next step or its end. During a log step they wait for the
  step to finish; held through a renewal, they go in the session that
  follows.
- `chat.unqueue {chat, id}` takes one back; answered with `chat.queue`,
  or `error code=chat.not_queued` when it has gone already. An edit is an
  unqueue and a new send (which queues at the end).
- `turn.stop` hands back everything held, at once: one `chat.queue`
  with no `items` and the messages, oldest first, as `returned`. The app
  puts them back in the composer (text and attachments), to send again
  or delete, as a terminal agent does on interrupt. A message queued
  after the stop, while the stopped turn winds down, is never written
  into that turn; when it ends (`turn.finished outcome=stopped`) it comes
  back the same way. Nothing held goes on its own after a stop. With no
  app attached at that moment the frame, and the messages, are dropped.
- `chat.stop` and `chat.remove` drop the queue (`chat.queue` with no
  items after a stop). The queue lives in the gateway's memory: stopping
  the gateway drops it.
- `chat.open` sends `chat.queue` after `chat.live` (an empty list too), so
  a reconnecting app shows exactly what is still waiting.

Without `queue.v1` on both sides nothing changes: a send during a turn is
`chat.busy`, and the gateway sends neither frame below.

### `chat.unqueue` — `ChatUnqueue` *(app → gateway)*
`chat`, `id` (as `chat.queued` named it).

### `chat.queued` — `ChatQueued`
`chat`, `id`. The answer to a `message.send` that was queued. Not stamped.

### `chat.queue` — `ChatQueue`
`chat`, `items: [{id, text, attachments}]`, oldest first: what the chat
holds for the agent, after every change. Not stamped and not in the ring:
each one replaces the list the app had. `returned?: [{id, text,
attachments}]`, oldest first: messages a `turn.stop` took out of the
queue, for the composer (absent otherwise).

## Models *(v0.15)*

The model in the status strip is a menu that switches the model the way
`/model` does in a terminal. When the gateway's `hello` and the app's both
list `models.v1`:

- **The list is the engine's own.** When an engine starts, the Claude Code
  CLI behind the Agent SDK answers its initialize request with `models`:
  the same list `/model` shows (on a hosted provider, built from the deployment's
  own settings). The gateway passes each entry's `value`, `displayName`,
  `description` and `resolvedModel` on as `{value, display_name,
  description, resolved_model?}`; no Portico config chooses them. The last
  list is kept in the gateway's `index.json`, so an app hears it before any
  engine of this launch starts.
- **Read at gateway start** (amended 11-02). When the gateway starts
  serving it asks the CLI for the list once, in the background: it
  connects with the same options an engine uses (in the deployment's
  `default_folder`, else the home folder), reads the server info and
  disconnects, sending no message, with the deployment's hooks off
  (`disableAllHooks`, so no `SessionStart`/`SessionEnd` hook fires for a
  session nobody opened; engines keep their hooks). A new list is kept and each live
  session hears `models`. A failure, or no answer within 30 s, is logged
  and the kept list stands; `hello` never waits for it.
- **The choice persists.** `model.set` switches the running engine at once
  (the SDK's `set_model`) and is kept in the index: every later engine
  starts on it, whether the session's engine restarts, a new session
  begins, or the gateway restarts. `"default"` or `null` goes back to the
  deployment's default. A choice made before the engine has started is
  the engine's starting model. A `chat.notice` records each switch:
  "Model: Sonnet", the choice's `display_name` ("Model: Default
  (recommended)" for the default).
- **Not while a reply runs.** `model.set` during a turn or a log step is
  refused with `error code=chat.busy` and the message "Change the model
  after this reply": switching mid-turn would leave it unclear which model
  answered. A `value` not in the kept list is `error code=model.unknown`,
  "That model isn't offered here." (With no list kept yet any value is
  taken and the next start checks it.) An ended session is
  `session.ended`.
- **A model the deployment no longer offers** (a stored choice missing from
  a newly read list) is dropped when the engine starts: the engine goes
  to the default, the choice is cleared, and a notice says "Model: Default
  (Opus is no longer offered here)", naming the model as the earlier list
  did (its `value` when that never had it).

Without `models.v1` on both sides the gateway sends no `models` frame, and
the strip stays plain text (`context.usage`'s `model_name`).

### `model.set` — `ModelSet` *(app → gateway)*
`chat`, `value: string | null` (a `models` choice's `value`; `"default"`
or `null`: the deployment's default), `id`. Answered with `models`
carrying the `id` and the new `current`, or with `error` as above.

### `models` — `Models`
`chat`, `current?: string` (the model this session runs on (see below);
absent: the default), `choices: [{value, display_name, description,
resolved_model?}]`, in the engine's order. `resolved_model` (11-02,
additive: an older app ignores it) is the model id the entry runs, so the
app can name the model Default resolves to. Sent after `hello` for each live session (when a list is
kept), after the start-up read, after each engine start, after a renewal for the session that
follows, and after a switch. Not stamped and not in the ring: each one
replaces what the app had. The choice is the gateway's, but `current` is
the model that session runs on: its running engine's, else the stored
choice it will start on. A switch never changes another session's running
engine, so with several sessions open their `current` can differ until
that engine restarts.

## MCP servers *(v0.18)*

Settings' MCP servers tab lists every server the agent could have and lets
the person manage them, with the same reach as Claude Code. When `hello`
lists `mcp.v1` the app may send the `mcp.*` requests below (an older app
never sends them). Each is answered with `mcp.servers` carrying the
request's `id`, or with `error` carrying the `id`.

- **Settings' folder** is the deployment's `default_folder`, else the home
  folder. Settings lists, turns off and adds local servers for it.
- **Where rows come from.** Four sources, as Claude Code reads them:
  `group: "user"` (top-level `mcpServers` in `~/.claude.json`, or
  `$CLAUDE_CONFIG_DIR/.claude.json`), `"local"` (that file's
  `projects["<folder>"].mcpServers`), `"shipped"` (the folder's
  `.mcp.json`), and `"core"` (the gateway's own `portico` server, plus the
  `.mcp.json` servers `[mcp] core` names). A claude.ai connector a live
  engine reports (scope `claudeai` or config type `claudeai-proxy`) that no
  source has is `"account"`; servers a plugin provides (`plugin:…`) are
  not listed: they belong to the plugins. Rows come in
  that group order: core, user, local, shipped, account. Group titles and
  brand words are the app's; rows carry data only.
- **Status** comes from the most recently started live engine on Settings'
  folder (`live: true`). With none, every row but `portico` reads "Starts
  with your next chat" and has no tools (`tool_count` absent).
- **A change applies to new chats.** Turning off and on, adding, removing,
  and signing in and out are written at once and take effect at the next
  engine start; the gateway never restarts an engine for them. Only
  `mcp.reconnect` (and a finished sign-in) reconnects the server in the live
  engines on Settings' folder.
- **Turning off** writes `projects["<folder>"].disabledMcpServers` in
  `~/.claude.json` (the key Claude Code's own toggle writes), keeping every
  other key, their order and the file's mode. A file that doesn't parse is
  never rewritten: the change is refused. Built-in servers can't be turned
  off.
- **Add, remove, sign in, sign out** run the bundled Claude Code CLI
  (`claude mcp add|remove|login|logout`) in Settings' folder, in the
  background: other requests are answered meanwhile, and the reply comes
  when the command ends. A failure is `error code=mcp.failed` whose message
  is the command's last stderr line. Web addresses in any message or
  status line reach the app without their query strings.
  Only user and local servers can be removed.
- **Tool policy.** Each tool's `policy` is the person's choice, else
  `allow` for a tool annotated `readOnly` and `ask` for the rest. Choices
  are kept in `<state>/mcp_tools.json`, keyed on the tool's full name as
  Claude Code names it (`{"mcp__<server>__<tool>": "allow" | "ask"}`, the
  server name with every character outside `[A-Za-z0-9_-]` turned into `_`,
  as the CLI does), only where they differ from the default. A tool set to
  `allow` runs without a permission card when the agent calls it by that
  exact name. Removing a server forgets its tools' choices. Built-in
  servers' tools can't be changed.
- `/mcp` and `/plugin` are the app's: it opens Settings. An older app that
  sends them as `message.send` gets an empty turn with the `chat.notice`
  "Open Settings to manage MCP servers and plugins."; nothing reaches the
  agent.

### `mcp.list` — `McpList` *(app → gateway)*
`id`. The servers as they stand.

### `mcp.toggle` — `McpToggle` *(app → gateway)*
`name`, `enabled: bool`, `id`. Refused for a built-in server: "Built-in
servers can't be turned off".

### `mcp.reconnect` — `McpReconnect` *(app → gateway)*
`name`, `id`. Reconnects the server in every live engine on Settings'
folder.

### `mcp.remove` — `McpRemove` *(app → gateway)*
`name`, `id`. `claude mcp remove <name> --scope user|local`. Refused for
shipped, built-in and account servers. The app asks first.

### `mcp.add` — `McpAdd` *(app → gateway)*
`name` (letters, numbers, `-` and `_`; otherwise "Use letters, numbers, -
and _ only"), `transport: "http" | "stdio"`, `url?` (http), `command?`
(stdio: the whole command line, split shell-style), `where: "user" |
"local"`, `id`. A name any group already has is refused with "There's
already a server called <name>". After an http add, when a live engine
on Settings' folder reports the server `needs-auth` once reconnected, the
gateway starts its sign-in (the browser opens) and the row reads
`signing_in`.

### `mcp.sign_in` — `McpSignIn` *(app → gateway)*
`name`, `id`. Answered at once, the row reading `signing_in` ("Signing in…
finish in your browser"); `claude mcp login` runs in the background (up to
300 s). When it ends the gateway reconnects the server in the live engines
on Settings' folder (on success) and sends a fresh `mcp.servers` with no
`id`; a failure also sends `error code=mcp.failed` with no `id`.

### `mcp.sign_out` — `McpSignOut` *(app → gateway)*
`name`, `id`. `claude mcp logout <name>`.

### `mcp.tool_policy` — `McpToolPolicy` *(app → gateway)*
`server`, `tool`, `policy: "allow" | "ask" | null` (`null`: back to the
default), `id`.

### `mcp.servers` — `McpServers`
`servers: [McpServerRow]`, `live: bool`; `id` when it answers a request.
Not stamped and not in the ring. `McpServerRow` is `{name, title (the
server's own `serverInfo.title`, else `name`), group, transport: "stdio" |
"http" | "sse" | "sdk" | "other", status: "connected" | "needs_auth" |
"failed" | "pending" | "off" | "signing_in" | "unknown", detail,
tool_count?, tools: [{name, description, read_only, policy}], account?,
can_toggle, can_remove, can_sign_out}`. `detail` is the status line:

| status | `detail` |
|---|---|
| `connected` | "Connected · N tools" (`portico`: "Connected · the viewer, files and screen · N tools") |
| `needs_auth` | "Needs you to sign in" |
| `failed` | "Couldn't start: <error, cut to 120>" or "Couldn't start: it stopped as soon as it opened" |
| `pending` | "Connecting…" |
| `off` | "Off"; a shipped server: "Off for you · it stays off through updates" |
| `signing_in` | "Signing in… finish in your browser" |
| `unknown` | "Starts with your next chat" |

`account` is set only when the status carries one; it is never invented.
`can_sign_out` is true when it is set, or for a connected http/sse server.

## Plugins *(v0.18)*

Settings' Plugins tab lists the plugins installed for the agent and what
the marketplaces offer, and manages them with the same reach as Claude
Code. When `hello` lists `plugins.v1` the app may send the `plugins.*`
requests below (an older app never sends them). `plugin` is the plugin's
id as Claude Code prints it (`name@marketplace`); `id` stays the request's
id. The list and every change are answered with `plugins.state` carrying
the request's `id`; `plugins.details` and `plugins.options` have their own
replies; a refusal or failure is `error` carrying the `id`
(`plugins.invalid`, `plugins.unknown`, `plugins.refused`, `plugins.failed`).

- **Every request runs the bundled Claude Code CLI** (`claude plugin …`)
  in Settings' folder (as for [MCP servers](#mcp-servers-v018)), in the
  background: other requests are answered meanwhile. A failure's message
  is the command's last stderr line, cut to 240 characters, web addresses
  without their query strings.
- **Installed** is `claude plugin list --json`, one row per id. An entry
  scoped `local` or `project` to another folder is left out; of several
  entries for one id, the one that governs Settings' folder is shown
  (local, then project, then user, then any other).
- **What the marketplaces offer** is `claude plugin list --json
  --available`, read once and kept 5 minutes (adding or updating a
  marketplace drops it). An installed row's `description`, `marketplace`
  and `update_to` come from its entry there, joined by id.
- **Changes** (turn on and off, install, uninstall, update, add or update a
  marketplace, configure) take effect at the next engine start; the
  gateway never restarts an engine for them. They are serialised with
  every other change to Claude Code's settings (the MCP servers' too): one
  runs at a time, and a request waits for the one before it.
- **A plugin that installs by running a command** (its `--json` result
  carries `shownCommand`) is refused: "This plugin runs a command to
  install. Install it in Claude Code, where you can read the command
  first." The gateway never accepts such a command for the person.
- **A sensitive option's value never reaches the app.**

### `plugins.list` — `PluginsList` *(app → gateway)*
`available: bool` (default false), `id`. With `available: true` the reply
carries `available` (Browse); otherwise it is absent.

### `plugins.set_enabled` — `PluginsSetEnabled` *(app → gateway)*
`plugin`, `enabled: bool`, `id`. `claude plugin enable|disable <id> --scope
<the row's scope>`. Refused for a plugin whose scope is not user, project
or local (one from the person's Claude account).

### `plugins.install` — `PluginsInstall` *(app → gateway)*
`plugin`, `id`. `claude plugin install <id> --json`.

### `plugins.uninstall` — `PluginsUninstall` *(app → gateway)*
`plugin`, `id`. `claude plugin uninstall <id> --scope <the row's scope>`.
The app asks first.

### `plugins.update` — `PluginsUpdate` *(app → gateway)*
`plugin`, `id`. `claude plugin update <id> --scope <the row's scope>
--json` (refused like an install when it would run a command).

### `plugins.marketplace_add` — `PluginsMarketplaceAdd` *(app → gateway)*
`source` (a GitHub `owner/repo`, a git address or a folder), `id`.
`claude plugin marketplace add <source>`.

### `plugins.marketplace_update` — `PluginsMarketplaceUpdate` *(app → gateway)*
`name`, `id`. `claude plugin marketplace update <name>` (Check for updates).

### `plugins.details` — `PluginsDetailsRequest` *(app → gateway)*
`plugin`, `id`. Answered with `plugins.details`.

### `plugins.options` — `PluginsOptionsRequest` *(app → gateway)*
`plugin`, `id`. `claude plugin configure <id> --json`; answered with
`plugins.options` (empty `options`: nothing to configure, so the app
offers no Configure…).

### `plugins.configure` — `PluginsConfigure` *(app → gateway)*
`plugin`, `values: {key: string}` (only the changed ones, each on one
line), `id`. Piped as JSON to `claude plugin configure <id>
--values-stdin`; options left out keep their values. Answered with a fresh
`plugins.options`.

### `plugins.state` — `PluginsState`
`installed: [PluginRow]` (sorted by name), `available: [AvailablePlugin]`
(only for `plugins.list` with `available: true`), `marketplaces:
[PluginMarketplace]`; `id`. Not stamped and not in the ring.

- `PluginRow` is `{id, name, version, scope, enabled, description,
  marketplace, update_to?}`. `update_to` is the marketplace's version when
  it differs from the installed `version` (the app's **Update to <v>**).
- `AvailablePlugin` is `{id, name, description, marketplace, version?,
  installed}`.
- `PluginMarketplace` is `{name, source_label?, plugin_count, checked}`.
  `source_label` is `github.com/<repo>` for a GitHub marketplace, else its
  address or folder, and absent for the official `claude-plugins-official`.
  `plugin_count` counts its plugins in the available list. `checked` is
  "today", "yesterday" or a date like "Oct 24": the newest change in its
  checkout, in the gateway's local time ("" when unknown).

### `plugins.details` — `PluginsDetails`
`plugin`, `text` (`claude plugin details <id>`: its skills, commands,
servers and projected token cost), `id`.

### `plugins.options` — `PluginsOptions`
`plugin`, `options: [PluginOption]`, `id`. `PluginOption` is `{key, title
(the option's title, else its key), description, sensitive, set, value?}`.
A sensitive option's `value` is always absent; `set` says whether it has
one.

## MCP Apps *(v0.18)*

An MCP server's tool can name a page (`_meta.ui.resourceUri`, a `ui://`
address; the MCP Apps extension, stable spec 2026-01-26). When the agent
calls such a tool, an app that declared `apps.v1` shows the page in a card
in place of the tool row, gives it the call's input and then its result,
and relays what the page asks for. Every other app keeps the plain tool row.

- **Capabilities.** The gateway lists `apps.v1` in `hello` when `[apps]
  enabled` (the default); it then starts every engine with
  `CLAUDE_CODE_MCP_APPS_HOST=1`, so the CLI tells MCP servers it can show
  their pages. The app lists `apps.v1` too; only then is it sent `app.*`
  frames, live or in a `chat.history`.
- **When apps are on.** For an engine whose CLI reports
  `mcp_call_result_not_for_model_v1`. The first page read that fails on an
  engine (after up to 10 s of retries while the server is still connecting)
  turns apps off for that engine, logged once: "MCP Apps are off for chat
  N: <error>". Its app tools stay plain tool rows.
- **Which tools.** After each engine start and each Reconnect, the gateway
  reads the engine's MCP status: per tool, its `_meta.ui.resourceUri` (or
  the deprecated `_meta["ui/resourceUri"]`), `_meta.ui.visibility`
  (default `["model", "app"]`) and `annotations.readOnly`. Servers Portico
  runs itself never have apps.
- **Order on the wire.** `tool.started` → `app.open` (once the page is read)
  → `tool.finished` → `app.result`, or `app.cancelled` when the call ended
  with no result. While a page is read the chat's later events wait, in
  order, so `app.open` is never after its `tool.finished`. An `app.open`
  that fails sends nothing more. `app.*` frames carry no `seq` and are not
  kept in the ring.
- **Saved cards.** The gateway keeps each card's record (the server, tool,
  page address, input, result, `csp`, `permissions`, `prefers_border`,
  server title; never the HTML) under `<state>/apps/<session>/<tool_use_id>.json`,
  readable only by the person. A result over 4 MiB of JSON keeps `content`
  and drops `structured_content`. `chat.history`, from the ring or a
  transcript, brings each card back right after its `tool.finished` as
  `app.open` with no `html` (the card is frozen; **Reload** shows it
  again), then `app.result` (or `app.cancelled`).
- **The page's sandbox is the app's** (spec §2.3.5): one web view per card
  with a non-persistent data store and nothing shared with Portico's other
  web views; its own origin, `mcpapp-<server>://app/index.html`; the CSP
  from `csp` sent as a response header, else the strict default (no
  network: `default-src 'none'; script-src 'self' 'unsafe-inline';
  style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self'
  data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri
  'self'`); no navigation of its own (links go through `ui/open-link` to the
  viewer); camera and microphone refused. The host side of the page's
  JSON-RPC is the app's own code. The page's HTML is third-party content:
  it is never rendered anywhere else.

### `app.open` — `AppOpen`
`chat`, `tool_use_id` (the agent's call), `server` (the configured name),
`server_title` (its `serverInfo.title`, else the name), `tool` (the bare
tool name), `resource_uri`, `html?` (absent in a replay), `csp?`,
`permissions?`, `prefers_border?` (the resource's `_meta.ui` members, as
the server gave them), `input` (the call's input). `id` when it answers
`app.reload`.

### `app.result` — `AppResult`
`chat`, `tool_use_id`, `content` (the result's content blocks),
`structured_content?` (absent when the server sent none or it was over the
cap), `is_error`. `id` when it answers `app.reload`.

### `app.cancelled` — `AppCancelled`
`chat`, `tool_use_id`. The call ended (stopped, or an error) with no result.

### `app.call_tool` — `AppCallTool` *(app → gateway)*
`chat`, `tool_use_id` (the card), `tool`, `arguments`, `id`. The page's
`tools/call`. A bare `tool` means the card's own server
(`mcp__<server>__<tool>`). The gateway checks, in this order, and never
takes the page's word for any of it (the CLI's call skips its own
permission checks):

1. the card exists — else "Unknown app";
2. the tool is on the card's server — else "That tool is on another server";
3. its visibility includes `"app"` — else "That tool isn't offered to apps";
4. consent. A tool marked read-only runs without asking unless the person
   set it to "Asks first" in Settings; any other asks with the agent's own
   permission card (`card.ask kind=permission`, `permission.tool` the full
   tool name, title and `permission.summary` "The <server_title> app wants
   to run <tool>", `scope_note` "<the tool's description> · from the card
   above"), unless the person set it to "Runs without asking" or allowed
   it for this session. Allow for this session is the same allow as the
   agent's own calls to that tool. Deny (or a card cancelled) is "Denied".

Then the tool runs with its result kept from the model. Every call from a
page is logged.

### `app.call_result` — `AppCallResult`
`tool_use_id`, `ok`, `content`, `structured_content?`, `is_error`, `error?`;
the request's `id`. `ok: false` carries `error` (one of the refusals above,
or why the call failed).

### `app.message` — `AppMessage` *(app → gateway)*
`chat`, `tool_use_id`, `text`, `id`. The page's `ui/message`: sent exactly
as a typed `message.send` (queued during a turn for an app with
`queue.v1`), its `user.text` carrying `via: "<server_title>"`. Text whose
first non-space character is `/` is refused with `error
code=app.refused` "Apps can't run commands" (the CLI would run it as a
command); an unknown card is `error code=app.unknown` "Unknown app".

### `app.context` — `AppContext` *(app → gateway)*
`chat`, `tool_use_id`, `text`. The page's `ui/update-model-context`. The
latest per card is kept (cut to 16 000 characters). Before the person's
next message (one that is not a slash command), each kept block goes first
in what the engine receives, as `<app-context
server="<server>">\n<text>\n</app-context>\n\n`, and is cleared; the
`user.text` shows only the message. The first update from each card
between two messages adds the `chat.notice` "<server_title> updated the
context". Not answered.

### `app.reload` — `AppReload` *(app → gateway)*
`chat`, `tool_use_id`, `id`. Reads the page again (starting the chat's
engine first when none is running, as a send would) and answers `app.open`
with the `html`, then `app.result` from the record, both with the `id`. A
failure is `error code=app.reload_failed` "Couldn't reload: <reason>" with
the `id`.

## Threads *(v0.16)*

A thread is another conversation with the same agent, in the same folder,
opened from Main and kept beside it. Main's agent proposes one; the person
starts it. Threads are for single presentation only.

**Main** is the newest chat that has not ended and has no `thread`.
Everywhere the gateway looks up the live session it means Main: the
`chat.new` refusal (`session.live` names Main), `/v1/status`'s `session`,
the welcome's number preview (asked when no Main is live, even with a
thread open) and following `default_folder` (Main moves; a thread is
never ended or followed as the live session). This holds whatever the
capability says: a gateway turned to `max = 0` never makes a thread the
live session. An app finds Main the same way.

When the gateway's `hello` and the app's both list `threads.v1`:

- **The capability.** The gateway lists `threads.v1` in single presentation
  when `[threads] max` is above 0 (0 to 2, default 2; anything else fails
  to load naming `threads.max`). With `max = 0` there is no tool and no
  thread UI. `hello.threads_max` carries the limit, so the app's card
  asks to close a thread at the right count.
- **A thread is a chat** with `ChatSummary.thread` set. It takes the next
  session number as every chat does, has its own transcript and log, and
  survives a gateway restart in `index.json`. A closed thread's slot is
  used again; its number is not. Its engine starts in Main's folder, with
  the deployment's system prompt and model, Main's permission mode at the
  time it starts, and the line "This is Thread N, opened from the person's
  main conversation for the brief below. Work on it here; the person
  answers here." after the deployment's prompt. A thread never renews
  (`session.renew` on it is `thread.renew`); it closes. Its "Allow for
  this session" covers that thread only, and with threads on the card's
  scope note says "For this conversation: …", ending "until you start a
  new session" in Main and "until you close this thread" in a thread.
- **Proposals are stored** in the gateway's index until started,
  dismissed, or Main's session ends (then `dismissed`), and survive a
  restart; the newest 100 are kept. Removing a chat drops its proposals.
- **Main's New leaves threads open.** They don't depend on Main's
  session. Main's pending proposals become `dismissed` when its session
  ends (New, or `default_folder` moving it), each sent as `thread.proposal`.
- **When Main moves** (`default_folder` changed at gateway start), its
  open threads are closed as `thread.close` closes them, log steps
  included. **With `max = 0`** open threads are closed the same way. Both
  run from a task once the gateway is listening, so start-up is not held;
  a thread whose close cannot start stays open.
- An older app ignores `thread` and sees threads as chats, and is never
  sent `thread.proposal`. An older gateway has no `threads.v1`, so the app
  shows no thread UI.

### The `open_thread` tool (what Main's agent sees)
With threads on, Main's engine (never a thread's) gets an in-process tool,
`mcp__portico__open_thread`, allowed outright (no card in any mode), and
this line after the deployment's prompt: "When the person wants work done
separately, alongside this conversation, call open_thread with a brief of
one or two sentences and any files it should start with. It proposes a
thread; the person decides whether to start it, and you won't see what it
does." Its description: "Propose a thread: another conversation with the
person, alongside this one, for work they want done separately. Give a
brief of one or two sentences and the files it should start with. Returns
at once; the person starts it or not."

Input `{brief: string, files?: [string]}`; a relative path is Main's
folder's. It stores the proposal (with the call's `tool_use_id`), sends
`thread.proposal` (`pending`), and returns at once: "Proposed as Thread 1;
it opens if the person starts it." (the slot it would take now), or, with
every slot taken, "Proposed; two threads are open, so the person picks one
to close before it starts." ("a thread is open" with `max = 1`) Refusals (`is_error`, nothing stored): "Not
proposed: give a brief of one or two sentences." and "Not proposed: <path>
isn't a file." The agent never hears whether the person started it.

### Closing a thread
`thread.close`, and `thread.start` with `close`, run the same routine, as
New ends a session without opening one:

1. A running turn is stopped (as `turn.stop`) and its end waited for.
2. A `chat.notice` "Close — logging, then closing this thread" (or "Close —
   closing this thread" with no log step).
3. The deployment's log step (`log_prompt`, or the plug-in's `on_renew`
   with `ending` true) runs in the thread as an ordinary turn. A log step
   that **cannot start** (its turn's engine cannot start or refuses the
   message, through a plug-in too) leaves the thread open: "The log step
   didn't finish; the session isn't logged" in the thread and the error
   answers the request. One that runs but doesn't finish `done` still
   closes, `logged: false`.
4. The engine is closed; anything still queued goes back to the app
   (`chat.queue` with `returned`); the thread gets `ended`, `chat.state
   stopped` (with the request's `id`), "Thread closed" in its
   conversation, then `chat.list`. Its slot is free again.

`thread.close` with `log: false` skips step 3: the thread ends `logged:
false` (no log step configured: `logged` absent). It is the app's "Close
without logging", the way out when a close fails because its log step
cannot start. A close that fails leaves the thread open, and a message
queued meanwhile goes as its next turn. While a close runs, sends to the
thread are `chat.busy` (or queued), and a close is refused with
`chat.busy` while a `session.log` runs in the thread (`thread.close`, and
`thread.start`'s `close`).

The plug-in rule in step 3 is the close's own: for `session.renew` and
`session.log`, a plug-in whose `send` is refused still ends the step with
its own verdict (renews unlogged), as before v0.16.

### `ChatSummary.thread`
`{label, slot, parent, brief, files, opened_at}`: `label` "Thread 1" or
"Thread 2"; `slot` 1 or 2, the key that switches to it (⌃1, ⌃2); `parent`
the Main session it was opened from; `brief` what it is for; `files` the
paths it started with; `opened_at` when it started (UTC, ISO 8601).
Absent on Main and every chat that is not a thread.

### `thread.proposal` — `ThreadProposal`
`chat` (Main's), `proposal` (the proposal's id), `tool_use_id?` (the
`open_thread` tool row the card is drawn in place of), `brief`, `files`,
`state: pending | started | dismissed`, `thread?` (the chat it started,
once `started`). A state frame like `chat.queue`: not stamped and not in
the ring, sent on every change and after `chat.live` on every `chat.open`.
Only to an app with `threads.v1`.

### `thread.start` — `ThreadStart` *(app → gateway)*
`chat` (Main's), `proposal`, `close?` (an open thread to close first, at
the limit), `id`. Starting a thread never changes which chat is Main, and
does not ask the app to switch to it. Answered with `chat.state idle` for
the new thread (with the `id`), `chat.list`, then `thread.proposal`
(`started`, `thread` set). The thread takes the lowest free slot and the
next session number; its first message is the brief with the files
attached (the `Attached files:` block), sent as a `message.send` would be.
The request is answered once: a brief that cannot go after that (a file
removed since the proposal) is a `chat.notice` in the thread, "The brief
wasn't sent: <why>", and the thread stays open, empty. At the limit with
`close`, that thread is closed first (see Closing a thread); if the close
fails nothing starts and the proposal stays `pending`. If Main's session
ended meanwhile (New during the close), nothing starts and the answer is
`thread.proposal_resolved`. Below the limit `close` is ignored. Errors: `threads.off`
(threads are off: multiple presentation or `max = 0`),
`thread.proposal_unknown` (no such proposal in that chat),
`thread.proposal_resolved` (already started or dismissed, or a start of it
is in flight: a second Start makes no second thread), `thread.limit` ("two
threads are open; close one to start another", or with `max = 1` "a thread
is open; close it to start another": at the limit with no `close`), `thread.not_open` (`close` names no open thread).

### `thread.dismiss` — `ThreadDismiss` *(app → gateway)*
`chat` (Main's), `proposal`, `id`. "Not now": the proposal becomes
`dismissed`, so its record reads "Not started" after a restart too.
Answered with `thread.proposal` (`dismissed`, with the `id`). Errors:
`thread.proposal_unknown`, `thread.proposal_resolved`.

### `thread.close` — `ThreadClose` *(app → gateway)*
`chat` (the thread), `log: bool` (default `true`), `id`. Runs the
thread's log step (unless `log` is false), then ends it into History (see
Closing a thread). Answered with `chat.state stopped` (with
the `id`), then `chat.list`. Errors: `thread.not_open` (not a thread, ended,
or already closing), `chat.busy` (a `session.log` is running in it), and
the log step's own when it cannot start (`engine.start_failed`,
`engine.send_failed`).

## Subagents and workflows *(v0.10)*

When the agent hands work to subagents, or runs a workflow, the gateway
reports them with the frames below. They go only to an app whose `hello`
declared `agents.v1` (an older app's decoder skips an unknown frame but
refuses a whole `chat.history` that holds one, so nothing is sent that it
did not ask for). Each is chat-scoped, stamped with `seq`, kept in the
ring and replayed by `chat.history` like every other turn event.

### `agent.started` — `AgentStarted`
`chat`, `seq`, `turn`, `id` (names the agent in the frames that follow),
`tool_use_id` (the call that started it: the main conversation's `Agent`
row; a workflow's agents share the workflow's call), `description` (the
agent's task in a few words), `kind` (the agent type the engine names,
e.g. `general-purpose`, `Explore`; `agent` when it names none;
`workflow` for one of a workflow's agents), `workflow_id?` and `phase?`
(a workflow's agent: the workflow's `id`, and an index from 0 into its
`phases`, absent when the workflow reports no phases), `background?`
(`true` when the agent runs on after its turn finishes: background
subagents and every workflow agent).

*v0.21.* `task?: shell | monitor` marks background work that is not an
agent: a command run in the background (Bash `run_in_background`, or one
moved there while it ran) or a Monitor. `kind` repeats it, `background`
is `true`, `description` is the engine's, and `tool_use_id` is the Bash
or Monitor call, whose row stays the conversation's own. It ends like a
background agent, with `agent.finished` (the summary is the engine's
notification, e.g. the exit code); it has no steps. Sent only to an app
whose `hello` names `tasks.v1`; the engine's housekeeping tasks
(`ambient`, `skip_transcript`) are never sent. `run?` (2, 3, …) is a
resumed agent's new run (SendMessage to one that had finished): the same
`id`, working again in `turn`, with its earlier steps kept. A frame the
engine sends for an earlier run is dropped.

### `agent.progress` — `AgentProgress`
`chat`, `seq`, `id`, `step?` (what it is doing now, one short line: the
tool and its target from the agent's latest call, e.g. `Read
transcripts/p11.md`, `Bash grep -rn quote`, `Glob **/*.py`; before its
first call the engine's own words, e.g. `Reading alpha.md`), `steps`
(its tool calls so far), `elapsed` (seconds since it started, one
decimal). Sent on each of its calls and on each of the engine's progress
reports. Each one says all the one before it did, so the ring keeps only
an agent's latest `agent.progress`: a replay from the ring (from the
beginning or `since` a `seq`) carries the latest progress of each agent
and none of the earlier ones, whose `seq` numbers are skipped. A replaced
progress is not a loss and never makes a replay `truncated`.

### `agent.finished` — `AgentFinished`
`chat`, `seq`, `id`, `outcome: done | failed | stopped`, `summary?` (the
first line of what it reported, at most 120 characters). Exactly one per
agent, or per run of a resumed one (v0.21). A foreground agent still open when its own turn's engine result
arrives is ended then (`stopped`, or what the engine last said); another
turn's result ends none of it. A background agent can finish during a
later turn, or between turns.

*When the engine goes away (v0.10).* Closing a chat's engine —
`chat.stop`, a stop whose grace ran out, `session.renew`, `chat.remove`,
`gateway.stop` — or the engine's process dying ends its background work
with it: the gateway sends `agent.finished outcome=stopped` for every
agent still open and `workflow.finished outcome=stopped` for every
workflow (one already known to have ended keeps its outcome), before the
turn's `turn.finished` when a turn was running. An app still treats a
foreground agent open at its turn's `turn.finished` as stopped, and, as
a backstop for a gateway that sent no such finish, treats every agent
and workflow still open in a chat as stopped once that chat's
`chat.state` is `stopped` or its session ended (`session.renewed`).

### `workflow.started` — `WorkflowStarted`
`chat`, `seq`, `turn`, `id`, `name` (the workflow's own name, else its
description), `phases: [string]` (the phase titles in order). Sent when
the workflow starts — usually with `phases: []`, because the engine
reports them with its first progress — and sent again with the same `id`
whenever the phase list becomes known or changes: the app replaces what
it had.

### `workflow.phase` — `WorkflowPhase`
`chat`, `seq`, `id` (the workflow's), `index` (into `phases`), `state:
pending | running | done | failed`. Sent when a phase's state changes: it
is `running` while any of its agents runs, then `done`, or `failed`
when one of its agents failed; `pending` until its first agent starts.

### `workflow.finished` — `WorkflowFinished`
`chat`, `seq`, `id`, `outcome: done | failed | stopped`, `summary?` (the
first line of the engine's report on it, at most 120 characters).
Any of its agents still open are ended first (`done` when the workflow
completed, else `stopped`), then their phases' `workflow.phase`. A
workflow runs in the background: its turn usually finishes first, and
these frames follow during later turns or between them.

### Where it comes from (reference gateway)

From the Agent SDK's task messages. A task whose type is a subagent
(`local_agent`; `subagent` and `remote_agent` are taken the same way) is
an agent; its own tool calls are the messages whose `parent_tool_use_id`
is its call. A task whose type is a workflow (`local_workflow`,
`workflow`) is a workflow: `workflow_name` names it, and its progress
reports' `workflow_progress` lists the phases (`workflow_phase {index,
title}`) and the agents (`workflow_agent {index, label, phaseIndex,
state, lastToolName, lastToolSummary, toolCalls, durationMs,
resultPreview}`); a workflow agent's `id` is `<workflow id>.<index>`, and
its steps are only what those reports say (it sends no tool rows). A
task ends with `task_notification`, or for background work possibly only
with a `task_updated` whose status is terminal (`completed`, `failed`,
`stopped`, `killed`); either ends it once. A background subagent ends on
whichever comes first; a foreground subagent's and a workflow's terminal
`task_updated` waits for the notification, which carries the summary (a
workflow waits at most 5 seconds, and no longer than the next message
that is not a task's). A subagent's own subagent (`spawn_depth` above 1)
is not reported as an agent: its start is the parent's `Agent` step, and
its own calls are left out. Shell and monitor tasks are not shown.

## The viewer and spaces *(v0.12)*

Both halves are additive. An older app is sent none of it; an older
gateway never sends it.

### The agent's view of the viewer

The reference gateway gives the agent seven tools beside `show_in_viewer`
(in-process, allowed outright, no permission card in any mode):
`viewer_look` (a PNG of the viewer as shown, what is open, an outline of
the page with a ref such as `e12` on each line, and the page errors since
the last look), `viewer_click(target)`, `viewer_type(target, text,
submit?)`, `viewer_scroll(direction | target)`, `viewer_back()`, and (v0.14)
`viewer_mark(marks, replace?)` and `viewer_clear_marks()`. A
`target` is a ref from the last look, or the visible text of a button or
link (v0.17: for `viewer_mark`, any text the person can see on the
page). Each carries out its action in the app over the connection and
returns what happened. The tool texts are the reference gateway's and the
app's; the protocol carries only the frames below.

The engine names them `mcp__portico__viewer_look` and so on (the reference
gateway's server is `portico`). Since v0.13 the app folds two or more of
these steps in a row into one conversation row ("Used the viewer · N
steps"). It is the one place the app reads a tool's name, and only
Portico's own: a gateway that names the server differently gets plain rows.

#### `viewer.settings` — `ViewerSettings` *(app → gateway)*
`can_see: bool`, `check_html: bool`. The person's two switches (Agent can
see the viewer; Agent checks HTML it creates). Sent after `hello` and
whenever either changes; not chat-scoped. The app that most recently sent
it is the one `viewer.act` goes to. Until one does, the gateway uses
`hello.viewer_defaults`.

#### `viewer.act` — `ViewerAct` *(gateway → app)*
`id`, `chat`, `action: look | click | type | scroll | back | mark |
clear_marks | show` (`show` v0.17), `args` (`{}` for `look`, `back` and `clear_marks`;
`{target}` for `click`; `{target, text, submit}` for `type`;
`{direction}` or `{target}` for `scroll`; v0.14: `{marks: [{target,
note?}], replace: bool, tool_use_id?}` for `mark`, 1 to 9 marks, `note`
at most 60 characters, `tool_use_id` the agent's tool call that made
them). `mark` and `clear_marks` go only to an app that declared
`viewer.marks.v1`; the app answers both with the ordinary
`viewer.result`. Sent
only to an app that declared `viewer.v1`, and only when the person has not
turned the agent's view off. The app shows the viewer for `chat` if it is
not open. In multiple presentation an act for a chat that is not on
screen is answered "The person is looking at another chat." (by the
app, in its `viewer.result`).

v0.17: `show`, `{artifact, location}` — the id and location of the
artifact the gateway has just sent as `artifact.created` with `open:
true` (for a show of several files, the last one, the one in front). Sent
only to an app that declared `viewer.show.v1`, whatever the person's
"agent can see" switch (it reports only that a page loaded, never what is
on it), and it draws no acting glow. The app answers `viewer.result`
`ok: true` once that page has loaded; at once when it will not put the
artifact in front (auto-open off for that kind, the gateway did not mark
it to open, or another chat is on screen); and, for a pane that is not a
web page, once it is in front. A page that failed to load answers `ok:
false` with "Not loaded: <why>", which the agent reads as it is. A show of
the file already in front loads it again when the pane is on a failure
page or on a site a link went to. The gateway waits 10 s: no answer, the
app's own timeout answer (or `ok: false` with no text), or the app
leaving (or the send failing) mid-show, and the agent reads "Shown; still
loading."; loaded, "Shown in the viewer.".
An app without `viewer.show.v1` (or no app) is sent nothing and the agent
reads "Shown in the viewer." at once, as before v0.17.

v0.17 (gateway behaviour): a conversation's viewer calls run one at a
time, in the order the gateway receives them — the seven tools,
`show_in_viewer` and a caught `open`. Each starts only when the one before
has finished (answered, timed out, or refused), so a show followed by two
clicks and a look acts on the page the show loaded. A caught `open` waits
in the same queue as the viewer tools and `show_in_viewer`. When the turn
a call was made in is stopped while the call waits, it does not act and
answers "Stopped." (a call already sent finishes as before). Calls in
different conversations do not wait for each other.

#### `viewer.result` — `ViewerResult` *(app → gateway)*
`id` (the act's), `ok: bool`, `text`, `image?: {data, media_type}`
(`data` is base64, `media_type` is `image/png`, or `image/jpeg` when the
PNG would pass 3.5 MB; the longer side at most 1,600 px), `error?`. A result for an unknown id, or from an app other
than the one asked, is ignored.

The gateway waits 10 s for the result. It answers the agent in a plain
sentence, never a hang, when:

- no app is connected, or the app lacks `viewer.v1`: "The viewer isn't
  available right now (Portico isn't open).";
- the person turned the view off: "The person has turned off the agent's
  view of the viewer in Settings.";
- the app lacks `viewer.marks.v1` and the act is `mark` or
  `clear_marks`: "This Portico can't show marks yet; it needs updating.";
- `viewer_mark` is given no marks or more than nine: "Mark 1 to 9 things
  at a time." (the gateway answers; nothing is sent);
- the app does not answer in time: "The viewer didn't answer in 10 s.";
- the app disconnects while an act is pending: the same sentence as no app.

What the app puts in `text` and `ok: false` for a page it cannot act on
(nothing open, a stale ref "Not found — look again" — or, when the
person clicked, pressed a key or scrolled on the page since the agent's
last look, "The person used the page since your last look; look again.",
or, for a ref from a page that has reloaded or been replaced since that
look, "The page reloaded since your last look; look again." — an image or PDF
pane "can be looked at, not used", a page whose host is not allowed) is
the app's. v0.17, for `mark` (a mark target is a ref, a listed name or any
visible text on the page, the innermost element that holds it): a target
that is none of these is refused one sentence per target, a repeated
sentence said once. A ref gets "The page reloaded since your last look;
look again." when the page has reloaded or been replaced, else "The person
used the page since your last look; look again.", else "No element e12 on
this page; look again."; text gets "No visible text matches '<text>'"
(no period when it is the whole answer). When every target is refused the
answer is `ok: false`; when some are marked it is `ok: true`, "Marked 1 ·
Save, 2 · Cancel." followed by the refusal sentences. The show answers
the agent reads, `viewer.show.v1`: "Shown in the viewer." (loaded, or the
app will not put the file in front), "Not loaded: <why>" (the page failed),
"Shown; still loading." (10 s without a loaded answer) and "Stopped."
(the person pressed Stop while the call waited). For outside sites the app checks the page's *current* host at
every click and type against `viewer_defaults.act_hosts` (a redirect or a
link to another site is checked again), and always allows `file://`,
`localhost`, `127.0.0.1` and `::1`. Look and scroll work on any page.

When Agent checks HTML it creates is on (and the view is not off), a
`PostToolUse` hook on `Write`, `Edit` and `MultiEdit` tells the agent,
after it writes an `.html` or `.htm` file inside the chat's folder or a
root, to show the file in the viewer and look at it before replying. The
hook reads the setting each time. This is gateway behaviour; no frame.

### Spaces

A space is one Markdown or HTML file the agent keeps current, in the
folder configured as `[spaces] folder`, or, when that is not set (v0.14),
`spaces` in the state directory (created at start if missing). Its id is the file name without
the extension. Its title, icon and order come from front matter (`---`
lines at the top) or, for any file, a leading `<!-- key: value -->`
block: `title`, `icon` (an SF Symbol name; default `doc.text`), `order`
(an integer, optional). A file with broken or missing front matter, or
that is not UTF-8, is listed by its file name with the defaults. Files
whose names start with `.` or `_` are not spaces. Subfolders of the
spaces folder are ignored: nothing inside them is listed or watched.
(v0.14: a deployment can keep a space's scripts in a same-named
subfolder.) Portico schedules nothing: the deployment (or the agent)
rewrites the files.

The gateway looks at the folder every 5 s (modification times) and also
after any of the actions below. It sends `spaces.list` only to an app that
declared `spaces.v1`. The agent is told in its system prompt where the
folder is and passed it as an extra directory, so it can write there.

#### `spaces.list` — `SpacesList` *(gateway → app)*
`spaces: [{id, title, icon, order?, location, media, updated}]`.
`location` is the absolute path, `media` as for `artifact.created`
(`markdown` or `html`), `updated` the file's modification time (UTC, ISO
8601). The whole list every time. Sent after `services.status` on `hello`
and whenever a file is added, changed or removed.

#### `space.refresh`, `space.rename`, `space.remove` *(app → gateway)*
`space.refresh {id}`, `space.rename {id, title}`, `space.remove {id}`. On
these three, `id` is **the space's id**, not a request id, and it is the
`id` an `error` echoes. Each is answered by a new `spaces.list` (sent to
the attached app, if it declared `spaces.v1`) or by an `error`. Refresh
runs `[spaces] refresh`, rename writes the title into the file's front
matter, and remove moves the file to the Trash and then runs `[spaces]
remove`. The commands run with `/bin/sh -c`, a 30 s timeout, and
`$PORTICO_SPACE` set to the id; a failure answers `error` and is logged.
Refresh and remove run beside the app's other frames, not ahead of them.
Symbolic links in the folder are not spaces. A title that would go into
an HTML comment block cannot contain `--` (`space.invalid`).

Error codes: `space.not_configured` (no spaces folder; since v0.14 a gateway always has one), `space.not_found`,
`space.invalid` (rename with an empty title, or with `--` in a title kept
in a comment block), `space.no_refresh` (no refresh command),
`space.refresh_failed`, `space.rename_failed`,
`space.remove_failed` (its message says when the file is already in the
Trash).

#### The space's file as an artifact
`artifact.created.artifact.space?` carries the space's id when the file is
one, so the app opens it as that space.

## Services *(v0.4)*

Configuration notes for the reference gateway (not protocol messages).
A deployment lists the services it depends on in `config.toml`:

```toml
services_interval_seconds = 30   # default 30, at least 5

[[services]]
id = "memory"                    # required, unique, [a-z0-9-]+
name = "Memory (recall server)"      # required: what the menu says
check = "curl -sf http://localhost:8888/health"   # required: /bin/sh -c, exit 0 = up, 75 = stuck, other = down
restart = "launchctl kickstart -k gui/$UID/com.example.memory"  # optional: the menu offers Restart
up_detail = "recall and capture" # optional: the detail shown while up
timeout_seconds = 10             # optional, default 10, at least 1: the check's time limit
```

The gateway runs every check at start, then every
`services_interval_seconds`, and after a `service.restart`; each check
(and each restart) runs in its own process group; a check is killed after
its service's `timeout_seconds` (default 10), a restart after
`command_timeout_seconds`. Checks of different services run side by side,
and each one's answer reaches the app (a `services.status`, when it changed
anything) as soon as it comes: one slow check never holds back the others.
One service never has two checks at once. A bad `[[services]]` entry (a
missing or blank key, an id with other characters, an id used twice, an
unknown key, a `timeout_seconds` under 1, an interval under 5) stops the gateway at start with the key
named; `bin/doctor` reports it on its `config` and `services` lines and
otherwise lists the configured ids without running any check. Portico
never knows what a service is: it draws what the deployment lists.

v0.8: a deployment that already has one command for all its services
names it instead (or as well):

```toml
[deployment]
restart = "my-tool restart-all"   # optional: Restart all services runs it; exit 0 = done
status = "my-tool status --json"  # optional: prints the services as JSON
```

`status` prints `{"services": [{"id": "memory", "name": "Memory", "up":
true, "detail": "recall and capture"}]}` (`detail` optional) on stdout;
v0.17: a row may carry `"state": "up" | "down" | "stuck"` instead of (or
as well as) `up`; `state` wins, and `up` may then be left out
(`{"id": "memory", "name": "Memory", "state": "stuck", "detail": "index
rebuilding"}`);
its stderr is kept apart (a warning there never breaks the JSON) and only
gives the reason when the command fails. When it is
set, the gateway runs it at start and every `services_interval_seconds`
instead of each `[[services]]` check; `[[services]]` entries then only give
rows their Restart, matched by id. Both commands run with `/bin/sh -c`, in
their own process group, killed after `command_timeout_seconds`. A
plug-in's `services_status()` and `restart_services()` hooks take
precedence over them.

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
  has not ended and, v0.16, is not a thread: Main), `state` its state word, `mode` its permission mode,
  `started_at` when the gateway started (UTC, ISO 8601), `config_stale`
  whether the config file changed since. v0.16: `threads: [{label, title?,
  state}]`, the open threads by slot, only when there are any (the line for
  a person ends "; threads: Thread 1 (working), Thread 2 (idle)").
  `version` changes only if a key changes meaning. Exit 0 when a gateway runs, 3 when none does. Without
  `--json`, one line for a person.
- `stop` — stops the gateway running on this state directory through its
  own stop path (as `gateway.stop`: running turns reported as stopped,
  `on_stop`, index saved) and waits for it to exit. Exit 0 when one was
  stopped, 3 when none ran, 1 when it did not stop in time
  (`--timeout`, default `command_timeout_seconds` + 30).
- `update --check` — runs config `update.check` with `/bin/sh -c`: exit 0
  and the version on stdout when an update is available (the command's
  last non-blank line), 1 when none (the command exited 1, or exited 0
  with no output), 2 when no check is configured, 4 when the check failed
  (any other exit, a timeout, or a command that cannot start; the reason
  on stderr).
- `update` — stops a running gateway (as `stop`), then runs config
  `update.run` with `/bin/sh -c`, its output (stdout and stderr) streamed
  to stdout; exits with its exit code, 2 when no update command is
  configured. It does not start the gateway again: the app does.
- `config-value <dotted.key>` — prints one config value (`brand.name`,
  `brand.app_icon`, `update.run`...) or nothing when it is unset or not a
  key; exit 0. A config file that does not load: its reason on stderr,
  exit 1. Lists and tables print as JSON.

- `sessions clear [--yes]` *(v0.12)* — forgets every ended session on a
  stopped gateway's state directory, keeping the live one; the engine's
  transcripts on disk stay and the numbers are never handed out again.
  Asks first unless `--yes`. Refuses with "Stop the gateway first." (exit
  1) while a gateway runs on the state directory, and in multiple
  presentation. It does what the `sessions.clear` message does.

The running gateway also checks for updates itself: `update.check` at
start and every 6 hours, in the background; a version found goes to the
attached app as `update.available`, and again to an app that attaches
later. It watches the config file's modification time every ~10 seconds
and sends `config.stale` once when the file is newer than at start.

