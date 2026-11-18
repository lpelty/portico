#!/usr/bin/env python3
"""A stand-in team source for Portico's team knowledge (v0.27). Not for real use.

One folder plays the team source; this script answers each ``[team]``
request from it, so every state the app can draw is reachable on one Mac
with no server. A real deployment replaces it with its own commands; the
requests and answers are described in ``gateway/portico_gateway/team.py``.

    team_sample.py --source DIR --root DIR --me "Your Name" <request>
    team_sample.py --source DIR sim <switch> ...

``--source`` is the folder standing in for the team source. ``--root`` is
the person's folder: the paths the app sends are relative to it, and files
from other people land in ``<root>/_team``. Each may come from the
environment instead: ``PORTICO_TEAM_SOURCE``, ``PORTICO_TEAM_ROOT``,
``PORTICO_TEAM_ME``.

A request reads one JSON object on stdin and prints one on stdout. The
``sim`` switches play the rest of the team and the network (README.md).

The personal-material check here is deliberately simple: a paragraph that
holds an email address, or starts with ``Personal:`` or ``Private:``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

TEAM_FOLDER = "_team"
MINE_FOLDER = f"{TEAM_FOLDER}/.mine"
SUMMARY = f"{TEAM_FOLDER}/_summary.md"
LOCAL_STATE = ".team-sample.json"
EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
MARKED = re.compile(r"^\s*(personal|private)\s*:", re.IGNORECASE)


def now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def person(name: str) -> dict[str, str]:
    return {"name": name, "short": name.split()[0] if name.split() else name}


def digest(path: Path) -> str:
    try:
        return hashlib.sha1(path.read_bytes()).hexdigest()
    except OSError:
        return ""


def read_json(path: Path, default: dict[str, Any]) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default
    return data if isinstance(data, dict) else default


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(json.dumps(data, indent=1), encoding="utf-8")
    os.replace(tmp, path)


def write_whole(path: Path, data: bytes) -> None:
    """Put ``data`` at ``path`` in one step: a run cut off part-way leaves the old file, never half of the new one."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def copy_whole(from_path: Path, to_path: Path) -> None:
    write_whole(to_path, from_path.read_bytes())


class Source:
    """The folder standing in for the team source: ``index.json`` and ``files/<name>``."""

    def __init__(self, folder: Path) -> None:
        self.folder = folder
        self.index_path = folder / "index.json"
        self.index = read_json(self.index_path, {})
        self.index.setdefault("files", {})
        self.index.setdefault("flags", {})
        self.index.setdefault("next_share", 1)

    @property
    def files(self) -> dict[str, dict[str, Any]]:
        return self.index["files"]

    @property
    def flags(self) -> dict[str, Any]:
        return self.index["flags"]

    def reach(self) -> str:
        return self.flags.get("reach", "ok")

    def content(self, name: str) -> Path:
        return self.folder / "files" / name

    def save(self) -> None:
        write_json(self.index_path, self.index)

    def new_share(self) -> str:
        n = self.index["next_share"]
        self.index["next_share"] = n + 1
        return f"s-{n}"

    def put(self, name: str, from_path: Path, by: str, share: str | None = None, note: str | None = None) -> None:
        """A new file, or a new version of one, from ``by``."""
        copy_whole(from_path, self.content(name))
        entry = self.files.get(name)
        if entry is None:
            self.files[name] = {"rev": 1, "by": person(by), "at": now(), "share": share, "note": note}
        else:
            entry["rev"] += 1
            entry["changed_by"], entry["changed_at"] = person(by), now()


class Local:
    """What this Mac holds: ``<root>/.team-sample.json``."""

    def __init__(self, root: Path, me: str) -> None:
        self.root = root
        self.me = me
        self.path = root / LOCAL_STATE
        self.data = read_json(self.path, {})
        self.data.setdefault("held", {})
        self.data.setdefault("stopped", [])
        self.data.setdefault("unannounced", [])
        self.data.setdefault("latest", None)
        self.data.setdefault("announced", None)
        self.data.setdefault("next_arrival", 1)

    @property
    def held(self) -> dict[str, dict[str, Any]]:
        return self.data["held"]

    def save(self) -> None:
        write_json(self.path, self.data)

    def by_path(self, path: str) -> tuple[str, dict[str, Any]] | tuple[None, None]:
        for name, entry in self.held.items():
            if entry["path"] == path:
                return name, entry
        return None, None

    def arrival(self, kind: str, entry: dict[str, Any]) -> None:
        n = self.data["next_arrival"]
        self.data["next_arrival"] = n + 1
        self.data["unannounced"].append({"id": f"a-{n}", "kind": kind, "at": now(), **entry})


class Sample:
    def __init__(self, source: Source, local: Local) -> None:
        self.source = source
        self.local = local
        self.root = local.root

    # --- one file -----------------------------------------------------------------

    def note_local_change(self, entry: dict[str, Any]) -> bool:
        """Whether the file changed here since it was last in step; the first sighting sets ``pending_since``."""
        changed = digest(self.root / entry["path"]) != entry["hash"]
        if changed and not entry.get("pending_since"):
            entry["pending_since"] = now()
        return changed or bool(entry.get("pending_since"))

    def let_go(self, name: str, entry: dict[str, Any]) -> None:
        """A file from the team leaves the team folder. Changes made here and never sent are kept beside it."""
        target = self.root / entry["path"]
        if entry["direction"] != "in":
            return
        if target.is_file() and digest(target) != entry["hash"]:
            kept = self.root / MINE_FOLDER / name
            # Never over a copy already kept there: a saved version, or what an earlier file of this name left.
            copy_whole(target, self.beside(name) if kept.exists() else kept)
        target.unlink(missing_ok=True)

    def beside(self, name: str) -> Path:
        """A new place in the kept folder for one more copy of ``name``."""
        stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
        return self.root / MINE_FOLDER / f"{Path(name).stem}.edited-{stamp}{Path(name).suffix}"

    def keep_edits(self, name: str, entry: dict[str, Any]) -> None:
        """While a file has two versions, the one at its path may be edited too: keep that before it is replaced."""
        target = self.root / entry["path"]
        if target.is_file() and digest(target) != entry["hash"]:
            copy_whole(target, self.beside(name))

    def push(self, name: str, entry: dict[str, Any]) -> None:
        """This Mac's version becomes the team's."""
        self.source.put(name, self.root / entry["path"], self.local.me)
        entry["rev"] = self.source.files[name]["rev"]
        entry["hash"] = digest(self.root / entry["path"])
        entry["pending_since"] = None
        entry["sent_at"] = now()

    def pull(self, name: str, entry: dict[str, Any]) -> None:
        """The team's version replaces the one at the file's path."""
        target = self.root / entry["path"]
        copy_whole(self.source.content(name), target)
        remote = self.source.files[name]
        entry["rev"] = remote["rev"]
        entry["hash"] = digest(target)
        entry["changed_by"], entry["changed_at"] = remote.get("changed_by"), remote.get("changed_at")

    def sync(self, only: set[str] | None = None, send_only: bool = False) -> None:
        """Send what is due and bring in what changed, for every held file (or the ones in ``only``)."""
        changed_files: list[str] = []
        changed_by: list[dict[str, str]] = []
        for name in list(self.local.held):
            entry = self.local.held[name]
            if only is not None and entry["path"] not in only:
                continue
            remote = self.source.files.get(name)
            if remote is None:
                # Removed from the team: a copy from someone else leaves; the person's own file stays.
                self.let_go(name, entry)
                del self.local.held[name]
                continue
            local_changed = self.note_local_change(entry)
            remote_new = remote["rev"] > entry["rev"]
            if remote_new and not send_only:
                if entry.get("conflict") or local_changed:
                    if entry.get("conflict"):
                        self.keep_edits(name, entry)
                    else:
                        mine = f"{MINE_FOLDER}/{name}"
                        copy_whole(self.root / entry["path"], self.root / mine)
                        entry["conflict"] = {"mine": {"path": mine, "at": now()}}
                    self.pull(name, entry)
                    entry["conflict"]["id"] = f"c-{name}-{remote['rev']}"
                else:
                    self.pull(name, entry)
                    entry["unread"] = True
                    changed_files.append(entry["path"])
                    if remote.get("changed_by") and remote["changed_by"] not in changed_by:
                        changed_by.append(remote["changed_by"])
            elif local_changed and not entry.get("paused_since") and not entry.get("conflict") and not remote_new:
                self.push(name, entry)
        if changed_files:
            self.local.arrival("changed", {"files": changed_files, "by": changed_by})

    # --- the state every answer carries ------------------------------------------------

    def waiting(self) -> list[dict[str, Any]]:
        shares: dict[str, dict[str, Any]] = {}
        for name, remote in sorted(self.source.files.items()):
            if name in self.local.held or name in self.local.data["stopped"] or remote["by"]["name"] == self.local.me:
                continue
            share = shares.setdefault(remote["share"], {"id": remote["share"], "by": remote["by"], "files": []})
            share["files"].append(name)
            if remote.get("note"):
                share["note"] = remote["note"]
        return list(shares.values())

    def join_arrivals(self, announced: str | None = None) -> None:
        """One ``latest`` for every arrival an app has not been shown, and one summary file for it.

        ``announced`` comes with ``check`` and with ``get``: what an app was last shown, as it stands now.
        """
        if announced is not None:
            self.local.data["announced"] = announced
        announced = self.local.data["announced"]
        latest = self.local.data["latest"]
        pending = self.local.data["unannounced"]
        if latest is not None and announced == latest["id"]:
            pending = [a for a in pending if a["id"] not in latest.get("covers", [])]
            self.local.data["unannounced"] = pending
        if not pending or (latest is not None and latest.get("covers") == [a["id"] for a in pending]):
            return
        shares = [s for a in pending for s in a.get("shares", [])]
        by: list[dict[str, str]] = []
        for a in pending:
            for p in a.get("by", []):
                if p not in by:
                    by.append(p)
        files: list[str] = []
        for a in pending:
            files += [f for f in a["files"] if f not in files]
        last = pending[-1]
        latest = {"id": last["id"], "kind": last["kind"], "at": last["at"], "summary": SUMMARY, "files": files, "covers": [a["id"] for a in pending]}
        if shares:
            latest["shares"] = shares
        if by:
            latest["by"] = by
        self.local.data["latest"] = latest
        lines = ["# What is new in team knowledge", ""]
        for a in pending:
            if a["kind"] == "new":
                for share in a["shares"]:
                    lines += [f"## New from {share['by']['name']}", ""]
                    if share.get("note"):
                        lines += [f"> {share['note']}", ""]
                    lines += [f"- {f}" for f in share["files"]] + [""]
            else:
                who = " and ".join(p["name"] for p in a.get("by", [])) or "The team"
                lines += [f"## Changed by {who}", ""] + [f"- {f}" for f in a["files"]] + [""]
        summary = self.root / SUMMARY
        summary.parent.mkdir(parents=True, exist_ok=True)
        summary.write_text("\n".join(lines), encoding="utf-8")

    def state(self) -> dict[str, Any]:
        latest = self.local.data["latest"]
        covered = set(latest["files"]) if latest else set()
        rows = []
        for name, entry in sorted(self.local.held.items(), key=lambda item: item[1]["path"]):
            remote = self.source.files.get(name, {})
            row: dict[str, Any] = {
                "path": entry["path"],
                "direction": entry["direction"],
                "rev": f"r-{entry['rev']}",
                "shared_by": remote.get("by") or person(self.local.me),
                "shared_at": remote.get("at") or entry.get("shared_at") or now(),
                "unread": bool(entry.get("unread")),
            }
            if entry.get("changed_by"):
                row["changed_by"], row["changed_at"] = entry["changed_by"], entry["changed_at"]
            if entry.get("pending_since"):
                row["pending"] = {"since": entry["pending_since"]}
            if entry.get("paused_since"):
                row["paused"] = {"since": entry["paused_since"]}
            if entry.get("sent_at"):
                row["sent_at"] = entry["sent_at"]
            if entry.get("conflict"):
                row["conflict"] = entry["conflict"]
            if entry["path"] in covered:
                row["summary"] = SUMMARY
            rows.append(row)
        out: dict[str, Any] = {"reach": self.source.reach(), "waiting": [], "files": rows}
        if out["reach"] == "unreachable":
            out["reach_reason"] = "The team source did not answer."
        elif out["reach"] == "refused":
            out["reach_reason"] = "The team source refused this Mac's sign-in."
        else:
            out["waiting"] = self.waiting()
        if latest:
            out["latest"] = {k: v for k, v in latest.items() if k != "covers"}
        return out

    def answer(self, failed: list[dict[str, str]] | None = None, reason: str | None = None) -> dict[str, Any]:
        self.local.save()
        self.source.save()
        out: dict[str, Any] = {"ok": not failed and reason is None, "state": self.state()}
        if reason:
            out["reason"] = reason
        if failed:
            out["failed"] = failed
        return out

    def offline(self) -> str | None:
        return None if self.source.reach() == "ok" else "The team source could not be reached."

    # --- the eight requests ---------------------------------------------------------

    def check(self, request: dict[str, Any]) -> dict[str, Any]:
        if self.source.reach() == "ok":
            self.sync()
        else:
            for entry in self.local.held.values():
                self.note_local_change(entry)
        self.join_arrivals(request.get("announced"))
        self.local.save()
        self.source.save()
        return self.state()

    def get(self, request: dict[str, Any]) -> dict[str, Any]:
        if self.offline():
            return self.answer(reason=self.offline())
        offered = {share["id"]: share for share in self.waiting()}
        failed, accepted = [], []
        for id in request.get("shares", []):
            share = offered.get(id)
            if share is None:
                failed.append({"share": id, "reason": "This share is no longer offered."})
                continue
            if id in self.source.flags.get("fail_shares", []):
                failed.append({"share": id, "reason": "These files could not be brought in. Try again."})
                continue
            paths = []
            for name in share["files"]:
                entry = {"path": f"{TEAM_FOLDER}/{name}", "direction": "in", "rev": 0, "hash": "", "unread": True}
                self.local.held[name] = entry
                self.pull(name, entry)
                entry["changed_by"] = entry["changed_at"] = None
                paths.append(entry["path"])
            accepted.append({**share, "files": paths})
        if accepted:
            self.local.arrival("new", {"files": [f for s in accepted for f in s["files"]], "shares": accepted})
            self.join_arrivals(request.get("announced"))
        return self.answer(failed)

    def send(self, request: dict[str, Any]) -> dict[str, Any]:
        if self.offline():
            return self.answer(reason=self.offline())
        failed = []
        for path in request.get("paths", []):
            name, entry = self.local.by_path(path)
            if entry is None:
                failed.append({"path": path, "reason": "This file is not shared."})
            elif entry.get("paused_since"):
                failed.append({"path": path, "reason": "Sending is paused for this file"})
            elif self.source.files.get(name, {}).get("rev", 0) > entry["rev"] and self.note_local_change(entry):
                # Nothing is sent over a version this Mac has not seen; the next check brings it in as a second version.
                failed.append({"path": path, "reason": "The team changed this file too. Its version arrives at the next check."})
        self.sync(only=set(request.get("paths", [])), send_only=True)
        return self.answer(failed)

    def sending(self, request: dict[str, Any]) -> dict[str, Any]:
        failed = []
        for path in request.get("paths", []):
            name, entry = self.local.by_path(path)
            if entry is None:
                failed.append({"path": path, "reason": "This file is not shared."})
            elif request.get("paused"):
                entry["paused_since"] = entry.get("paused_since") or now()
            else:
                entry["paused_since"] = None
        return self.answer(failed)

    def stop(self, request: dict[str, Any]) -> dict[str, Any]:
        failed = []
        for path in request.get("paths", []):
            name, entry = self.local.by_path(path)
            if name is None or entry is None:
                failed.append({"path": path, "reason": "This file is not shared."})
            elif entry.get("conflict"):
                failed.append({"path": path, "reason": "Choose a version first"})
            else:
                self.let_go(name, entry)
                del self.local.held[name]
                self.local.data["stopped"].append(name)
        return self.answer(failed)

    def resolve(self, request: dict[str, Any]) -> dict[str, Any]:
        path = request.get("path", "")
        name, entry = self.local.by_path(path)
        if name is None or entry is None or not entry.get("conflict") or entry["conflict"]["id"] != request.get("conflict"):
            return self.answer([{"path": path, "reason": "The team's version changed. Look again before choosing."}])
        mine = self.root / entry["conflict"]["mine"]["path"]
        if request.get("use") == "mine":
            if self.offline():
                return self.answer(reason=self.offline())
            if self.source.files.get(name, {}).get("rev", 0) > entry["rev"]:
                # The team's version moved on since the last check: bring it in, and let the person look again.
                self.sync(only={path})
                return self.answer([{"path": path, "reason": "The team's version changed. Look again before choosing."}])
            self.keep_edits(name, entry)
            copy_whole(mine, self.root / entry["path"])
            self.push(name, entry)
        else:
            # The team's version stays. Anything typed into it since it arrived is a change of the person's, sent as one.
            entry["pending_since"] = None
            self.note_local_change(entry)
        mine.unlink(missing_ok=True)
        entry["conflict"] = None
        return self.answer()

    def read(self, path: str) -> str | None:
        try:
            return (self.root / path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            return None

    def paragraphs(self, path: str) -> list[tuple[int, int, str]]:
        """Each paragraph of the file as (start, end, text): runs of text between blank lines."""
        text = self.read(path)
        if text is None:
            return []
        spans, start = [], 0
        for gap in re.finditer(r"\n[ \t]*\n\s*", text):
            spans.append((start, gap.start(), text[start:gap.start()]))
            start = gap.end()
        spans.append((start, len(text), text[start:]))
        # A paragraph ends at its last character: the file's final newline is not part of it.
        return [(a, a + len(body.rstrip()), body.rstrip()) for a, _, body in spans if body.strip()]

    @staticmethod
    def finding_id(path: str, paragraph: str) -> str:
        return "f-" + hashlib.sha1(f"{path}\0{' '.join(paragraph.split())}".encode()).hexdigest()[:10]

    def share_check(self, request: dict[str, Any]) -> dict[str, Any]:
        if self.source.flags.get("check_fails"):
            return {"findings": [], "error": "The check for personal material could not finish."}
        findings = []
        for path in request.get("paths", []):
            for n, (_, _, paragraph) in enumerate(self.paragraphs(path), start=1):
                if EMAIL.search(paragraph) or MARKED.match(paragraph):
                    text = " ".join(paragraph.split())
                    findings.append(
                        {
                            "id": self.finding_id(path, paragraph),
                            "path": path,
                            "text": text if len(text) <= 200 else text[:199] + "…",
                            "location": f"Paragraph {n}",
                        }
                    )
        return {"findings": findings}

    def take_out(self, finding: dict[str, Any]) -> None:
        """Cut one paragraph and the blank lines before it (after it, for the first). Nothing else changes."""
        path = finding["path"]
        text = self.read(path)
        if text is None:
            return
        spans = self.paragraphs(path)
        for i, (start, end, paragraph) in enumerate(spans):
            if self.finding_id(path, paragraph) != finding["id"]:
                continue
            if i > 0:
                start = spans[i - 1][1]
            elif i + 1 < len(spans):
                end = spans[i + 1][0]
            write_whole(self.root / path, (text[:start] + text[end:]).encode("utf-8"))
            return

    def share(self, request: dict[str, Any]) -> dict[str, Any]:
        if self.offline():
            return self.answer(reason=self.offline())
        failed = []
        names: list[str] = []
        for path in request.get("paths", []):
            name = Path(path).name
            if not (self.root / path).is_file():
                failed.append({"path": path, "reason": "This file could not be read."})
            elif name in self.source.files or name in names:
                failed.append({"path": path, "reason": "The team already has a file with this name."})
            names.append(name)
        if failed:
            # All of the share or none of it: no file is changed or sent when one of them cannot go.
            return self.answer(failed)
        share = self.source.new_share()
        for path in request.get("paths", []):
            name = Path(path).name
            # Only now, and only for a file that is going: what the person chose to take out.
            for finding in request.get("remove", []):
                if finding.get("path") == path:
                    self.take_out(finding)
            self.source.put(name, self.root / path, self.local.me, share=share, note=request.get("note"))
            self.local.held[name] = {"path": path, "direction": "out", "rev": 1, "hash": digest(self.root / path), "sent_at": now()}
            if name in self.local.data["stopped"]:
                self.local.data["stopped"].remove(name)
        return self.answer(failed)


# --- the rest of the team, and the network ------------------------------------------


def sim(source: Source, args: list[str]) -> str:
    """The switches: what a teammate or the network does. Returns one line saying what changed."""
    parser = argparse.ArgumentParser(prog="team_sample.py sim")
    sub = parser.add_subparsers(dest="switch", required=True)
    share = sub.add_parser("share", help="a teammate shares files")
    share.add_argument("--as", dest="who", default="Priya Raman")
    share.add_argument("--note")
    share.add_argument("files", nargs="+", type=Path)
    change = sub.add_parser("change", help="a teammate changes a shared file")
    change.add_argument("--as", dest="who", default="Priya Raman")
    change.add_argument("--text", default="A line added by a teammate.")
    change.add_argument("name")
    remove = sub.add_parser("remove", help="a file is removed from the team source")
    remove.add_argument("name")
    reach = sub.add_parser("reach", help="whether the team source can be reached")
    reach.add_argument("how", choices=["ok", "unreachable", "refused"])
    fail = sub.add_parser("fail-check", help="the personal-material check cannot finish")
    fail.add_argument("on", choices=["on", "off"])
    fail_get = sub.add_parser("fail-get", help="a share that cannot be brought in")
    fail_get.add_argument("share")
    fail_get.add_argument("on", choices=["on", "off"])
    sub.add_parser("seed", help="two files from Priya with a note, ready to Get")
    ns = parser.parse_args(args)
    if ns.switch == "share":
        id = source.new_share()
        for path in ns.files:
            source.put(path.name, path, ns.who, share=id, note=ns.note)
        said = f"{ns.who} shared {len(ns.files)} file(s) as {id}"
    elif ns.switch == "change":
        if ns.name not in source.files:
            raise SystemExit(f"the team source has no file named {ns.name}")
        target = source.content(ns.name)
        scratch = target.with_name(f".{ns.name}.new")
        scratch.write_text(target.read_text(encoding="utf-8").rstrip("\n") + f"\n\n{ns.text}\n", encoding="utf-8")
        source.put(ns.name, scratch, ns.who)
        scratch.unlink()
        said = f"{ns.who} changed {ns.name}"
    elif ns.switch == "remove":
        source.files.pop(ns.name, None)
        source.content(ns.name).unlink(missing_ok=True)
        said = f"{ns.name} was removed from the team source"
    elif ns.switch == "reach":
        source.flags["reach"] = ns.how
        said = f"the team source is now {ns.how}"
    elif ns.switch == "fail-check":
        source.flags["check_fails"] = ns.on == "on"
        said = f"the personal-material check {'cannot finish' if ns.on == 'on' else 'works'}"
    elif ns.switch == "fail-get":
        failing = set(source.flags.get("fail_shares", []))
        failing.add(ns.share) if ns.on == "on" else failing.discard(ns.share)
        source.flags["fail_shares"] = sorted(failing)
        said = f"share {ns.share} {'cannot be brought in' if ns.on == 'on' else 'can be brought in'}"
    else:
        id = source.new_share()
        seeds = {
            "release-calendar.md": "# Release calendar\n\n- 3 December: the autumn release\n- 14 January: the winter release\n",
            "review-template.md": "# Review template\n\n1. What changed\n2. Who it is for\n3. What to check\n",
        }
        source.folder.mkdir(parents=True, exist_ok=True)
        for name, text in seeds.items():
            scratch = source.folder / f".{name}.seed"
            scratch.write_text(text, encoding="utf-8")
            source.put(name, scratch, "Priya Raman", share=id, note="The two files we agreed to keep in one place.")
            scratch.unlink()
        said = f"Priya Raman shared 2 files as {id}"
    source.save()
    return said


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", default=os.environ.get("PORTICO_TEAM_SOURCE"))
    parser.add_argument("--root", default=os.environ.get("PORTICO_TEAM_ROOT"))
    parser.add_argument("--me", default=os.environ.get("PORTICO_TEAM_ME", "Me"))
    parser.add_argument("request", choices=["check", "get", "send", "sending", "stop", "resolve", "share_check", "share", "sim"])
    parser.add_argument("rest", nargs=argparse.REMAINDER)
    ns = parser.parse_args(argv)
    if not ns.source:
        parser.error("--source (or PORTICO_TEAM_SOURCE) is needed: the folder standing in for the team source")
    source = Source(Path(ns.source).expanduser())
    if ns.request == "sim":
        print(sim(source, ns.rest))
        return 0
    if not ns.root:
        parser.error("--root (or PORTICO_TEAM_ROOT) is needed: the person's folder")
    raw = sys.stdin.read()
    request = json.loads(raw) if raw.strip() else {}
    sample = Sample(source, Local(Path(ns.root).expanduser(), ns.me))
    print(json.dumps(getattr(sample, ns.request)(request)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
