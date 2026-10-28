# Changelog

## v0.1.0

First hand-off. One repo holding a versioned app-to-gateway protocol, a
Python reference gateway on the Claude Agent SDK, and a SwiftUI Mac app.

### What a person gets

**The app**

- A native Mac window: a sidebar of numbered chats (`#1`, `#2`, ...) with an
  optional alias, each showing its state in plain words (`idle`, `working`,
  `waiting on you`, `stopped`) and its folder; New Chat picks a folder.
- A conversation pane: your messages, the agent's reply streamed as it is
  written, one row per tool call with a summary and the full input behind a
  disclosure, and a marker at the end of every turn. Send with cmd-return,
  Stop with cmd-period. Attachments by drag-and-drop or an open panel; a
  half-typed message survives switching chats, and a refused send keeps
  what you typed.
- Cards, pinned above the input until answered: a permission card (Allow
  this time / Allow for this chat / Always allow / Deny, with a note), a
  question card (radio or checkbox options plus "Other"), and a form card.
  "Allow for this chat" on a command tool covers that command, not every
  command the tool could run.
- A viewer beside the conversation: markdown rendered, images, HTML, PDFs
  and local URLs, with a history of everything the agent produced, Open
  externally on every entry, and a collapsible column. The newest viewable
  artifact of a turn opens on its own; non-viewable files are listed only.
- A files pane under the chat list: the chat's folder and any roots the
  deployment configures, browsed lazily, filtered by name; a click shows a
  file in the viewer, "Add to chat" attaches it to the next message.
- A status strip: the chat's state, its folder, whether the gateway is
  running, and the last status line a lifecycle command printed.
- Settings: auto-open on or off, per kind; what quitting does (keep the
  agent running, or stop everything); appearance; a gateway address and
  token file override; a Doctor button that shows the checks inline.
- The app starts the gateway itself when none is running, finds a running
  one through its ledger, and reconnects after a drop. Quitting with "keep
  the agent running" leaves the gateway and its turns going; reopening
  shows the prior conversation and its artifacts once, never duplicated,
  with any card asked while the app was closed waiting to be answered.
- Brand name, agent name, accent colour and icon come from the gateway's
  `hello`, so one app serves any deployment; a protocol version mismatch is
  shown, not tolerated.

**The gateway**

- `portico-gateway run`: one WebSocket on 127.0.0.1 for the app, refused
  without the per-launch token (HTTP 401), plus `GET /v1/health` and the
  producer endpoint `POST /v1/artifact` on the same port. Prints
  `PORTICO_READY port=<n>` once listening.
- Owns the agent session per chat through the Claude Agent SDK, with the
  folder's own `.claude/` settings and hooks in force. Auth and provider
  come from the environment only.
- Never allows a tool by default. Every permission and every question goes
  to the app as a card; with no app attached a card is held (default
  10 minutes) and then denied with "nobody was there to answer".
- Streams text and tool events with a sequence number per chat and keeps a
  ring buffer, so an app that reattaches catches up from where it left off;
  older history replays from the engine's own transcript, artifacts included.
- Detects artifacts from tool writes, local URLs and named paths in the
  reply; records them in the index so they survive a restart.
- Runs the deployment's lifecycle commands: `before_first_chat` before any
  engine starts (bounded by a timeout; a failure refuses the chat with the
  command's last line) and `on_stop` on the way out. One instance per state
  directory; SIGINT/SIGTERM stop cleanly.
- `portico-gateway doctor`: one line per check (Python, SDK, credential
  present, config, `setting_sources`, token file mode, env file mode,
  ledger live or stale, swift on PATH); exit 1 on any failure.
- Config in `~/.portico/config.toml`; state (token, ledger, index, lock,
  log) in `~/.portico/`; `PORTICO_HOME` moves both.

**The protocol**

- `protocol/PROTOCOL.md`, version 1: the transport, the envelope, every
  message in both directions, the attachment form, the hold rule, the
  auto-open rule, the ready line, the health and producer endpoints.
- `protocol/schema/portico.schema.json` exported from the gateway's models
  and one example per message in `protocol/examples/`, which both test
  suites decode.

**Tooling**

- `bin/install`, `bin/doctor`, `bin/update`, `bin/portico-gateway` (loads
  `~/.portico/env` when present, then runs the installed CLI).
- Model-free tests on both sides (gateway against a fake engine; Swift
  against every protocol example), one opt-in live smoke test
  (`PORTICO_LIVE=1`), and a distribution test that keeps deployment names
  out of the repo.
