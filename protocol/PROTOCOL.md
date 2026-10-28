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
  `Authorization: Bearer <token>`. *(Task 9)*
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
`folder: string` (absolute path). Reply: `chat.state` (`idle`) then an
updated `chat.list`. *(Task 7; `before_first_chat` at Task 11)*

### `chat.open` — `ChatOpen`
`chat`, `since: integer | absent` (last `seq` seen). Reply: `chat.history`,
then `chat.live`, then any open `card.ask` again. *(Tasks 7, 8, 10)*

### `chat.stop` — `ChatStop`
`chat`. Interrupts and closes the chat's engine; state becomes `stopped`. *(Task 7)*

### `chat.alias` — `ChatAlias`
`chat`, `alias: string | absent` (absent clears it). *(Task 7)*

### `chat.remove` — `ChatRemove`
`chat`. *(Task 7)*

### `message.send` — `MessageSend`
`chat`, `text: string`, `attachments: [string]` (absolute paths, default
empty). A send while the chat is `working` is refused with
`error code=chat.busy`; a missing attachment with `error code=attachment.missing`.
Attachment form appended to the text: *(Task 7)*

```
<text>

Attached files:
- /abs/path
```

### `turn.stop` — `TurnStop`
`chat`. Interrupts the running turn; it finishes with `outcome: stopped`. *(Task 7)*

### `card.answer` — `CardAnswer`
`chat`, `id` (the card's id), `answer: object`, `scope: once | chat | always | absent`,
`note: string | absent`. A permission answer is
`{"decision": "allow" | "deny"}` with `scope`; a question answer is
`{"answers": {<question text>: <label> | [labels]}}`. An unknown or
already-answered id is refused with `error code=card.stale`. *(Task 8)*

### `files.list` — `FilesListRequest`
`root: string` (a root name from `hello.roots`, or `chat` for the chat's
folder, with `chat` set), `path: string` (relative, default `""`), `id` to
correlate. Reply: `files.list` (server). *(Task 12)*

### `artifact.opened` — `ArtifactOpened`
`chat`, `artifact_id: string`. Informational; the gateway acknowledges
nothing. *(Task 9)*

## Messages: gateway → app

### `hello` — `HelloServer`
`protocol: 1`, `gateway_version`, `epoch`, `brand {name, agent_name, accent?, icon?}`,
`actions: [{label, text}]`, `roots: [{name, path}]`, `commands: [string]`
(reserved; empty in v0.1), `capabilities: [string]` (v0.1: `cards.form`,
`files`, `producer`). Always followed by `chat.list`, so the app has the
sidebar before anything else arrives.

### `chat.list` — `ChatList`
`chats: [{chat, folder, alias?, state, created}]`. *(Tasks 5, 7)*

### `chat.state` — `ChatState`
`chat`, `seq`, `state`: exactly `idle`, `working`, `waiting on you`, `stopped`. *(Task 5)*

### `chat.history` — `ChatHistory`
`chat`, `events: [event]` (chat-scoped events with their original `seq`),
`truncated: bool` (true when `since` fell behind the ring buffer and the
replay starts later than asked). *(Tasks 7, 10)*

### `chat.live` — `ChatLive`
`chat`, `seq` (the chat's current sequence number). History is complete;
what follows is live. *(Task 7)*

### `turn.started` — `TurnStarted`
`chat`, `seq`, `turn: integer`. *(Task 7)*

### `text.delta` — `TextDelta`
`chat`, `seq`, `turn`, `text`. *(Task 7)*

### `tool.started` — `ToolStarted`
`chat`, `seq`, `turn`, `tool_use_id`, `tool`, `summary`, `input: object`. *(Task 4)*

### `tool.finished` — `ToolFinished`
`chat`, `seq`, `turn`, `tool_use_id`, `ok: bool`, `summary`. *(Task 4)*

### `turn.finished` — `TurnFinished`
`chat`, `seq`, `turn`, `outcome: done | stopped | error`. *(Task 7)*

### `card.ask` — `CardAsk`
`chat`, `seq`, `id`, `kind: permission | question | form`, `title`, and one of
`permission {tool, summary, input}`,
`questions: [{question, header, options: [{label, description}], multi_select}]`,
`form: [{key, label, kind: text | choice | toggle, options?}]`.
Held while no app is attached (`card_hold_seconds`, default 600) and then
denied with the message `nobody was there to answer`. *(Task 8)*

### `card.cancel` — `CardCancel`
`chat`, `seq`, `id`, `reason?`. *(Task 8)*

### `artifact.created` — `ArtifactCreated`
`chat`, `seq`, `artifact {id, kind: file | url, location, media, title, source, open}`.
`media` is one of `markdown`, `image`, `html`, `pdf`, `text`, `url`, `other`;
`source` is `tool`, `text`, or `producer`; `open` is true on the artifact the
app should show now. *(Task 9)*

### `files.list` — `FilesList`
`root`, `path`, `entries: [{name, dir, size?}]`, `id` echoing the request. *(Task 12)*

### `status.set` — `StatusSet`
`chat?`, `seq?`, `text`. One line for the status strip. *(Task 11)*

### `error` — `Error`
`chat?`, `id?` (the request it answers), `code`, `message`. Codes so far:
`protocol.invalid`, `protocol.unknown_type`, `protocol.hello_required`,
`protocol.unsupported` (a known type this gateway has no handler for),
`session.replaced`, `chat.unknown` (no chat with that number), `chat.busy`,
`attachment.missing`, `card.stale`, `files.outside_root`,
`lifecycle.before_first_chat_failed`, `gateway.error` (a handler failed;
the message says which).

A bad frame after `hello` (unknown type, unknown field, not JSON) is
answered with an `error` and the connection stays open; only the first
frame is fatal.
