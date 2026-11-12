# Changelog

## v0.26.4 (unreleased)

- Release gate: no distributed file may name the maintainer's home folders, so a deployment's own config can never ride along with a release.
- **Blank conversation until scrolled (first fix).** A field trace caught it: idle at the
  bottom, a small change in the view's height made the app scroll to the end
  by id, the lazy stack swapped its measured height for an estimate and
  dropped every row, and the view sat below the last real row. Back at the
  end after a height change, the app now scrolls by id only when the last row
  is out of view (a width change scrolls by id as before). The blank-space
  watch counts transcript rows apart from the cards under them, and a
  conversation at its end whose rows have all been dropped is scrolled back
  to its last row, up to three times. Not reproduced hosted; a field run
  decides.

### Diagnostics

- **A diagnostics suite for the deployment's maintainer agent.** It looks at the
  conversation view's behaviour. Off unless turned on, with no setting in the
  app and nothing the person sees. Recordings hold sizes, counts and ids,
  never text, file names, paths, URLs, titles or image content, and stay on
  the machine. While on, the app records each chat's shape, geometry and
  inputs (wheel, keys, jumps, scroll phases) and the gateway's events as sizes
  to `diagnostics/recordings/`.
- **`portico-gateway diagnostics on | off | status [--json]`.** `on` creates
  `diagnostics/` in the app's home with the switch file and a README, and the
  app notices within a few seconds. `off` deletes the whole directory,
  recordings included, and exits 1 naming anything it could not delete.
  `status` says on or off and lists the files (exit 0 on, 3 off).
- **A replay runner and its evaluation.** A recording replays on the real
  conversation view (`PORTICO_REPLAY=<recording> swift test -c release
  --filter 'DiagnosticsReplayTests/testReplayRecordingFromEnvironment$'`),
  checks it for alternating heights, wheels that did not move the view, rows
  in view, a view past the end and estimate drift, and writes counts and ids
  to `diagnostics/evaluations/`. Its first line is the verdict: `red`,
  `green`, or `inconclusive` with the reasons. Each gesture replays inside a
  zero-delta began/ended envelope so the view treats it as the person
  scrolling, and the header says whether the envelope's phases fired. Every
  segment replays from where the recording started it, at the recorded text
  scale. See Diagnostics in the README.
- **The scroll trace moved under `diagnostics/`.** It is now
  `diagnostics/trace.log` and follows the same switch; the root-level
  `scroll-trace` file is retired. The field build's 0.43.3 lines (row, width, viewer and
  paint) are carried unchanged.

### Fixes

The blank chat and the scroll jumps, once the field evaluation names the cause.

## v0.26.3 (2026-11-09)

### Fixes

- **Comment was greyed out when a whole line was selected** (found in demos;
  one word worked). A triple click, or a drag past the end of a line, ends
  the selection at the start of the next paragraph or list item, so it read
  as crossing two blocks. The selection's edges now come in to the text it
  actually covers, in reading mode and in Edit mode. A selection that really
  spans two paragraphs is still refused, as is one that starts or ends inside
  bold, a link or code (the comment's markers can't go there).

## v0.26.2 (2026-11-09)

### Fixes

- **The conversation markers didn't respond to the pointer** (v0.26). Their
  hover area was SwiftUI drawing under the transcript's scroll view, an
  AppKit view, which took every pointer event. The area is now an AppKit
  view above it: hovering a mark shows its tip again, clicking jumps back,
  and a wheel over the rail still scrolls the conversation.
- **The conversation went blank until scrolled** (found in the field on
  v0.26.1). Scrolled up near the end, a column-width change (a side panel
  or the viewer opening) re-estimated the transcript shorter under the view
  and left the view past its end, with nothing drawn. The app's twice-a-second
  check for this now puts the view back at the end of the conversation when
  the person isn't scrolling, instead of only logging it. The trigger itself
  wasn't reproduced off the field; the opt-in scroll trace notes each
  correction (`past-end`).

## v0.26.1 (2026-11-09)

A fix for a freeze and for jumpy scrolling in the conversation, both found
in the field on v0.25.

### Fixes

- **The app froze in some conversations** (main thread at 100%, needing a
  force quit). At the end of the conversation, a 1 pt marker the app scrolls
  to sat on the view's bottom edge inside the lazy list: it was laid out at
  its real height, then dropped and estimated about 200 pt taller, then laid
  out again, every frame. The end of the transcript (the bottom marker, the
  working line, a thread calling or done) is now always laid out, outside the
  lazy part; messages stay lazy.
- **Scrolling jumped.** The view kept the content's bottom still through every
  size change, so each row measured as it scrolled into view moved the view
  by the difference between its estimated and real height. While you scroll,
  size changes no longer hold the bottom; otherwise it holds as before, so a
  streaming reply is still followed at the end and a kept place still holds.

### Diagnostics

- **A scroll trace, off by default.** Create `scroll-trace` in the app's home
  folder (where the gateway keeps its state) and restart: each scroll reading
  and each move the app makes is written to `scroll-trace.log` beside it, with
  why. No message text is written. Remove the file to turn it off.

## v0.26.0 (2026-11-08)

ElevenLabs voices for Read aloud (in Labs), the agent's name on Main,
markers down the chat's left edge, quieter Settings lines, one colour token
set across the app, the viewer and the design file, and the v0.25 review's
low findings and nits.

### What a person gets (app)

- **ElevenLabs voices for Read aloud** (Labs, Preview). Turned on with
  `[voice.elevenlabs] enabled = true`, normally in `config.local.toml`, with
  `[voice] read_aloud = true`. Read aloud's block gains a Voice source: This
  Mac or ElevenLabs. With ElevenLabs: an API key, kept in this Mac's
  Keychain as "<app name> — ElevenLabs key" (never in a config file, a log,
  an HTTP cache, the gateway, or anything the agent sees; read only when
  ElevenLabs speaks or lists voices; Replace… and Remove); a voice ID with Choose…, the account's
  voices by name; and a model (`eleven_v4_turbo` by default; the documented
  models when the list can't be fetched). Long replies are split at
  paragraphs, then sentences, under the model's limit and played in order;
  Stop stops them all. When ElevenLabs can't speak a reply (no key, no
  voice, a key it refuses, an unknown voice, the plan's limit, no network,
  audio this Mac can't play) the reply is read with this Mac's voice and a
  one-line note in its hover row says why.
- **"Wren (Main)".** Main's row in the conversation list, its open card and
  the View menu read "<agent name> (Main)" when the deployment names its
  agent; a long name truncates before "(Main)". With no real name (unset,
  blank or "Agent") it stays "Main"; threads and "Brief from Main" are
  unchanged.
- **Conversation markers.** A short mark per message you sent, in a tight
  stack in the chat's left margin, never over the text (the margin away
  from the stack still scrolls and selects the conversation). Marks for messages
  on screen are longer and brighter, the hovered one longest; hover shows
  your message, the start of the reply and its time with "Click to go
  back"; a click scrolls to the message and highlights it for a moment.
  Long conversations thin the marks (every other one, then every fourth);
  fewer than three messages, no rail. Keeping your place is unchanged.
- **Settings lines.** Section outlines and the lines between rows (MCP
  servers and Plugins lists too) use the quieter `border-subtle`; controls
  keep their borders.
- **The viewer's colours match the app.** Its palette is the app's tokens,
  set when the page is built; in dark mode its background is the window's.

### The gateway

- **`[voice.elevenlabs] enabled`** lists the Labs item `voice.elevenlabs`
  after Read aloud (only with it). The key never goes in config (an
  `api_key` there is refused). With it on and Read aloud off,
  `bin/doctor`'s config check says so.
- **`chat.notice` kind `signin.continued`** marks where a turn carried on
  after a sign-in, live, in the ring and in a replay from the transcript.
- **`bin/doctor`** lists only the sign-in kinds this environment allows.

### Protocol (additive)

- `hello.labs` built-in item `voice.elevenlabs`.
- `chat.notice.kind` value `signin.continued` (example `server.chat.notice.signin-continued.json`).

### Fixes (the v0.25 review)

- L1 A plug-in can no longer rewrite, drop or relabel a Labs item that was
  there before its hook ran; its own items are always Local.
- L2 An AWS sign-in made while the turn was still failing counts.
- L3 SSO start URLs match with a trailing `/`, a `#/` or another host case.
- L4 A comment can quote a URL followed by `,` `.` `)` and an autolink's
  address (the markers go around the whole `<…>`, so the link still
  renders); the agent's refusal no longer asks for the whole link.
- L5 A conversation replayed after a continue shows "Continued after
  sign-in" between the replies, also after a reconnect.
- L6 The SDK's private transcript lookup is imported where it's used, so an
  SDK that moves it can't stop the gateway from starting.
- L7 Restoring a conversation reads its transcript once more as a stream,
  and never parses an image-sized line whole.
- L9 A sign-in command started just as the wait ended is closed.
- L10 A sign-in check that times out ends everything it started.
- L11 A Labs tag the app doesn't know decodes (and draws no pill).
- L12 Read aloud's Labs controls show only where Read aloud is available.
- L13 Closed: fixed by v0.25's M3 and pinned by its test.
- "Yesterday" no longer depends on the real date in tests: relative
  formatting judged yesterday by the clock, not the time passed in. People
  always saw the right word; the tests only passed on the day they were written.
- N1 Only the exact continue text is hidden in a replay.
- N2 v0.25.0's #5 says what the status really shows.
- N3 The sign-in command's exit report is kept until it logs.
- N4 The sign-in command's output stops being parsed once its link and
  code are found, and its buffer is capped.
- N5 The three comment scanners use one whitespace class.
- N6 Closed by design: a `∶` in a reply's author isn't turned back into
  `:` (it would merge a real `∶` with `:`); documented in COMMENTS.md.
- N7 "Moves to … when released" is said only for Preview items.
- N8 An older gateway's Read aloud row says "the gateway's config", not a
  file it can't know.

### Design system

- **One token set.** Every colour the app draws is a `Theme` token: no
  white, black or hex outside `Theme.swift`. New tokens for white on colour,
  the scrim, shadows, the switch knob, the agent pointer's shadow, the
  tooltip (and its secondary lines), the window buttons (Pen only) and the
  MCP and Plugins badges.
- **The Pen check.** `PenTokensTests` compares `Theme` with
  `design/portico.pen`'s variables (names in kebab case);
  `tests/pen_tokens.py` lists hex in the design file's UI frames, with its
  exemptions in `design/token-check.json`.

## v0.25.0 (2026-11-08)

Labs for features being tried out, the date and time on every message, and
a turn that pauses when a sign-in runs out and carries on by itself once
the person signs in again. Plus the sweep's 26 smaller fixes.

### What a person gets (app)

- **Settings › Labs.** A tab, last in Settings, shown only while a feature
  being tried out on this Mac is on. Each row says what it is, whether it is
  a **Preview** (built into the app, not yet released) or **Local** (added by
  this Mac's plug-in, not part of the app), where it was turned on, and for
  a Preview, the tab it moves to when released. **Read aloud moves there**
  from Settings › Voice, with its switch, voice, speed and sample unchanged;
  it is turned on as before (`[voice] read_aloud = true`, or the machine
  flag `voice.readAloudAvailable`). On a stock install there is no Labs tab.
- **Date and time on hover.** Beside Copy under each of the agent's
  replies, and now under the person's own messages too (with a Copy of its
  own): "3:42 PM" today, "Yesterday 3:42 PM", "Nov 6, 3:42 PM", or with the
  year; the full date and time as a tooltip. A conversation restored after a
  gateway restart shows its real times. Where no real time is known, nothing
  is shown.
- **Signing in again carries the turn on.** When a turn fails because the
  sign-in ran out (AWS SSO, or the Claude subscription login), the turn's
  marker reads "Paused: sign-in ran out" and a card docks above the
  composer: "Sign in again to continue", the deployment's words for which
  sign-in, "Waiting for sign-in… since 9:14 PM", Don't wait, and Open
  sign-in page when the deployment has a command for it. Once the sign-in is
  current again the card says "Signed in. Continuing…", the turn carries on
  in the same session, and the conversation notes "Continued after sign-in"
  (the person's message is not sent again). "Trouble signing in?" shows the
  sign-in link and code, or a field to paste the browser's code. Don't wait
  (or ×) leaves the turn ended: "Sign-in ran out". There is no time limit;
  each conversation waits at most twice in a row.

### The gateway

- **`[signin.aws-sso]` and `[signin.claude]`**, every key optional:
  `patterns` (regular expressions over the turn's error detail), `check` (a
  command that exits 0 once signed in again; without it, `aws-sso` reads the
  AWS SSO token cache every 5 s, `claude` runs `claude auth status` every
  10 s), `open` (the card's Open sign-in page; `claude auth login` by
  default for `claude`), `sso_start_url` (`aws-sso` only), `title`, `body`.
  `bin/doctor` says what each kind would use. Nothing about a credential is
  logged: not the command's output, the link, the code or a pasted code.
- **Real times for restored conversations.** A replay from the engine's
  transcript carries each entry's own time (found the way the SDK finds the
  transcript); an event with no match is marked as having none.
- **`config show --json`** writes a table key (`links.sites`) as one row
  with a nested `value`, its `default` object, and a `source` per entry. The
  text output is unchanged.
- Plug-ins may add their own Labs rows in `on_hello`
  (`hello.labs`); the gateway marks them Local, from `plugin:<module>`.

### Protocol (additive)

- `hello.labs?: [{key, title, detail, tag, source, home?}]`.
- `user.text.no_time?` and `text.delta.no_time?`; capability
  `history.times.v1` (a transcript replay's times are real).
- `signin.wait` (gateway → app), `signin.open`, `signin.stop`,
  `signin.code` (app → gateway), all under capability `signin.v1` on both
  sides; `turn.finished.reason?` (`signin.expired`), sent to every app.

### Fixes (the 2026-11-08 sweep)

- #3 A comment can't be anchored inside a link or an HTML entity any more
  (its markers would break the link or the text); the selection is refused.
- #4 Edit mode no longer offers a recovery copy older than the saved file.
- #5 "Exited before it was ready" shows this run's last log line when it
  wrote one, else its exit code; never an earlier run's last log line.
- #6 Renaming a space keeps the file's line endings and a leading BOM.
- #7 Deleting (or replacing) `config.toml` while the gateway runs says
  "Settings changed", as the README says.
- #8 `test_fixture_finds` checks where each match ends.
- #9 Resolving an indented thread block with no `at:` keeps its ID.
- #10 Reading a file no longer deletes a save in progress; only leftover
  temporaries older than 10 s are swept.
- #11 A name with a colon keeps its authorship (written as `∶` on the reply
  line), and the person can edit their own comments.
- #12 A comment draft that lost its place across Edit on/off keeps its
  text and asks to select the text again.
- #13 A file named `{{SOURCE}}.md` no longer gets its body as the page title.
- #17 The CLI docs name only flags the commands take.
- #18 The refusal no longer says comments can't go in tables.
- #19 The `host_allowed` docstring no longer claims the doctor uses it.
- #20 The `[update] check` docs say what exit 1 and other exits mean.
- #21–#30 Test-only and dead code removed: `GatewaySupervisor.stop(using:)`,
  `EditableText.lineEnding`/`trailingNewline`, two `CommentFormat` helpers,
  `comments.ignored_regions`/`live_markers`, `threads.files_phrase`,
  `images.image_block`; the zoom label renders `percentText`; one Markdown
  render path in `WebPane`; `ViewerAgent.detachPane`; the editor uses
  `anchorAwareMarkdown`.
- #31 `test_non_utf8_is_not_parsed_here` is named for what it tests.

## v0.24.0 (2026-11-08)

Configuration a person can live with: a local override file, two clear
system prompt modes, Read aloud from config, `config show`, and a generated
reference for every key.

### What a person gets (app)

- **Read aloud from config.** `[voice] read_aloud = true` shows the Read
  aloud switch in Settings › Voice; the on/off choice stays the person's.
  Without it the app keeps the older machine flag
  (`voice.readAloudAvailable`), so a Mac that already turned it on keeps it.
  Talk is unchanged.
- **The restart notice covers the local file.** Creating, changing or
  deleting `config.local.toml` says a restart is needed, as `config.toml`
  does.

### The gateway

- **`config.local.toml`** beside `config.toml` holds a person's own
  overrides; nothing else writes it. Tables merge key by key; any other
  value, arrays included, replaces the deployment's. The merged result is
  checked as one file; an error from the local file names it
  (`config.local.toml: system_prompt_file: … is not a file`), stops the
  gateway from starting, and `bin/doctor` reports it.
- **System prompt modes.** `system_prompt = "claude_code"` (also
  `"default"`) is unchanged. New `"custom"` with `system_prompt_file`: the
  file's text is the whole prompt, read at each engine start and passed to
  the engine as a file, with `system_prompt_append` and Portico's own lines
  after it. An unreadable or empty file at a session's start is logged and that
  session uses Claude Code's prompt, never an empty one; the status line
  says so once. `"none"` stays as legacy, with a log note suggesting
  `"custom"`.
- **`bin/portico-gateway capture-prompt [--out PATH]`** copies Claude Code's
  own prompt (one small model request, raw request logging to a temporary
  folder that is then deleted) to `<state>/prompts/claude-code-<version>.md`,
  with a header recording the version, the model and the date, and a marker
  comment before machine-specific lines. It never writes inside the
  checkout and never overwrites a file.
- **The change warning.** With `"custom"`, `bin/doctor` and the gateway log
  (once per engine version) say when the engine's Claude Code version
  differs from the one the file was captured from.
- **Each session records its prompt**: the mode, the file (or
  `claude_code`) and the first 8 hex digits of a SHA-256 of the final
  prompt text, in the session's record and the gateway log.
  `bin/portico-gateway sessions` (or `sessions list`, `--json`) lists them.
- **`bin/portico-gateway config show`**: every key, its value in force and
  `[default]`, `[config.toml]` or `[config.local.toml]`, by section, with
  when a change applies; `--changed`, `--json`. No gateway needed.
- **`CONFIGURATION.md`** and **`config.example.toml`** are generated from
  the key docs (`bin/portico-gateway export-config-doc`), and a test fails
  when they are out of date. The README's long config block is now a short
  example and a link.
- `hello` gains `voice: {read_aloud}` (additive). Nothing else changes on
  the wire.

### Security fixes before release (sweep)

- **A viewed Markdown file runs only the page's own scripts.** Raw HTML in
  a Markdown file could run script in the viewer (`<img onerror>`,
  `<svg onload>`), write, resolve or delete comments in the file as the
  person, and send data out. The rendered page now carries a
  Content-Security-Policy with a fresh nonce on every render: only the
  page's own script and style blocks apply (no inline handlers, no
  injected `<script>`, no `eval`, no styles from the file). No script,
  fetch, frame or form can reach outside the page's own scheme; images,
  fonts and media load as before. Before a rendered block is inserted,
  the page also drops `<script>`, `<iframe>`, `<object>`, `<embed>`,
  `<base>`, `<meta>`, `<style>`, `<link>` and SVG animation (`<set>`,
  `<animate>`, `<animateMotion>`, `<animateTransform>`), every `on*`,
  `style`, `class` (except marked's `language-…` on code),
  `autofocus` and `tabindex` attribute and the colour attributes
  (`color`, `bgcolor`, `background`, `text`, `link`, `vlink`, `alink`),
  unwraps `<font>` (its text stays), and removes `javascript:`,
  `vbscript:` and `data:` URLs (`data:image/` stays, in `src` only). The
  file's `id` and `name` attributes are kept with a `user-content-`
  prefix in the rendered page, as on GitHub, so a deployment's CSS or
  script can't rely on them; in-page `#links`, the address's fragment and
  a space's `notice_target` still find them, and references within the
  file (label `for`, image maps, ARIA id lists, SVG `url(#…)` and
  `<use href="#…">`) are rewritten to match. Ordinary raw HTML (`<details>`,
  `<kbd>`, `<br>`, tables, images, links) renders as before, without
  inline styles. The Properties block's fold is now wired by the page's
  script rather than an inline handler.
- **Comments are written only by the viewer's own comments script, for
  the page rendered for the file.** The comments script and its handler
  run in a content world of their own, so no page script in any document
  can post to it; and the handler still ignores, and logs, a message from
  any page but the one rendered for the file. A document beside a
  rendered Markdown page (an HTML file, an SVG, XML) that a link opens is
  loaded under an address of its own, so it can neither take on the
  rendered page's address nor read it. While the viewer is away from the
  rendered page, comments draw nothing and leave the context menu alone.
- **Space actions only on the person's real click or key press (behaviour
  change).** A `space-action:` link now runs only when a trusted click by
  the person landed on that link within the last second (used once), or
  the person pressed Return on it after their own Tab or click put the
  focus there. A script's `a.click()`, a dispatched event, a timer, a
  redirect, or focus set by script or `autofocus` runs nothing and is
  logged, in Markdown and HTML spaces alike. **A space that triggered
  actions from script must now have the person click the link.** In a
  Markdown space an action link counts only when it is text (plain, bold,
  italic or code, with at least one letter or digit), and the page drops
  the file's styles, `class` attributes, colour attributes, `<font>`,
  `autofocus` and `tabindex` (and prefixes its `id` and `name` with
  `user-content-`). **What it cannot do:** the app checks that a real click or key
  press by the person reached the link; it can't tell who wrote the link.
  A space that shows untrusted text (email, web pages, other people's
  notes) must not let links from that text through unchanged. In an HTML
  space, script the deployment does not control can also steer a real
  click or key press (by changing a link as the mouse goes down, or moving
  the keyboard focus). PROTOCOL.md (`space.act`) says so.
- HTML files and sites shown in the viewer are unchanged: they run their
  scripts as before. The Markdown editor shows no untrusted HTML and is
  unchanged.

### Loose ends

- **Running prompt files are cleaned up.** `<state>/prompts/running/chat-<n>.md`
  (a session's composed custom prompt) is deleted when its chat is removed
  or cleared (in the app or with `sessions clear`), and at gateway start
  for any chat no longer in the index. A renewal overwrites it as before.
  Only regular files inside the state directory are touched, and a
  failure is logged, never fatal.
- **PROTOCOL.md**: `config.stale` (and `hello.config_stale`) name both
  `config.toml` (newer, or appeared) and `config.local.toml`; `hello` documents
  `voice?: {read_aloud: bool}`.

### For deployments

- Keep `config.toml` the deployment's; a person's preferences go in
  `config.local.toml`. A deployment that keeps its config in git adds
  `config.local.toml` to that repository's `.gitignore`.

### Owed

- On screen: a `config.local.toml` with `[voice] read_aloud = true` shows the
  Read aloud switch; a custom prompt session, checked with `config show` and
  the session's fingerprint, then back to Claude Code's prompt by deleting
  the line; the restart notice after changing the local file; one real
  `capture-prompt` run.

## v0.23.0 (2026-11-07)

Comments in Markdown files, shown and written in the viewer and by the
agent, and the Edit icon fix.

### What a person gets (app)

- **Comments in Markdown files.** Comments live in the file itself, as
  HTML comments, in comment format v1 (`protocol/COMMENTS.md`): the same
  format as the Obsidian Document Comments plugin today, so a comment made
  in Obsidian shows here and the reverse. Any Markdown viewer shows nothing;
  an agent reads them as plain text.
- **Highlights are always on.** Text anchored by an open thread has the
  amber highlight whether comments are shown or not; resolved-only text
  isn't highlighted.
- **The Show comments toggle**, a speech bubble just left of Edit, for a
  Markdown file. Off, it shows the count of open threads in amber; on, the
  text column moves left and the comments margin fills the right, each card
  beside the first line of its text. Turning comments on in the narrow
  viewer also widens it. The choice is remembered per file.
- **Cards** show each comment's author (a real name, never "me"), a
  relative time and the text, with replies under it. Hovering a card
  brightens its text; clicking highlighted text opens its card. The active
  card has a Reply field (Return posts, Shift+Return for a new line, Esc
  cancels) and Resolve; a resolved thread folds to one dimmed line that
  opens to show it and Reopen. A thread whose text is gone says "Text no
  longer found". A read-only file shows its comments but can't take new
  ones.
- **Commenting from the context menu.** Right-click a selection, in
  reading or Edit mode, for the viewer's own menu: Comment, Cut, Copy,
  Paste and Select All. Comment snaps the selection to whole words, opens a
  draft card beside it, and posting writes the comment into the file. When
  the selection can't be anchored (across paragraphs, in code or a table,
  across formatting), Comment is disabled and says why.
- **Card actions.** Each comment has a … menu: Edit (your own comments)
  and Delete. Edit in place with Save and Cancel (⌘Return, Esc); the time
  stays as written. Deleting a reply needs no confirmation; deleting a
  thread with replies asks inside the card first, and removes its
  highlight. Long comments fold at six lines with "Show more".
- **Resolved threads are hidden** until "Show resolved (n)" at the bottom
  of the margin is on; it is remembered per file.
- **⌥⌘M adds a comment** on the selection, as Comment in the menu does.
- **Comments in table cells.** Select text within one cell, in reading
  or Edit mode, and comment on it; the thread goes after the table. A
  selection across cells says "Select text within one cell." In Edit mode,
  click into a table to comment in it.
- **Edit mode** hides the comment markup the way reading mode does,
  keeps the anchors around text you edit inside them, and removes them when
  you delete all of their text. The margin works there too: a comment action
  is a change to the editor's text, saved the usual way.
- **The Edit toggle uses a square and pencil** (`square.and.pencil`) in
  place of the bare pencil, which read as a slash at the header's size. Its
  "on" fill is now a solid colour, like the rest of the window.

### The gateway

- Three tools beside the viewer tools, available whenever they are and
  allowed with no permission card: `comments_list` (each thread with its
  quote, anchored text and replies), `comment_reply` and `comment_add`
  (anchors a new thread on a quote's match). They write in the agent's
  name with the time now, only inside the chat's folders and only in `.md`
  files, atomically, keeping line endings. Agents can't resolve threads;
  resolving is the person's. The app reloads the file as it does for any
  agent write.
- New optional config `[person] name`, sent in `hello` as `person: {name}`;
  a deployment's plug-in may fill it (`on_hello`). Without it the app uses
  the computer's full user name.
- The app's `hello` lists `comments.v1`. No new message kinds.

### Owed

- On screen: the toggle on and off in the widened and the narrow viewer;
  commenting from reading mode and from Edit mode; the Obsidian round trip,
  both ways; an agent replying in a thread.

## v0.22.1 (2026-11-06)

A crash fix, field notes 24–26 from using v0.22.0, and three small visual
tweaks.

### What a person gets (app)

- **No more crash on a tooltip (the widen button's, among others).** The
  tip's panel had a SwiftUI view as its window content, and SwiftUI kept
  resizing that window to the text's limits while the app placed it; for
  some tips the two never settled and AppKit stopped the app. The panel's
  content is now a plain view holding the tip, which SwiftUI doesn't size.
- **One tooltip at a time (24).** Scrolling hides it, and the next waits
  the usual moment after scrolling stops; a tip shows only while the
  pointer is still on its control. Tips no longer pile up down a list.
- **The Folders tab keeps the folders you opened (25)**, per session,
  when you switch to Bookmarks, another session, and back.
- **A space's header shows the full date and time (26)**: "Brief ·
  Friday, November 6, 7:23 AM", in your locale, in place of "Updated
  7:23 AM". A page can drop its own date bar.
- **A conversation whose folder was deleted says so**: "This conversation's
  folder no longer exists: <path>. Start a new conversation in another
  folder.", in place of "This turn ended with an error".
- **Settings: the tab header stands apart from the page**, on the
  sidebar's colour with a line under it.
- **Files: the folder's name is an ordinary row**, without the band and
  the line under it.
- **Three border tones, further apart.** The lines above and below the
  status strip use a new, quieter `borderSubtle` (#2C2C30 dark, #DDDDE2
  light), so the strip and the conversation read as separate pieces;
  `borderStrong` is a step stronger (#68686F dark, #B2B2BA light);
  `border` is unchanged.

### The gateway

- New error code `chat.folder_missing`: a send, or anything else that
  starts a conversation's engine, when the conversation's folder is gone
  (or is now a file). Nothing starts; it works again once the folder is
  back. An older app shows the message in its status line.

### Owed

- On screen: the widen button and its tooltip, several times; scrolling a
  long Folders list with the pointer still; opening folders, switching
  to Bookmarks and back; a space's header date; the Settings header.

## v0.22.0 (2026-11-05)

Five visual fixes from using v0.20.1 (field notes 7 and 20–23), and five
things a deployment's spaces and routines asked for (S1–S5).

### What a person gets (app)

- **Tooltips sit by their control again (7).** The tip's panel was being
  held to its text's minimum size (narrow and very tall), so once on
  screen it grew from its top edge and the bubble dropped well below the
  control; a long path's tip ended near the bottom of the window. Tips now
  keep the size they're given and stay on the control's screen.
- **"Changed this session" is a plain heading (20)** like the Files pane's
  other sections, without the band and rule.
- **Thin overlay scroll bars everywhere (21)**, over the content's edge,
  also in the viewer and the editor, even with "Show scroll bars: Always".
- **The Settings window is the main window's dark colour (22)**, header
  included.
- **The viewer's header buttons are one height (23).** The close button is
  24 pt everywhere, the app card's header included.
- **Space actions (S1).** A link `space-action:<action>?item=<item>` on a
  space's page (HTML or Markdown) runs the deployment's `[spaces] act`
  with the space, the action and the item. A failure shows in the space's
  header, in red, until the next refresh or action. Only the person's own
  click runs one: the viewer agent can't click such a link (it can ask the
  person to), and a link in a frame, on another site or in another file
  is ignored.
- **Worded notices (S2).** A page's `notice` key is the notification's
  text ("Prep for your 10:00 is ready"), and `notice_target` the place in
  the page a click scrolls to; `notice: ""` means no notification.
- **Messages from the deployment (S3)** dock above the message box like
  question cards, held while a reply streams: title, text, Dismiss, and
  Open when they name a space; up to three stacked, then "N more". They can
  also post a system notification. They aren't sent to the agent or kept
  in the chat.
- **Fixed spaces (S4).** `removable: false` on a page hides Remove and
  Rename for it.
- **Refreshing (S5).** After Refresh, the space shows a spinner in the
  switcher and "Refreshing…" in its header until its page changes, or for
  five minutes.

### The gateway

- `[spaces] act = "..."`: a command run with `/bin/sh -c` for up to 30 s,
  with `$PORTICO_SPACE`, `$PORTICO_ACTION` and `$PORTICO_ITEM` in its
  environment. New frame `space.act {id, action, item?}`; errors
  `space.no_act`, `space.act_failed`, and `protocol.invalid` for an action
  or item outside `[A-Za-z0-9._:-]{1,128}`. Capability `spaces.act` when
  the key is set.
- `SpaceInfo` gains `notice?`, `notice_target?` and `removable?` (sent
  only as `false`). `space.remove` and `space.rename` of a fixed space
  answer `space.fixed`, and nothing is touched.
- `portico-gateway message "<text>" [--title T] [--notify] [--space ID]`
  drops a message into `<state dir>/messages/` (or write the JSON file
  yourself; see PROTOCOL.md). The gateway sends it as `deployment.message`
  to apps naming `messages.deployment.v1` within two seconds, or at the
  next hello; at most 50 wait, a file that doesn't parse goes to
  `messages/failed/`.
- **Update the gateway before adding `[spaces] act`.** An older gateway
  refuses a key it doesn't know. The page keys (`notice`,
  `notice_target`, `removable`) are safe on any gateway.

### Owed

- On screen, on the 1x external display: the tooltips on "Hide the sidebar" and
  the Files Archive row; the scroll bars; the Settings window (macOS 26 may
  still draw its own glass on the tab header); the viewer's buttons; the
  "Changed this session" heading lining up with the folder headings.
- On screen anywhere: an action link in HTML and in Markdown; a worded
  notice and its click; docked messages (three or more, and Open); a fixed
  space's menu; the refreshing spinner.

## v0.21.0 (2026-11-05)

Field notes 19 and 18: background work you can see, and only real
spaces in the switcher. A command or Monitor running
in the background showed nothing once the turn ended, so the app looked
idle while work ran; an agent resumed with SendMessage didn't show as
running again.

### What a person gets (app)

- **Background commands and Monitors sit in the tray** with the agents,
  the same card: the command's description, "Running in the background"
  under it, the time at the right, then a check (or a warning) and the
  engine's summary when it ends. The tray stays after the turn ends while
  any of it runs, and its header and folded line count it: "1 task · 1
  working", "1 agent · 2 tasks · 2 working".
- **The Bash or Monitor row stays in the conversation**; no "Started" row
  for a task.
- **A resumed agent works again in the tray** in the turn that resumed it,
  with its earlier steps kept; the SendMessage row draws as usual.

### The gateway

- Shell (`local_bash`) and Monitor tasks become `agent.started` with
  `task: shell | monitor`, for an app that names the new capability
  `tasks.v1`. An older app sees the conversation as before. Housekeeping
  tasks the engine marks `ambient` or `skip_transcript` are never sent; a
  command started in the foreground is shown only once it moves to the
  background.
- A subagent the engine starts again under the same task id with a later
  `run_id` is a new run: `agent.started` again, with `run` 2, 3, ….
  Frames naming an earlier run are dropped.
- **Field note 18: `[spaces] require_folder = true`** lists a page as a
  space only when a folder of the same name sits beside it (`brief.html`
  and `brief/`). Other files in the spaces folder, such as a README with
  instructions for the agent, stay where they are and are not listed; the
  switcher can't rename or remove them. Off by default. As with any new
  key, update the gateway before adding it.

### Owed

- On screen: a background build in the tray after the turn ends, its end,
  and a resumed agent, in a live chat; the switcher without the README on a
  deployment with `require_folder`.

## v0.20.1 (2026-11-05)

Field notes 16 and 17: the About panel is the deployment's, and nothing says
"Portico" before the gateway's `hello` arrives.

### What a person gets (app)

- **The About panel shows the deployment's version** (`[brand] version`,
  e.g. "Version 0.40.2"), with the app's own version on a generic line
  under it: "App 0.20.1 · Built 5 Nov 2026 at 09:30". Without the key the
  panel shows the app's version, as before, and when it was built.
- **The deployment writes the panel's text** with `[brand] about`: any
  lines (contact details, a support link), with `{app_version}` and
  `{built}` filled in and web and email addresses as links. `""` shows
  nothing.
- **The Dock's menu and the window title use the brand from launch.**
  Before `hello`, an installed app is called by its bundle's name (the
  brand's, from `bin/install`), and the window's title follows the brand
  when `hello` changes it.

### The gateway

- `brand` in `hello` gains optional `version` and `about`. An older app
  ignores them.
- **Update the gateway before adding the keys.** An older gateway refuses a
  config with keys it doesn't know, so `[brand] version` or `about` on a
  0.20.0 gateway stops it loading.

### Packaging

- `make-app.sh` records the build time as `PorticoBuildDate` (ISO 8601,
  UTC) in `Info.plist`. `CFBundleShortVersionString` and `app_version`
  stay the app's own version.

### Owed (on screen)

- The About panel with and without the keys, links clickable; the Dock's
  right-click menu on an installed, branded app before and after `hello`.

## v0.20.0 (2026-11-04)

Edit in the viewer, and zoom images and PDFs. What is verified by tests is
said so; what still needs a person at the screen is under "Owed".

### What a person gets (app)

- **Edit** (pencil in the viewer header, ⌘E) for Markdown, text, code and
  HTML source on this Mac. Off at every open; spaces, web pages, tables and
  files over 2 MB stay read-only, and so does a file you can't write.
- **Markdown as the page.** CodeMirror 6 with a live preview: headings,
  bold, italic, links (⌘-click), lists, checkboxes (click to toggle) and code
  are drawn; the line with the cursor shows its marks. The file keeps exactly
  what was written — tested: moving through every line changes nothing, and a
  CRLF file round-trips byte for byte. Front matter is edited as its YAML.
- **Code** with line numbers and syntax colours for common languages; Wrap
  code applies without losing undo.
- **Autosave**, atomic, keeping line endings, permissions, extended
  attributes and Finder tags; written through symlinks.
- **When the agent changes the file mid-edit:** with nothing unsaved the
  editor reloads in place; with unsaved edits a bar offers **Keep mine** or
  **Use the agent's** (your edits stay in undo), and nothing is written until
  you choose.
- **Never lost silently.** A failed save keeps the text, says why, and keeps
  a copy in `<home>/unsaved/` (offered back when the file is reopened);
  closing, switching, hiding the viewer or quitting saves first, and a quit
  that can't save stops and says so. **Discard my edits** takes a second
  click to confirm.
- **One editor per file**: a second viewer on a file being edited shows it
  read-only.
- **The agent hears about edits** with your next message ("Edited in the
  viewer since your last message: …"), never mid-turn. While you edit, the
  agent can look but not click, type, scroll or mark in that file.
- **Zoom images and PDFs**: a control at the bottom right (−, percent, +,
  Fit, Actual size; a PDF also shows "Page N of M"), pinch, double-click, and
  ⌥⌘= / ⌥⌘− / ⌥⌘0. Each file keeps its zoom for the session.

### The gateway

- **`files.edited.v1`**: `files.edited {chat, path}`; the note goes to the
  agent ahead of the person's next message only, is stripped from replayed
  history, and survives a failed send. Paths with control characters or
  parentheses are dropped.

### Checks

- The editor bundle carries a hash of its sources; the distribution test
  fails on a stale bundle and scans it for deployment names.

### Owed (on screen, or live)

- The live preview in light and dark; a real agent write during an edit;
  quitting with an unsaved, failing edit; ⌘E against the system's Find
  shortcut; pinch and pan on a trackpad; VoiceOver on the zoom control.
- From v0.19: the live image probe and the tooltip screenshot.

## v0.19.0 (2026-11-04)

The first field round from a deployment: solid colours, Settings drawn one
way, a folder a deployment can lock, extra folders in Files, images as
images, runs of commands folded, prose that wraps, and links. What is
verified by tests is said so; what still needs a person at the screen is
under "Owed".

### What a person gets (app)

- **Solid colours, more contrast.** No translucent surfaces anywhere:
  lists, popovers and sheets are solid. Darker backgrounds in dark mode;
  brighter borders and secondary text in both modes. Secondary text meets
  WCAG AA on the window, sidebar and panel (tested from the hex values).
- **Settings, one drawing for every tab.** General, Gateway, Voice and
  Appearance are drawn like MCP servers and Plugins: a title on the panel's
  edge, rows in one solid box. Every switch, checkbox, radio, menu and
  button has a hover state and says what it is to VoiceOver.
- **Gateway → Advanced.** The connection address and token file sit behind
  an Advanced disclosure, closed by default; it opens by itself, with
  "Custom connection in use", when either is set.
- **A folder a deployment can lock** (`[sessions] lock_folder`). "Works in"
  shows the path with a lock and "Set by <brand>"; there is no Choose….
- **More folders in Files.** Settings → General → Also show in Files: add
  folders to browse beside the deployment's; a missing one says "Not
  found". The agent isn't told about them.
- **Continue only the newest session.** When sessions ran outside the app
  since the last one here, the welcome offers "Start Session N" and names
  them ("Sessions 153–158 ran outside the app"). Threads on the same
  counter don't count.
- **Runs of commands fold.** Three or more steps in a row fold into one row:
  "Ran 7 steps · Bash ×5 · Read ×2", or "Working · N steps" with the
  newest step while it runs. A failed step stays visible under the folded
  row. The viewer's own fold is unchanged.
- **Images are images.** Drop, paste or pick an image and it's a
  thumbnail, never path text, in the composer and in the sent message. A
  message can be only an image. Pasted images are kept with the session and
  removed when the gateway confirms the session's removal.
- **Prose wraps.** A fenced box with no language (or text, markdown, prose)
  wraps to the column. Code keeps its lines, with a Wrap toggle. Copy gives
  the original text either way.
- **Links.** Bare web addresses are links, in replies and in your own
  messages. A Slack, Google Docs/Sheets/Slides, GitHub, Figma or Notion
  link in your message shows as a chip with the site's name; a deployment
  adds its own sites with `[links] sites`. Nothing is fetched. Only http,
  https and mailto links open.

### The gateway

- **Images reach the agent as images.** png, jpeg, gif and webp up to 3 MB
  each, at most 4 and 12 MB encoded per message, go as image content
  blocks; the text still lists every path. Anything else, or past a cap, goes
  as a path with a notice saying the agent can still open the file.
- **`user.text.attachments`** and typed-only `text`, for apps that declare
  `messages.attachments.v1`; older apps get today's text.
- **`files.extra.v1`**: `files.roots.set` / `files.roots`, per connection.
- **hello** gains `lock_folder` and `link_sites`; notices gain an optional
  `kind`.

### Checks

- New sweeps: no translucent surfaces; no Settings tab on `Form` or
  default control styles; no "Portico" in a string a person reads; no
  Xcode-only SwiftUI macros. Built with only the Command Line Tools
  (`PORTICO_CLT_BUILD=1`).

### Owed (on screen, or live)

- A real image reaching a real model through the gateway
  (`PORTICO_LIVE=1 uv run pytest tests/test_live_image_block.py`).
- The palette in light and dark; every Settings tab, its hover states and
  VoiceOver; a Finder drag onto the composer; thumbnails; the folded runs;
  the welcome's "ran outside the app" line.
- Tooltip position under the viewer's side-panel and column-expand
  buttons (field note 7): correct under the toolbar's sidebar button in a
  real window; the reported buttons wait for a screenshot.

## v0.18.1 (2026-11-04)

The app builds on a Mac with only the Command Line Tools again, plus three
small fixes from the first field round.

### Fixed

- **Builds without Xcode.** v0.18.0 used SwiftUI's `@Entry` for nine
  environment values. Its macro plugin ships only with Xcode, so on a Mac
  with the Command Line Tools alone every SDK failed. They are hand-written
  `EnvironmentKey`s now, with computed defaults (Swift 6's Sendable check).
  The build falls back from the 27.0 SDK to 26.5 as before; the 27.0 SDK
  cannot build a SwiftUI app without Xcode at all, since `@State` is a macro
  there.
- **The build names the cause.** When every SDK fails because a SwiftUI
  macro's plugin is missing, `build-app.sh` names the macro and says it is a
  bug in Portico, instead of advising a Command Line Tools update that cannot
  help.
- **Changed this session shows once,** under Files → Folders. The Bookmarks
  tab holds bookmarks only.
- **The brand's name, never "Portico".** The Spaces note, When … quits and
  its caption, the "another window" notice and the slash list's heading use
  the deployment's brand; the viewer's can't-show lines, the text-size note,
  the spaces too-old tip and the missing-folder error no longer name the app.

### Checks

- `tests/test_build_without_xcode.py`: no Xcode-only SwiftUI macro (`@Entry`,
  `@Previewable`, `#Preview`) in `app/Sources`; with `PORTICO_CLT_BUILD=1`,
  the real build with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`,
  run before each release.
- `BrandTests`: no string a person reads spells "Portico".

## v0.18.0 (2026-11-03)

Your own MCP servers and plugins reach Portico; Settings manages them; MCP
Apps show a tool's page in the chat. What is verified by tests is said so;
what is verified only on screen or with a real server is listed at the end,
under "Owed".

### What a person gets (app)

- **Your servers and plugins are Portico's too.** The MCP servers you set up
  in Claude Code at user scope and local scope, and your enabled plugins, now
  reach Portico's agent. The gateway passes them in; `setting_sources` is
  unchanged. A server the folder's `.mcp.json` ships still loads from that
  file, and one turned off stays off.
- **Settings → MCP servers.** Servers in groups: All your projects, "<brand>
  only" (with "Ships with <brand>"), Built into <brand>, From your Claude
  account. Turn off, reconnect, sign in and out, add (a web address or a
  program on the Mac) and remove, with a confirmation. Each tool shows "Runs
  without asking" or "Asks first" and the menu changes it. A server change
  applies to new chats; an open chat picks it up when it reconnects. A tool's
  setting applies at once.
- **Settings → Plugins.** Installed, Browse and marketplaces: turn on and
  off, install, update, configure, uninstall with a confirmation. A plugin
  that installs by running a command is refused ("Install it in Claude Code,
  where you can read the command first").
- **`/mcp` and `/plugin`** open those Settings tabs.
- **MCP Apps** (stable spec 2026-01-26). A tool's page is a card in the
  conversation, sandboxed per card. The three newest cards are live; older
  ones freeze with Reload. Open in viewer shows a fresh copy beside the
  chat. A call from a page asks first unless the tool only reads; a page can
  send a message (`ui/message`) and update what the agent knows
  (`ui/update-model-context`).
- **The agent's pointer.** In the viewer it glides to a click or a field
  before acting, pulses on a click, and fades out. With Reduce Motion it
  appears without gliding.
- **Tooltips are Portico's own**, centred under their control, after 0.8 s.

### Protocol and gateway

- Capabilities `mcp.v1` and `plugins.v1` (always) and `apps.v1` (gateway
  when `[apps] enabled`, and the app names it in its own hello; `app.*` frames go only
  to an app that did). New frames: `mcp.list`, `mcp.toggle`,
  `mcp.reconnect`, `mcp.remove`, `mcp.add`, `mcp.sign_in`, `mcp.sign_out`,
  `mcp.tool_policy`, `mcp.servers`; `plugins.list`, `plugins.set_enabled`,
  `plugins.install`, `plugins.uninstall`, `plugins.update`,
  `plugins.marketplace_add`, `plugins.marketplace_update`,
  `plugins.details`, `plugins.options`, `plugins.configure`,
  `plugins.state`; `app.open`, `app.result`, `app.cancelled`,
  `app.call_tool`, `app.call_result`, `app.message`, `app.context`,
  `app.reload`. `user.text` gains an optional `via`. All additive.
- New config: `[mcp] core = [...]` (servers in `.mcp.json` that are part of
  the deployment) and `[apps] enabled` (default true).
- Apps rely on private control requests of the Claude Code CLI, kept behind
  one seam in the gateway; `claude-agent-sdk` is pinned to `==0.2.174` and a
  test fails if the request is gone.
- Management runs the bundled CLI (`claude mcp`, `claude plugin`) with
  stdin closed; the person's `~/.claude.json` is written only through
  Claude Code's own commands, except the one `disabledMcpServers` key (the
  on/off switch), which the gateway rewrites in place, keeping every other key.
- Gateway version 0.18.0 to match the app.

### Small items

- **Deployments:** name the servers `.mcp.json` ships that belong to the
  deployment itself in `[mcp] core`. `[apps] enabled = false` turns MCP Apps
  off for every chat.
- **Not in v0.18:** `openai/*` aliases, `_meta.ui.domain`, app-provided
  tools, `ui/download-file`, `sampling`, and `resources/read` from a page
  beyond the tool's own `ui://` resource.

### Owed: verified only on screen

These have tests for their logic, not for what the person sees or for a
real server. They need a look in the running app:

- A real MCP App server added through Settings, its card in a chat, Open in
  viewer, and a write call asking first.
- `/mcp` and `/plugin`.
- Turning a shipped server off, then a new chat.
- Sign in on an OAuth server.
- The pointer on a click and on a type.
- Tooltips at a window edge.
- VoiceOver on a card and on tooltips.

## v0.17.0 (2026-11-02)

A field-fix release. What is verified by tests is said so; what is verified
only on screen is listed at the end, under "Owed".

### What a person gets (app)

- **The viewer takes web addresses, and the agent waits for the page.**
  `show_in_viewer` accepts an `http://` or `https://` address as well as a
  file. The app answers once the page has loaded, so the agent's next look
  or click acts on that page. A page that does not load says so: the viewer
  shows the failure (with its address), and the agent reads "Not loaded:
  <why>". After 10 s it reads "Shown; still loading." A failed load is tried
  again by the next show; showing a file again while a linked page is in
  front reloads the file.
- **Viewer calls run in order.** A conversation's viewer calls (the seven
  tools, `show_in_viewer`, and a caught `open`) run one at a time, in the
  order sent. Stop drops the ones still waiting; they answer "Stopped." and
  never act afterwards (controller ruling R-c2).
- **X closes the viewer and clears it.** The viewer holds one file; X closes
  it, and opened again from the toolbar it is empty. The toolbar's panel
  button only hides and shows the viewer, keeping what was there. Every file
  stays in the session list, which is how you open it again.
- **"This session".** The viewer's list is one row per file, newest first,
  headed "This session" in single presentation ("This chat" in multiple).
  The file-type glyph leads the row; a small trailing mark says who put it
  there: sparkles for made by the agent, an eye for opened by you (R-c4). A
  filter field shows past 12 files. The row of the file in front is
  highlighted even when a newer version of that file exists. A file you open
  again moves to the top.
- **Properties remember their fold.** A Markdown page's front-matter
  Properties stay open or folded the way you last left them, for every page.
  Until you first toggle one, the deployment's `[viewer] properties` decides
  (default folded).
- **Header icons are one size.** The viewer header's buttons, the Focus
  button and both X buttons draw at one size and weight. The Obsidian
  button wears Obsidian's own icon when an app handles `obsidian://`; with
  none installed it keeps its plain symbol and stays dimmed.
- **Marks on any visible text.** `viewer_mark` finds a ref, a listed name,
  or any text the person can see on the page, taking the innermost element
  that holds it. Badges of marks whose boxes touch no longer cover each
  other. A target that is not there is refused in words (see Protocol).
- **A stuck service says so, and offers Restart.** A service whose check
  exits 75 shows "stuck" with the check's first line, in its own colour, and
  floats above the healthy ones (down first, then stuck). The row has a
  visible Restart button (and the context-menu one) when the service has a
  `restart`.
- **No "Continues Session N" notice.** The gateway no longer puts that line
  in the transcript when a session continues.
- **Tooltips appear after 0.8 s** (the system default is longer). The app
  registers the delay as a default, so a value you have set yourself wins.
- **File pickers are sheets.** Choosing a folder or file in the input bar,
  Settings and the start screen opens a sheet on its window instead of a
  separate dialog. No second sheet opens while one is showing. One
  icon-only control found by the sweep (the start screen's remove-file x)
  now has a tooltip.
- **Portico's folder is chosen at install.** `bin/install --home DIR` (see
  Protocol and gateway).
- **Three v0.16 leftovers.** A thread whose turn you stopped is not marked
  "done" (no done card, no new-reply dot). An answered question reads
  "Your answer: <option>" to VoiceOver. The question card's preview pane
  follows the highlighted row, hover or keys, whichever you used last
  (R-c7); a hover alone never arms an answer: Return and digits act on the
  keyboard-focused option, and a digit or click takes the highlight back
  from the pointer.

### Protocol and gateway

- Capability `viewer.show.v1`. `viewer.act` gains `show`
  (`{artifact, location}`; for several files, the last). The app answers
  `viewer.result` `ok: true` once the page has loaded, at once when it will
  not put the file in front, and `ok: false` "Not loaded: <why>" on a
  failure. The gateway waits 10 s. The agent reads "Shown in the viewer.",
  "Not loaded: <why>", "Shown; still loading." or "Stopped.". A show draws no
  glow and ignores the "agent can see" switch (it reports only that a page
  loaded). An older app is sent nothing and the agent reads "Shown in the
  viewer." at once.
- Viewer calls are queued per conversation (above); argument refusals such
  as "Mark 1 to 9 things at a time." answer outside the queue (R-c1). The
  seven tool descriptions say calls run one at a time.
- Mark refusals, in the app's words (R-c5): a ref gets "The page reloaded
  since your last look; look again." when the page reloaded, else "The
  person used the page since your last look; look again.", else "No element
  e12 on this page; look again."; text gets "No visible text matches
  '<text>'". One sentence per target; all refused is `ok: false`.
- `services.stuck.v1`. `ServiceState` gains `stuck`; a check that exits 75
  (`EX_TEMPFAIL`, not 2; R-c6) is stuck, its `detail` the check's first
  non-empty line. A `status` command row may carry `"state": "up" | "down" |
  "stuck"` (`state` wins over `up`). A stuck service neither starts nor
  ends an outage. An app without the capability is sent "down".
- `[viewer] properties = "folded" | "open"` (default folded), sent as
  `viewer_defaults.properties`.
- `bin/install --home DIR` writes `PorticoHome` into the app's `Info.plist`
  and, once the install succeeds, `DIR` into the checkout's git-ignored
  `.portico-home`. One folder order everywhere (app, scripts, CLI, gateway):
  `PorticoHome` in `Info.plist`; `$PORTICO_HOME`; the folder `.portico-home`
  names (read only from a real checkout); `~/.portico`. A plain install bakes
  nothing; `$PORTICO_HOME` alone is used for the install but not baked.
  The folder is normalised (`~/` expanded, relative made absolute, trailing
  slash dropped) before it is compared or baked. `PORTICO_HOME_SOURCE`
  saying "the default" (what the app and gateway export when they fell
  back) counts as not chosen, so `.portico-home` still wins over it. An
  update started from the app (or `bin/update`) keeps `PorticoHome`. When
  `PORTICO_HOME` and `.portico-home` differ, the install warns and keeps
  `PORTICO_HOME`. An update the app starts (`PORTICO_HOME_SOURCE=Info.plist`)
  bakes the folder even when the checkout has no `.portico-home` (a
  re-clone), and the install writes `.portico-home` back so a later
  terminal `bin/update` keeps it. A remembered folder that has gone stops
  the install: "Portico's folder <path> is missing; reinstall with --home
  <path>".
- The app starts the gateway with `run --port 0 --state <folder>`, and the
  gateway exports `PORTICO_HOME` (and `PORTICO_HOME_SOURCE`) to its plug-ins
  and service checks. `bin/doctor` lists "home" second, naming the folder
  and where it came from. The index stores paths inside the folder as
  `@state/...` (old absolute paths still load), so moving the folder does
  not strand its spaces.
- A `PorticoHome` folder that has been deleted is not recreated: the Gateway
  row reads "stopped · Portico's folder <path> is missing; reinstall".
- Gateway version 0.17.0 to match the app.

### Small items

- **Deployments:** a service whose check should read as stuck must exit 75;
  exit 2 is down as before. A deployment that wants Portico's folder
  somewhere else installs with `--home`; a plug-in or check reads
  `$PORTICO_HOME`.
- **Not changed:** `.portico-home` is machine-local and git-ignored; moving a
  checkout means running `bin/install` (with `--home`, if it had one) again.
- **Downgrading:** `index.json` written by v0.17 keeps paths inside Portico's
  folder as `@state/...`; an older gateway can't read them, so don't downgrade
  the gateway in place.

### Owed: verified only on screen

These have tests for their logic, not for what the person sees. They need
a look in the running app:

- The live tooltip delay (0.8 s), and that a person's own tooltip-delay
  default wins over the registered one.
- The file pickers as sheets (the sheet attaches to the right window; no
  second one opens). Only the absence of a modal `runModal` call is tested.
- The missing-folder message on the Gateway row ("stopped · Portico's folder
  ... is missing; reinstall") after deleting the folder an app was
  installed with. The throw and the status are tested; the row is not
  looked at.
- An `https://` page in the viewer, a batch of viewer calls in order, marks
  on body text, X and the toolbar, header icons, "This session", the
  Properties fold across pages, no Continues notice, and a stuck service's
  Restart.
- The file picker still opens after an alert sheet is dismissed.
- An install with `--home` end to end on the real machine (it was run once
  into a scratch folder and scratch Applications folder during the build).
- Two cases from the v0.16 scroll rework remain unproven on screen (a
  restored offset during a trackpad gesture; a long streamed reply when the
  column narrows). Hosted scroll tests that need an unlocked display fail
  on a locked screen and pass on an unlocked one.

## v0.16.0 (2026-11-02)

### What a person gets (app)

- **Threads.** Main's agent can propose another conversation with the same
  agent, in the same folder, for a task that can run alongside: a card in
  Main titled "Start Thread 1" shows the brief with Start Thread 1 / Not now
  (the agent is told "Proposed as Thread 1; it opens if the person starts
  it."). Starting it opens the thread on
  that brief and leaves you in Main; the card then reads "Thread 1 started"
  with Go to Thread 1. A thread takes the brief and any files named with
  it, not Main's conversation ("It takes this brief, not this
  conversation."). There are at most two besides Main. At the limit the
  card offers "Close a thread to start another" and Close and start.
- **Moving between them.** ⌃0 is Main, ⌃1 and ⌃2 the threads (also in the
  View menu); ⌘0-⌘9 stay Work and the spaces. The sidebar's Conversations
  section is one list in a fixed order, Main, Thread 1, Thread 2, so
  nothing moves when you switch: Main (a speech bubble, "Session 4 ·
  Mobile login screen") and each thread (a branch, its title) on the same
  left edge, each with its state (working, needs you, new reply, last
  reply). The row you're in opens into its card: Context and its meter,
  then Log session and New for Main, or Log session and Close thread for
  a thread ("Close writes a summary to History"); the two buttons share a
  row when they fit and stack when they don't, so the list fits the
  sidebar at any text size. Click a row to switch to it. There is no
  toolbar button back to Main: the list says where you are. In a thread the
  first message is drawn as its brief ("BRIEF FROM MAIN · 2:05 PM").
  Buttons, cards and rows show no key glyph: the tooltip spells the key
  ("Go to Thread 1 (Control-1)"). With threads off, the sidebar is the
  single-session card as before.
  Close a working thread and it asks first. If the log step can't start, the
  card offers Close without logging.
- **A thread that needs you** shows "Needs you" on its sidebar row, and in
  Main a calling card ("Thread 2 has a question") with Go to Thread 2 and
  Later. The calling card shows in Main only.
- **A thread that finishes while you're elsewhere** shows Main a card
  "Thread 1 is done" with the first line of its last reply, Go to Thread 1
  and Dismiss, and its sidebar row an accent dot and "New reply" until you
  open it. Opening the thread clears both; Dismiss clears the card. A
  thread's question shows instead of its done card. Like the calling card,
  the app draws it: it never enters Main's transcript or its agent's
  context, and it does not come back after a restart.
- **Questions and permissions dock above the composer,** in the pattern of
  Claude's own: numbered options (1-4 on the keyboard, ↑/↓ and Return), the
  recommended option first, a pager for several questions ("1 of 2"), a
  "Something else" field, Skip, and × to dismiss. "Or reply directly..."
  sends what you type as an ordinary message and declines the question. A
  question card takes the keyboard when it appears only if the composer is
  empty or unfocused, so a Return you were typing is never an answer. A
  permission card has Allow once, Allow for this session and Deny; neither
  a stray Return nor a digit grants anything until you have moved the focus
  with an arrow or clicked a row (the pointer resting on a row does not
  count). The first arrow shows Allow once, and the highlighted row is
  always the one Return answers. There is no "Allow always". An answered
  question shows in the transcript as your reply: a bubble like a sent
  message, "Answer to: Which tone for step 2?" over the option you chose or
  the words you typed in full, one pair per question. A declined question
  keeps a one-line record ("Asked: Which tone for step 2? · Not answered").
  Both survive a restart.
- **The preview column needs an agent that sends previews.** An option's
  `preview` shows beside the options, rendered as Markdown. The CLI does not
  offer previews to an SDK agent (Portico sets nothing to change that), so
  most cards have none until an agent sends one.
- **New space is a dialog.** Name and "What do you want?", then Create; it
  sends "New space: <name>" and the words to Main (or starts the first
  session when there is no Main). Create is dimmed with the reason shown when
  Main is busy or no folder is set. The old prefill of the composer is gone.
- **Each conversation keeps its place.** Main, a thread or an earlier session
  reopens at the row and point you left it, and at the bottom if you were
  following. The transcript's scroll is now on `ScrollPosition`.
- **An outside site in a space** keeps its page when the space is re-read
  in the background, a failed link keeps its address (with its port) and Retry
  retries that link, and Back after a visit reads a revision that moved
  meanwhile.

### Protocol and gateway

- Capability `threads.v1`, in single presentation when `[threads] max` is
  above 0 (0 to 2, default 2; 0 turns threads off: no tool, no thread UI).
  `ChatSummary.thread` (`label, slot, parent, brief, files, opened_at`),
  `thread.proposal` (state frame), `thread.start`, `thread.dismiss`,
  `thread.close` (with `log: false` to close without a log step), and
  `hello.threads_max`. Additive: an older app sees threads as chats; an
  older gateway has no capability and the app shows no thread UI.
- Main's engine gets an in-process `open_thread` tool; a thread is a gateway
  chat that never renews (`thread.renew`). Main is the newest live chat
  without a `thread`, in the gateway and the app, whatever the capability.
  A folder change, or `max = 0` at start, closes open threads with their log
  steps.
- Questions: `Option.preview`, `card.answer` `{"declined": "skipped" |
  "dismissed" | "replied"}` (the agent reads the matching message), and
  `tool.finished.answers`, live and in replay, recorded per `tool_use_id`.
  `CardAsk.tool_use_id` is set on question cards. An answer with an empty
  `answers` map is treated as the "skipped" decline.
- **For plug-in and engine authors:** `EngineCallbacks.on_question` now
  receives `tool_use_id` (`on_question(questions, tool_use_id="")`); an owner
  with the old one-argument signature must add it.
- Gateway version 0.16.0 to match the app.

### Small items

- **A thread's "Allow for this session"** covers that thread only; its scope
  note says "until you start a new session" in Main and "until you close
  this thread" in a thread.
- **Three v0.15 strings** that named a particular cloud provider in the
  model-pricing note are now neutral.
- **Owed, and said plainly.** Two cases of the scroll rework are guard
  tests only, unproven pending an on-screen check: (2) SwiftUI restoring an offset during a trackpad
  gesture, and (3) a long streamed reply when the column narrows from 900 to
  640. The field report of "empty space under the
  conversation" (11-02, item 11) is not reproduced; guards added, and a
  diagnostic now logs it (next item).
- **If the blank space comes back,** please send the log line the app writes
  when it sees it (it logs once per occurrence, after a second of blank with
  no scrolling):
  `log show --predicate 'subsystem BEGINSWITH "dev.portico" AND category == "transcript"' --last 1h`.
  It names the chat, the document height, the clip bounds, the last row's
  frame, the scroll phase and whether the view was at the bottom edge.
- **Deployments:** ⌃1 and ⌃2 can be taken by macOS when "Switch to Desktop N"
  is on in Mission Control's keyboard shortcuts; turn those off, or use the
  View menu or the sidebar.

## v0.15.0 (2026-11-02)

### What a person gets (app)

- **The model in the status strip is a menu.** Choose from the same list
  `/model` shows in a terminal; the strip names your choice at once. Each
  chat's menu shows the model that chat runs on, and your choice carries to
  new sessions. The menu is dimmed while a reply runs ("Change the model
  after this reply") and while disconnected ("Not connected").
- **The list is there before the first message,** and Default names the
  model it runs ("Fable 5.1", not "Default"), in the strip and in its menu
  row. Until a list has ever arrived, the strip shows the name without a
  menu. Descriptions show no pricing (an API-key login adds it; it is
  wrong for other providers).
- **Text size.** Settings → Appearance has a Text size setting, under
  Appearance, which is now a pop-up. It scales the conversation, the
  sidebar (the Files tree's names and headers too), the menus and the
  viewer's Markdown together. ⌘+ and ⌘= make text bigger, ⌘- smaller;
  Actual Size has no shortcut (⌘0 stays Work).
- **Popovers read more clearly.** The glass stays, with a tint of the
  window behind the text, and their secondary text is a step darker (in
  light mode; lighter in dark). This covers the model menu, services,
  History, the space switcher, marks, the viewer menu, the mode chip and
  agent steps.
- **Earlier is now History,** a popover with one title filter. The sidebar
  starts under the traffic lights, in a band 36 pt tall.
- **The conversation stays at the newest message.** At the bottom, it stays
  there when a space or the viewer opens and closes, and follows new text
  only while you are at the bottom. Your own scroll (trackpad, wheel, keys) is
  respected; returning to the bottom resumes following.
  (Found on v0.14.0 too.)
- **A space shows an outside site.** The space header gives the site's
  address with the same note as Work, and offers Open externally in place
  of Refresh there. The header address follows in-page navigation; a
  `#fragment` shows only when it reads as a route.

### Protocol and gateway

- Two frames, `models` (the engine's own list, plus `current`: the model
  that chat runs on, absent for the default) and `model.set` (a value, or
  `"default"` or `null` for the deployment's default). Both sides announce
  `models.v1`; without it the strip stays plain text.
- `model.set` during a reply is refused with `chat.busy`, and a model not
  in the list with `model.unknown`. A choice the deployment stops offering
  is dropped at the next engine start, with a notice.
- The gateway reads the model list once when it starts (it connects to the
  CLI, reads its server info and disconnects, sending no message). If that
  fails or takes over 30 s it logs a warning and keeps the last list.
- Each `models` choice can carry `resolved_model`, the model id it runs.
  The field is optional, and an older app ignores it.
- Gateway version 0.15.0 to match the app.

### Small items

- **Open in Obsidian** is offered only for md, markdown, canvas, pdf and
  image files.
- **A mark on a page that didn't load** says "That page didn't load; the
  marks are kept for when it does."
- **The gateway checks mark items:** "Each mark needs a target, and a note
  of at most 60 characters."
- **A long space title shortens in the middle.**
- **The services test flake is fixed;** CJK input, 24-hour times and
  declined writes are now pinned by tests.

## v0.14.0 (2026-11-01)

### What a person gets (app)

- **The space switcher always shows.** With no spaces its menu lists Work,
  "No spaces yet" and New space…. Against a gateway too old for spaces,
  New space… is dimmed ("This Portico gateway is too old for spaces.").
  The gateway uses `<state dir>/spaces` when `[spaces] folder` is not
  set, creating it at start and advertising `spaces.v1` as for a
  configured folder.

- **The agent can point at things on a page.** After a critique, "show me
  all three" draws a numbered accent box with a short note on each part of
  the page, and scrolls to the first. Marks work on HTML files, Markdown,
  spaces and outside sites (including ones the agent may only look at). On
  an image, PDF, text file or table the agent says marks are for web
  pages. Marks sit on top of the page, change nothing in it and don't
  block clicks or scrolling.
- **Marks belong to their page.** Leaving a page hides its marks and
  coming back shows them. A new page's marks carry on the numbering (1-3
  here, then 4 on the next screen). A jump to a `#` heading hides nothing.
- **Kept until cleared or the session ends.** A click or Esc doesn't clear
  them. A new or resumed session starts with none.
- **A marks chip in the viewer header** ("4 marks · 2 pages"). It shows
  only while there are marks and opens a list grouped by page. Choose a
  mark to scroll to it, going to its page first if needed. Clear all marks
  is at the bottom; numbering then starts again at 1.
- **When the agent changes a marked page,** each mark is found again. One
  whose element is gone is listed dimmed as "not on the page now".
- **Show again on the conversation's Mark row** brings that call's marks
  back, going to their page first. Rows from a resumed session don't have
  it.
- **The viewer header gives way by measured fit,** not fixed widths. When
  it runs short: the Open buttons lose their words, the outside-site note
  shortens, the chip shortens ("4 marks", then "4"), then the title
  shortens in the middle. Focus and Collapse always stay.

### Protocol and gateway

- Two agent tools, `viewer_mark` (1-9 targets with optional notes of up to
  60 characters, `replace` to start over) and `viewer_clear_marks`, over
  `viewer.act` with the actions `mark` and `clear_marks`. They follow the
  other viewer tools: off with **Agent can see the viewer**, same timeout.
- The app announces `viewer.marks.v1`. With an older app both tools answer
  "This Portico can't show marks yet; it needs updating."
- `viewer_look` lists the marks in use, so the agent knows the numbers.
- Marks live in the app, per chat; the gateway keeps nothing. Gateway
  version 0.14.0 to match the app.

### From the v0.13 field report

- **`bin/update` stops the running gateway.** After moving to the new tag
  (or pulling main) it stops a gateway still running the old version and
  says "Stopped the running gateway (it was the old version); Portico
  starts the new one." With no gateway running it says nothing. If the
  install then fails, it says "update: install failed; the gateway was
  stopped. Fix the error above, then run bin/install."
- **The viewer divider is as easy to grab as the sidebar's.** Its 14 pt
  grip now sits wholly on the conversation side; the web page beside it
  had taken the half over it. The conversation's scrollers move in by as
  much while the viewer is open, so they stay draggable.
- **A brighter acting glow.** The line stays 3 pt at full accent; the glow
  is wider, stronger and more blurred, and its pulse runs 75-100% (was
  55-100%). Still steady with Reduce Motion.
- **"The person used the page since your last look."** When a click,
  typing, scroll-to or mark target isn't found and the person has clicked,
  pressed a key or scrolled on the page since the agent's last look, the
  agent hears "The person used the page since your last look; look
  again." instead of "Not found — look again" (a mark call that finds
  only some targets says it for the rest). The viewer is not locked; the
  person's input still wins. A ref from a page that reloaded or was
  replaced since the look says so: "The page reloaded since your last
  look; look again."
- **A space and back keeps the Work viewer as it was.** The Work page
  stays loaded under an open space, so going back to Work does not load
  it again: its scroll, what the person typed, and the refs of the
  agent's last look are all still there.
- **The conversation keeps its place across a space and back.** A
  scrolled-up conversation no longer jumps to the start of a remembered
  message when the column narrows and widens.
- **New space… fills the composer on screen.** On the welcome that
  continues the live session it went into that session's draft, which no
  composer there shows; on an earlier, read-only session it had no
  composer at all. It now fills the welcome's composer, or takes the
  person to the live session and fills its composer.
- **The services menu's Stop and Restart show for the whole row.** Only
  the row's words were the hover target; now the whole row is, and the
  buttons are drawn as the app's other small row actions.
- **A heading inside a clickable card clicks the card.** Click by text
  also matches headings, after buttons and links. When the heading sits in
  a clickable card (a link, a button, `[role=button]`, an element with a
  click handler or `cursor: pointer`), the heading is clicked and the
  click reaches the card as a person's would. Something holding other
  headings or covering most of the viewport (a list, a page, a dialog's
  backdrop) is not a card. Otherwise the answer is "That's a heading, not
  something to click; use its ref."
- **Subfolders of the spaces folder are ignored**, now a documented
  guarantee: only top-level `.md`, `.markdown`, `.html` and `.htm` files
  are spaces, and nothing inside a subfolder is listed or watched, so a
  deployment can keep a space's scripts in a same-named subfolder. Stated
  in PROTOCOL.md and pinned by tests.

## v0.13.0 (2026-10-31)

### What a person gets (app)

- **A quieter sign that the agent is using the viewer.** While it looks,
  clicks or types, a thin accent line and a soft glow sit around the page
  and pulse gently (steady with Reduce Motion). The header no longer says
  "Agent is using the viewer" or carries its own Stop; the message box's
  Stop stops the agent, as before, and the glow goes at once.
- **Tool rows close up.** Steps that follow each other sit together as one
  block; the space around the block is unchanged.
- **The agent's viewer steps fold into one row.** Two or more looks,
  clicks, typing, scrolls or backs in a row read "Used the viewer · 12
  steps" with the latest step, the count rising while it works. Open it to
  see each step. A refused or failed step marks the row red.
- **A resumed session opens at its newest message,** not near the top.
- **A page with no background shows white**, as in a browser. Pages that
  set their own colours look as they did.
- **An outside site's address in the viewer header.** When a link leaves
  the file, the header shows the site (for example `example.com/docs`) and
  whether the agent may only look and scroll there. Open externally opens
  the site.
- **More room before the space switcher** in the toolbar.
- **Settings is 20% shorter:** 700 × 640. A tab taller than that scrolls.
- **Typing while the agent works stays in the message box.** (Also in
  v0.12.0's tag.)

### Protocol and gateway

- No changes. Gateway version 0.13.0 to match the app.

## v0.12.0 (2026-10-31)

### What a person gets (app)

- **The agent sees the viewer you're looking at.** It can look at whatever
  is open (a web page, a Markdown file and its front matter, a table, a
  PDF, an image, a space) and, on web pages, click, type, scroll and go
  back. You watch it happen: the target is outlined for a moment first,
  the viewer header says "Agent is using the viewer" with a Stop button,
  and each action is a row in the conversation. Your own clicks and
  scrolling always win.
- **Outside websites are look-only** unless the deployment lists the site
  (see `[viewer] act_hosts`). Your own files and local test servers can
  always be used. The site is checked again at the moment of every click.
- **The agent checks HTML it creates.** After writing or changing an HTML
  page (with its Write/Edit tools or a shell command) it opens the page
  and looks before replying.
- **Spaces.** Pages the agent keeps up to date (a Brief, Meeting prep, or
  anything you ask for) are listed in a switcher in the toolbar: Work
  (⌘0), then each space (⌘1–⌘9), then New space…. A space opens beside the
  chat; × or ⌘0 goes back. A dot marks a space that changed since you
  last looked; with Portico in the background you get a notification.
  Right-click a space to rename or remove it (removing asks first and
  moves the file to the Trash). "Show me my brief" in the chat switches
  to it.
- **Settings is one 700 × 800 window** on every tab. General gains Viewer
  (open files automatically, with the five kinds in one row; Agent can
  see the viewer; Agent checks HTML it creates) and Spaces (Notify when a
  space is updated). Gateway puts its state and controls first.
- **Clear earlier sessions… left Settings.** It is now an admin command
  (`portico-gateway sessions clear`).
- **Conversation text is 15 pt** (code stays 14). The toolbar drops the
  chat title: sidebar toggle, brand, the space switcher, viewer toggle.
- **Small fixes.** The services menu's Gateway row shows Stop and Restart
  on hover. Changed-this-session rows in Bookmarks match the folder list,
  and stay visible while you filter.

### For deployments

- `[viewer] agent_can_see`, `agent_checks_html` (both default on; the
  person can change them in Settings) and `act_hosts` (host names the
  agent may click and type on, subdomains included; empty by default; not
  settable in the app). Example: `act_hosts = ["figma.com", "lovable.dev"]`.
- `[spaces] folder` (one Markdown or HTML file per space, named by front
  matter `title`, optional `icon` and `order`), `refresh` and `remove`
  commands (`$PORTICO_SPACE` = the space id). Portico schedules nothing;
  your heartbeat rewrites the files. An example space is in
  `examples/spaces/`. The spaces folder is one of the agent's own places.
- `portico-gateway sessions clear [--yes]` (refuses while a gateway runs).
- A memory count belongs in your `[deployment] status` row's `detail`
  (README has the example).
- Doctor prints which outside sites the agent can use.

### Gateway

- Five viewer tools beside `show_in_viewer`: `viewer_look` (image plus an
  outline of refs, page errors), `viewer_click`, `viewer_type`,
  `viewer_scroll`, `viewer_back`; 10 s per action.
- Inbound frames up to 16 MiB and an engine buffer of 32 MiB, so a
  full-size look image fits.
- Spaces folder scanned every 5 s; symlinked files are ignored; refresh
  and remove run off the connection's frame loop.

### Protocol (still version 1; additions only)

- App capability `viewer.v1`; `viewer.settings`, `viewer.act`,
  `viewer.result` (image `image/png` or `image/jpeg`).
- `hello.viewer_defaults`; gateway capabilities `spaces.v1`,
  `spaces.refresh`; app capability `spaces.v1`; `spaces.list`,
  `space.refresh`, `space.rename`, `space.remove`; `artifact.space`.
- `sessions.clear` is kept but the app no longer sends it.

## v0.11.0 (2026-10-30)

### What a person gets (app)

- **Opening a file keeps your place.** When the viewer opens (on its own
  or by hand) the conversation stays where it was: at the bottom it stays
  at the bottom, otherwise the same message stays at the top. It used to
  slide away as the narrower column wrapped every line again. The viewer
  panel eases in.
- **MCP tools read once, plainly.** A tool from an MCP server shows as
  "memory · query documents" (the server, then the tool's name with
  spaces), not its raw id twice.
- **The restart notice says why.** "Restart the gateway to apply" reads
  "Settings changed — restart the gateway to apply", still in the wait
  colour with a restart arrow, apart from Update available.
- **The notice keeps its words while there is room.** It folded to a bare
  icon whenever the strip left its fullest form (so whenever the viewer
  was open); now the strip's other words shrink first and the notice
  becomes an icon only when even the smallest strip has no room for it.
- **The live session follows the deployment's folder.** When
  `default_folder` changes, the next launch ends the session working in
  the old folder and starts one in the new one, and the conversation says
  why: "Started a new session in ~/… — the deployment's folder changed".
  A folder the person chose for a session is kept while `default_folder`
  stays the same.
- **Clear earlier sessions…** in Settings → General (single presentation;
  asks first) empties the list of ended sessions. The live session and
  every transcript on disk stay.
- **The welcome names the real next session.** With no sessions yet it
  said "Session 1" whatever the gateway's counter said; it now shows the
  number the session will get.
- **Folders.** The Files pane's "Folder" switch reads "Folders".
- **The session card says what its buttons do:** "Log writes it up · New
  starts fresh", not "Same as typing /log or /new".
- **Type while the agent works (item 74).** The composer stays usable
  during a turn and during the log step. A message sent then waits above
  the composer as a card, "Queued — sends at Acme's next step", with Edit
  (back into the composer) and Cancel; several wait in order. The gateway
  writes it into the turn when the agent's current step ends (its next
  tool result, never a subagent's), and it shows in the conversation as
  your message at that point; one still waiting when the turn ends goes
  as the next turn. During the log step it goes into the log step itself,
  so a rating typed while the close runs reaches it. While nothing is
  typed, the composer offers Stop alone, as before. **Stop gives queued
  messages back:** pressing Stop puts everything still waiting back in
  the composer, in order, with its files, ready to send or delete (as
  Claude Code does); one sent while the stop takes effect comes back too.
  Nothing waiting goes on its own after a stop.
- **Slash-command completion.** Typing `/` at the start of the composer
  (the conversation's or the welcome's) lists Portico's own `/log` and
  `/new`, then the agent's commands and skills with one-line
  descriptions, filtered as you type (names first, then descriptions).
  ↑/↓ move, Enter or Tab picks, Esc closes. The gateway sends the list as
  `chat.commands` when an engine starts and keeps the last one per folder
  (`commands.json`), so the welcome has it before the first engine runs.
  Arrows, Return and Tab with ⌘, ⌥, ⌃ or Shift held, and any key while
  an input method is composing, stay the text's.
- **A reading column (item 58).** Replies, tool rows, your messages, the
  composer (the welcome's too), its slash list and the queued cards share
  one centred column at most 768 pt wide; a narrower window uses all of
  it. Replies and tool rows take 92% of it; your message at most 70%,
  right-aligned.
- **Easier reading (item 73).** Replies and your messages are 16 pt
  regular (they were 13); bold is semibold and shows; list bullets and
  numbers are full-size in the text colour.
- **Quieter tool rows (item 59).** No fill or border until the pointer is
  on one; the tool's name in secondary text, what it touched in tertiary.
  The status icon keeps its colour, and a failed step's words follow on
  the row in red.
- **The composer's `+` and mic** light up in the same 28 pt box, 6 pt
  corners, as Send (item 72).

- **Front matter reads as Properties (item 68).** A Markdown file's YAML
  front matter shows as a quiet Properties block at the top of the
  viewer (keys and values; lists as small tags; a status with a dot),
  foldable to one line: "Properties · 4 — draft, Oct 28, 3 tags". It
  used to come out as text with its last line made a heading.
- **Open in Obsidian in the viewer (item 69)**, beside Open externally,
  for a file inside an Obsidian vault. When the viewer is narrow both
  are icons, their words in the tooltip.
- **The services menu, quieter (item 60).** One line per service with
  its dot; a second line only when it says something (the gateway's
  port, a check's detail, an error in red). One Restart all at the foot
  (the deployment's command for all its services, or the gateway when it
  has none). A row's own Restart, and the gateway's Stop or Start, moved
  to the row's right-click menu. The developer note at the foot is gone.
- **Context on the session card only (item 64).** The status strip
  keeps the model and the services.
- **Changed this session (item 70)** sits in the Folders list as its
  first section, its rows the same as the folders' rows, with the time
  each changed; five show, the rest behind "N more".
- **The empty Bookmarks tab (item 62)** says "No bookmarks yet." and how
  to add one, from the pane's left edge, without a second "Bookmarks"
  heading.

### For deployments

- **`[sessions] next_number = "<command>"`**: the command's stdout is the
  next session's number, run (`/bin/sh -c`, two seconds) when a new
  session starts, and once at start with no live session for the
  welcome. A failure, anything but a whole number, or a number Portico has
  already passed falls back to Portico's own counter, logged. See Session
  numbers in the README.

- **`[files] hide_session_folder = true`** (default `false`) leaves the
  session's own folder out of the Files pane (and quick open), for a
  deployment whose roots already cover it. It is still where the agent
  works; a file in it still shows. With no roots to show instead, the
  session's folder stays.

- **The engine finds `npx`, `node` and `uvx`.** Started from the app the
  gateway inherited launchd's bare PATH; with `login_shell_path = true`
  (the default) it now asks the person's login shell for its PATH and
  puts it first. A `PATH=` line in the env file goes first of all. See
  The engine's environment in the README.
- **`PORTICO_ATTENDED=1`** is in the environment of every engine started
  for a person's session (title generation never has it), so a
  deployment's start-up checks can tell someone is present.

### Gateway

- The index records the `default_folder` the gateway last ran with, so a
  change is told from a folder the person chose. An index from before
  v0.11 has none: a live session outside `default_folder` follows it once.
- **A file the agent writes outside the session opens no more.** A file
  opens on its own only inside the session's folder or the deployment's
  roots, the same rule `show_in_viewer` keeps; one written anywhere else
  (a scratch file in `/tmp`) is still listed in the viewer's history.
- **`doctor`** shows where the PATH came from and whether `node`, `npx`
  and `uvx` resolve, and counts `[deployment] status` rows as the
  services check.
- The agent's slash commands are kept per folder in `commands.json` in
  the state directory (the newest 20 folders).

### Protocol (still version 1; additions only)

- `hello` gains `hide_session_folder` (default `false`); `chat.list`
  gains `next_chat?`. New app → gateway `sessions.clear` (answered with
  `chat.list`; `sessions.not_single` in multiple presentation), offered by
  the `sessions.clear` capability in single presentation. Schema and
  examples regenerated.
- **Queued messages:** Capability `queue.v1` on both sides. A
  `message.send` during a turn is answered `chat.queued {id}` instead of
  `chat.busy`; `chat.queue {chat, items}` carries the list after every
  change and after `chat.live` on `chat.open`; `chat.unqueue {chat, id}`
  takes one back (`chat.not_queued` once it has gone). `turn.stop`
  empties the queue into `chat.queue`'s new `returned: [{id, text,
  attachments}]` (absent otherwise), for the app's composer; one queued
  while the stopped turn winds down is returned when it ends, never sent.
  `chat.stop` still drops the queue. An app or gateway without `queue.v1`
  behaves as in v0.10.
- **Slash commands:** new gateway → app `chat.commands {chat?, folder,
  commands: [{name, description, source?}]}`, sent when an engine starts
  and, for the kept lists, on every connection after `services.status`.
  An older app ignores it.

## v0.10.0 (2026-10-30)

### What a person gets (app)

- **Subagents in a tray.** When the agent starts subagents, the
  conversation shows one row where it started them ("Started 3 agents ·
  details in the tray below"), and a tray sits on the message box, as wide
  as it: "3 agents · 2 working" and the time, then a row per agent with its
  status, its description, its current step ("Reading transcripts/p11.md")
  and its step count ("9 steps", "14 steps · 1 m 52 s" once done). The
  chevron folds it to one line with the busiest agent's step. It folds
  itself when every agent is done and goes at the end of the turn.
- **An agent's steps.** Clicking an agent shows its steps (its tool rows,
  read-only) in a popover on the row. A subagent's tool rows are its steps,
  not the conversation's.
- **Workflows in a box.** A workflow takes the tray's place: its name,
  "phase 2 of 3 · 7 agents · 4 m 10 s", and Phases (a column per phase,
  its agents with their step and result, "…and N more" past what fits),
  Agents and Log. About 290 pt tall; drag its top edge to resize; the
  chevron folds it to its header line.
- **The record.** After the turn, the "Started N agents" row becomes a
  folded block per agent (✓ or ⚠, its description, "14 steps · 1 m 52 s"),
  which opens to its steps; a workflow leaves one block per phase. Opening
  the conversation again shows the same record.
- **Background work outlives its turn.** A background subagent, and a
  workflow, keep their tray or box after the turn ends and keep reporting
  while later turns run; they end on their own, not as "stopped" with the
  turn, and the turn's record fills in when they do. A foreground agent
  still open at the end of its turn reads stopped, as before.
- **A failed phase shows ⚠** in the workflow box and in the record. A
  workflow's end folds its box.
- **Stopping a chat ends its background work on screen.** When a chat
  stops or its session ends, any agent or workflow still shown as working
  reads stopped, so a workflow box can never stay up for good.
- **The agent's own follow-up is a turn.** When background work finishes
  and the agent answers on its own, that answer is a turn of its own, with
  no message bubble above it.
- **The viewer shows what the agent just made.** An artifact that opens
  (or one the person picks) now always wins over the one remembered at the
  last quit: it arrived while the welcome held the remembered one, or
  before a replay re-listed it, and the remembered one came back over it.
  **Open externally** stays in the viewer's header.
- **No repeated artifacts.** A reply that only names a file the chat
  already lists, unchanged since, no longer adds it to the viewer's history
  again (the agent's follow-up turns after background work named the same
  files over and over); a file written again still gets a new entry.
- **Plainer agent steps.** An agent's step no longer appears twice in a
  row, and its last step reads "Reporting back" instead of the engine's
  internal tool name.

### For deployments

- **The agent starts from Claude Code's system prompt.** New config
  `system_prompt = "claude_code" | "none"` (default `claude_code`) and
  `system_prompt_append` (a file of the deployment's, added after it, read
  at each engine start). Until v0.10 the gateway set none, so the agent ran
  on the SDK's empty prompt; `system_prompt = "none"` keeps that. Expect
  replies to change on upgrade: the agent now behaves as Claude Code does
  in a terminal. See "The agent's system prompt" in the README.
- The app's `hello` carries `capabilities: ["agents.v1"]` (new, optional).
  A gateway older than v0.10 refuses the field; the app then says hello
  again without it and works as before.
- The app reads `agent.started` (with `background`), `agent.progress`,
  `agent.finished`, `workflow.started` (sent again with the same `id`
  replaces its phases), `workflow.phase` (`pending|running|done|failed`),
  `workflow.finished` and `agent_id` on tool rows. An
  event it cannot read inside a `chat.history` is now skipped instead of
  failing the whole replay.

### Gateway

- **Subagents and workflows are reported.** The engine's task messages
  become `agent.started`, `agent.progress` and `agent.finished` for each
  subagent (its type, description, current step from its latest call,
  step count, elapsed seconds, outcome and the first line of its report),
  and `workflow.started`, `workflow.phase` and `workflow.finished` for a
  workflow, with its agents as `agent.*` frames carrying `workflow_id` and
  `phase`. Phases come from the engine's own workflow progress reports.
  A subagent's own tool calls are tool rows with `agent_id`. Everything is
  stamped, kept in the ring and replayed.
- Background subagents end on a terminal `task_updated` alone; a
  foreground one waits for the notification's summary, and one still open
  when the turn's result arrives is ended with it. Background work that
  reports after its turn is kept under the turn that started it.
- Shell and monitor tasks are not shown as agents.
- **Closing an engine ends its background work.** `chat.stop`, a stop's
  grace running out, a renewal, removing a chat, stopping the gateway, or
  the engine's process dying sends `agent.finished` / `workflow.finished`
  `stopped` for everything still open, instead of leaving it working.
- **A turn nobody sent.** When the engine speaks on its own after a
  background task finishes (a fresh init, text and a second result), the
  gateway runs it as a turn of its own: `turn.started` (no `user.text`),
  `chat.state working`, its artifacts, `turn.finished`, `idle`. Before, its
  result was a second `turn.finished` for the turn already over, and a send
  during it could be ended early by it. A send meanwhile is `chat.busy`. A
  turn's result now ends only that turn's foreground agents.
- `workflow.finished` carries the summary from the notification that
  follows the terminal `task_updated` (held up to 5 seconds for it).
- **`open` follows the shell's directory.** A relative path in a caught
  `open` resolves against the Bash tool's working directory (the hook
  input's `cwd`), not the chat folder; without one, only absolute paths
  are caught. `show_in_viewer` still takes paths relative to the folder.
- A file a background subagent writes while no turn runs is reported when
  the write finishes (`artifact.created`, `open` as a turn would decide).
- The ring keeps only each agent's latest `agent.progress`, so progress
  frames no longer push the conversation out of the ring.
- A subagent's own subagent (`spawn_depth` 2+) is no longer reported as a
  new top-level batch; it shows as its parent's `Agent` step.
- **`show_in_viewer`.** The agent gets an in-process tool that shows a
  file in the viewer at once (`artifact.created`, `open: true`): a viewable
  file inside the session's folder or a configured root, otherwise a clear
  refusal. Allowed outright, so no permission card in any mode. One line
  is appended to the agent's system prompt (the SDK's default, which is
  empty) telling it to use the tool rather than `open` or a browser.
- **A plain `open <file>` is shown, not run.** A `PreToolUse` hook on
  `Bash` catches `open <path> [<path> …]` of such files, denies it with
  "Shown in Portico's viewer instead of opening it." and shows the files.
  Flags, URLs, globs, chains and files outside the folders run as before.
  Hooks run in every permission mode, auto included.
- A file shown during a turn is not reported again at the turn's end, and
  nothing older opens over it.
- **A file the reply only names no longer takes `open`.** One unchanged
  since the turn began is listed with `open: false`; before, a reply that
  named an earlier page after the new one opened the earlier page.

### Protocol (still version 1; additions only)

- `hello` from the app gains `capabilities: [string]`; `agents.v1` asks
  for the new frames. The gateway's `hello.capabilities` lists `agents.v1`.
- An app without `agents.v1` is sent none of the new frames and no tool
  row with `agent_id`, live or in `chat.history`: an older app sees the
  conversation as before.
- New frames `agent.started`, `agent.progress`, `agent.finished`,
  `workflow.started` (sent again when its phases become known),
  `workflow.phase`, `workflow.finished`; `agent_id?` on `tool.started` and
  `tool.finished`. Schema and examples regenerated.
- A gateway before v0.10 refuses a `hello` with `capabilities` (it is
  strict about fields).
- No new frame or field for the review fixes; documented behaviour:
  `turn.started` without `user.text` for a turn nobody sent; finishes sent
  for open work when an engine closes (and the app's backstop on `chat.state
  stopped` / `session.renewed`); only the latest `agent.progress` per agent
  kept in the ring (skipped `seq`s, never `truncated` for it).

## v0.9.0 (2026-10-29)

### What a person gets (app)

- **`[TTS: …]` counts too.** The shorthand some agents already write is
  one spoken part, the same as `[TTS]…[/TTS]`; its marker is hidden too.
- **Talk to the message box.** A mic in the conversation's and the
  welcome's message box: press it and speak, and your words appear as
  they are recognised, after what you had typed; press again or Esc to
  stop. Transcription is on-device (`SpeechAnalyzer`, macOS 26). The first
  press asks for the microphone and speech recognition. "Send when I stop
  talking" sends on stop (off by default); an optional hold-to-talk key
  (Hold Right Option; none by default). Sending, typing into the box, or
  leaving it (another conversation, Document View, closing the window)
  ends the talk without sending; your typing is never overwritten. A key
  typed while holding the hold-to-talk key cancels that talk.
- **Read aloud, behind a flag (off by default).** The voices apps can use
  still sound dated, so Read aloud and Settings › Voice › Listen are hidden
  until `defaults write dev.portico.portico voice.readAloudAvailable -bool YES`.
  When on: every reply has Read aloud beside Copy, on hover; Stop
  reading while it speaks, and Esc stops. Code blocks and tables are never
  read ("See the code below.", "See the table below."); links are read as
  their text. When the reply has `[TTS]…[/TTS]` parts, only they are read.
- **`[TTS]` tags never show.** The text inside them reads as part of the
  reply, and Copy leaves the tags out. Inside code blocks and inline code they
  are the code's own text: shown, copied and never read as a part.
- **Settings › Voice** (between Gateway and Appearance): Talk (voice input,
  send when I stop talking, hold-to-talk key) and Listen (Read aloud, the
  voice, including your Personal Voice once allowed there, and the speed,
  with a sample).

### For deployments

- The app bundle's Info.plist carries `NSMicrophoneUsageDescription` and
  `NSSpeechRecognitionUsageDescription`. A `swift run` build has neither, so
  voice input there says it needs the installed app instead of asking.
- The README's Voice section has a suggested system-prompt instruction for
  `[TTS]` parts. No protocol or gateway change.

- **Settings from the sidebar.** The bottom of the sidebar shows a round
  initial and your first name (from the account's full name, as the
  welcome greeting), with a gear on the right that opens Settings, the
  same window as ⌘,. With no name set it shows a person glyph.
- **"When Portico quits" lives in Settings › Gateway**, moved from
  General, with clearer choices: "Keep the gateway and its services
  running" (the default) or "Stop the gateway and its services", which
  saves battery and runs the deployment's stop command first. The
  behaviour and saved choice are unchanged.

## v0.8.0 (2026-10-29)

### What a person gets (app)

- **The welcome shows on its own.** An artifact that was showing at quit
  no longer opens beside the welcome; it comes back when you go into the
  conversation (View Session N, a send from the welcome, or picking the
  session). Quitting from the welcome keeps it for next time.
- **Gateway controls in the services menu.** The Gateway row has Stop
  while the gateway runs, Start while it doesn't, and always Restart: the
  same actions as Settings › Gateway. Restart stops the gateway and starts
  it again, so a config change no longer needs a terminal. Settings ›
  Gateway now always offers Restart too.
- **Stop and Restart ask first during a turn**: "A turn is running in
  Session 3. Restart anyway?" (several sessions are named together). The
  status strip's Restart for a stale config asks the same way.
- **Restart all services.** When the deployment has one restart command
  (`services.restart_all` in `hello.capabilities`), the services menu ends
  with Restart all services. It asks first, sends `services.restart_all`,
  spins until a fresh `services.status`, and shows the gateway's reason
  under it when an `error` comes back for the request (the gateway sends
  that status first, then the error: the reason still shows).
- **A row's Restart says why it failed**: the gateway's reason (an `error`
  for that request) shows under the row, tinted like a down row, until the
  next try or a new gateway. A row's Restart waits while Restart all
  services runs.
- **The Gateway row's Restart waits while the gateway is starting**, as
  Start does.
- **Generated titles need nothing new in the app**: a title that changes
  in a later `chat.list` updates the Earlier row, the session card and the
  divider (tested).

- **A down service says when on the date rule.** "not responding since
  17:28" (the gateway's own clock, no day) now reads "not responding since
  today, 5:28 PM", from the service's `since`; any gateway version.

### Gateway

- **Generated session titles.** After a session's first turn finishes
  `done`, the gateway asks a small model for a title of at most six words
  (from the first message and the first 500 characters of the reply),
  stores it on the session and sends `chat.list`. The call goes through
  the Agent SDK's one-shot `query` to the agent's own provider and
  credentials (the gateway's environment plus the `env` blocks of the
  settings files the agent reads, `setting_sources`; the files themselves
  are not loaded, so no hooks, servers or instructions): one turn, no
  tools, from the state directory, twenty seconds at most, in the
  background (it never holds up or fails a turn). The first line stays
  until it arrives, and for good when the call fails. The default model is the alias `haiku`, the
  provider's small model (a hosted provider maps it with
  `ANTHROPIC_DEFAULT_HAIKU_MODEL`); `title_model` overrides it. `titles =
  "first_line"` makes no extra call. A log step's turn, an unknown
  command's empty turn, a session with an alias and a restored session
  are never titled; a generated title is never replaced. A session whose
  first message was an unknown command is titled from the first message
  that reaches the agent.
- **One restart and one status for the whole deployment.** New optional
  `[deployment]` with `restart` and `status` commands. `status` prints
  `{"services": [{"id", "name", "up", "detail"?}]}` on stdout (its
  stderr is kept apart and only names the reason when it fails) and,
  when set, replaces the `[[services]]` checks (rows keep their Restart from a
  `[[services]]` entry with the same id); a status that fails or prints
  something else is one row saying so, with the reason. `restart` is run
  by the new request `services.restart_all`, advertised as the
  `services.restart_all` capability in `hello`; the next
  `services.status` (none goes out meanwhile) is the answer, plus `error
  code=services.restart_failed` when it failed. A `service.restart` sent
  while it runs is refused with `services.busy`. A single service whose
  restart command fails now answers `services.restart_failed` with the
  reason too (after its fresh status), so the menu can say why. Plug-ins can provide both
  with the new hooks `services_status()` and `restart_services()`, which
  take precedence over the config.
- Protocol: additive only (a new request an older app never sends, a new
  capability string, a title that changes once in `chat.list`, an
  existing error code on `service.restart`). Schema and examples
  re-exported.

## v0.7.0 (2026-10-29)

### What a person gets (app)

- **Times say which day, in your own clock.** One rule everywhere a time
  is shown, on the Mac's locale and 12/24-hour setting: within the hour
  "just now" or "12 min ago" (kept current); then "today, 9:14 AM",
  "yesterday, 4:12 PM", "Oct 27, 4:12 PM", "Oct 27, 2025, 4:12 PM". The
  session card ("Started today, 9:14 AM"), the welcome line ("Continuing
  Session 15 · started today, 8:47 AM · last reply 6 min ago"), the ended
  bar and the logged line use it; the Earlier list and Changed this
  session show a compact form ("12 min ago", "10:30 AM", "Yesterday",
  "Oct 27") with the full date and time on hover. The card's age ("38 m")
  is a duration and stays.
- **View Session N and Start a new session are buttons**: small bordered
  ones the size of the suggestion chips, with hover and a pointing hand.
- **A square brand icon is drawn rounded** on the welcome and in the
  sidebar header (the macOS icon shape, corners about 22 % of the side);
  an icon whose corners are already transparent is drawn as given.
  The icon is read and its shape tested once per version of the file,
  not on every redraw (each streamed word redrew it from disk before).
- **A send whose engine could not start is not "last reply"**: a turn that
  ends `error` before the agent said or did anything leaves the welcome's
  "last reply" where it was.

- **A Log session before New counts.** The divider over the next session
  said "not logged" when the session had been logged with Log session and
  then ended with New; it now says "logged" with the time of that log.

- **A header image in the toolbar.** New optional `brand.header_image`
  (absolute path; SVG or PDF stays sharp, a PNG at least 84 px tall): the
  toolbar shows it 28 pt tall in place of the mark and the app name, at the
  image's own proportions (capped at 200 pt wide), never stretched. Unset,
  the toolbar is unchanged. Sent in `hello.brand`; an older app ignores it.

### What a person gets (gateway)

- **The first send shows at once.** The gateway sends `turn.started`, the
  `user.text` echo and `chat.state working` before it starts or resumes the
  agent's engine, so after a gateway restart the message and "Working"
  appear immediately instead of after the engine's 5–10 s start. An engine
  that cannot start ends the turn `error` and answers `engine.start_failed`
  (or `lifecycle.before_first_chat_failed`), as a refused send does; a
  `turn.stop` while it starts ends the turn stopped without sending.
- **Stop works while the engine starts.** The start and the send run after
  the echo while the gateway keeps reading frames, so Stop (`turn.stop`,
  `chat.stop`) takes effect at once instead of after the 5–10 s start. A
  refusal from the start still reaches the app as an `error` with the
  send's `id`. A chat stopped or removed while its engine starts stays as
  it was left: a start that then fails sends no second `turn.finished`,
  no `idle`, and no frames for a removed chat.
- **A turn that never reached the agent is not work.** One whose engine
  could not start, or that was stopped before its send, leaves
  `last_reply` and `unlogged` as they were.
- **Log session and New are recorded in the conversation** as `chat.notice`
  lines, kept in the ring so a replay shows them: "Log session — running
  the log step" at once, then "Session logged" or "The log step didn't
  finish; the session isn't logged"; "New — logging, then ending this
  session" (or "New — ending this session"), then "Session ended ·
  continues in Session M", and "Continues Session N" first in the next
  session. `/log` and `/new` in the composer send the same requests and get
  the same lines. A refused command (busy, ended, no log step) writes none.
  A chat restored after a gateway restart, which replays from the engine's
  transcript, gets this run's lines back in after the turns they followed;
  only lines from before the restart are lost.
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
