"""Services (v0.4): the deployment's own checks, run on a timer, shown in the app's services menu.

A deployment lists what it depends on in ``config.toml``::

    [[services]]
    id = "memory"
    name = "Memory (Hindsight)"
    check = "curl -sf http://localhost:8888/health"   # exit 0 = up
    restart = "launchctl kickstart -k gui/$UID/com.fleet.hindsight"  # optional
    up_detail = "recall and capture"                   # optional

The ``ServiceMonitor`` runs every check at start (each service is
``checking`` until its first answer), every ``services_interval_seconds``,
and after a restart. Each check is a lifecycle command
(``lifecycle.run_command``: its own process group, killed after
``command_timeout_seconds``). A check that exits 0 is ``up`` with the
service's ``up_detail``; anything else is ``down`` with
``not responding since H:MM`` (local time) plus `` · <last output line>``
when the check printed one. The monitor hands the app a ``services.status``
only when some service's state or detail changed. Portico never knows
what a service is: it draws what the deployment lists.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import UTC, datetime

from .config import ServiceConfig
from .lifecycle import run_command
from .messages import ProtocolError, Service, ServiceState

log = logging.getLogger(__name__)

# A check's last output line is cut to this many characters in the detail.
DETAIL_LINE_LIMIT = 80

Publish = Callable[[list[Service]], Awaitable[None]]
Clock = Callable[[], datetime]


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
    ) -> None:
        self.services = list(services)
        self.interval = interval
        self.timeout = timeout
        self.publish = publish
        self.clock = clock
        started = clock()
        self._status: dict[str, _Status] = {s.id: _Status(since=started) for s in self.services}
        # One check or restart per service at a time.
        self._locks: dict[str, asyncio.Lock] = {s.id: asyncio.Lock() for s in self.services}
        # What the app was last handed (at start: everything ``checking``,
        # which is also what a connecting app is sent).
        self._last: list[Service] = self.snapshot()

    # --- what the app sees ----------------------------------------------------

    def snapshot(self) -> list[Service]:
        """Every service as last found: down ones first, then in config order."""
        out: list[Service] = []
        for service in self.services:
            status = self._status[service.id]
            out.append(
                Service(
                    id=service.id,
                    name=service.name,
                    state=status.state,
                    detail=status.detail,
                    since=_iso(status.since) if status.since is not None else None,
                    can_restart=service.restart is not None,
                )
            )
        return sorted(out, key=lambda s: 0 if s.state == "down" else 1)

    async def _publish_if_changed(self) -> None:
        """Hand the app the list when a state or detail differs from what it last got."""
        now = self.snapshot()
        if [(s.id, s.state, s.detail) for s in now] == [(s.id, s.state, s.detail) for s in self._last]:
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
        status = self._status[service_id]
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
            code = await run_command(service.check, seen, self.timeout)
        except TimeoutError:
            code = None
            if last is None:
                last = f"check timed out after {self.timeout:g} s"
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

    async def check_all(self) -> None:
        """Check every service at once; then one ``services.status`` if anything changed."""

        async def one(service: ServiceConfig) -> None:
            async with self._locks[service.id]:
                try:
                    await self._run_check(service)
                except Exception:
                    log.exception("service %s: the check failed to run", service.id)

        await asyncio.gather(*(one(s) for s in self.services))
        await self._publish_if_changed()

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

    async def restart(self, service_id: str) -> None:
        """Run the service's ``restart`` (``checking`` meanwhile), then check it again.

        The ``services.status`` that follows is the answer: the state always
        changes to ``checking`` and back, so the app hears both.
        """
        service = self.check_restart(service_id)
        assert service.restart is not None
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
            await self._run_check(service)
        await self._publish_if_changed()
