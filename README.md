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
| State: token, ledger, index, lock, gateway log | `~/.portico/` (`PORTICO_HOME` moves it) |
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

[brand]
name = "Portico"
agent_name = "Agent"
accent = "#3B6EF5"                  # optional CSS hex
icon = "/path/to/icon.png"          # optional; may be a flat square: Portico rounds it in the macOS icon shape
                                    # (an image whose corners are already transparent is drawn as given)
header_image = "/path/to/lockup.svg" # optional; replaces the mark and the name in the toolbar, 28 pt tall,
                                    # width from the image's shape (SVG or PDF stays sharp; a PNG at least 84 px tall)
app_icon = "~/icons/app.png"        # optional 1024x1024 PNG for the .app bundle (bin/install); never sent to the app
app_icon_assets = "~/icons/Assets.car" # optional precompiled asset catalog (macOS 26 icon); with app_icon_name
app_icon_name = "AppIcon"           # the icon's name inside app_icon_assets; neither is sent to the app

[update]                            # optional: the deployment's own update commands, run with /bin/sh -c
check = "my-tool update --check"    # exit 0 and print the version when an update is available
run = "my-tool update"              # performs it; the app's "Update available" runs it through portico-gateway update

[deployment]                        # optional (v0.8): one restart and one status for all the services
restart = "my-tool restart-all"     # /bin/sh -c, bounded by command_timeout_seconds; exit 0 = done;
                                    # the services menu ends with Restart all services
status = "my-tool status --json"    # prints {"services": [{"id", "name", "up": true|false, "detail"?}]} on stdout
                                    # (stderr is not read as JSON; it only names the reason when it fails);
                                    # when set, its rows replace the [[services]] checks; a row offers
                                    # Restart when a [[services]] entry with the same id gives one

[[actions]]                         # buttons in the input bar; each sends its text
label = "Review"
text = "/review"

[[services]]                        # what the deployment depends on, shown in the app's services menu
id = "memory"                       # unique, lowercase letters, digits and dashes
name = "Memory"
check = "curl -sf http://localhost:8888/health"   # /bin/sh -c; exit 0 = up
restart = "my-tool restart memory"  # optional: the menu offers Restart
up_detail = "recall and capture"    # optional: shown while it is up
timeout_seconds = 10                # optional, default 10, at least 1: the check is killed after this
                                    # (a restart is bounded by command_timeout_seconds)

[[roots]]                           # folders the files pane can browse
name = "projects"
path = "~/projects"                 # absolute; a leading ~ is expanded
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
Settings and `bin/doctor` say "restart the gateway to apply":
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
session"), then "Session ended · continues in Session M", and "Continues
Session N" first in the next. A replay shows them.

The log step is `log_prompt`, sent to the agent as a message — so the
agent logs itself with the command or skill its folder already has. A
plug-in's `on_renew` replaces it. With neither, renewing just ends the
session and opens the next. In single mode `chat.new` is refused while a
session is live; nothing renews on its own, ever.

After every turn the gateway reports how full the agent's context is
(`context.usage`); when the agent summarizes earlier conversation to make
room, the app is told (`chat.compacted`) and the record counts it.

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
so; move the change into a plug-in, or ask upstream for it. `bin/doctor`
prints the tag or commit the checkout is on.

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
