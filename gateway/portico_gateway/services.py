"""Services (v0.4): the deployment's own checks, run on a timer, shown in the app's services menu.

A deployment lists what it depends on in ``config.toml``::

    [[services]]
    id = "memory"
    name = "Memory (recall server)"
    check = "curl -sf http://localhost:8888/health"   # exit 0 = up
    restart = "launchctl kickstart -k gui/$UID/com.example.memory"  # optional
    up_detail = "recall and capture"                   # optional
    timeout_seconds = 10                               # optional, default 10, at least 1

The ``ServiceMonitor`` runs every check at start (each service is
``checking`` until its first answer), every ``services_interval_seconds``,
and after a restart. Each check is a lifecycle command
(``lifecycle.run_command``: its own process group, killed after the
service's ``timeout_seconds``; a restart is killed after
``command_timeout_seconds``). A check that exits 0 is ``up`` with the
service's ``up_detail``; anything else is ``down`` with
``not responding since H:MM`` (local time) plus `` · <last output line>``
when the check printed one. The monitor hands the app a ``services.status``
only when some service's state or detail changed, as each check answers:
one slow check never holds back what the others found. Portico never
knows what a service is: it draws what the deployment lists.

v0.8: a deployment can instead give one status and one restart for all
its services (``[deployment] status`` / ``restart``, or a plug-in's
``services_status()`` / ``restart_services()``, which take precedence).
With a status source the monitor reads it at start and every interval
instead of running each check: its rows are the services (``up`` true is
``up`` with the row's ``detail``; false is ``down``, ``not responding
since H:MM`` plus `` · <detail>``), and a status that cannot be read
(the command fails or times out, its output is not the expected JSON, the
hook raises) is one ``down`` row, ``status``, saying so with the reason.
A row's Restart comes from the ``[[services]]`` entry with the same id.
``restart_all`` runs the restart, reads everything again and always
publishes the result as the one ``services.status`` between the request
and that point (the app ends its progress on the next one it gets: no
interim list goes out meanwhile); a restart that fails raises
``services.restart_failed`` after that. A row's restart meanwhile is
refused with ``services.busy``. The status command's stdout is the JSON;
its stderr only names the reason when it fails.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from .config import ServiceConfig
from .lifecycle import run_command
from .messages import ProtocolError, Service, ServiceState
from .plugins import ServicesHook, call_hook

log = logging.getLogger(__name__)

# A check's last output line is cut to this many characters in the detail.
DETAIL_LINE_LIMIT = 240

Publish = Callable[[list[Service]], Awaitable[None]]
Clock = Callable[[], datetime]
# v0.8: the deployment's status, as text (JSON) or already a dict; and its restart.
StatusSource = Callable[[], Awaitable[Any]]
RestartSource = Callable[[], Awaitable[None]]

# The one row a status that cannot be read becomes.
STATUS_FAILED_ID = "status"
STATUS_FAILED_NAME = "Services status"


class SourceFailed(Exception):
    """A status or restart source did not work; the message is the reason, one line."""


@dataclass
class StatusRow:
    """One service as the deployment's status gives it."""

    id: str
    name: str
    up: bool
    detail: str | None = None


def parse_status(raw: Any) -> list[StatusRow]:
    """``{"services": [{"id", "name", "up", "detail"?}]}`` (text or dict) as rows; ``SourceFailed`` otherwise."""
    if isinstance(raw, (str, bytes)):
        try:
            raw = json.loads(raw)
        except ValueError as e:
            raise SourceFailed(f"output is not JSON: {e}") from None
    if not isinstance(raw, dict) or not isinstance(raw.get("services"), list):
        raise SourceFailed('output is not {"services": [...]}')
    rows: list[StatusRow] = []
    seen: set[str] = set()
    for n, item in enumerate(raw["services"]):
        if not isinstance(item, dict):
            raise SourceFailed(f"services[{n}] is not an object")
        id, name, up, detail = item.get("id"), item.get("name"), item.get("up"), item.get("detail")
        if not isinstance(id, str) or not id.strip():
            raise SourceFailed(f"services[{n}] has no id")
        if id in seen:
            raise SourceFailed(f"services[{n}]: id {id!r} is used twice")
        if not isinstance(name, str) or not name.strip():
            raise SourceFailed(f"services[{n}] ({id}) has no name")
        if not isinstance(up, bool):
            raise SourceFailed(f"services[{n}] ({id}): up must be true or false")
        if detail is not None and not isinstance(detail, str):
            raise SourceFailed(f"services[{n}] ({id}): detail must be text")
        seen.add(id)
        rows.append(StatusRow(id=id, name=name, up=up, detail=_short(detail) if detail and detail.strip() else None))
    return rows


async def _run_source_command(command: str, timeout: float, stdout_only: bool = False) -> list[str]:
    """Run a deployment command; its output lines, or ``SourceFailed`` saying why it did not work.

    ``stdout_only`` (the status command, whose stdout is JSON): the lines
    are stdout's; stderr is kept apart and only gives the reason a failed
    run names (its last line, else stdout's).
    """
    lines: list[str] = []
    errors: list[str] = []

    async def seen(line: str) -> None:
        lines.append(line)

    async def said(line: str) -> None:
        errors.append(line)

    try:
        code = await run_command(command, seen, timeout, on_stderr=said if stdout_only else None)
    except TimeoutError:
        raise SourceFailed(f"timed out after {timeout:g} s") from None
    except OSError as e:
        raise SourceFailed(f"could not start: {e}") from None
    if code != 0:
        last = (errors or lines or [None])[-1]
        raise SourceFailed(f"exited {code}" + (f": {_short(last)}" if last else ""))
    return lines


def command_status(command: str, timeout: float) -> StatusSource:
    """``[deployment] status`` as a status source: the command's stdout (stderr is not part of the JSON)."""

    async def status() -> Any:
        return "\n".join(await _run_source_command(command, timeout, stdout_only=True))

    return status


def command_restart(command: str, timeout: float) -> RestartSource:
    """``[deployment] restart`` as a restart source: exit 0 is done."""

    async def restart() -> None:
        await _run_source_command(command, timeout)

    return restart


def hook_status(hook: ServicesHook) -> StatusSource:
    """A plug-in's ``services_status`` as a status source; whatever it raises is the reason."""

    async def status() -> Any:
        try:
            return await call_hook(hook)
        except Exception as e:
            raise SourceFailed(f"{type(e).__name__}: {e}") from e

    return status


def hook_restart(hook: ServicesHook) -> RestartSource:
    """A plug-in's ``restart_services`` as a restart source: ``False`` or raising is a failure."""

    async def restart() -> None:
        try:
            result = await call_hook(hook)
        except Exception as e:
            raise SourceFailed(f"{type(e).__name__}: {e}") from e
        if result is False:
            raise SourceFailed("the plug-in's restart_services reported a failure")

    return restart


def _utc_now() -> datetime:
    return datetime.now(UTC)


def _iso(moment: datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _clock_time(moment: datetime) -> str:
    """``H:MM`` in local time, 24-hour (``9:05``, ``17:42``)."""
    local = moment.astimezone()
    return f"{local.hour}:{local.minute:02d}"


def _short(line: str) -> str:
    line = " ".join(line.split())
    return line if len(line) <= DETAIL_LINE_LIMIT else line[: DETAIL_LINE_LIMIT - 1].rstrip() + "…"


@dataclass
class _Status:
    state: ServiceState = "checking"
    detail: str | None = None
    # When the current state began (``since``).
    since: datetime | None = None
    # When the service was first seen down without coming up since: a
    # restart's ``checking`` in between does not reset it.
    down_since: datetime | None = None


class ServiceMonitor:
    """Runs the deployment's service checks and says when what they found changes."""

    def __init__(
        self,
        services: list[ServiceConfig],
        interval: float,
        timeout: float,
        publish: Publish,
        clock: Clock = _utc_now,
        status: StatusSource | None = None,
        restart_all: RestartSource | None = None,
        status_label: str = "status command",
    ) -> None:
        # ``timeout`` bounds a restart (``command_timeout_seconds``); each
        # check is bounded by its own service's ``timeout_seconds``.
        self.services = list(services)
        self.interval = interval
        self.timeout = timeout
        self.publish = publish
        self.clock = clock
        # v0.8: the deployment's status and restart for all its services;
        # ``status_label`` names the status source in its failure row.
        self.status_source = status
        self.restart_all_source = restart_all
        self.status_label = status_label
        started = clock()
        self._status: dict[str, _Status] = {s.id: _Status(since=started) for s in self.services}
        # With a status source, the rows (id, name) its last reading gave, in
        # its order; none until the first reading.
        self._rows: list[tuple[str, str]] = []
        # One check or restart per service at a time.
        self._locks: dict[str, asyncio.Lock] = {s.id: asyncio.Lock() for s in self.services}
        # One status reading, and one restart of everything, at a time.
        self._reading = asyncio.Lock()
        self._restarting_all = asyncio.Lock()
        # One publish at a time, so the app gets the lists in the order they were found.
        self._publishing = asyncio.Lock()
        # What the app was last handed (at start: everything ``checking``,
        # which is also what a connecting app is sent).
        self._last: list[Service] = self.snapshot()

    # --- what the app sees ----------------------------------------------------

    @property
    def active(self) -> bool:
        """Whether there is anything to watch: ``[[services]]`` checks or a status source."""
        return bool(self.services) or self.status_source is not None

    @property
    def can_restart_all(self) -> bool:
        return self.restart_all_source is not None

    @property
    def restarting_all(self) -> bool:
        return self._restarting_all.locked()

    def _restart_command(self, service_id: str) -> str | None:
        for service in self.services:
            if service.id == service_id:
                return service.restart
        return None

    def snapshot(self) -> list[Service]:
        """Every service as last found: down ones first, then in config (or status) order."""
        rows = self._rows if self.status_source is not None else [(s.id, s.name) for s in self.services]
        out: list[Service] = []
        for service_id, name in rows:
            status = self._status[service_id]
            out.append(
                Service(
                    id=service_id,
                    name=name,
                    state=status.state,
                    detail=status.detail,
                    since=_iso(status.since) if status.since is not None else None,
                    can_restart=self._restart_command(service_id) is not None,
                )
            )
        return sorted(out, key=lambda s: 0 if s.state == "down" else 1)

    async def _publish_if_changed(self, force: bool = False) -> None:
        """Hand the app the list when a state or detail differs from what it last got (or ``force``)."""
        async with self._publishing:
            if self._restarting_all.locked() and not force:
                return  # restart all answers with one list, once it is done
            now = self.snapshot()
            if not force and [(s.id, s.state, s.detail) for s in now] == [(s.id, s.state, s.detail) for s in self._last]:
                return
            self._last = now
            await self.publish(now)

    # --- checks ---------------------------------------------------------------

    def service(self, service_id: str) -> ServiceConfig:
        for service in self.services:
            if service.id == service_id:
                return service
        raise ProtocolError("service.unknown", f"no service {service_id!r}")

    def _set(self, service_id: str, state: ServiceState, detail: str | None) -> None:
        status = self._status.setdefault(service_id, _Status(since=self.clock()))
        now = self.clock()
        if state == "down" and status.down_since is None:
            status.down_since = now
        elif state == "up":
            status.down_since = None
        if state != status.state:
            # Down again after a restart's ``checking``: the outage began when it was first seen down.
            status.since = status.down_since if state == "down" else now
        status.state = state
        status.detail = detail

    async def _run_check(self, service: ServiceConfig) -> None:
        last: str | None = None

        async def seen(line: str) -> None:
            nonlocal last
            last = line

        try:
            code = await run_command(service.check, seen, float(service.timeout_seconds))
        except TimeoutError:
            code = None
            if last is None:
                last = f"check timed out after {service.timeout_seconds:g} s"
        except OSError as e:
            code = None
            last = f"check could not start: {e}"
        if code == 0:
            self._set(service.id, "up", service.up_detail)
            return
        status = self._status[service.id]
        if status.down_since is None:
            status.down_since = self.clock()
        detail = f"not responding since {_clock_time(status.down_since)}"
        if last:
            detail += f" · {_short(last)}"
        if status.state != "down":
            log.warning("service %s is down: %s", service.id, detail)
        self._set(service.id, "down", detail)

    async def check(self, service_id: str) -> None:
        """Check one service now; the app hears of it only if something changed."""
        service = self.service(service_id)
        async with self._locks[service.id]:
            await self._run_check(service)
        await self._publish_if_changed()

    async def read_status(self) -> None:
        """Read the deployment's status (v0.8); its rows replace the last ones, published if anything changed."""
        assert self.status_source is not None
        async with self._reading:
            # A status that cannot be read is one row saying so, its detail as written.
            failed = True
            try:
                rows = parse_status(await self.status_source())
                failed = False
            except SourceFailed as e:
                log.warning("services: the %s failed: %s", self.status_label, e)
                rows = [StatusRow(STATUS_FAILED_ID, STATUS_FAILED_NAME, False, f"{self.status_label} failed · {_short(str(e))}")]
            except Exception as e:
                log.exception("services: reading the %s failed", self.status_label)
                rows = [StatusRow(STATUS_FAILED_ID, STATUS_FAILED_NAME, False, f"{self.status_label} failed · {e}")]
            ids = {row.id for row in rows}
            for gone in [i for i in self._status if i not in ids]:
                del self._status[gone]
            self._rows = [(row.id, row.name) for row in rows]
            for row in rows:
                if row.up:
                    self._set(row.id, "up", row.detail)
                elif failed:
                    self._set(row.id, "down", row.detail)
                else:
                    status = self._status.setdefault(row.id, _Status(since=self.clock()))
                    if status.down_since is None:
                        status.down_since = self.clock()
                    detail = f"not responding since {_clock_time(status.down_since)}"
                    if row.detail:
                        detail += f" · {row.detail}"
                    if status.state != "down":
                        log.warning("service %s is down: %s", row.id, detail)
                    self._set(row.id, "down", detail)
        await self._publish_if_changed()

    async def check_all(self) -> None:
        """Check every service at once; each answer is published (if it changed anything) as it comes.

        A slow check (up to its ``timeout_seconds``) delays only its own
        service: the others reach the app as soon as they answer. With a
        status source (v0.8), one reading of it instead.
        """
        if self.status_source is not None:
            await self.read_status()
            return

        async def one(service: ServiceConfig) -> None:
            async with self._locks[service.id]:
                try:
                    await self._run_check(service)
                except Exception:
                    log.exception("service %s: the check failed to run", service.id)
            await self._publish_if_changed()

        await asyncio.gather(*(one(s) for s in self.services))

    async def run(self) -> None:
        """At start, then every ``interval`` seconds, until cancelled."""
        while True:
            await self.check_all()
            await asyncio.sleep(self.interval)

    # --- restart --------------------------------------------------------------

    def check_restart(self, service_id: str) -> ServiceConfig:
        """The service, when it can be restarted; ``service.unknown`` / ``service.no_restart`` otherwise."""
        service = self.service(service_id)
        if service.restart is None:
            raise ProtocolError("service.no_restart", f"service {service_id!r} has no restart command")
        return service

    def check_not_restarting_all(self) -> None:
        """``services.busy`` while a restart of all services runs: a row's restart waits for it.

        Its ``checking`` frame would be held back with everything else, so
        the app would never see its restart answered.
        """
        if self._restarting_all.locked():
            raise ProtocolError("services.busy", "a restart of all services is running; try again when it is done")

    async def restart(self, service_id: str) -> None:
        """Run the service's ``restart`` (``checking`` meanwhile), then check it again.

        The ``services.status`` that follows is the answer: the state always
        changes to ``checking`` and back, so the app hears both.
        """
        service = self.check_restart(service_id)
        assert service.restart is not None
        self.check_not_restarting_all()
        async with self._locks[service.id]:
            self._set(service.id, "checking", "restarting")
            await self._publish_if_changed()
            last: str | None = None

            async def seen(line: str) -> None:
                nonlocal last
                last = line

            try:
                code = await run_command(service.restart, seen, self.timeout)
                if code != 0:
                    log.warning("service %s: restart exited %d%s", service.id, code, f": {last}" if last else "")
            except TimeoutError:
                log.warning("service %s: restart did not finish within %g s and was stopped", service.id, self.timeout)
            except OSError as e:
                log.warning("service %s: restart could not start: %s", service.id, e)
            log.info("service %s: restarted; checking it again", service.id)
            if self.status_source is None:
                await self._run_check(service)
        if self.status_source is not None:
            await self.read_status()
        await self._publish_if_changed()

    async def restart_all(self) -> None:
        """Restart all the deployment's services (v0.8), then read everything again.

        Nothing is published while it runs (not the periodic checks, not a
        row's restart): the list as found afterwards is published once,
        changed or not, and is the answer. A restart that fails raises
        ``services.restart_failed`` with the reason, after that list; a
        second restart while one runs is ``services.busy``.
        """
        if self.restart_all_source is None:
            raise ProtocolError("services.no_restart_all", "this deployment has no restart for all its services")
        if self._restarting_all.locked():
            raise ProtocolError("services.busy", "a restart of all services is already running")
        async with self._restarting_all:
            failure: str | None = None
            try:
                await self.restart_all_source()
                log.info("services: restarted all; checking them again")
            except SourceFailed as e:
                failure = str(e)
            except Exception as e:
                log.exception("services: restarting all failed")
                failure = f"{type(e).__name__}: {e}"
            if failure is not None:
                log.warning("services: restarting all failed: %s", failure)
            await self.check_all()
            await self._publish_if_changed(force=True)
        if failure is not None:
            raise ProtocolError("services.restart_failed", f"restarting all services failed: {failure}")
