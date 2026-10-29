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

Requirements: macOS 15, `uv` (brings Python 3.13), Swift 6 (Xcode or the
Command Line Tools), and a provider credential for the agent.

```sh
git clone <this repo> ~/dev-projects/portico && cd ~/dev-projects/portico
bin/install                      # gateway: uv sync; app: swift build -c release
bin/doctor                       # one line per check; tells you if a credential is missing
bin/portico-gateway run          # prints PORTICO_READY port=<n>; leave it running
cd app && swift run              # opens the app; it finds the running gateway
```

The app also starts the gateway itself when none is running, so `swift run`
alone works once `bin/install` has been done. In the app: **New Chat**,
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
log_prompt = "/session-close"       # the log step a renewal runs first; unset = no log step
plugins = ["my_deployment_plugin"]  # plug-in modules, imported at start (see Plug-ins)
plugin_paths = ["~/portico-plugins"] # absolute directories put on the import path for them

[brand]
name = "Portico"
agent_name = "Agent"
accent = "#3B6EF5"                  # optional CSS hex
icon = "/path/to/icon.png"          # optional
app_icon = "~/icons/app.png"        # optional 1024x1024 PNG for the .app bundle (bin/install); never sent to the app

[update]                            # optional: the deployment's own update commands, run with /bin/sh -c
check = "my-tool update --check"    # exit 0 and print the version when an update is available
run = "my-tool update"              # performs it; the app's "Update available" runs it through portico-gateway update

[[actions]]                         # buttons in the input bar; each sends its text
label = "Review"
text = "/review"

[[roots]]                           # folders the files pane can browse
name = "projects"
path = "~/projects"                 # absolute; a leading ~ is expanded
```

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
```

`ctx` carries `chat` (the number), `folder`, `log_prompt` and `send`;
`chat` is the session's `ChatSummary` (title, created, compactions, ...).
For `on_renew` and `search` the last plug-in listed that defines one wins.
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
restarts; the next session starts with none. Given on a file edit it
covers every file edit; given on a command it covers that command.

## Command line

`bin/portico-gateway <command>`, each with `--state` (default
`$PORTICO_HOME` or `~/.portico`):

```sh
bin/portico-gateway status --json      # {"version": 1, "running": true, "pid", "port", "folder", "session",
                                       #  "state", "mode", "started_at", "config_stale"}; exit 0 running, 3 not
bin/portico-gateway stop               # stop the running gateway (its own stop path); exit 3 when none runs
bin/portico-gateway update --check     # [update] check: exit 0 + version, 1 none, 2 not configured
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
