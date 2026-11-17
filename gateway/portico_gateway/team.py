"""Team knowledge (v0.27, ``team.v1``): the deployment's team source, checked on a timer.

Portico never knows what the team source is. A deployment answers eight
requests, each by a ``[team]`` command or a plug-in hook of the same name
(``team_check`` for ``check`` and so on; a hook takes precedence)::

    [team]
    label = "Team knowledge"          # optional; what the app calls it
    folder = "_team"                  # optional; where files from other people live
    check = "my-tool team check"
    get = "my-tool team get"
    send = "my-tool team send"
    sending = "my-tool team sending"
    stop = "my-tool team stop"
    resolve = "my-tool team resolve"
    share_check = "my-tool team share-check"
    share = "my-tool team share"

A command runs with ``/bin/sh -c``, bounded by ``command_timeout_seconds``.
It reads one JSON object on stdin (the request) and prints one JSON object
on stdout (the answer); stderr only names the reason when it exits
non-zero. A hook is called with the request as a dict and returns the
answer as a dict (or that JSON as text); raising is a failure, and the
exception's message is the reason.

The requests and their answers:

``check``  ``{"announced": id?}``. Sends what is due, brings in what
    changed for files already held, and prints the whole state:
    ``{"reach": "ok" | "unreachable" | "refused", "reach_reason"?,
    "waiting": [share], "latest"?: {...}, "files": [row]}``, with the
    shapes ``team.state`` has. ``announced`` is the ``latest.id`` an app
    was last shown: ``latest`` covers every arrival after it, so arrivals
    while no app was attached are announced as one. A check that cannot
    reach the source still prints the rows it knows, with ``reach`` saying so.
``get``  ``{"shares": [id]}``. Accept and bring in these shares.
``send``  ``{"paths": [path]}``. Send these files' changes now.
``sending``  ``{"paths": [path], "paused": bool}``. Pause or resume.
``stop``  ``{"paths": [path]}``. Stop syncing on this Mac.
``resolve``  ``{"path", "conflict", "use": "mine" | "team"}``.
``share``  ``{"paths", "note"?, "remove": [finding], "unchecked": bool}``.
    Take each finding out of the person's own file, then share the files.

    Each of these six prints ``{"ok": bool, "reason"?, "failed"?:
    [{"path" | "share", "reason"}], "state"?: {...}}``. ``state`` is what
    ``check`` prints, as it stands after the request; without it the
    snapshot is left as it was.
``share_check``  ``{"paths": [path]}``. The check for personal material.
    Prints ``{"findings": [{"id", "path", "text", "location"}], "error"?}``.
    Changes nothing. A finding keeps its ``id`` while its text stays where
    it was, so the gateway can tell a new finding from one already shown.

The gateway owns the timer, the kept interval, what the person has opened
(``team.seen``), the outcome of every request by its ``id`` (kept in
``team.json`` for ``OUTCOME_DAYS``, so a request sent twice is done once),
the share drafts, and the one snapshot it sends. Detecting a change,
holding a pause, remembering a stop, saving a second version and writing
the change summary are the deployment's.
"""

from __future__ import annotations

import asyncio
import contextlib
import inspect
import json
import logging
import os
import signal
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, ValidationError

from .plugins import TEAM_REQUESTS
from .messages import (
    TeamFailure,
    TeamFile,
    TeamFinding,
    TeamHello,
    TeamLatest,
    TeamResult,
    TeamShare,
    TeamShareDraft,
    TeamState,
)

log = logging.getLogger(__name__)

SHELL = "/bin/sh"
# The eight requests a deployment answers, by config key and (with ``team_`` in front) by hook name.
REQUESTS = TEAM_REQUESTS
# Larry's ruling of 2026-11-16: 15, 30 or 60 minutes, 15 unless the person chose.
INTERVALS = (15, 30, 60)
DEFAULT_INTERVAL = 15
DEFAULT_LABEL = "Team knowledge"
DEFAULT_FOLDER = "_team"
# How long a request's outcome is kept, so the same ``id`` is answered and not repeated.
OUTCOME_DAYS = 2
STATE_FILE = "team.json"
REASON_LIMIT = 240

CHOOSE_FIRST = "Choose a version first"
PAUSED_REASON = "Sending is paused for this file"
VERSION_CHANGED = "The team's version changed. Look again before choosing."
NEW_FINDINGS = "The check found something new. Look again before sharing."
DRAFT_CHANGED = "This share changed. Look again before sharing."
DRAFT_GONE = "This share is no longer open. Start it again."

Hook = Callable[[dict[str, Any]], Any]
Clock = Callable[[], datetime]
PublishState = Callable[[TeamState], Awaitable[bool]]
PublishDraft = Callable[[TeamShareDraft], Awaitable[None]]


class SourceFailed(Exception):
    """A request to the deployment did not work; the message is the reason, one line."""


class NoSource(SourceFailed):
    """The deployment gives no command or hook for this request."""


def _short(text: str) -> str:
    line = text.strip().splitlines()[-1].strip() if text.strip() else ""
    return line if len(line) <= REASON_LIMIT else line[: REASON_LIMIT - 1] + "…"


def _iso(moment: datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _kill(pid: int) -> None:
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(pid, signal.SIGKILL)


async def run_json_command(command: str, request: dict[str, Any], timeout: float) -> Any:
    """Run ``command`` with ``request`` as JSON on stdin; its stdout parsed as JSON. ``SourceFailed`` otherwise."""
    try:
        proc = await asyncio.create_subprocess_exec(
            SHELL, "-c", command,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as e:
        raise SourceFailed(f"could not start: {e}") from None
    try:
        out, err = await asyncio.wait_for(proc.communicate(json.dumps(request).encode()), timeout)
    except TimeoutError:
        _kill(proc.pid)
        await proc.wait()
        raise SourceFailed(f"timed out after {timeout:g} s") from None
    except asyncio.CancelledError:
        _kill(proc.pid)  # the gateway is stopping: leave nothing behind
        raise
    if proc.returncode != 0:
        last = _short(err.decode(errors="replace")) or _short(out.decode(errors="replace"))
        raise SourceFailed(f"exited {proc.returncode}" + (f": {last}" if last else ""))
    try:
        return json.loads(out.decode(errors="replace"))
    except ValueError as e:
        raise SourceFailed(f"output is not JSON: {e}") from None


class TeamSource:
    """The deployment's answers: a hook when a plug-in gives one, else the ``[team]`` command."""

    def __init__(self, commands: Mapping[str, str | None], hooks: Mapping[str, Hook] | None = None, timeout: float = 120.0) -> None:
        self.commands = {name: command for name, command in commands.items() if command}
        self.hooks = dict(hooks or {})
        self.timeout = timeout

    def has(self, name: str) -> bool:
        return name in self.hooks or name in self.commands

    @property
    def active(self) -> bool:
        """Team knowledge is on when the deployment can be checked."""
        return self.has("check")

    def missing(self) -> list[str]:
        return [name for name in REQUESTS if not self.has(name)]

    async def call(self, name: str, request: dict[str, Any]) -> dict[str, Any]:
        """Ask the deployment; its answer as a dict. ``NoSource`` when it has none, ``SourceFailed`` when it did not work."""
        hook = self.hooks.get(name)
        if hook is not None:
            raw = await self._call_hook(hook, request)
        elif name in self.commands:
            raw = await run_json_command(self.commands[name], request, self.timeout)
        else:
            raise NoSource(f"this deployment has no [team] {name}")
        if isinstance(raw, (str, bytes)):
            try:
                raw = json.loads(raw)
            except ValueError as e:
                raise SourceFailed(f"output is not JSON: {e}") from None
        if not isinstance(raw, dict):
            raise SourceFailed("output is not a JSON object")
        return raw

    async def _call_hook(self, hook: Hook, request: dict[str, Any]) -> Any:
        try:
            async with asyncio.timeout(self.timeout):
                if inspect.iscoroutinefunction(hook):
                    return await hook(request)
                result = await asyncio.to_thread(hook, request)
                if inspect.isawaitable(result):
                    result = await result
                return result
        except TimeoutError:
            raise SourceFailed(f"timed out after {self.timeout:g} s") from None
        except SourceFailed:
            raise
        except Exception as e:
            raise SourceFailed(_short(f"{type(e).__name__}: {e}")) from None


class SourceState(BaseModel):
    """What ``check`` prints, and ``state`` in every other answer."""

    model_config = ConfigDict(extra="ignore")

    reach: Literal["ok", "unreachable", "refused"] = "ok"
    reach_reason: str | None = None
    waiting: list[TeamShare] = []
    latest: TeamLatest | None = None
    files: list[TeamFile] = []


class SourceAnswer(BaseModel):
    """What a request other than ``check`` and ``share_check`` prints."""

    model_config = ConfigDict(extra="ignore")

    ok: bool | None = None
    reason: str | None = None
    failed: list[TeamFailure] = []
    state: SourceState | None = None


class SourceFindings(BaseModel):
    model_config = ConfigDict(extra="ignore")

    findings: list[TeamFinding] = []
    error: str | None = None


def _parse(model: type[BaseModel], raw: dict[str, Any]) -> Any:
    try:
        return model.model_validate(raw)
    except ValidationError as e:
        first = e.errors()[0]
        where = ".".join(str(part) for part in first["loc"])
        raise SourceFailed(f"output could not be read: {where}: {first['msg']}") from None


@dataclass
class Draft:
    """One share being prepared. In memory only: a gateway restart drops it."""

    id: str
    paths: list[str]
    note: str | None = None
    chat: int | None = None
    rev: int = 1
    checking: bool = True
    check_error: str | None = None
    findings: list[TeamFinding] = field(default_factory=list)
    task: asyncio.Task[None] | None = None
    # The findings each ``rev`` showed the person, by finding id.
    shown: dict[str, set[str]] = field(default_factory=dict)


class TeamMonitor:
    """Owns the timer, the snapshot, the kept outcomes and the drafts; asks the deployment for everything else."""

    def __init__(
        self,
        source: TeamSource,
        state_dir: Path,
        publish: PublishState,
        publish_draft: PublishDraft,
        label: str = DEFAULT_LABEL,
        folder: str = DEFAULT_FOLDER,
        clock: Clock | None = None,
        interval_seconds: float | None = None,
    ) -> None:
        self.source = source
        self.path = Path(state_dir) / STATE_FILE
        self._publish = publish
        self._publish_draft = publish_draft
        self.label = label
        self.folder = folder
        self._clock: Clock = clock if clock is not None else (lambda: datetime.now(UTC))
        # Tests run the timer in seconds; a deployment's interval is always whole minutes.
        self._interval_seconds = interval_seconds
        kept = self._load()
        minutes = kept.get("interval_minutes")
        self.interval_minutes: int = minutes if minutes in INTERVALS else DEFAULT_INTERVAL
        self._seen: dict[str, str] = {k: v for k, v in (kept.get("seen") or {}).items() if isinstance(v, str)}
        self._announced: str | None = kept.get("announced") if isinstance(kept.get("announced"), str) else None
        self._outcomes: dict[str, dict[str, Any]] = dict(kept.get("outcomes") or {})
        self._inflight: dict[str, asyncio.Future[TeamResult]] = {}
        self._drafts: dict[str, Draft] = {}
        self._reach: Literal["ok", "unreachable", "refused", "never"] = "never"
        self._reach_reason: str | None = None
        self._last_ok: datetime | None = None
        self._next: datetime = self._clock()
        self._source_state = SourceState()
        self._getting: list[str] | None = None
        # One request to the deployment at a time: a check never runs across a Get.
        self._lock = asyncio.Lock()
        self._wake = asyncio.Event()
        self._check_requested = False

    # --- what the app is told -------------------------------------------------

    @property
    def active(self) -> bool:
        return self.source.active

    def hello(self) -> TeamHello | None:
        if not self.active:
            return None
        return TeamHello(label=self.label, folder=self.folder, intervals=list(INTERVALS))

    def snapshot(self) -> TeamState:
        """The one snapshot: the deployment's state, with what the gateway itself keeps."""
        files = [
            row.model_copy(update={"unread": row.unread and self._seen.get(row.path) != row.rev})
            for row in self._source_state.files
        ]
        return TeamState(
            ts=_iso(self._clock()),
            reach=self._reach,
            reach_reason=self._reach_reason if self._reach in ("unreachable", "refused") else None,
            last_ok_at=_iso(self._last_ok) if self._last_ok is not None else None,
            next_check_at=_iso(self._next),
            interval_minutes=self.interval_minutes,
            waiting=list(self._source_state.waiting),
            getting=list(self._getting) if self._getting else None,
            latest=self._source_state.latest,
            files=files,
        )

    async def publish(self) -> None:
        """Send the snapshot; an arrival an app was shown is remembered, so it is announced once."""
        state = self.snapshot()
        delivered = await self._publish(state)
        self.note_delivered(state, delivered)

    def note_delivered(self, state: TeamState, delivered: bool) -> None:
        if delivered and state.latest is not None and state.latest.id != self._announced:
            self._announced = state.latest.id
            self._save()

    # --- the timer --------------------------------------------------------------

    def _interval(self) -> timedelta:
        if self._interval_seconds is not None:
            return timedelta(seconds=self._interval_seconds)
        return timedelta(minutes=self.interval_minutes)

    async def run(self) -> None:
        """Check at start, then at every interval; ``check_now`` and a new interval wake it."""
        while True:
            try:
                await self.check()
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("team check failed")
            while not self._check_requested:
                delay = (self._next - self._clock()).total_seconds()
                if delay <= 0:
                    break
                self._wake.clear()
                with contextlib.suppress(TimeoutError):
                    await asyncio.wait_for(self._wake.wait(), delay)
            self._check_requested = False

    def check_now(self) -> None:
        """Run the check at once (Try again); answered by the ``team.state`` that follows."""
        self._check_requested = True
        self._wake.set()

    async def check(self) -> None:
        """One check: the deployment sends what is due, brings in what changed, and says how things stand."""
        async with self._lock:
            started = self._clock()
            try:
                raw = await self.source.call("check", {"announced": self._announced})
                self._apply(_parse(SourceState, raw))
            except SourceFailed as e:
                # The rows stay as last known; the app says when they were last checked.
                self._reach, self._reach_reason = "unreachable", f"The team check did not work: {e}"
                log.warning("team check: %s", e)
            self._next = max(started, self._clock()) + self._interval()
        await self.publish()

    def _apply(self, state: SourceState) -> None:
        self._source_state = state
        self._reach, self._reach_reason = state.reach, state.reach_reason
        if state.reach == "ok":
            self._last_ok = self._clock()
        held = {row.path for row in state.files}
        if any(path not in held for path in self._seen):
            self._seen = {path: rev for path, rev in self._seen.items() if path in held}
            self._save()

    async def set_interval(self, minutes: int) -> None:
        """Keep the interval and count the next check from the last one."""
        if minutes not in INTERVALS:
            raise ValueError(f"the interval must be one of {', '.join(str(i) for i in INTERVALS)} minutes")
        previous = self._interval()
        self.interval_minutes = minutes
        self._save()
        self._next = self._next - previous + self._interval()
        self._wake.set()
        await self.publish()

    async def seen(self, path: str, rev: str) -> None:
        """The person opened this version: its row stops being unread, if ``rev`` is still the row's."""
        row = self._row(path)
        if row is None or row.rev != rev or self._seen.get(path) == rev:
            return
        self._seen[path] = rev
        self._save()
        if row.unread:
            await self.publish()

    def _row(self, path: str) -> TeamFile | None:
        return next((row for row in self._source_state.files if row.path == path), None)

    # --- requests, each done once -------------------------------------------------

    async def request(self, id: str, name: str, payload: dict[str, Any]) -> TeamResult:
        """Do ``name`` once for ``id``; the same ``id`` again is answered with the first outcome."""
        return await self._once(id, lambda: self._do(name, payload))

    async def _once(self, id: str, work: Callable[[], Awaitable[TeamResult]], keep_failure: bool = True) -> TeamResult:
        kept = self._outcomes.get(id)
        if kept is not None:
            return self._result(id, kept)
        running = self._inflight.get(id)
        if running is not None:
            return (await asyncio.shield(running)).model_copy(update={"ts": _iso(self._clock())})
        future: asyncio.Future[TeamResult] = asyncio.get_running_loop().create_future()
        self._inflight[id] = future
        try:
            result = (await work()).model_copy(update={"id": id})
        except BaseException as e:
            future.cancel() if isinstance(e, asyncio.CancelledError) else future.set_exception(e)
            with contextlib.suppress(BaseException):
                future.exception()  # nobody else may be waiting: mark it retrieved
            raise
        finally:
            self._inflight.pop(id, None)
        if result.ok or keep_failure:
            self._outcomes[id] = {
                "at": _iso(self._clock()),
                "ok": result.ok,
                "reason": result.reason,
                "failed": [f.model_dump(exclude_none=True) for f in result.failed or []],
            }
            self._save()
        future.set_result(result)
        return result

    def _result(self, id: str, kept: dict[str, Any]) -> TeamResult:
        failed = [TeamFailure.model_validate(f) for f in kept.get("failed") or []]
        return TeamResult(ts=_iso(self._clock()), id=id, ok=bool(kept.get("ok")), reason=kept.get("reason"), failed=failed or None)

    def _made(self, ok: bool, reason: str | None = None, failed: list[TeamFailure] | None = None) -> TeamResult:
        return TeamResult(ts=_iso(self._clock()), ok=ok and not failed, reason=reason, failed=failed or None)

    async def _do(self, name: str, payload: dict[str, Any]) -> TeamResult:
        refused: list[TeamFailure] = []
        payload = dict(payload)
        if name in ("send", "stop"):
            # The same for every deployment: a paused file is not sent, a file with two versions is not stopped.
            keep: list[str] = []
            for path in payload.get("paths", []):
                row = self._row(path)
                if name == "send" and row is not None and row.paused is not None:
                    refused.append(TeamFailure(path=path, reason=PAUSED_REASON))
                elif name == "stop" and row is not None and row.conflict is not None:
                    refused.append(TeamFailure(path=path, reason=CHOOSE_FIRST))
                else:
                    keep.append(path)
            payload["paths"] = keep
            if not keep:
                return self._made(False, refused[0].reason if len(refused) == 1 else None, refused)
        if name == "resolve":
            row = self._row(payload["path"])
            if row is None or row.conflict is None or row.conflict.id != payload["conflict"]:
                return self._made(False, VERSION_CHANGED, [TeamFailure(path=payload["path"], reason=VERSION_CHANGED)])
        if name == "get":
            self._getting = list(payload.get("shares", []))
            await self.publish()
        try:
            async with self._lock:
                try:
                    answer: SourceAnswer = _parse(SourceAnswer, await self.source.call(name, payload))
                except NoSource as e:
                    return self._made(False, str(e), refused)
                except SourceFailed as e:
                    return self._made(False, f"The team {name.replace('_', ' ')} did not work: {e}", refused)
                if answer.state is not None:
                    self._apply(answer.state)
        finally:
            if name == "get":
                self._getting = None
            await self.publish()
        failed = refused + answer.failed
        ok = answer.ok if answer.ok is not None else answer.reason is None
        return self._made(ok, answer.reason, failed)

    # --- share ----------------------------------------------------------------------

    async def prepare(self, id: str, paths: list[str], note: str | None = None, chat: int | None = None) -> TeamResult | None:
        """Open a draft and start the check for personal material. ``None`` when it opened; a result when it could not."""
        kept = self._outcomes.get(id)
        if kept is not None:
            return self._result(id, kept)
        if id in self._drafts:
            await self._send_draft(self._drafts[id])
            return None
        if not paths:
            return self._made(False, "No file was chosen to share.").model_copy(update={"id": id})
        draft = Draft(id=id, paths=list(paths), note=note, chat=chat)
        self._drafts[id] = draft
        await self._send_draft(draft)
        draft.task = asyncio.create_task(self._check_draft(draft), name="portico-team-share-check")
        return None

    async def _check_draft(self, draft: Draft) -> None:
        findings, error = await self._findings(draft.paths)
        draft.findings, draft.check_error, draft.checking = findings, error, False
        draft.rev += 1
        if draft.id in self._drafts:
            await self._send_draft(draft)

    async def _findings(self, paths: list[str]) -> tuple[list[TeamFinding], str | None]:
        try:
            answer: SourceFindings = _parse(SourceFindings, await self.source.call("share_check", {"paths": paths}))
        except NoSource:
            return [], "This deployment has no check for personal material."
        except SourceFailed as e:
            return [], f"The check for personal material did not work: {e}"
        return answer.findings, answer.error

    async def _send_draft(self, draft: Draft) -> None:
        draft.shown[str(draft.rev)] = {f.id for f in draft.findings}
        await self._publish_draft(
            TeamShareDraft(
                ts=_iso(self._clock()),
                id=draft.id,
                chat=draft.chat,
                rev=str(draft.rev),
                paths=list(draft.paths),
                note=draft.note,
                checking=draft.checking,
                check_error=draft.check_error,
                findings=list(draft.findings),
            )
        )

    def close(self) -> None:
        """The gateway is stopping: no check for personal material is left running."""
        for draft in self._drafts.values():
            if draft.task is not None and not draft.task.done():
                draft.task.cancel()
        self._drafts.clear()

    async def cancel(self, id: str) -> None:
        """The draft was closed: nothing is shared and no file was changed."""
        draft = self._drafts.pop(id, None)
        if draft is not None and draft.task is not None and not draft.task.done():
            draft.task.cancel()

    async def share(self, id: str, rev: str, note: str | None, remove: list[str], unchecked: bool) -> TeamResult:
        """The person pressed Share on draft ``id`` as ``rev`` showed it. Only now does anything reach the team."""
        # A Share that was refused is asked again under the same id (the draft's), so only a done one is kept.
        return await self._once(id, lambda: self._share(id, rev, note, remove, unchecked), keep_failure=False)

    async def _share(self, id: str, rev: str, note: str | None, remove: list[str], unchecked: bool) -> TeamResult:
        draft = self._drafts.get(id)
        if draft is None:
            return self._made(False, DRAFT_GONE)
        told = True  # whether the app already has the draft as it now stands
        if draft.checking and draft.task is not None and rev == str(draft.rev):
            # Share pressed during the check: finish it first. The check sends the draft it ends with.
            with contextlib.suppress(asyncio.CancelledError):
                await asyncio.shield(draft.task)
            if self._drafts.get(id) is not draft:
                return self._made(False, DRAFT_GONE)
        elif rev != str(draft.rev):
            await self._send_draft(draft)
            return self._made(False, DRAFT_CHANGED)
        else:
            # A file may have changed since the check: check again before anything is sent.
            findings, error = await self._findings(draft.paths)
            if error != draft.check_error or [f.id for f in findings] != [f.id for f in draft.findings]:
                draft.findings, draft.check_error = findings, error
                draft.rev += 1
                told = False
        refusal: str | None = None
        if draft.check_error:
            if not unchecked:
                refusal = draft.check_error
        elif not self._all_shown(draft, rev):
            refusal = NEW_FINDINGS
        if refusal is not None:
            if not told:
                await self._send_draft(draft)
            return self._made(False, refusal)
        by_id = {f.id: f for f in draft.findings}
        payload = {
            "paths": list(draft.paths),
            "note": note if note is not None else draft.note,
            "remove": [by_id[f].model_dump() for f in remove if f in by_id],
            "unchecked": bool(draft.check_error),
        }
        result = await self._do("share", payload)
        if result.ok:
            self._drafts.pop(id, None)
        return result

    def _all_shown(self, draft: Draft, rev: str) -> bool:
        """Whether every finding the draft now has was on the screen the person pressed Share on."""
        shown = draft.shown.get(rev)
        return shown is not None and {f.id for f in draft.findings} <= shown

    # --- what is kept ---------------------------------------------------------------

    def _load(self) -> dict[str, Any]:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def _save(self) -> None:
        cutoff = _iso(self._clock() - timedelta(days=OUTCOME_DAYS))
        self._outcomes = {id: o for id, o in self._outcomes.items() if str(o.get("at", "")) >= cutoff}
        data = {
            "interval_minutes": self.interval_minutes,
            "seen": self._seen,
            "announced": self._announced,
            "outcomes": self._outcomes,
        }
        tmp = self.path.with_name(f".{self.path.name}.tmp")
        try:
            tmp.write_text(json.dumps(data, indent=1), encoding="utf-8")
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        except OSError as e:
            log.warning("team.json could not be written: %s", e)
            with contextlib.suppress(OSError):
                tmp.unlink()
