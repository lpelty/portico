# Changelog

## v0.17.0 (unreleased)

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
- **X closes the file.** The X in the viewer header closes the file in front
  and shows the next one that is still open; with none left the viewer
  hides. The toolbar's panel button only hides the viewer. A file you close
  stays in the session list and comes back when you open it again.
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
  `PORTICO_HOME`.
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
- **Doctor started from the app** before this release reported its folder
  as "from PORTICO_HOME"; it now reads the app's own source.

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
