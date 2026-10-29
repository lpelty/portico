# Changelog

## v0.7.0 — unreleased

### What a person gets (gateway)

- **The first send shows at once.** The gateway sends `turn.started`, the
  `user.text` echo and `chat.state working` before it starts or resumes the
  agent's engine, so after a gateway restart the message and "Working"
  appear immediately instead of after the engine's 5–10 s start. An engine
  that cannot start ends the turn `error` and answers `engine.start_failed`
  (or `lifecycle.before_first_chat_failed`), as a refused send does; a
  `turn.stop` while it starts ends the turn stopped without sending.
- **Log session and New are recorded in the conversation** as `chat.notice`
  lines, kept in the ring so a replay shows them: "Log session — running
  the log step" at once, then "Session logged" or "The log step didn't
  finish; the session isn't logged"; "New — logging, then ending this
  session" (or "New — ending this session"), then "Session ended ·
  continues in Session M", and "Continues Session N" first in the next
  session. `/log` and `/new` in the composer send the same requests and get
  the same lines. A refused command (busy, ended, no log step) writes none.
- README: `brand.icon` may be a flat square; Portico rounds it in the macOS
  icon shape (an image with transparent corners is drawn as given).

### Protocol (still version 1; no new messages)

- The echo frames come before the engine starts; `chat.notice` also
  records session commands. Same frames, earlier and more of them.

## v0.6.0 (2026-10-29)

Launch continues the live session, a way back from an earlier one, a calmer
resume. Screens: `design/portico.pen` row Y (Y1, Y2).

### What a person gets (app)

- **Launch with a live session** opens the welcome view and stays there (no
  more welcome-then-jump). Its composer continues the session ("Continue
  Session N — what next?"); sending switches to the conversation. A quiet
  line offers **View Session N** and **Start a new session** (which asks to
  log first when there is unlogged work). With no live session the welcome
  starts one, as before. A reconnect never sends you back to the welcome.
- **The viewer opens only with something in it**: on relaunch it comes back
  only if an artifact was showing when you quit; elsewhere it opens when an
  artifact is set to show, not just because a session has artifacts.
- **New files appear in the Folder tree** without pressing refresh: the
  session's folders are listed again shortly after a write or a turn ends.
- **A way back from an earlier session**: a bar pinned at the top ("Session
  N · ended … · read-only") with **Back to Session M**, and the THIS
  SESSION card is itself a button back to the live session.
- **Earlier rows are plain** until hovered; selected is a tint and a
  brighter title; no focus ring.
- The log-first dialog keeps its buttons on one line.

### Fixed before release (review)

A second `chat.open` while the first was unanswered could drop the start of
a conversation and forget a send in flight; the welcome could send into a
session being logged or ended; the column flickered between blank and "Not
connected" while a gateway failed to start; a click on a disabled button in
the session card fell through to the card.

### Protocol (still version 1; additions only)

- `last_reply` (optional) on `ChatSummary`: when the session's last turn
  finished, kept on the record across restarts. An older app ignores it; an
  older gateway leaves it out and the welcome omits "last reply … ago".

## v0.5.0 (2026-10-29)

The viewer shows more, and nine fixes from the first deployment's use.
Screens: `design/portico.pen` row X (X1, X2).

### What a person gets (app)

- **CSV and TSV as tables**: header row pinned while the rows scroll down
  and moving sideways with the columns; one viewport with its scrollbars
  at the viewer's edges; rows draw lazily, so tens of thousands scroll
  smoothly; numeric columns right-aligned; cells select and copy. Quoted
  commas, quotes and line breaks parse. Read and parsed off the main
  thread ("Loading…"), cancelled when you switch files. Limits, each with
  a line under the table: 50 MB / 200,000 rows (a cut inside a quoted
  cell keeps the complete rows), 200 drawn columns.
- **Text and code** (`toml`, `json`, `yaml`, `py`, `js`, `swift`, `sh`,
  `log`, `sql` and about forty more) drawn monospaced, unwrapped, top left,
  selectable like the chat; the first 1 MB; lines over 10,000 characters
  broken to fit, with a note.
- **A file that isn't on disk** says so ("The agent's write may have been
  declined, or the file was moved or deleted…"), with no Open button.
- **A kind Portico can't show** names the app that can ("Open in Pages")
  and says so in plain words ("Word documents", not the system's type name).
- **A file the agent changes reloads** when you open it again.
- **Selection clears when you click elsewhere**, as everywhere on macOS
  (a scrollbar click keeps it).
- **Log session without a log step** shows disabled with the reason;
  `/log` says why in a notice instead of reaching the agent.
- **Changed this session** heads the Folder tab too; declined, blocked and
  unanswered writes are never listed.
- **The services menu wraps** each row's detail; a check's reason may run
  to 240 characters.
- **The Dock icon stays the bundle's**: `brand.icon` replaces it only for a
  build without one (it is the in-app mark).

### Install

- **`bin/install` stops on a config that does not load**, printing the
  gateway's reason, instead of building a default-branded app.
- **A square `brand.app_icon` is shaped for macOS** (824 px rounded body on
  1024, shadow); an icon with transparent corners is used as given.
- New optional **`brand.app_icon_assets`** (absolute path to a precompiled
  `Assets.car`) and **`brand.app_icon_name`** (the icon's name in it): the
  macOS 26 glass icon, with the PNG as the fallback. Never sent in `hello`.

### Protocol (still version 1)

No new messages or fields. The gateway maps the text and code extensions
to the existing `text` media (an older app would not decode a new media
word); `text` still never auto-opens. The app picks the table by
extension.

### For deployments

- If you pointed `brand.icon` at the app icon to stop the Dock swapping,
  you can point it back at the in-app mark.
- A config error now stops `bin/install`; fix it and run it again.

## v0.4.0 (2026-10-29)

Chat that reads like chat, session commands, services, a quieter strip.
Screens: `design/portico.pen` row W (W1–W4).

### What a person gets (app)

- **The agent's messages render Markdown**: headings, bold, italic,
  `code`, links (open in the browser), strikethrough, bulleted and numbered
  lists (two levels, with code fences inside items), code blocks, quotes
  (holding lists and paragraphs), rules and tables (drawn as a grid). Your
  own messages stay plain text. In-house parser, no package dependency.
- **Selecting and copying works like Mail**: the agent's prose and code are
  native text views, so a drag starts anywhere in the text (not only on a
  letter), runs across paragraphs and list items, shows the I-beam, and
  copies with ⌘C.
- **Copy**: each code block shows its language and a Copy button that
  copies the code alone (no fence, no trailing blank lines, no wrapping
  breaks), so a pasted command runs as it reads. Each agent message shows
  Copy on hover, copying its Markdown.
- **No "turn N" dividers.** A stopped or failed turn keeps its one-line
  note.
- **Session card commands**: **Log session** (when the deployment can log)
  logs without ending the session; **New** starts the next one. When the
  session has unlogged work, New asks first: *Log Session N before starting
  a new one?* — Cancel, Start without logging, **Log and start new**
  (default). `/log` and `/new` typed do the same.
- **Status strip**: model · context · services, plus the update link. The
  state word and the folder are gone. The strip never wraps; when narrow it
  shortens its words, then hides the model.
- **Services**: one control, **All services up** / **X is down** / **N
  services down** / **Checking…**, opening a menu with a row per service
  (dot, name, one line of detail, down ones first) and **Restart** where
  the deployment gives a restart command. The Gateway row comes from the
  app itself, so it shows even when the gateway is what is down.
- **Files words**: tabs **Folder | Bookmarks**; Bookmarks lists your
  bookmarks and **Changed this session** (files the agent created or
  edited, newest first, with the time). Existing pins carry over.

### What a person gets (gateway)

- **`session.log`** runs the deployment's log step in the live session
  without ending it; the record keeps `logged_at` and `unlogged`, sent on
  every `chat.state`, so the app never guesses whether New should ask.
- **Services monitor**: `[[services]]` checks run at start, every
  `services_interval_seconds` and on request, each bounded by its own
  timeout and published as it answers; a failing check reads "not
  responding since H:MM" plus its last output line. `service.restart` runs
  the restart command and rechecks. `portico-gateway doctor` checks the
  services too.

### Review fixes (before release)

A fresh-context review found eleven problems, all fixed: New would not ask
after ordinary turns (unlogged now rides on every `chat.state`); "Logging…"
could stick after a reconnect; one slow check delayed every service; any
status update cleared every Restart spinner; a pre-0.4 gateway left
"Checking…" forever (now: no services after 5 s or on an older gateway);
Markdown misreads (`C#` heads, fences in list items, table cells, a stray
`a | b` line, a wrapped "2024." becoming a list, quoted lists); re-parsing
every message on each streamed delta (now cached); the strip measuring
itself too narrow.

### Protocol (still version 1; additions only)

- App → gateway: `session.log {chat, id}`, `service.restart {service, id}`.
- Gateway → app: `session.logged {id, chat}`, `services.status {services:
  [{id, name, state: up | down | checking, detail?, since?, can_restart}]}`.
- Fields: `logged_at` and `unlogged` on `ChatSummary`; `unlogged` on
  `chat.state`; `hello.commands` lists `log` when the deployment can log.
- Errors: `session.cannot_log`, `service.unknown`, `service.no_restart`.

### Configuration

New keys, all optional: `[[services]]` tables (`id`, `name`, `check`,
optional `restart`, `up_detail`, `timeout_seconds` default 10) and
`services_interval_seconds` (default 30). With no `[[services]]` the menu
holds the Gateway row only.

### For plug-in authors

- Plug-in API stays **1**.
- `on_renew` now also runs for **Log session** (`/log`), where the session
  goes on: `ctx.ending` is `False` there and `True` for a renewal. A
  plug-in whose log prompt tells the agent "this session is ending" should
  check `ctx.ending`.

## v0.3.0 (2026-10-28)

### What a person gets (gateway)

- **Single session by default**: `presentation` defaults to `"single"`;
  multiple chats stay behind config.
- **Permission mode per session**: `permission_mode` (`auto` by default,
  `acceptEdits`, `default`) is passed to the agent engine; `session.mode`
  changes it mid-session (the running engine at once, later engines from
  the record). `chat.state` and the chat list carry the mode.
- **One permission unit**: a permission card asks a plain question
  (`Save changes to notes.md?`, `Create notes.md?`, `Run git status?`,
  `Open example.com?`, else `Use <tool>?`) and names its tool row
  (`tool_use_id`). The closing (`card.answered`) and the row
  (`tool.finished`) carry the outcome: `once`, `session`, `declined` (with
  the note), `auto` (auto mode allowed a step that would otherwise ask),
  `blocked` (auto mode's classifier refused it). Outcomes are kept on the
  record, so rows replayed after a restart read the same.
- **"Allow for this session" lasts**: the allows are saved on the chat
  record. Before, a gateway restart lost them (they lived in memory only);
  an allow given on a `Write` did not cover the `Edit` of the same file
  that followed (both now ask "Save changes to ...?" and share one allow);
  and `cd <the session's folder> && <allowed command>` asked again. A new
  session starts with none.
- **"Allow for this session" never covers more than the card showed**
  (review fixes): on a file edit inside the session's folder it covers
  edits to files in that folder (symlinks followed), outside it only that
  one file — before, one allow covered every file edit anywhere. On a
  command, a prefix rule (`git status:*`) no longer covers a part with a
  background `&`, `$(…)`, `${…}`, backticks or a `<`/`>` redirection
  (`git status & rm -rf ~` asks), and a `cd` alongside it is covered only as
  `cd <literal path>` into the session's folder — before, `cd "$(…)"`,
  ``cd `…` ``, `cd >file`, `cd $HOME`, `cd -` and a bare `cd` were covered.
  The card says what the allow covers (`card.ask.scope_note`).
- **Card titles** resolve a relative path against the session's folder
  (`Create x.md?` vs `Save changes to x.md?` looked in the gateway's own
  directory).
- **Outcomes go by the mode when the tool started**: `auto` and `blocked`
  are labelled from the mode at `tool.started`, not at `tool.finished`;
  `blocked` only in auto mode and only when no person answered for that
  step. An answer's outcome is saved at once, not at the tool's end.
- **Sessions created before v0.3** (no mode on the record) resume in the
  deployment's `permission_mode` (`auto` by default); the chip shows it.
- **A message that starts with a path is not a command**: `/tmp please
  summarize`, `/etc`, `/file.md summarize` go to the agent as typed (the
  word has a `.` in it, or names something at the root of the disk).
- **`update --check` exits 4 when the check fails** (another exit code, a
  timeout, or a command that cannot start), with the reason on stderr: 0
  available, 1 none, 2 not configured, 4 failed.
- **Starting the gateway while `status` probes** no longer refuses it as a
  second copy: it retries the lock for half a second first.
- **Friendly model name**: `context.usage.model_name` from
  `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL_NAME` when the model in use
  is that family's `ANTHROPIC_DEFAULT_*_MODEL` or alias.
- **Unknown slash command**: `/foo` that neither Portico, the deployment
  nor the engine knows is not sent to the agent; the conversation shows
  "No command /foo here" (an empty turn with `chat.notice`) and the
  gateway logs it.
- **Config changes are visible**: `hello.config_stale`, a `config.stale`
  frame when the file changes while the gateway runs, and a doctor warning
  "restart the gateway to apply".
- **New commands**: `portico-gateway stop`, `status [--json]`, `update
  [--check]`, `config-value <key>` (see README, Command line).
- **Updates**: the gateway runs `update.check` at start and every 6 hours
  in the background and tells the app (`update.available`); `hello.can_update`
  says whether `update.run` is set.

### What a person gets (app, review fixes)

- **The start screen's mode chip is the truth**: it shows the pick, else
  the deployment's mode for new sessions (`hello.permission_mode`), never
  the mode some other session last reported — and the new session runs in
  what it showed (before, it could read "Ask each time" while the session
  ran in auto, or Auto while a `default` deployment asked).
- **The card says what "Allow for this session" covers**, in the gateway's
  words (`scope_note`): edits to files in the folder, this file, this
  command, or the command prefix.
- **Enter while an input method is composing** (marked text) commits the
  composition instead of sending.
- **Updater waits for the old app to quit** (`--wait-pid`) before running
  the update, so the old app cannot restart the gateway mid-update; after
  30 seconds it gives up and says so.
- **Start screen mark**: bigger (54 pt, from 34), and the deployment's
  brand icon (`brand.icon`) when it gives one, else the sparkle.

### Protocol (still version 1; additions only)

- App → gateway: `session.mode {chat, mode}`, answered with `chat.state`
  (stamped, with `mode` and the request's `id`).
- Gateway → app: `chat.notice {chat, text}` (stamped), `config.stale`,
  `update.available {version}`. `chat.open` now ends with a `chat.state`
  (state and mode; a direct reply, no `seq`) after `chat.live`.
- Fields: `mode` on `chat.state` and `ChatSummary`; `tool_use_id` on a
  permission `card.ask`; `tool_use_id`, `outcome`, `note` on
  `card.answered`; `permission`, `note` on `tool.finished`; `model_name` on
  `context.usage`; `config_stale`, `can_update`, `default_folder`,
  `permission_mode` (the mode a new session starts in) on `hello`;
  `scope_note` on a permission `card.ask`;
  `presentation` defaults to `single`.

### Configuration

New keys, all optional: `permission_mode` (`"auto"`, `"acceptEdits"`,
`"default"`; default `"auto"`), `[update] check` and `run` (shell strings),
`brand.app_icon` (absolute path, `~` expanded; read by `bin/install`, never
sent in `hello`). `presentation` now defaults to `"single"`.

### For plug-in authors

- Plug-in API stays **1**; no hook changed.
- `on_hello` sees two new `hello` fields, `config_stale` and `can_update`,
  and the brand without `app_icon`. A plug-in that adds `hello.commands`
  also teaches the gateway those commands: they are never reported as
  unknown.
- `session.mode` is handled by the gateway; a deployment that wants a
  different starting mode sets `permission_mode` (for example
  `"acceptEdits"` where the engine's auto mode classifier is not
  available).
- A deployment's tools should read `portico-gateway status --json`, not the
  lock or ledger files, to see whether the app holds a live session.

## v0.2.0 (2026-10-28)

### What a person gets

- **One session at a time** (`presentation = "single"`): one live session;
  **Log and start new** (or `/new`) runs the deployment's log step in the
  ending session, marks it ended and logged, and opens the next number in
  the same folder. Ended sessions keep their number, title, and whether
  they were logged. Multiple-chat mode is unchanged.
- **Session facts on every chat**: a title (the first line of the first
  message, up to 60 characters), ended, logged, the session it followed,
  how many times the agent compacted it, and the last context reading.
  A v0.1 `index.json` loads unchanged.
- **Context and compaction**: after every turn the gateway reports how full
  the context is and the model (`context.usage`); a compaction is
  reported (`chat.compacted`) and counted, never hidden.
- **Full-text file search** under any root (`files.search`), through
  Spotlight: no index of Portico's own. At most 50 hits, 5 seconds.
- **Resizable columns**: drag the line beside the sidebar or the viewer;
  double-click it for the default width. Widths are remembered. The viewer
  remembers two: one for documents (markdown, text, PDF, images; 440 to
  start) and one for web pages and prototypes (640 to start), so widening
  a prototype leaves documents alone. A bigger window widens the
  conversation; a smaller one narrows the viewer, then the sidebar, before
  the conversation goes below 420. The window's own size is remembered by
  macOS.
- **Earlier sessions, as tall as you like**: drag the line under the
  EARLIER list to show more or fewer sessions (remembered; double-click for
  four rows); the list scrolls, and "All sessions…" is gone.
- **Everything clickable says so**: the pointing hand, a tint on hover and
  a deeper one while pressed, on every button, chip, row and menu; a
  folder's arrow (and the whole row) opens it.
- **Deep folders stay readable**: the file tree indents less past four
  levels, cuts long names in the middle, and shows the full path on hover.
- **Releases by tag**: `bin/update` moves to the newest `vX.Y.Z` tag,
  reinstalls, rebuilds the app and runs the doctor (`--channel main`
  follows main). It refuses to update over local changes; the doctor warns
  about them and prints the tag or commit.

### Protocol (still version 1; additions only)

- App → gateway: `session.renew {chat, log}`, `files.search {root, query}`.
- Gateway → app: `session.renewed {ended, next}` (answers the renew's `id`,
  after `chat.state` for both sessions and before `chat.list`),
  `context.usage {chat, percent, model}` (not stamped), `chat.compacted
  {chat, trigger}` (stamped, replayed), `files.results {root, query, hits}`.
- `hello` gains `presentation` and `can_log`, and the capabilities
  `sessions`, `files.search`, `context`. `ChatSummary` gains `title`,
  `ended`, `logged`, `parent`, `compactions`, `context_percent`.
- New error codes: `session.ended` (renewing, or sending to, a session that
  has ended), `session.live` (`chat.new` in single mode while a session is
  live), `files.search_failed` (Spotlight failed or timed out).

### Configuration

New keys, all optional: `presentation` (`"multiple"` or `"single"`,
default `"multiple"`), `log_prompt`, `plugins`, `plugin_paths`.

### For plug-in authors

- Plug-in API **1**. A plug-in is a module outside the checkout, named in
  `plugins`, with its directory in `plugin_paths`; it must define
  `PORTICO_PLUGIN_API = 1`.
- Hooks, each optional: `on_hello(hello) -> hello`;
  `async on_renew(ctx, chat) -> bool` (the log step; `ctx.send(text)` runs a
  turn in the ending session and returns `"done"`, `"stopped"` or
  `"error"`; `ctx.folder`, `ctx.chat`, `ctx.log_prompt`); `search(root,
  query) -> list[Hit]` (sync or async; dicts with `path` and `snippet` are
  accepted; paths relative to `root`, anything outside it is dropped).
- A missing module, an import error or another API number stops the
  gateway at start with one line; `bin/doctor` reports each plug-in.
- `examples/plugin/portico_example_plugin.py` overrides `on_renew` and
  `on_hello`.

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
- A start screen (frame "A4 · New chat" in `design/portico.pen`) whenever no
  chat is selected, and behind New Chat: a greeting, one large composer with
  Attach, the folder the chat will work in (the last one used, else the first
  configured root, or any folder through its menu) and Send, and the
  deployment's actions as suggestion chips. Send or a chip makes the chat in
  that folder and sends the message in one motion; a refused start puts the
  words and files back with the reason.
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
