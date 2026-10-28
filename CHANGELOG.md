# Changelog

## v0.1.0

First hand-off. One repo holding a versioned app-to-gateway protocol, a
Python reference gateway on the Claude Agent SDK, and a SwiftUI Mac app.

### What a person gets

**The app**

- The window laid out as the A1 frame in `design/portico.pen` ("Classic
  three-column"): no title bar, a 260-wide sidebar whose top band holds the
  traffic lights, the conversation under a 52-high toolbar and a 30-high
  status strip, a 440-wide viewer; opens at 1440 x 900. The toolbar's end
  buttons (and View > Hide Sidebar / Hide Viewer, ctrl-cmd-S / ctrl-cmd-V)
  collapse the side columns; the viewer's state is per chat. Colours come
  from the frame's variables in light and dark.
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
  against every protocol example), opt-in live tests against a real model
  (`PORTICO_LIVE=1`: the smoke plus one file per window-facing done-when
  check), and a distribution test that keeps deployment names out of the
  repo.

### Validated live

On 2026-10-28 the gateway was driven against a real model, opt-in, by
`gateway/tests/test_live_smoke.py` and `test_live_check1/2/3/4/5/9.py`:
25 tests, all passed, in 5 minutes 20 seconds. Together they cover the
gateway half of done-when checks 1, 2, 3, 4, 5, 6 and 9: a fresh `git
clone` installed and started through its own `bin/`, a reply streamed over
the protocol, a permission card denied (no file, the agent says so) and
allowed (the file written, its markdown artifact opening), a chat-scoped
allow covering the next write, question cards answered single-select,
multi-select and with free text, a markdown report and a page on a local
port opening as artifacts, the producer endpoint mid-turn, stop
interrupting a turn, a client leaving mid-turn with the gateway finishing
the work and replaying it gaplessly on return, a card held while nothing
was attached, two chats with their own state words, a gateway restart
replaying the transcript and resuming the session, a configured root
browsed and an attached file read by the agent, and a folder's own deny
hook firing. What is left is the window itself, seen by a person;
`docs/done-when.md` says which part of each check that is, and holds the
numbers.

### Fixed after review

Found by the live runs and a code review, fixed in the commits between the
build hand-off and the live close-out.

**Gateway**

- A frame nested too deeply is refused as `protocol.invalid` instead of
  crashing on recursion.
- Config refuses a zero or negative timeout, a zero history buffer, or a
  negative card hold.
- An engine that dies mid-turn ends the turn with `outcome=error`.
- An index holding an unknown chat state word is refused as a state error.
- The env file is read by the gateway itself as literal `KEY=value` lines and
  is never sourced by a shell, so nothing in it can run; `check-env` applies
  the same parser.
- Shutdown closes a connection that never said hello instead of hanging on it.
- The stop watchdog closes an engine that ignored an interrupt, so its late
  finish cannot end the next turn.
- A viewable file named as a markdown link in the reply is reported as an
  artifact.
- A stale or zero `since` on a restored chat replays the transcript, not an
  empty history.
- A stop during a hung `before_first_chat` is honoured at once, not after
  its timeout.
- A root written as `~/vault` is expanded at config load; a relative root
  is refused.
- Transcript replay no longer shows the engine's interrupt marker as the
  person's words.
- Doctor: a login token in the environment counts as a provider credential.
- Doctor: a malformed env file is reported by line number instead of
  killing `bin/doctor`.
- Tests: the live smoke answers a permission card in the protocol's shape;
  the live drivers for checks 1, 2, 3, 4, 5 and 9 are opt-in gateway tests.

**App**

- The window shows from `swift run`: a bare executable is a background-only
  process to AppKit until the app asks to be a regular one.
- The ready-line and hello deadlines fire against a silent gateway.
- The first open of a chat only heard through broadcasts asks for history
  from the beginning.
- One send in flight per chat; a second waits in the editor.
- An action button sends on its own and leaves the composer alone.
- A card the gateway re-sends after an unconfirmed answer is open again.
- A failed viewer load is not retried on every redraw; the failure page
  offers Try again.
- A Files pane listing lands where it was asked for, and never says
  Listing… forever.
- Quit with "stop everything" stops the gateway after the main window was
  closed.

**Protocol** (wording in `PROTOCOL.md`; version 1 unchanged)

- `roots[].path` in `hello` is absolute, with `~` expanded.
- `since: 0` means from the beginning; a `since` beyond the chat's current
  `seq` replays from the transcript.
- A stop during `before_first_chat` kills the command's process group and
  refuses the request waiting on it.
- After the stop grace period the gateway closes the engine; the next send
  starts a fresh one on the same session.
- User-role entries the engine writes for itself (reminders, command
  output, the interrupt marker) replay as nothing and start no turn.
