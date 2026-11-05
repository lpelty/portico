# Portico

One native Mac front for a local coding agent. A SwiftUI app talks a small,
versioned protocol over a loopback WebSocket to a reference gateway written
in Python on the Claude Agent SDK. The gateway owns the agent session,
numbers chats, forwards every permission and question to the app as a card,
detects the files and URLs the agent produces, and replays history on
reattach. The app is a pure protocol client: a sidebar of chats and files, a
conversation pane with inline cards, a viewer, a status strip, and settings.
The protocol in `protocol/` is the authority a deployment builds against.

## Run it

Requirements: macOS 15, the Command Line Tools (`xcode-select --install`;
Xcode is not needed), `uv` (it brings Python 3.13), and a provider
credential for the agent.

```sh
git clone <this repo> ~/dev-projects/portico && cd ~/dev-projects/portico
bin/install                      # prerequisites, gateway (uv sync), app (release build) -> ~/Applications/Portico.app
bin/install --home ~/acme/portico   # the same, with Portico's folder (config, token, index, log) kept there
bin/doctor                       # one line per check; tells you if a credential is missing
open ~/Applications/Portico.app  # the app starts the gateway itself
```

**What `bin/install` does.** It checks the prerequisites first and stops in
plain words when one is missing (nothing is installed then). It builds the
app with the default macOS SDK; when that SDK does not compile it (a macOS
beta's newest SDK can fail on SwiftUI's `@State`), it retries with each other
installed `MacOSX*.sdk`, newest first, and says which one worked; compiler
output is shown only when every SDK fails. `PORTICO_SDKROOT=<path to an
.sdk>` builds with that SDK only. It then assembles `<brand.name>.app` in
`~/Applications` (`PORTICO_APP_DIR` to put it elsewhere): the release binary,
an icon made from `brand.app_icon` (Portico's own when unset), this
checkout's `bin/portico-gateway` recorded in `Info.plist` as
`PorticoGatewayBin`, signed locally (`codesign -s -`). An existing app of the
same name is replaced. Stock macOS tools only (`sips`, `iconutil`,
`codesign`, and `swift` from the Command Line Tools for the icon). The app
keeps using this checkout: move or delete the checkout and run `bin/install`
again from its new place.

**Portico's folder (v0.17).** `bin/install --home DIR` keeps config, token,
index and log in `DIR` (made, with any missing folder above it, mode 0700;
`~/` and a relative path are expanded, a trailing slash dropped; a `DIR`
that is a file stops the install before anything runs). It is written into
the app's `Info.plist` as `PorticoHome` and, once the install has succeeded,
into this checkout's git-ignored `.portico-home`, so `bin/update` and the
app's own Update keep it. Everything finds the folder in the same order:
the app's `PorticoHome`; `$PORTICO_HOME`; the folder `.portico-home` names
(read only from a real checkout); `~/.portico`. A plain `bin/install` writes
nothing into the app, and `$PORTICO_HOME` alone is used for the install but
not baked in. An app whose `PorticoHome` folder has been deleted says
"Portico's folder <path> is missing; reinstall" on the Gateway row instead
of making a new one. `bin/doctor` names the folder and which of these it
came from.

The config is read before the build. A config that does not load (a
`[brand]` without `agent_name`, a relative `app_icon`, a typo'd key) stops
the install with the gateway's reason; nothing is built or installed. A key
that is simply unset falls back to Portico's own.

**The app icon.** `brand.app_icon` is a 1024×1024 PNG. A full-bleed square
(the artwork reaching every edge, opaque corners) is put on macOS's app-icon
grid for you: an 824-pixel body with continuous rounded corners, centred with
a 100-pixel margin, and a soft drop shadow, so it sits in the Dock like every
other app. A PNG whose corners are already transparent is taken as already
shaped and used as given; draw it on the same grid. For the macOS 26 look,
compile an Icon Composer `.icon` to an asset catalog elsewhere (Xcode's
`actool` makes `Assets.car`; Portico does not need Xcode and does not compile
it) and set `brand.app_icon_assets` to that `Assets.car` and
`brand.app_icon_name` to the icon's name in it: `bin/install` copies the
catalog into the bundle and sets `CFBundleIconName`, and the `.icns` made
from `app_icon` stays as the fallback for older macOS. Set both or neither;
one without the other, or a catalog that is not there, is skipped with a
warning.

`bin/doctor` names the Command Line Tools version, the Swift and uv in use,
the macOS SDK the app was built with, and whether the installed
`claude-agent-sdk` is the version `gateway/uv.lock` pins.

For development, `bin/portico-gateway run` (prints `PORTICO_READY
port=<n>`) and `cd app && swift run` still work; the app finds a running
gateway, or starts one itself. In the app: **New Chat**,
pick a folder, type, cmd-return. The agent works in that folder with the
folder's own `.claude/` settings and hooks in force.

**Credential.** Auth and provider come from the environment only; nothing in
this repo names one. Export the variable the agent engine reads in your
shell, or put `KEY=value` lines in `~/.portico/env` (mode 0600), which the
gateway reads itself before `run` and `doctor`. Values are literal: the file
is never sourced by a shell, nothing is expanded (`$HOME` stays `$HOME`),
quotes are optional (`'...'` or `"..."`), a comment needs a blank before its
`#`, and a variable already set in the shell wins. `bin/doctor` says whether
a credential is present, and names (by line number, never by content) any
line of that file that is not `KEY=value`; such a file is not loaded until it
is fixed.

## Where things live

| What | Where |
|---|---|
| State: token, ledger, index, lock, gateway log, the agent's last command lists (`commands.json`) | `~/.portico/` (v0.17: `bin/install --home DIR` or `PORTICO_HOME` moves it; see Portico's folder) |
| Config | `~/.portico/config.toml` (optional; defaults apply when absent) |
| Credential file | `~/.portico/env` (optional) |
| App settings (auto-open, quit behaviour, appearance, gateway address and token file overrides) | the app's Settings window, stored in `UserDefaults` |

`config.toml` keys, all optional:

```toml
setting_sources = ["project"]   # never empty: [] drops the folder's instructions and hooks
before_first_chat = "bin/prepare"   # run once per launch before the first engine starts
on_stop = "bin/cleanup"             # run on the way out
command_timeout_seconds = 120       # at least 1
default_folder = "/Users/me/work"
card_hold_seconds = 600             # a card with no app attached waits this long, then is denied; 0 = deny at once
history_buffer = 2000               # events kept per chat for reattach; at least 1
presentation = "single"             # the default: one live session at a time; "multiple": a list of chats
permission_mode = "auto"            # a new session's mode: "auto" (the engine's classifier decides),
                                    # "acceptEdits" (file edits allowed), "default" (ask each time)
log_prompt = "/session-close"       # the log step (Log session, /log, and a renewal first); unset = no log step
plugins = ["my_deployment_plugin"]  # plug-in modules, imported at start (see Plug-ins)
plugin_paths = ["~/portico-plugins"] # absolute directories put on the import path for them
services_interval_seconds = 30      # how often the services below are checked; at least 5
titles = "generated"                # the default: after a session's first clean turn, a small model names it
                                    # (six words at most; the first line until then, and if the call fails);
                                    # "first_line": the first line of the first message, no extra model call
title_model = "my-small-model"      # optional: the model for titles; default "haiku", the provider's small model
system_prompt = "claude_code"       # the default: Claude Code's own system prompt, so the agent behaves as in a
                                    # terminal; "none": the SDK's empty prompt (as before v0.10). See Showing
                                    # the agent's work and The agent's system prompt
system_prompt_append = "~/my-deployment/prompt.md" # optional absolute path: the deployment's text, after it
login_shell_path = true             # the default: the engine gets the person's login-shell PATH first (see
                                    # The engine's environment); false keeps the PATH the gateway inherited

[brand]
name = "Portico"
agent_name = "Agent"
accent = "#3B6EF5"                  # optional CSS hex
icon = "/path/to/icon.png"          # optional; may be a flat square: Portico rounds it in the macOS icon shape
                                    # (an image whose corners are already transparent is drawn as given)
header_image = "/path/to/lockup.svg" # optional; replaces the mark and the name in the toolbar, 28 pt tall,
                                    # width from the image's shape (SVG or PDF stays sharp; a PNG at least 84 px tall)
version = "0.40.2"                  # optional: the deployment's version; the About panel shows it in place of the app's
about = """App {app_version} · Built {built}
Questions: help@example.com"""      # optional: the About panel's text under the version; {app_version} and {built}
                                    # are filled in, web and email addresses become links, "" shows nothing. Unset:
                                    # "App <version> · Built <date>" with version set, else "Built <date>"
app_icon = "~/icons/app.png"        # optional 1024x1024 PNG for the .app bundle (bin/install); never sent to the app
app_icon_assets = "~/icons/Assets.car" # optional precompiled asset catalog (macOS 26 icon); with app_icon_name
app_icon_name = "AppIcon"           # the icon's name inside app_icon_assets; neither is sent to the app

[update]                            # optional: the deployment's own update commands, run with /bin/sh -c
check = "my-tool update --check"    # exit 0 and print the version when an update is available
run = "my-tool update"              # performs it; the app's "Update available" runs it through portico-gateway update

[deployment]                        # optional (v0.8): one restart and one status for all the services
restart = "my-tool restart-all"     # /bin/sh -c, bounded by command_timeout_seconds; exit 0 = done;
                                    # the services menu's Restart all runs it (without it,
                                    # Restart all restarts the gateway)
status = "my-tool status --json"    # prints {"services": [{"id", "name", "state": "up"|"down"|"stuck" (or "up": true|false), "detail"?}]} on stdout
                                    # (stderr is not read as JSON; it only names the reason when it fails);
                                    # when set, its rows replace the [[services]] checks; a row's
                                    # context menu offers Restart when a [[services]] entry with the
                                    # same id gives one
```

A service is **stuck** when its check exits 75 (`EX_TEMPFAIL`): running but not
working. The row says "stuck" with the check's first line of output, and the
row offers Restart when the service has a `restart` (a status row can say
`"state": "stuck"` too). An app without `services.stuck.v1` is told "down".

A row's `detail` is shown while the row is up, so a count worth
spot-checking over time (a memory count, say) goes there. The status
command prints it in the row, and the app receives it as
`services.status` row `{"id": "memory", "name": "Memory", "state": "up",
"detail": "71,946 memories"}`:

```json
{"services": [{"id": "memory", "name": "Memory", "up": true, "detail": "71,946 memories"}]}
```

```toml

[[actions]]                         # buttons in the input bar; each sends its text
label = "Review"
text = "/review"

[[services]]                        # what the deployment depends on, shown in the app's services menu
id = "memory"                       # unique, lowercase letters, digits and dashes
name = "Memory"
check = "curl -sf http://localhost:8888/health"   # /bin/sh -c; exit 0 = up, 75 = stuck, other = down
restart = "my-tool restart memory"  # optional: the menu offers Restart
up_detail = "recall and capture"    # optional: shown while it is up
timeout_seconds = 10                # optional, default 10, at least 1: the check is killed after this
                                    # (a restart is bounded by command_timeout_seconds)

[[roots]]                           # folders the files pane can browse
name = "projects"
path = "~/projects"                 # absolute; a leading ~ is expanded

[sessions]                          # optional (v0.11)
next_number = "acme-sessions next"  # /bin/sh -c; stdout is the next session's number (see Session numbers)
lock_folder = false                 # v0.19: true fixes "Works in" to the deployment's folder; Settings shows
                                    # "Set by <brand>" and a person can't pick another (their own Files folders still work)

[threads]                           # optional (v0.16): threads beside Main (single presentation only)
max = 2                             # 0 to 2, default 2; 0 turns threads off (no tool, no thread UI)

[files]                             # optional (v0.11): the Files pane
hide_session_folder = false         # true: the pane lists only the [[roots]], not the session's own folder
                                    # (it is still where the agent works, and a file in it still shows)

[viewer]                            # optional (v0.12): the agent's view of the viewer
agent_can_see = true                # default for Settings > Agent can see the viewer (look, scroll, click, type)
agent_checks_html = true            # default for Settings > Agent checks HTML it creates
act_hosts = ["figma.com", "lovable.dev"] # outside sites the agent may click and type on; ships empty (see below)
properties = "folded"               # v0.17: "folded" or "open", how a Markdown page's front-matter Properties start;
                                    # the person's own fold, once made, is remembered and wins

[links]                             # optional (v0.19): link chips in the person's messages
sites = { "tracker.acme.example" = "Acme Tracker" }  # host (or a parent domain) -> the name the chip shows;
                                    # adds to the built-in Slack, Google Docs/Sheets/Slides, GitHub, Figma and Notion

[apps]                              # optional (v0.18): MCP Apps, a tool's page shown in the chat
enabled = true                      # the default; false keeps every tool a plain tool row

[mcp]                               # optional (v0.18): MCP servers
core = ["acme-tracker"]             # servers in the folder's .mcp.json that are part of the deployment itself;
                                    # Settings lists them as "Built into <brand>", not as shipped servers a person may turn off

[spaces]                            # optional (v0.12): files the agent keeps current, in the app's switcher
folder = "~/Spaces"                 # must exist; one Markdown or HTML file per space. Unset: <state dir>/spaces, created at start
refresh = "my-tool refresh-space"   # optional: /bin/sh -c, 30 s, $PORTICO_SPACE = the space's id; the app offers Refresh
remove = "my-tool forget-space"     # optional: runs after the file is moved to the Trash; same environment
```

A title call goes through the Agent SDK to the same provider, with the
same credentials, as the agent: the gateway's environment plus the `env`
blocks of the settings files the agent reads (`setting_sources`: user,
then the session folder's project and local settings). The files
themselves are not loaded, so the call runs none of their hooks, servers
or instructions: one turn, no tools, from the state directory, given
twenty seconds. A provider set up through another settings key (an API
key helper, a cloud credential refresh) reaches the agent but not the
title call; put what it needs in `env`, or set `titles = "first_line"`.
A session that already has an alias is not titled, and a generated title
is never replaced.

A status command that fails, times out or prints something else becomes
one row in the menu, "status command failed · <reason>".

The gateway reads `config.toml` once, at start. Change it, and the app's
status strip and Settings say "Settings changed — restart the gateway to
apply" (`bin/doctor` says the gateway needs a restart):
`bin/portico-gateway stop`, and the app starts a fresh one.

## One session at a time

By default (`presentation = "single"`) the app shows one live session
instead of a list of chats. A session is a chat: numbered, in one folder, with its
history and artifacts. **Log and start new** (or `/new` in the composer)
sends `session.renew`: the gateway runs the deployment's log step in the
ending session as an ordinary turn (its cards come to the app as usual),
marks the session ended (and logged when that turn finished cleanly),
then opens the next number in the same folder with the ended one as its
parent. Ended sessions stay listed, read-only.

**Log session** (or `/log`) runs the same log step in the live session
without ending it (`session.log`). Each session's summary carries when it
was last logged and whether it has work since (`unlogged`), so New asks
"log first?" only when something would be lost.

Both are recorded in the conversation as quiet lines, at once and again
when they finish: "Log session — running the log step", then "Session
logged" (or "The log step didn't finish; the session isn't logged");
"New — logging, then ending this session" (or "New — ending this
session"), then "Session ended · continues in Session M" (v0.17: the next
session no longer opens with a "Continues Session N" line). A replay shows them.

The log step is `log_prompt`, sent to the agent as a message — so the
agent logs itself with the command or skill its folder already has. A
plug-in's `on_renew` replaces it. With neither, renewing just ends the
session and opens the next. In single mode `chat.new` is refused while a
session is live; nothing renews on its own, ever.

When the deployment's `default_folder` changes, the live session follows
it: at its next start the gateway ends the session working elsewhere
(without a log step) and starts the next one in the new folder, and the
conversation says why ("Started a new session in ~/… — the deployment's
folder changed"). The gateway records the `default_folder` it ran with,
so a session the person started in a folder of their own choosing keeps
it while `default_folder` stays the same.

Settings → General → **Clear earlier sessions…** (after a confirmation)
empties the list of ended sessions. Only Portico's list: the live session
stays, the agent's transcripts stay on disk, and the numbers are not used
again.

### Threads, docked cards and New space (v0.16)

Main's agent can propose a **thread**: another conversation with the same
agent in the same folder, started from a brief (and the files named with
it), for work that can run alongside. The proposal is a card in Main; the
person starts it or says Not now. At most `[threads] max` (default 2, 0 =
off) are open besides Main. ⌃0 is Main, ⌃1 and ⌃2 the threads, and the
sidebar lists them with their state. A thread needing an answer shows a
calling card in Main. Closing a thread writes a summary through the log
step to History; a thread never renews. A thread takes the brief, not
Main's conversation. Threads need `presentation = "single"` and an app that
announces `threads.v1` (see `protocol/PROTOCOL.md`, Threads). ⌃1 and ⌃2 can
be taken by macOS if the "Switch to Desktop N" shortcuts are on (Mission
Control).

Questions and permissions appear as a card docked above the composer, with
numbered options, a pager for several questions, "Something else", and Skip.
The keys while the card has the focus:

- **1–4** choose an option (on a permission card, only after you have moved
  the focus with an arrow or clicked a row);
- **↑/↓** move the focus;
- **Return** confirms the focused option (on a multi-select question: the
  next question, or submit on the last);
- **×** dismisses the card.

Digits type normally in the composer and in "Something else". Typing a reply
in the composer instead declines the question and sends the reply. A preview on an
option shows in a column beside the options when the agent sends one.
**New space...** in the space switcher opens a dialog (name and what you
want) instead of filling the composer.

### Session numbers

Sessions are numbered by Portico's own counter, and a number is never
handed out twice. The welcome names the number the next session will have
("Session 17"). A deployment that numbers its sessions itself sets
`[sessions] next_number` to a command whose stdout is that number (one
whole number above zero; stderr is ignored). The gateway runs it with
`/bin/sh -c` when a new session starts (the first one, and each New), and
once when it starts with no live session, for the welcome's title; so the
command should read the number, not reserve it. It is given two seconds.
If it fails, times out, prints anything else, or prints a number Portico
has already passed, Portico uses its own counter and logs one line saying
why. After a deployment's number, Portico's counter carries on from it.

After every turn the gateway reports how full the agent's context is
(`context.usage`); when the agent summarizes earlier conversation to make
room, the app is told (`chat.compacted`) and the record counts it.

**Model and text size** (v0.15). The model in the status strip is a menu
of the same list `/model` shows in a terminal; the choice applies at once
and carries to new sessions (not while a reply runs). Settings →
Appearance has Text size, which scales the conversation, sidebar, menus
and the viewer's Markdown together (⌘+ or ⌘= bigger, ⌘- smaller). The
sidebar's History lists earlier sessions, with one title filter.

**Slash commands** (v0.11). Typing `/` at the start of the composer opens
a list above it: Portico's own (`/log`, `/new`) first, then the agent's
commands and skills, each with a one-line description, filtered as you
type (names first, then descriptions). ↑/↓ move, Enter or Tab puts
`/name ` in the composer, Esc closes; Enter on `/log` or `/new` does what
typing it and Enter always did. The gateway reads the agent's list when
its engine starts (`chat.commands`) and keeps the last one per folder in
`commands.json`, so the welcome has it before the first engine runs.

## Plug-ins

A deployment changes what Portico *does* through plug-ins, never by
editing the checkout (`bin/update` refuses to update over local changes,
and `bin/doctor` warns about them). A plug-in is a Python module kept
**outside** the checkout, named in `config.toml`:

```toml
plugins = ["my_deployment_plugin"]
plugin_paths = ["~/portico-plugins"]    # the directory that holds my_deployment_plugin.py
```

The module names the plug-in API it speaks and defines any of the hooks;
Portico's default runs for every hook it leaves out.

```python
PORTICO_PLUGIN_API = 1

def on_hello(hello):                 # adjust the hello the app receives; every plug-in's runs, in order
    return hello

async def on_renew(ctx, chat):       # the log step; replaces log_prompt; return True when logged
    outcome = await ctx.send("/my-log-command")   # a turn in the ending session: "done", "stopped" or "error"
    return outcome == "done"

def search(root, query):             # files.search instead of Spotlight; sync or async
    return [{"path": "relative/to/root.md", "snippet": None}]

def services_status():               # v0.8: the services menu's rows instead of [deployment] status
    return {"services": [{"id": "memory", "name": "Memory", "up": True}]}   # sync or async; raise = failed

async def restart_services():        # v0.8: Restart all services instead of [deployment] restart
    ...                              # sync or async; return False or raise = failed
```

`ctx` carries `chat` (the number), `folder`, `log_prompt`, `send` and
`ending` (true for a renewal, false for Log session, which keeps the
session live);
`chat` is the session's `ChatSummary` (title, created, compactions, ...).
For `on_renew`, `search`, `services_status` and `restart_services` the
last plug-in listed that defines one wins; the last two take precedence
over `[deployment]`.
A module that is missing, fails to import, or names another API number
stops the gateway at start with one line saying which; `bin/doctor` checks
each configured plug-in the same way. `examples/plugin/` holds a complete
example. The app takes no plug-ins: a new kind of screen is a request
upstream.

## Permissions

Each session has a permission mode, shown on the composer and changeable
there at any time (`session.mode`): **Auto** (`auto`, the default) lets the
agent engine's classifier allow or block each step and asks only when it
escalates; **Edits allowed** (`acceptEdits`) allows file edits and asks for
the rest; **Ask each time** (`default`) asks for every step the folder's
own rules do not allow. A new session starts with `permission_mode`.

A request is one card with a plain question ("Save changes to
notes.md?"). Its outcome is drawn on the tool row: allowed once, allowed
for this session, auto, declined (with your note), blocked by auto mode.
"Allow for this session" lasts as long as the session, across gateway
restarts; the next session starts with none. A line under the buttons
says what it covers: given on a file edit in the session's folder, edits
to files in that folder; outside the folder, that one file; given on a
command, that command (or the prefix the engine suggests, never with a
second command, a substitution or a redirection appended).

## Subagents and workflows

When the agent hands work to subagents or runs a workflow (v0.10), the
gateway follows the engine's task reports and sends each agent's start,
current step ("Read transcripts/p11.md"), step count, time and outcome,
and a workflow's phases as they advance (`agent.*`, `workflow.*` in
`protocol/PROTOCOL.md`). A subagent's own tool calls come as tool rows
marked with its `agent_id`. All of it goes only to an app that lists
`agents.v1` in its `hello`; an older app sees the conversation as before,
with one `Agent` row per subagent. Shell and monitor tasks are not shown
as agents. Nothing to configure.

## Voice

Voice is all in the app and all on the Mac (macOS 26 or later): nothing
said or read goes to a server, and the gateway and protocol stay text.
Settings › Voice turns each half on or off.

**Read aloud is off by default and hidden** (v0.9): the voices macOS lets
apps use still sound dated, so the button and the Listen settings are kept
behind a flag until a better voice is available. Turn it on with
`defaults write dev.portico.portico voice.readAloudAvailable -bool YES`
(and off with `-bool NO`), then relaunch.

**Talk.** The mic in the message box (the conversation's and the
welcome's) starts listening; your words land in the box as they are
recognised, after anything already typed. Press the mic again, or Esc, to
stop; the text stays for you to glance at and send. With "Send when I stop
talking" a stop by the mic sends it at once (Esc only stops). A
hold-to-talk key is off by default; Hold Right Option is offered. The
first press asks macOS for the microphone and speech recognition. The
transcription is the Speech framework's on-device `SpeechAnalyzer`
(`SpeechTranscriber`, or `DictationTranscriber` where the Mac does not
support it); the first time, macOS fetches its speech model for your
language. A build run with `swift run` has no Info.plist and cannot ask for
the microphone: voice input says it needs the installed app (`bin/install`).

**Read aloud.** Each reply has Read aloud beside Copy; while it reads it
is Stop reading, and Esc stops too. It uses the voice and speed chosen in
Settings › Voice (the system voices, and your Personal Voice once you
allow it there). Code is never read: a code block is "See the code below.",
a table "See the table below."; links are read as their text.

**Spoken parts.** When a reply holds `[TTS]…[/TTS]` parts, or the
shorthand `[TTS: …]`, Read aloud speaks only those, in order. The tags are never shown; the text inside
them reads as part of the reply. Portico only honours the tags: asking the
agent to write them is the deployment's, in its system prompt or the
folder's agent instructions. A suggested instruction:

> When a reply is longer than a few sentences, or holds code, tables or
> long lists, begin it with one to three plain sentences that say what
> you did or found, as you would say it aloud, wrapped in `[TTS]` and
> `[/TTS]`. Write those sentences for the ear: no Markdown, no code, no
> file paths or links. Short conversational replies need no tags.

## MCP servers, plugins and apps

**The person's own servers and plugins reach Portico (v0.18).** The MCP
servers a person has set up in Claude Code at user scope (all projects) or
local scope (this folder), and the plugins enabled there, are now passed to
Portico's agent, so it can use what they use in a terminal. The gateway
passes them in; `setting_sources` is unchanged. A server the folder's
`.mcp.json` ships still loads from that file, and a server turned off stays
off.

**Settings → MCP servers.** Lists the servers in groups: All your projects,
"<brand> only" (including "Ships with <brand>"), Built into <brand>, and
From your Claude account. Each row can be turned off, reconnected, signed in
or out, and removed (after a confirmation); Add server… takes a web address
or a program on the Mac. Each tool reads "Runs without asking" or "Asks
first", and the person can change it. A server change applies to new chats;
an open chat picks it up when it reconnects. A tool's setting applies at
once. The tab is `/mcp`.

**Settings → Plugins.** Installed plugins (turn on and off, update,
configure, uninstall after a confirmation), Browse, and marketplaces. A
plugin that installs by running a command is refused; install it in Claude
Code, where the command can be read first. The tab is `/plugin`.

Both tabs run the Claude Code CLI bundled with the Agent SDK against the
same files Claude Code uses, so a change shows in both.

**MCP Apps.** A tool that offers a page (an MCP App, stable spec
2026-01-26) is shown as a card in the conversation, in a sandbox of its own
per card with no access to Portico's other pages. The three newest cards
are live; older ones freeze to a picture with Reload. Open in viewer shows a
fresh copy beside the conversation. A call the page makes asks first, like
the agent's own, unless the tool only reads; a page can also send a message
or update what the agent knows. `[apps] enabled = false` keeps every tool a
plain tool row. Apps rely on private control requests of the Claude Code
CLI, behind one seam in the gateway, so the Agent SDK is pinned
(`claude-agent-sdk==0.2.174`).

**The pointer and tooltips.** In the viewer, the agent's pointer glides to
a click or a field before it acts. Portico's own tooltips are centred
under their control.

## The viewer's vision and spaces

**What the agent can do in the viewer (v0.12).** Beside `show_in_viewer`,
the agent has `viewer_look`, `viewer_click`, `viewer_type`, `viewer_scroll`
and `viewer_back`. Since v0.14 it also has `viewer_mark` (draw numbered,
noted boxes around parts of a web page; needs `viewer.marks.v1`) and
`viewer_clear_marks` (remove them all). A look returns a picture of what the viewer shows, an
outline of the page (a ref such as `e12` on each heading, link, button and
field) and any page errors since the last look; the other tools act on a
ref or on a link's or button's visible text. The person sees every action
as it happens and turns the whole thing off in Settings (**Agent can see
the viewer**). **Agent checks HTML it creates** (on by default, off with
the first) has the agent open an HTML page it wrote and look at it before
it replies; it uses more tokens. `[viewer] agent_can_see` and
`agent_checks_html` set the defaults.

**v0.17.** `show_in_viewer` takes a web address (`http://` or `https://`) as
well as a file, and waits until the page has loaded: the agent reads "Shown in
the viewer.", "Not loaded: <why>" or, after 10 s, "Shown; still loading."
(`viewer.show.v1`). A conversation's viewer calls run one at a time, in the
order sent; Stop drops the ones still waiting. `viewer_mark` finds any text
the person can see, not only controls.

**Outside sites.** The viewer keeps website sign-ins the way a browser does,
so a click on an outside site is the person's click. Local pages (`file://`
and `localhost`, `127.0.0.1`, `::1` on any port) are always usable. On every
other site the agent can look and scroll, not click or type, unless the
site is in `act_hosts`. An entry is a bare host name that matches that host
and its subdomains (`figma.com` covers `www.figma.com`); a scheme, path,
port, wildcard, leading or trailing dot, or a name with no dot at all
(`com`) is a configuration error at start. Matching ignores case. The app checks the page's current host at
every click and type, so a redirect or a link to another site is checked
again. Only the deployment sets the list: there is no control in the app.
It ships empty, and `bin/doctor` prints it ("Agent can click and type on:
figma.com, lovable.dev" or "Outside sites: look only").

**Spaces.** A space is a Markdown or HTML file the agent keeps current, in
`[spaces] folder`, or, when that is not set, `spaces` in the state
directory (`~/.portico/spaces`, created at start). The app always shows
the toolbar switcher, with "No spaces yet" until there is one, and opens
a space beside the conversation. On a gateway too old for spaces, New
space… is dimmed. A space's name, icon and order come from front
matter (`title`, `icon` as an SF Symbol name, `order`); an HTML file puts
the same keys in a leading `<!-- ... -->` block. A file with no title is
listed by its file name, and files starting with `.` or `_` are skipped.
Subfolders of the spaces folder are ignored: nothing inside them is
listed or watched.
Portico schedules nothing: the deployment rewrites the files (it can ask
the agent to). The gateway checks the folder every 5 seconds and tells the
agent where it is in the system prompt. `refresh` and `remove` run
commands you provide, so a space can be re-run on demand or its source
dropped when the person removes it. `examples/spaces/meeting-prep.md` is a
starting file. Spaces need an app that lists `spaces.v1`, and the
viewer tools need `viewer.v1`; an older app is sent neither.

## Editing and zoom in the viewer (v0.20)

**Edit** (the pencil in the viewer header, or ⌘E) turns on editing for
Markdown, plain text, code and HTML source on this Mac. Markdown is edited
as the page: the marks show only on the line the cursor is on, and the file
keeps exactly what was written. Changes save on their own a moment after
typing stops, atomically, keeping line endings, permissions and extended
attributes. If the agent changes the file while there are unsaved edits, a
bar offers **Keep mine** or **Use the agent's**. A save that fails keeps the
text and a copy in `<home>/unsaved/`; reopening the file offers to restore
it. With a gateway that offers `files.edited.v1`, the agent hears which
files were edited with the person's next message.

Images and PDFs zoom with the control at the bottom right, a pinch, or
⌥⌘= / ⌥⌘− / ⌥⌘0; ⌘+ and ⌘− stay text size.

The editor is CodeMirror 6 with Portico's live preview, bundled into
`app/Sources/Portico/Resources/editor.js`, which is committed: building the
app needs no Node. To change the editor, edit `app/Editor/src`, then run
`app/Editor/build.sh` (Node and npm from Homebrew); it runs the editor's
tests and rewrites the bundle, whose first line carries a hash of its
sources. `tests/test_distribution.py` fails if the bundle is out of date.

## Command line

`bin/portico-gateway <command>`, each with `--state` (default
`$PORTICO_HOME` or `~/.portico`):

```sh
bin/portico-gateway status --json      # {"version": 1, "running": true, "pid", "port", "folder", "session",
                                       #  "state", "mode", "started_at", "config_stale"}; exit 0 running, 3 not
bin/portico-gateway stop               # stop the running gateway (its own stop path); exit 3 when none runs
bin/portico-gateway update --check     # [update] check: exit 0 + version, 1 none, 2 not configured, 4 failed
bin/portico-gateway update             # stop the gateway, run [update] run with its output, exit with its code
bin/portico-gateway config-value brand.name   # one config value, or nothing
bin/portico-gateway sessions clear     # (v0.12) forget every earlier session; asks first, --yes skips that;
                                       # refuses while a gateway runs ("Stop the gateway first.") and in
                                       # multiple presentation; the transcripts on disk stay
```

`status --json` is the supported way for other tools to see that the app
holds a live session in a folder; the lock and ledger files in the state
directory are internal. Keys whose value is unknown are left out.

## Updating

Releases are tags `vX.Y.Z`; `CHANGELOG.md` says what changed, with a "For
plug-in authors" part when the plug-in API or its hooks move.

```sh
bin/update                  # newest release tag: check it out, bin/install (gateway + app), bin/doctor
bin/update --channel main   # follow main instead (fast-forward pull), then the same
```

`bin/update` refuses to run over local changes in the checkout and says
so; move the change into a plug-in, or ask upstream for it. Once the
checkout has moved it stops a gateway still running the old version
(`portico-gateway stop`) and says so; Portico starts the new one. If the
install then fails, it says to fix the error and run `bin/install`.
`bin/doctor` prints the tag or commit the checkout is on.

## The agent's system prompt

The agent starts from Claude Code's own system prompt
(`system_prompt = "claude_code"`, the default): its tool habits, the date
and the working folder, so it behaves as it does in a terminal. A
deployment makes it its own with `system_prompt_append`, a file of its
text added after Claude Code's (kept outside this checkout). The file is
read each time a session's engine starts, so an edit applies to the next
new or renewed session, no gateway restart. A file missing at load is a
config error; one that can't be read later is logged and the session
starts without it. `system_prompt = "none"` drops Claude Code's prompt:
the agent gets only the append file's text (or nothing), as every
deployment did before v0.10.

Either way the folder's `CLAUDE.md`, skills and hooks still load through
`setting_sources`; they are not part of the system prompt. Session titles
keep their own prompt.

## The engine's environment

Started from the app, the gateway inherits launchd's bare PATH
(`/usr/bin:/bin:/usr/sbin:/sbin`), so `npx`, `node`, `uvx` and anything in
Homebrew or `~/.local/bin` would be missing for the agent and its MCP
servers. With `login_shell_path = true` (the default) the gateway asks the
person's login shell (`$SHELL -l -i -c`, 5 s at most) for its PATH and puts
it first, keeping the inherited entries it lacks. If the shell can't be read
it logs one line and keeps the inherited PATH. A `PATH=` line in the env
file goes first of all: the deployment's explicit choice wins. `doctor`
shows where the PATH came from and whether `node`, `npx` and `uvx` resolve.

Every engine started for a person's session has `PORTICO_ATTENDED=1` in its
environment (title generation never does). The Agent SDK marks its engines
as automated (`CLAUDE_CODE_ENTRYPOINT=sdk-py`); a deployment whose start-up
checks skip work when nobody is present can read `PORTICO_ATTENDED` to know
someone is. Portico sets no Claude Code variable of its own.

## Showing the agent's work

The agent shows files in the viewer, not in another app. The gateway
gives it a `show_in_viewer(path)` tool (in-process, no permission card in
any mode) for a viewable file (HTML, markdown, images, PDF) inside the
session's folder or a configured root, and appends one line to its system
prompt saying so (always last, after the deployment's text). A plain
`open <path>` (or `open <path> <path>`) of such a file in its shell is
not run: the file goes to the viewer and the agent is told it was shown.
URLs, flags, anything chained or globbed, and files outside the folders
run as before. **Open externally** in the viewer's
header still hands the file to its default app.

## The producer endpoint

Anything on the machine can push an artifact into a chat's viewer. The
token is the per-launch one in `~/.portico/token`; the port is in
`~/.portico/ledger.json` (or the `PORTICO_READY` line).

```sh
port=$(sed -n 's/.*"port": *\([0-9]*\).*/\1/p' ~/.portico/ledger.json)
curl -s -X POST "http://127.0.0.1:$port/v1/artifact" \
  -H "Authorization: Bearer $(cat ~/.portico/token)" \
  -H "Content-Type: application/json" \
  -d '{"chat": 1, "location": "/tmp/report.md", "title": "Report"}'
```

Answers `201 {"artifact": {...}}` and the file opens in the viewer at once.
`location` is a file path (relative paths resolve against the chat's folder)
or a URL; `title` is optional. `GET /v1/health` on the same port needs no
token and answers `{"epoch": "...", "protocol": 1}`.

## Layout

```
protocol/   PROTOCOL.md (the contract), schema/portico.schema.json, examples/*.json
gateway/    Python package portico_gateway; tests against a fake engine
app/        SwiftPM package Portico; tests decode every protocol example
bin/        install, doctor, update, portico-gateway
            (install's helpers and the default icon: app/Packaging/)
examples/   plugin/: an example plug-in (copy it outside the checkout to use it)
docs/       done-when.md: the release checklist and what each test covers
tests/      test_distribution.py: no deployment names in the repo
```

## Tests

```sh
cd gateway && uv run pytest -q                      # model-free, a few seconds
cd app && swift test                                # model-free
cd gateway && uv run pytest ../tests/test_distribution.py -q
cd gateway && PORTICO_LIVE=1 uv run pytest tests/test_live_smoke.py -v   # opt-in, needs a credential
cd gateway && PORTICO_LIVE=1 uv run pytest tests/test_live_*.py -v        # the smoke plus done-when checks 1-5 and 9 live; about five minutes
```

Other commands: `bin/update` (newest release tag, then install; see Updating);
`bin/portico-gateway export-schema` and `export-examples` regenerate
`protocol/` from the gateway's models.
