# A stand-in team source

`team_sample.py` answers every `[team]` request from one folder on this
Mac, so each state the app draws for team knowledge can be reached with no
server and no second person. It is a sample to build and test against. A
real deployment replaces it with its own commands or plug-in hooks; the
requests and answers are described at the top of
`gateway/portico_gateway/team.py`.

## Turn it on

In `config.toml`, with your own paths (`--root` is the root the app's Files
pane shows, since the paths the app sends are relative to it):

```toml
[team]
check       = "python3 ~/portico/examples/team-sample/team_sample.py --source ~/team-source --root ~/work --me 'Your Name' check"
get         = "python3 ~/portico/examples/team-sample/team_sample.py --source ~/team-source --root ~/work --me 'Your Name' get"
send        = "python3 ~/portico/examples/team-sample/team_sample.py --source ~/team-source --root ~/work --me 'Your Name' send"
sending     = "python3 ~/portico/examples/team-sample/team_sample.py --source ~/team-source --root ~/work --me 'Your Name' sending"
stop        = "python3 ~/portico/examples/team-sample/team_sample.py --source ~/team-source --root ~/work --me 'Your Name' stop"
resolve     = "python3 ~/portico/examples/team-sample/team_sample.py --source ~/team-source --root ~/work --me 'Your Name' resolve"
share_check = "python3 ~/portico/examples/team-sample/team_sample.py --source ~/team-source --root ~/work --me 'Your Name' share_check"
share       = "python3 ~/portico/examples/team-sample/team_sample.py --source ~/team-source --root ~/work --me 'Your Name' share"
```

`bin/doctor` says whether every request is answered. Restart the gateway.

## Play the rest of the team

Each switch changes the team source; the app shows it at the next check
(Try again, or wait for the interval).

| To see | Run `team_sample.py --source ~/team-source sim …` |
|---|---|
| "2 new from Priya" and Get | `seed` |
| New files from someone else | `share --as "Sam Ortiz" --note "For Thursday" a.md b.md` |
| "Priya changed 1 file" | `change --as "Priya Raman" release-calendar.md` |
| "Can't reach team knowledge" | `reach unreachable` (back: `reach ok`) |
| The sign-in refused | `reach refused` |
| A Get that fails for one share | `fail-get s-1 on` |
| A check for personal material that cannot finish | `fail-check on` |
| A file removed from the team | `remove release-calendar.md` |

The rest needs no switch:

- **Going out:** edit a file you shared or accepted. Its mark shows the
  change waiting; the next check sends it.
- **Paused:** pause the file in the app, then edit it.
- **Two versions:** pause a file, edit it, then run `change` on the same
  file and check. Your version is kept under `_team/.mine/`.
- **Personal material:** share a file with a paragraph that holds an email
  address or starts with `Personal:` or `Private:`.

## What it keeps, and where

- `<source>/index.json` and `<source>/files/`: the team's files, who shared
  each, and the switches.
- `<root>/.team-sample.json`: what this Mac holds, pauses, stops and the
  arrivals not yet shown.
- `<root>/_team/`: files from other people, and `_summary.md`, the one
  change summary.

File names are the team's keys here: two people cannot share files with
the same name. A real team source would not have that limit.
