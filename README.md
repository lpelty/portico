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

[brand]
name = "Portico"
agent_name = "Agent"
accent = "#3B6EF5"                  # optional CSS hex
icon = "/path/to/icon.png"          # optional

[[actions]]                         # buttons in the input bar; each sends its text
label = "Review"
text = "/review"

[[roots]]                           # folders the files pane can browse
name = "projects"
path = "~/projects"                 # absolute; a leading ~ is expanded
```

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

Other commands: `bin/update` (fast-forward pull, then install);
`bin/portico-gateway export-schema` and `export-examples` regenerate
`protocol/` from the gateway's models.
