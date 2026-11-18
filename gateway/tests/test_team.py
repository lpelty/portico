"""v0.27: team knowledge — the monitor's snapshot, timer, requests done once, share drafts, and the frames.

The monitor is tested against a scripted source (hooks) and against the
sample provider in ``examples/team-sample`` run as real ``[team]``
commands; the server tests use a real ``websockets`` client.
"""

from __future__ import annotations

import asyncio
import shlex
import subprocess
import sys
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest
from websockets.asyncio.client import ClientConnection, connect

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import ConfigError, TeamConfig, hello_for, load_config
from portico_gateway.doctor import check_team
from portico_gateway.messages import (
    TEAM_CAPABILITY,
    ChatList,
    Error,
    HelloClient,
    HelloServer,
    ServicesStatus,
    TeamCheck,
    TeamGet,
    TeamIntervalSet,
    TeamResult,
    TeamSeen,
    TeamShareDraft,
    TeamSharePrepare,
    TeamShareSend,
    TeamState,
    TeamStop,
    dump,
    parse_server,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from portico_gateway.team import (
    CHOOSE_FIRST,
    DRAFT_CHANGED,
    NEW_FINDINGS,
    PAUSED_REASON,
    VERSION_CHANGED,
    SourceFailed,
    TeamMonitor,
    TeamSource,
    run_json_command,
)
from tests.conftest import FakeEngine, make_config
from tests.test_server import ws_url
from tests.test_turns import recv, recv_until

TS = "2026-11-17T12:00:00Z"
PRIYA = {"name": "Priya Raman", "short": "Priya"}
SAMPLE = Path(__file__).resolve().parents[2] / "examples" / "team-sample" / "team_sample.py"
REQUESTS = ("check", "get", "send", "sending", "stop", "resolve", "share_check", "share")


def share(id: str) -> dict[str, Any]:
    return {"id": id, "by": PRIYA, "files": [f"{id}.md"]}


def row(path: str, **kw: Any) -> dict[str, Any]:
    return {"path": path, "direction": "in", "rev": "r-1", "shared_by": PRIYA, "shared_at": TS, **kw}


class Scripted:
    """A deployment as hooks: each request is recorded and answered from ``state`` and ``answers``."""

    def __init__(self) -> None:
        self.state: dict[str, Any] = {"reach": "ok", "waiting": [], "files": []}
        self.answers: dict[str, Any] = {}
        self.calls: list[tuple[str, dict[str, Any]]] = []
        self.gate: asyncio.Event | None = None

    def hooks(self) -> dict[str, Any]:
        return {name: self._hook(name) for name in REQUESTS}

    def _hook(self, name: str) -> Any:
        async def hook(request: dict[str, Any]) -> Any:
            self.calls.append((name, request))
            if self.gate is not None and name in ("get", "share_check"):
                await self.gate.wait()
            answer = self.answers.get(name)
            if isinstance(answer, Exception):
                raise answer
            if name == "check":
                return self.state
            if name == "share_check":
                return answer if answer is not None else {"findings": []}
            return answer if answer is not None else {"ok": True, "state": self.state}

        return hook

    def named(self, name: str) -> list[dict[str, Any]]:
        return [request for called, request in self.calls if called == name]


class Heard:
    def __init__(self) -> None:
        self.states: list[TeamState] = []
        self.drafts: list[TeamShareDraft] = []
        self.attached = True

    async def state(self, state: TeamState) -> bool:
        self.states.append(state)
        return self.attached

    async def draft(self, draft: TeamShareDraft) -> None:
        self.drafts.append(draft)


def monitor(tmp_path: Path, scripted: Scripted, **kw: Any) -> tuple[TeamMonitor, Heard]:
    heard = Heard()
    mon = TeamMonitor(TeamSource({}, scripted.hooks(), timeout=5.0), tmp_path, heard.state, heard.draft, **kw)
    return mon, heard


# --- the source ---------------------------------------------------------------------


async def test_a_command_reads_the_request_on_stdin_and_prints_its_answer() -> None:
    echo = f"{shlex.quote(sys.executable)} -c 'import json,sys; print(json.dumps({{\"got\": json.load(sys.stdin)}}))'"
    assert await run_json_command(echo, {"paths": ["a.md"]}, 5.0) == {"got": {"paths": ["a.md"]}}


async def test_a_command_that_fails_names_its_reason() -> None:
    with pytest.raises(SourceFailed, match="exited 3: no sign-in"):
        await run_json_command("echo no sign-in >&2; exit 3", {}, 5.0)
    with pytest.raises(SourceFailed, match="not JSON"):
        await run_json_command("echo hello", {}, 5.0)
    with pytest.raises(SourceFailed, match="timed out"):
        await run_json_command("sleep 5", {}, 0.2)


async def test_a_hook_takes_precedence_over_the_command() -> None:
    source = TeamSource({"check": "exit 9", "get": "echo '{\"ok\": true}'"}, {"check": lambda request: {"reach": "ok"}}, timeout=5.0)
    assert await source.call("check", {}) == {"reach": "ok"}
    assert await source.call("get", {"shares": []}) == {"ok": True}
    assert source.active and source.missing() == ["send", "sending", "stop", "resolve", "share_check", "share"]
    assert not TeamSource({}, {}).active


def test_the_team_table_refuses_an_unknown_key_and_a_blank_label() -> None:
    assert TeamConfig(check="  ").check is None
    with pytest.raises(Exception, match="chekc"):
        TeamConfig.model_validate({"chekc": "true"})
    with pytest.raises(ValueError, match="label must not be empty"):
        TeamConfig(label=" ")


def test_a_team_table_in_config_toml_is_read(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text('[team]\nlabel = "Shared notes"\ncheck = "my-tool team check"\nget = "my-tool team get"\n')
    config = load_config(path)
    assert config.team.label == "Shared notes" and config.team.commands()["get"] == "my-tool team get"
    assert config.team.commands()["share"] is None
    path.write_text('[team]\ncheck = "x"\nintervals = [5]\n')
    with pytest.raises(ConfigError, match="intervals"):
        load_config(path)


def test_the_doctor_names_what_nothing_answers(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text("")
    assert check_team(path).ok and check_team(path).line.startswith("off")
    path.write_text('[team]\nget = "x"\n')
    assert not check_team(path).ok and "no check" in check_team(path).line
    path.write_text('[team]\ncheck = "x"\nget = "x"\n')
    assert not check_team(path).ok and "missing send, sending, stop, resolve, share_check, share" in check_team(path).line
    path.write_text("[team]\n" + "".join(f'{name} = "x"\n' for name in REQUESTS))
    assert check_team(path).ok and check_team(path).line.startswith('on as "Team knowledge"')
    path.write_text('[team]\nchekc = "x"\n')
    assert not check_team(path).ok and "chekc" in check_team(path).line


def test_hello_says_team_only_when_the_deployment_can_be_checked() -> None:
    assert hello_for(make_config(), "e", "0.27.0").team is None
    hello = hello_for(make_config(team={"check": "true", "label": "Shared notes"}), "e", "0.27.0")
    assert hello.team is not None
    assert (hello.team.label, hello.team.folder, hello.team.intervals) == ("Shared notes", "_team", [15, 30, 60])


# --- the snapshot and the timer ---------------------------------------------------


async def test_before_the_first_check_reach_is_never(tmp_path: Path) -> None:
    mon, _ = monitor(tmp_path, Scripted())
    state = mon.snapshot()
    assert (state.reach, state.interval_minutes, state.last_ok_at, state.files) == ("never", 15, None, [])


async def test_a_check_publishes_the_deployments_state(tmp_path: Path) -> None:
    scripted = Scripted()
    scripted.state = {
        "reach": "ok",
        "waiting": [{"id": "s-1", "by": PRIYA, "files": ["plan.md"], "note": "For Thursday"}],
        "files": [row("_team/calendar.md", unread=True)],
    }
    mon, heard = monitor(tmp_path, scripted)
    await mon.check()
    state = heard.states[-1]
    assert state.reach == "ok" and state.last_ok_at is not None and state.next_check_at > state.last_ok_at
    assert [(s.id, s.by.short, s.note) for s in state.waiting] == [("s-1", "Priya", "For Thursday")]
    assert [(f.path, f.unread) for f in state.files] == [("_team/calendar.md", True)]


async def test_a_check_that_fails_keeps_the_rows_and_the_last_good_time(tmp_path: Path) -> None:
    scripted = Scripted()
    scripted.state["files"] = [row("_team/calendar.md")]
    mon, heard = monitor(tmp_path, scripted)
    await mon.check()
    good = heard.states[-1].last_ok_at
    scripted.answers["check"] = RuntimeError("no network")
    await mon.check()
    state = heard.states[-1]
    assert state.reach == "unreachable" and state.reach_reason is not None and "no network" in state.reach_reason
    assert state.last_ok_at == good and [f.path for f in state.files] == ["_team/calendar.md"]
    scripted.answers.pop("check")
    scripted.state["reach"], scripted.state["reach_reason"] = "refused", "Sign in again."
    await mon.check()
    assert (heard.states[-1].reach, heard.states[-1].reach_reason, heard.states[-1].last_ok_at) == ("refused", "Sign in again.", good)


async def test_output_that_is_not_the_expected_shape_is_a_failed_check(tmp_path: Path) -> None:
    scripted = Scripted()
    scripted.state = {"reach": "ok", "files": [{"path": "a.md"}]}
    mon, heard = monitor(tmp_path, scripted)
    await mon.check()
    assert heard.states[-1].reach == "unreachable" and "files.0.direction" in (heard.states[-1].reach_reason or "")


async def test_run_checks_at_start_at_each_interval_and_when_asked(tmp_path: Path) -> None:
    scripted = Scripted()
    mon, heard = monitor(tmp_path, scripted, interval_seconds=0.05)
    task = asyncio.create_task(mon.run())
    try:
        await asyncio.sleep(0.18)
        assert 2 <= len(scripted.named("check")) <= 5
        mon._interval_seconds = 30.0
        await asyncio.sleep(0.1)  # the check under way, or one more tick, then a long wait
        before = len(scripted.named("check"))
        await asyncio.sleep(0.1)
        assert len(scripted.named("check")) == before
        mon.check_now()
        await asyncio.sleep(0.05)
        assert len(scripted.named("check")) == before + 1
    finally:
        task.cancel()


async def test_the_interval_is_kept_across_a_restart_and_moves_the_next_check(tmp_path: Path) -> None:
    mon, heard = monitor(tmp_path, Scripted())
    await mon.check()
    first = heard.states[-1].next_check_at
    await mon.set_interval(60)
    assert heard.states[-1].interval_minutes == 60 and heard.states[-1].next_check_at > first
    with pytest.raises(ValueError):
        await mon.set_interval(7)
    again, _ = monitor(tmp_path, Scripted())
    assert again.interval_minutes == 60


async def test_seen_clears_unread_only_for_the_version_shown(tmp_path: Path) -> None:
    scripted = Scripted()
    scripted.state["files"] = [row("_team/calendar.md", rev="r-2", unread=True)]
    mon, heard = monitor(tmp_path, scripted)
    await mon.check()
    await mon.seen("_team/calendar.md", "r-1")  # an older version: still unread
    assert heard.states[-1].files[0].unread
    await mon.seen("_team/calendar.md", "r-2")
    assert not heard.states[-1].files[0].unread
    again, _ = monitor(tmp_path, scripted)
    await again.check()
    assert not again.snapshot().files[0].unread, "kept across a restart"
    scripted.state["files"] = [row("_team/calendar.md", rev="r-3", unread=True)]
    await again.check()
    assert again.snapshot().files[0].unread, "a newer version is unread again"


async def test_an_arrival_is_remembered_as_announced_only_once_an_app_was_shown_it(tmp_path: Path) -> None:
    scripted = Scripted()
    latest = {"id": "a-1", "kind": "changed", "at": TS, "summary": "_team/_summary.md", "files": ["_team/calendar.md"], "by": [PRIYA]}
    scripted.state["latest"] = latest
    mon, heard = monitor(tmp_path, scripted)
    heard.attached = False
    await mon.check()
    await mon.check()
    assert [c["announced"] for c in scripted.named("check")] == [None, None]
    heard.attached = True
    await mon.check()
    await mon.check()
    assert scripted.named("check")[-1]["announced"] == "a-1"
    again, _ = monitor(tmp_path, scripted)
    await again.check()
    assert scripted.named("check")[-1]["announced"] == "a-1", "kept across a restart"


# --- requests, each done once ---------------------------------------------------------


async def test_a_request_is_done_once_and_answered_again_after_a_restart(tmp_path: Path) -> None:
    scripted = Scripted()
    scripted.state["waiting"] = [share("s-1"), share("s-2")]
    scripted.answers["get"] = {"ok": False, "failed": [{"share": "s-2", "reason": "Try again."}], "state": scripted.state}
    mon, _ = monitor(tmp_path, scripted)
    await mon.check()
    first = await mon.request("req-1", "get", {"shares": ["s-1", "s-2"]})
    assert (first.id, first.ok) == ("req-1", False) and first.failed is not None and first.failed[0].share == "s-2"
    second = await mon.request("req-1", "get", {"shares": ["s-1", "s-2"]})
    assert second.model_dump(exclude={"ts"}) == first.model_dump(exclude={"ts"})
    assert len(scripted.named("get")) == 1
    again, _ = monitor(tmp_path, scripted)
    third = await again.request("req-1", "get", {"shares": ["s-1", "s-2"]})
    assert third.failed is not None and third.failed[0].reason == "Try again." and len(scripted.named("get")) == 1


async def test_the_same_request_sent_twice_at_once_runs_once(tmp_path: Path) -> None:
    scripted = Scripted()
    scripted.state["waiting"] = [share("s-1")]
    mon, heard = monitor(tmp_path, scripted)
    await mon.check()
    scripted.gate = asyncio.Event()
    one = asyncio.create_task(mon.request("req-1", "get", {"shares": ["s-1"]}))
    two = asyncio.create_task(mon.request("req-1", "get", {"shares": ["s-1"]}))
    await asyncio.sleep(0.05)
    assert heard.states[-1].getting == ["s-1"], "the app is told the Get is under way"
    scripted.gate.set()
    results = await asyncio.gather(one, two)
    assert [r.ok for r in results] == [True, True] and len(scripted.named("get")) == 1
    assert heard.states[-1].getting is None


async def test_a_get_carries_what_an_app_was_last_shown(tmp_path: Path) -> None:
    scripted = Scripted()
    scripted.state["waiting"] = [share("s-1")]
    scripted.state["latest"] = {"id": "a-4", "kind": "changed", "at": TS, "summary": "_team/_summary.md", "files": ["_team/x.md"]}
    mon, heard = monitor(tmp_path, scripted)
    await mon.check()  # the app is shown a-4 by this check's snapshot
    assert scripted.named("check")[-1] == {"announced": None}
    await mon.request("req-1", "get", {"shares": ["s-1"]})
    assert scripted.named("get") == [{"shares": ["s-1"], "announced": "a-4"}]


async def test_a_second_get_while_the_first_runs_does_not_ask_for_what_already_came(tmp_path: Path) -> None:
    # A double click: two requests, two ids. The second finds nothing still offered and is done, with no error.
    scripted = Scripted()
    scripted.state["waiting"] = [share("s-1")]
    mon, heard = monitor(tmp_path, scripted)
    await mon.check()
    scripted.gate = asyncio.Event()
    arrived = {"reach": "ok", "waiting": [], "files": [row("_team/s-1.md")]}
    scripted.answers["get"] = {"ok": True, "state": arrived}
    first = asyncio.create_task(mon.request("req-a", "get", {"shares": ["s-1"]}))
    second = asyncio.create_task(mon.request("req-b", "get", {"shares": ["s-1"]}))
    await asyncio.sleep(0.05)
    scripted.gate.set()
    results = await asyncio.gather(first, second)
    assert [r.ok for r in results] == [True, True] and len(scripted.named("get")) == 1
    assert heard.states[-1].getting is None and [f.path for f in heard.states[-1].files] == ["_team/s-1.md"]


async def test_a_request_the_deployment_cannot_run_is_a_result_not_a_crash(tmp_path: Path) -> None:
    scripted = Scripted()
    scripted.answers["sending"] = RuntimeError("disk full")
    mon, _ = monitor(tmp_path, scripted)
    result = await mon.request("req-1", "sending", {"paths": ["a.md"], "paused": True})
    assert not result.ok and "disk full" in (result.reason or "")
    (tmp_path / "x").mkdir()
    bare = TeamMonitor(TeamSource({"check": "true"}), tmp_path / "x", Heard().state, Heard().draft)
    result = await bare.request("req-2", "stop", {"paths": ["a.md"]})
    assert not result.ok and result.reason == "this deployment has no [team] stop"


async def test_a_paused_file_is_not_sent_and_a_file_with_two_versions_is_not_stopped(tmp_path: Path) -> None:
    scripted = Scripted()
    conflict = {"id": "c-1", "mine": {"path": "_team/.mine/b.md", "at": TS}}
    scripted.state["files"] = [row("a.md", paused={"since": TS}, pending={"since": TS}), row("b.md", conflict=conflict), row("c.md")]
    mon, _ = monitor(tmp_path, scripted)
    await mon.check()
    sent = await mon.request("req-1", "send", {"paths": ["a.md", "c.md"]})
    assert not sent.ok and sent.failed is not None and [(f.path, f.reason) for f in sent.failed] == [("a.md", PAUSED_REASON)]
    assert scripted.named("send") == [{"paths": ["c.md"]}], "the rest was done"
    stopped = await mon.request("req-2", "stop", {"paths": ["b.md"]})
    assert not stopped.ok and stopped.reason == CHOOSE_FIRST and scripted.named("stop") == []


async def test_resolve_is_refused_when_the_conflict_is_no_longer_the_rows(tmp_path: Path) -> None:
    scripted = Scripted()
    scripted.state["files"] = [row("b.md", conflict={"id": "c-2", "mine": {"path": "_team/.mine/b.md", "at": TS}})]
    mon, _ = monitor(tmp_path, scripted)
    await mon.check()
    stale = await mon.request("req-1", "resolve", {"path": "b.md", "conflict": "c-1", "use": "team"})
    assert not stale.ok and stale.reason == VERSION_CHANGED and scripted.named("resolve") == []
    fresh = await mon.request("req-2", "resolve", {"path": "b.md", "conflict": "c-2", "use": "mine"})
    assert fresh.ok and scripted.named("resolve") == [{"path": "b.md", "conflict": "c-2", "use": "mine"}]


# --- share ---------------------------------------------------------------------------


def finding(id: str = "f-1") -> dict[str, str]:
    return {"id": id, "path": "plan.md", "text": "Call me on 555 0100", "location": "Paragraph 3"}


async def settle(mon: TeamMonitor, id: str) -> None:
    task = mon._drafts[id].task
    assert task is not None
    await task


async def test_prepare_opens_a_draft_at_once_and_the_check_follows(tmp_path: Path) -> None:
    scripted = Scripted()
    scripted.answers["share_check"] = {"findings": [finding()]}
    mon, heard = monitor(tmp_path, scripted)
    assert await mon.prepare("d-1", ["plan.md"]) is None
    assert (heard.drafts[0].rev, heard.drafts[0].checking, heard.drafts[0].findings) == ("1", True, [])
    await settle(mon, "d-1")
    assert (heard.drafts[1].rev, heard.drafts[1].checking) == ("2", False)
    assert [f.location for f in heard.drafts[1].findings] == ["Paragraph 3"]
    assert scripted.named("share") == [], "nothing reaches the team before Share"


async def test_share_sends_the_findings_the_person_chose_to_take_out(tmp_path: Path) -> None:
    scripted = Scripted()
    scripted.answers["share_check"] = {"findings": [finding("f-1"), finding("f-2")]}
    mon, heard = monitor(tmp_path, scripted)
    await mon.prepare("d-1", ["plan.md"])
    await settle(mon, "d-1")
    result = await mon.share("d-1", "2", "For Thursday", ["f-2"], False)
    assert result.ok and result.id == "d-1"
    (request,) = scripted.named("share")
    assert request["paths"] == ["plan.md"] and request["note"] == "For Thursday" and request["unchecked"] is False
    assert [f["id"] for f in request["remove"]] == ["f-2"]
    again = await mon.share("d-1", "2", "For Thursday", ["f-2"], False)
    assert again.ok and len(scripted.named("share")) == 1, "the same Share is not sent twice"


async def test_share_is_refused_when_the_check_now_finds_something_not_shown(tmp_path: Path) -> None:
    scripted = Scripted()
    mon, heard = monitor(tmp_path, scripted)
    await mon.prepare("d-1", ["plan.md"])
    await settle(mon, "d-1")
    scripted.answers["share_check"] = {"findings": [finding()]}  # the file changed after the check
    refused = await mon.share("d-1", "2", None, [], False)
    assert not refused.ok and refused.reason == NEW_FINDINGS and scripted.named("share") == []
    assert (heard.drafts[-1].rev, len(heard.drafts[-1].findings)) == ("3", 1), "a new draft was sent"
    stale = await mon.share("d-1", "2", None, [], False)
    assert not stale.ok and stale.reason == DRAFT_CHANGED
    done = await mon.share("d-1", "3", None, ["f-1"], False)
    assert done.ok and [f["id"] for f in scripted.named("share")[0]["remove"]] == ["f-1"]


async def test_share_pressed_during_the_check_waits_for_it(tmp_path: Path) -> None:
    scripted = Scripted()
    scripted.gate = asyncio.Event()
    mon, heard = monitor(tmp_path, scripted)
    await mon.prepare("d-1", ["plan.md"])
    pressed = asyncio.create_task(mon.share("d-1", "1", None, [], False))
    await asyncio.sleep(0.05)
    assert scripted.named("share") == [] and not pressed.done()
    scripted.gate.set()
    assert (await pressed).ok and len(scripted.named("share")) == 1

    scripted.gate = asyncio.Event()
    scripted.answers["share_check"] = {"findings": [finding()]}
    await mon.prepare("d-2", ["plan.md"])
    pressed = asyncio.create_task(mon.share("d-2", "1", None, [], False))
    await asyncio.sleep(0.05)
    scripted.gate.set()
    refused = await pressed
    assert not refused.ok and refused.reason == NEW_FINDINGS and len(scripted.named("share")) == 1


async def test_a_check_that_cannot_finish_offers_share_anyway(tmp_path: Path) -> None:
    scripted = Scripted()
    scripted.answers["share_check"] = RuntimeError("scanner missing")
    mon, heard = monitor(tmp_path, scripted)
    await mon.prepare("d-1", ["plan.md"])
    await settle(mon, "d-1")
    assert heard.drafts[-1].check_error is not None and "scanner missing" in heard.drafts[-1].check_error
    refused = await mon.share("d-1", "2", None, [], False)
    assert not refused.ok and "scanner missing" in (refused.reason or "") and scripted.named("share") == []
    anyway = await mon.share("d-1", "2", None, [], True)
    assert anyway.ok and scripted.named("share")[0]["unchecked"] is True


async def test_cancel_while_share_checks_again_shares_nothing(tmp_path: Path) -> None:
    scripted = Scripted()
    mon, _ = monitor(tmp_path, scripted)
    await mon.prepare("d-1", ["plan.md"])
    await settle(mon, "d-1")
    scripted.gate = asyncio.Event()  # Share's own check, before anything is sent
    pressed = asyncio.create_task(mon.share("d-1", "2", None, [], False))
    await asyncio.sleep(0.05)
    await mon.cancel("d-1")
    scripted.gate.set()
    result = await pressed
    assert not result.ok and scripted.named("share") == [], "cancelled before anything reached the team"


async def test_cancel_drops_the_draft_and_nothing_is_shared(tmp_path: Path) -> None:
    scripted = Scripted()
    mon, _ = monitor(tmp_path, scripted)
    await mon.prepare("d-1", ["plan.md"])
    await mon.cancel("d-1")
    gone = await mon.share("d-1", "1", None, [], False)
    assert not gone.ok and scripted.named("share") == []


# --- the sample provider, as real commands -------------------------------------------------


class SampleSite:
    def __init__(self, tmp_path: Path) -> None:
        self.source = tmp_path / "team-source"
        self.root = tmp_path / "work"
        self.root.mkdir()
        self.state = tmp_path / "state"
        self.state.mkdir()
        base = f"{shlex.quote(sys.executable)} {shlex.quote(str(SAMPLE))} --source {shlex.quote(str(self.source))} --root {shlex.quote(str(self.root))} --me 'Larry Pelty'"
        self.commands = {name: f"{base} {name}" for name in REQUESTS}
        self.heard = Heard()
        self.monitor = TeamMonitor(TeamSource(self.commands, timeout=20.0), self.state, self.heard.state, self.heard.draft)

    def sim(self, *args: str) -> None:
        subprocess.run([sys.executable, str(SAMPLE), "--source", str(self.source), "sim", *args], check=True, capture_output=True)

    async def check(self) -> TeamState:
        await self.monitor.check()
        return self.heard.states[-1]


async def test_the_sample_get_then_a_change_from_the_team(tmp_path: Path) -> None:
    site = SampleSite(tmp_path)
    site.sim("seed")
    state = await site.check()
    assert [(s.by.short, s.files, s.note) for s in state.waiting] == [
        ("Priya", ["release-calendar.md", "review-template.md"], "The two files we agreed to keep in one place.")
    ]
    assert state.files == [] and not (site.root / "_team").exists(), "nothing waiting is on this Mac"

    result = await site.monitor.request("req-1", "get", {"shares": [state.waiting[0].id]})
    assert result.ok
    state = site.heard.states[-1]
    assert state.waiting == [] and [f.path for f in state.files] == ["_team/release-calendar.md", "_team/review-template.md"]
    assert state.latest is not None and state.latest.kind == "new" and state.latest.shares is not None
    assert state.latest.shares[0].note == "The two files we agreed to keep in one place."
    assert (site.root / state.latest.summary).is_file()
    assert all(f.unread and f.direction == "in" for f in state.files)

    site.sim("change", "--as", "Sam Ortiz", "release-calendar.md")
    state = await site.check()
    assert state.latest is not None and (state.latest.kind, state.latest.files) == ("changed", ["_team/release-calendar.md"])
    assert state.latest.by is not None and state.latest.by[0].short == "Sam"
    changed = next(f for f in state.files if f.path == "_team/release-calendar.md")
    assert changed.rev == "r-2" and changed.changed_by is not None and changed.changed_by.short == "Sam" and changed.summary
    assert (site.root / "_team/release-calendar.md").read_text().endswith("A line added by a teammate.\n"), "the person's copy is the team's"


async def test_the_sample_share_pause_two_versions_and_stop(tmp_path: Path) -> None:
    site = SampleSite(tmp_path)
    plan = site.root / "notes" / "plan.md"
    plan.parent.mkdir()
    original = "# Plan\n\nShip in December.\n\nPersonal: my review is on the 4th.\n"
    plan.write_text(original)
    await site.check()

    await site.monitor.prepare("d-1", ["notes/plan.md"])
    await settle(site.monitor, "d-1")
    draft = site.heard.drafts[-1]
    assert [(f.location, f.text) for f in draft.findings] == [("Paragraph 3", "Personal: my review is on the 4th.")]
    assert plan.read_text() == original, "the check changes nothing"
    shared = await site.monitor.share("d-1", draft.rev, "The plan", [draft.findings[0].id], False)
    assert shared.ok
    assert plan.read_text() == "# Plan\n\nShip in December.\n", "only the paragraph went: the rest is as it was"
    (mine,) = site.heard.states[-1].files
    assert (mine.path, mine.direction, mine.shared_by.short) == ("notes/plan.md", "out", "Larry")

    # A change here goes out at the next check.
    plan.write_text(plan.read_text() + "\nAnd January.\n")
    state = await site.check()
    assert state.files[0].pending is None and state.files[0].rev == "r-2" and state.files[0].sent_at is not None

    # Paused: the change waits. A change from the team on top of it makes two versions.
    assert (await site.monitor.request("req-p", "sending", {"paths": ["notes/plan.md"], "paused": True})).ok
    held_back = plan.read_text() + "\nAnd February.\n"
    plan.write_text(held_back)
    state = await site.check()
    assert state.files[0].paused is not None and state.files[0].pending is not None and state.files[0].rev == "r-2"
    site.sim("change", "--as", "Priya Raman", "--text", "Priya's line.", "plan.md")
    state = await site.check()
    conflict = state.files[0].conflict
    assert conflict is not None and plan.read_text().endswith("Priya's line.\n"), "the team's version is at the file's path"
    assert (site.root / conflict.mine.path).read_text() == held_back, "the person's version is kept beside it"
    refused = await site.monitor.request("req-s", "stop", {"paths": ["notes/plan.md"]})
    assert not refused.ok and refused.reason == CHOOSE_FIRST

    resolved = await site.monitor.request("req-r", "resolve", {"path": "notes/plan.md", "conflict": conflict.id, "use": "mine"})
    assert resolved.ok
    after = site.heard.states[-1].files[0]
    assert after.conflict is None and after.pending is None and after.paused is not None, "the pause survives the choice"
    assert plan.read_text() == held_back and not (site.root / conflict.mine.path).exists()

    stopped = await site.monitor.request("req-s2", "stop", {"paths": ["notes/plan.md"]})
    assert stopped.ok and site.heard.states[-1].files == [] and plan.exists(), "the person's own file stays"


async def test_the_sample_unreachable_keeps_rows_and_sends_when_reachable_again(tmp_path: Path) -> None:
    site = SampleSite(tmp_path)
    site.sim("seed")
    state = await site.check()
    await site.monitor.request("req-1", "get", {"shares": [state.waiting[0].id]})
    site.sim("reach", "unreachable")
    (site.root / "_team/review-template.md").write_text("changed here\n")
    state = await site.check()
    assert state.reach == "unreachable" and state.last_ok_at is not None and len(state.files) == 2
    assert next(f for f in state.files if f.path == "_team/review-template.md").pending is not None
    site.sim("reach", "ok")
    state = await site.check()
    assert state.reach == "ok" and next(f for f in state.files if f.path == "_team/review-template.md").pending is None

    site.sim("remove", "release-calendar.md")
    state = await site.check()
    assert [f.path for f in state.files] == ["_team/review-template.md"] and not (site.root / "_team/release-calendar.md").exists()
    assert (await site.monitor.request("req-2", "stop", {"paths": ["_team/review-template.md"]})).ok
    state = await site.check()
    assert state.files == [] and state.waiting == [], "a stopped file is not offered again"


async def test_the_sample_take_it_out_touches_nothing_else_and_nothing_at_all_when_refused(tmp_path: Path) -> None:
    site = SampleSite(tmp_path)
    notes = site.root / "notes.md"
    text = "# Notes\n\n\nFirst.\n\n```\ncode\n\nmore code\n```\n\nPrivate: only for me.\n\nLast.\n"
    notes.write_text(text)
    await site.check()
    await site.monitor.prepare("d-1", ["notes.md"])
    await settle(site.monitor, "d-1")
    draft = site.heard.drafts[-1]
    (found,) = draft.findings
    assert found.text == "Private: only for me."

    # The team already has a file of this name: the share is refused, and the person's file is untouched.
    other = tmp_path / "theirs" / "notes.md"
    other.parent.mkdir()
    other.write_text("theirs\n")
    site.sim("share", "--as", "Priya Raman", str(other))
    refused = await site.monitor.share("d-1", draft.rev, None, [found.id], False)
    assert not refused.ok and refused.failed is not None and "already has a file" in refused.failed[0].reason
    assert notes.read_text() == text

    site.sim("remove", "notes.md")
    done = await site.monitor.share("d-1", site.heard.drafts[-1].rev, None, [found.id], False)
    assert done.ok
    assert notes.read_text() == text.replace("\n\nPrivate: only for me.", ""), "the blank lines and the code block are as they were"


async def test_the_sample_a_get_after_a_shown_change_announces_only_what_is_new(tmp_path: Path) -> None:
    site = SampleSite(tmp_path)
    site.sim("seed")
    state = await site.check()
    await site.monitor.request("req-1", "get", {"shares": [state.waiting[0].id]})
    # A teammate's change and another teammate's share land between the same two checks.
    site.sim("change", "release-calendar.md")
    extra = tmp_path / "b.md"
    extra.write_text("b\n")
    site.sim("share", "--as", "Sam Ortiz", str(extra))
    state = await site.check()  # the one check that shows the change and offers the share
    assert state.latest is not None and (state.latest.kind, state.latest.files) == ("changed", ["_team/release-calendar.md"])
    await site.monitor.request("req-2", "get", {"shares": [state.waiting[0].id]})
    latest = site.heard.states[-1].latest
    assert latest is not None and (latest.kind, latest.files) == ("new", ["_team/b.md"]), "the shown change is not announced again"
    assert latest.by is None, "the change's author is not the new share's"


async def test_the_sample_never_deletes_changes_that_were_not_sent(tmp_path: Path) -> None:
    site = SampleSite(tmp_path)
    site.sim("seed")
    state = await site.check()
    await site.monitor.request("req-1", "get", {"shares": [state.waiting[0].id]})
    template = site.root / "_team/review-template.md"
    assert (await site.monitor.request("req-p", "sending", {"paths": ["_team/review-template.md"], "paused": True})).ok
    template.write_text("my unsent edit\n")
    assert (await site.monitor.request("req-s", "stop", {"paths": ["_team/review-template.md"]})).ok
    assert not template.exists(), "the team's copy leaves the team folder"
    assert (site.root / "_team/.mine/review-template.md").read_text() == "my unsent edit\n", "the unsent changes are kept"

    calendar = site.root / "_team/release-calendar.md"
    calendar.write_text("another unsent edit\n")
    site.sim("reach", "unreachable")
    await site.check()
    site.sim("remove", "release-calendar.md")
    site.sim("reach", "ok")
    await site.check()
    assert not calendar.exists() and (site.root / "_team/.mine/release-calendar.md").read_text() == "another unsent edit\n"


async def test_the_sample_use_my_version_does_not_overwrite_a_newer_team_version(tmp_path: Path) -> None:
    site = SampleSite(tmp_path)
    plan = site.root / "plan.md"
    plan.write_text("# Plan\n")
    await site.check()
    await site.monitor.prepare("d-1", ["plan.md"])
    await settle(site.monitor, "d-1")
    assert (await site.monitor.share("d-1", site.heard.drafts[-1].rev, None, [], False)).ok
    assert (await site.monitor.request("req-p", "sending", {"paths": ["plan.md"], "paused": True})).ok
    plan.write_text("# Plan\n\nMine.\n")
    site.sim("change", "--text", "Priya's first.", "plan.md")
    state = await site.check()
    conflict = state.files[0].conflict
    assert conflict is not None
    site.sim("change", "--text", "Priya's second.", "plan.md")  # after the check the person's choice rests on
    refused = await site.monitor.request("req-r", "resolve", {"path": "plan.md", "conflict": conflict.id, "use": "mine"})
    assert not refused.ok
    assert (site.source / "files" / "plan.md").read_text().endswith("Priya's second.\n"), "the team's newer version is still the team's"
    now = site.heard.states[-1].files[0].conflict
    assert now is not None and now.id != conflict.id and plan.read_text().endswith("Priya's second.\n")
    assert (site.root / now.mine.path).read_text() == "# Plan\n\nMine.\n"


async def test_the_sample_keeps_what_is_typed_into_the_teams_version_while_there_are_two(tmp_path: Path) -> None:
    site = SampleSite(tmp_path)
    plan = site.root / "plan.md"
    plan.write_text("# Plan\n")
    await site.check()
    await site.monitor.prepare("d-1", ["plan.md"])
    await settle(site.monitor, "d-1")
    assert (await site.monitor.share("d-1", site.heard.drafts[-1].rev, None, [], False)).ok
    assert (await site.monitor.request("req-p", "sending", {"paths": ["plan.md"], "paused": True})).ok
    plan.write_text("# Plan\n\nMine.\n")
    site.sim("change", "--text", "Priya's first.", "plan.md")
    await site.check()
    mine = site.root / "_team/.mine/plan.md"
    assert mine.read_text() == "# Plan\n\nMine.\n"

    # The viewer opens the file at its own path: a merge by hand is typed there.
    merged = plan.read_text() + "\nMerged by hand.\n"
    plan.write_text(merged)
    site.sim("change", "--text", "Priya's second.", "plan.md")
    state = await site.check()
    assert plan.read_text().endswith("Priya's second.\n"), "the team's newer version is at the file's path"
    kept = [p for p in mine.parent.iterdir() if p.name.startswith("plan.edited-")]
    assert [p.read_text() for p in kept] == [merged], "what was typed into the team's version is kept beside it"
    assert mine.read_text() == "# Plan\n\nMine.\n"

    # Use the team's version, after typing into it again: the typing is a change of the person's, and it is sent.
    conflict = state.files[0].conflict
    assert conflict is not None
    typed = plan.read_text() + "\nOne more line of mine.\n"
    plan.write_text(typed)
    assert (await site.monitor.request("req-r", "resolve", {"path": "plan.md", "conflict": conflict.id, "use": "team"})).ok
    assert plan.read_text() == typed
    assert (await site.monitor.request("req-u", "sending", {"paths": ["plan.md"], "paused": False})).ok
    state = await site.check()
    assert (site.source / "files" / "plan.md").read_text() == typed, "it was not taken as in step and dropped"
    assert state.files[0].conflict is None and state.files[0].pending is None


async def test_the_sample_use_my_version_keeps_what_was_typed_into_the_teams(tmp_path: Path) -> None:
    site = SampleSite(tmp_path)
    plan = site.root / "plan.md"
    plan.write_text("# Plan\n")
    await site.check()
    await site.monitor.prepare("d-1", ["plan.md"])
    await settle(site.monitor, "d-1")
    assert (await site.monitor.share("d-1", site.heard.drafts[-1].rev, None, [], False)).ok
    assert (await site.monitor.request("req-p", "sending", {"paths": ["plan.md"], "paused": True})).ok
    plan.write_text("# Plan\n\nMine.\n")
    site.sim("change", "--text", "Priya's.", "plan.md")
    state = await site.check()
    conflict = state.files[0].conflict
    assert conflict is not None
    typed = plan.read_text() + "\nTyped into the team's version.\n"
    plan.write_text(typed)
    assert (await site.monitor.request("req-r", "resolve", {"path": "plan.md", "conflict": conflict.id, "use": "mine"})).ok
    assert plan.read_text() == "# Plan\n\nMine.\n"
    kept = [p for p in (site.root / "_team/.mine").iterdir() if p.name.startswith("plan.edited-")]
    assert [p.read_text() for p in kept] == [typed]


async def test_the_sample_shares_all_of_several_files_or_none(tmp_path: Path) -> None:
    site = SampleSite(tmp_path)
    theirs = tmp_path / "notes.md"
    theirs.write_text("Priya's notes\n")
    site.sim("share", str(theirs))
    first, second = site.root / "a.md", site.root / "notes.md"
    text = "# A\n\npersonal: my own line\n\nThe rest.\n"
    first.write_text(text)
    second.write_text("my notes\n")
    await site.check()
    await site.monitor.prepare("d-1", ["a.md", "notes.md"])
    await settle(site.monitor, "d-1")
    draft = site.heard.drafts[-1]
    assert len(draft.findings) == 1
    for _ in range(2):  # Share, and Share again
        result = await site.monitor.share("d-1", draft.rev, None, [draft.findings[0].id], False)
        assert not result.ok and result.failed is not None
        assert [(f.path, f.reason) for f in result.failed] == [("notes.md", "The team already has a file with this name.")]
        assert first.read_text() == text, "nothing was taken out of a file that did not go"
        assert not (site.source / "files" / "a.md").exists(), "and it was not shared"
    assert site.heard.states[-1].files == []


async def test_the_sample_send_now_says_so_when_the_team_changed_the_file_first(tmp_path: Path) -> None:
    site = SampleSite(tmp_path)
    plan = site.root / "plan.md"
    plan.write_text("# Plan\n")
    await site.check()
    await site.monitor.prepare("d-1", ["plan.md"])
    await settle(site.monitor, "d-1")
    assert (await site.monitor.share("d-1", site.heard.drafts[-1].rev, None, [], False)).ok
    plan.write_text("# Plan\n\nMine.\n")
    site.sim("change", "--text", "Priya's.", "plan.md")  # not yet seen by a check
    result = await site.monitor.request("req-s", "send", {"paths": ["plan.md"]})
    assert not result.ok and result.failed is not None and result.failed[0].path == "plan.md"
    assert (site.source / "files" / "plan.md").read_text().endswith("Priya's.\n"), "the team's version was not written over"
    state = await site.check()
    assert state.files[0].conflict is not None, "the next check shows both versions"


async def test_the_sample_restarted_while_unreachable_still_says_when_it_last_checked(tmp_path: Path) -> None:
    site = SampleSite(tmp_path)
    site.sim("seed")
    state = await site.check()
    await site.monitor.request("req-1", "get", {"shares": [state.waiting[0].id]})
    good = (await site.check()).last_ok_at
    assert good is not None
    site.sim("reach", "unreachable")
    again = SampleSite.__new__(SampleSite)  # the gateway starts again on the same state
    again.heard = Heard()
    again.monitor = TeamMonitor(TeamSource(site.commands, timeout=20.0), site.state, again.heard.state, again.heard.draft)
    await again.monitor.check()
    state = again.heard.states[-1]
    assert state.reach == "unreachable" and len(state.files) == 2
    assert state.last_ok_at == good, "the rows are not shown as checked just now"


# --- the server ---------------------------------------------------------------------------


async def attach_team(server: GatewayServer, capabilities: list[str] | None = None) -> tuple[ClientConnection, HelloServer]:
    conn = await connect(ws_url(server, server.token))
    await conn.send(dump(HelloClient(ts=TS, app_version="0.27.0", capabilities=[TEAM_CAPABILITY] if capabilities is None else capabilities)))
    hello = parse_server(await conn.recv())
    assert isinstance(hello, HelloServer)
    assert isinstance(parse_server(await conn.recv()), ChatList)
    assert isinstance(parse_server(await conn.recv()), ServicesStatus)
    return conn, hello


async def start(state_dir: StateDir, **config: Any) -> GatewayServer:
    cfg = make_config(**config)
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=cfg.history_buffer)
    srv = GatewayServer(config=cfg, state=state_dir, registry=registry, engine_factory=FakeEngine, version=__version__)
    await srv.serve(0)
    return srv


@pytest.fixture
async def team_server(state_dir: StateDir, tmp_path: Path) -> AsyncIterator[GatewayServer]:
    site = SampleSite(tmp_path)
    site.sim("seed")
    srv = await start(state_dir, team=site.commands)
    try:
        yield srv
    finally:
        await srv.shutdown()


async def checked_state(conn: ClientConnection) -> TeamState:
    """The first snapshot after the first check (the one sent on attach may come before it)."""
    while True:
        state = (await recv_until(conn, TeamState))[-1]
        assert isinstance(state, TeamState)
        if state.reach != "never":
            return state


async def test_the_app_hears_team_state_after_hello_and_a_get_is_answered(team_server: GatewayServer) -> None:
    conn, hello = await attach_team(team_server)
    try:
        assert hello.team is not None and hello.team.folder == "_team"
        state = await checked_state(conn)
        assert [s.by.short for s in state.waiting] == ["Priya"]
        await conn.send(dump(TeamGet(ts=TS, id="req-g", shares=[state.waiting[0].id])))
        frames = await recv_until(conn, TeamResult)
        result = frames[-1]
        assert isinstance(result, TeamResult) and result.ok and result.id == "req-g"
        states = [f for f in frames if isinstance(f, TeamState)]
        assert states[0].getting == [state.waiting[0].id] and len(states[-1].files) == 2 and states[-1].latest is not None

        await conn.send(dump(TeamSeen(ts=TS, path="_team/release-calendar.md", rev=states[-1].files[0].rev)))
        seen = (await recv_until(conn, TeamState))[-1]
        assert isinstance(seen, TeamState) and [f.unread for f in seen.files] == [False, True]

        await conn.send(dump(TeamIntervalSet(ts=TS, id="req-i", minutes=30)))
        moved = (await recv_until(conn, TeamState))[-1]
        assert isinstance(moved, TeamState) and moved.interval_minutes == 30
        await conn.send(dump(TeamIntervalSet(ts=TS, id="req-j", minutes=7)))
        err = (await recv_until(conn, Error))[-1]
        assert isinstance(err, Error) and err.code == "team.interval" and err.id == "req-j"

        await conn.send(dump(TeamGet(ts=TS, id="req-g", shares=["s-1"])))  # the same id again
        again = (await recv_until(conn, TeamResult))[-1]
        assert isinstance(again, TeamResult) and again.ok

        await conn.send(dump(TeamCheck(ts=TS)))
        assert isinstance((await recv_until(conn, TeamState))[-1], TeamState)
    finally:
        await conn.close()


async def test_a_share_over_the_socket(team_server: GatewayServer, tmp_path: Path) -> None:
    plan = tmp_path / "work" / "plan.md"
    plan.write_text("# Plan\n\nWrite to me at someone@example.com.\n")
    conn, _ = await attach_team(team_server)
    try:
        await checked_state(conn)
        await conn.send(dump(TeamSharePrepare(ts=TS, id="d-1", paths=["plan.md"])))
        draft = (await recv_until(conn, TeamShareDraft))[-1]
        while isinstance(draft, TeamShareDraft) and draft.checking:
            draft = (await recv_until(conn, TeamShareDraft))[-1]
        assert isinstance(draft, TeamShareDraft) and [f.location for f in draft.findings] == ["Paragraph 2"]
        await conn.send(dump(TeamShareSend(ts=TS, id="d-1", rev=draft.rev, note="The plan", remove=[draft.findings[0].id])))
        frames = await recv_until(conn, TeamResult)
        assert isinstance(frames[-1], TeamResult) and frames[-1].ok
        rows = [f for f in frames if isinstance(f, TeamState)][-1].files
        assert [(f.path, f.direction) for f in rows] == [("plan.md", "out")]
        assert plan.read_text() == "# Plan\n"
    finally:
        await conn.close()


async def test_an_app_that_cannot_draw_team_knowledge_is_sent_none_of_it(team_server: GatewayServer) -> None:
    conn, hello = await attach_team(team_server, capabilities=[])
    try:
        await team_server.team.check()
        await team_server.broadcast(TeamResult(ts=TS, id="x", ok=True))
        await conn.send(dump(TeamStop(ts=TS, paths=["a.md"])))  # no id: an error, which every app can read
        frame = await recv(conn)
        assert isinstance(frame, Error) and frame.code == "team.no_id", "no team frame came before it"
    finally:
        await conn.close()


async def test_without_team_knowledge_nothing_runs_and_requests_are_refused(state_dir: StateDir) -> None:
    srv = await start(state_dir)
    try:
        assert not any(t.get_name() == "portico-team" for t in srv._tasks)
        conn, hello = await attach_team(srv)
        try:
            assert hello.team is None
            await conn.send(dump(TeamCheck(ts=TS, id="req-c")))
            err = await recv(conn)
            assert isinstance(err, Error) and err.code == "team.off" and err.id == "req-c"
        finally:
            await conn.close()
    finally:
        await srv.shutdown()
