"""v0.4: services — the deployment's checks, the monitor's states, restart, and the frames the app gets.

The monitor runs real shell commands (``true``, ``false``, ``sleep``,
``echo``) through ``lifecycle.run_command``; the server tests use a real
``websockets`` client.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from pathlib import Path

import pytest

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import ServiceConfig
from portico_gateway.messages import (
    Error,
    ProtocolError,
    Service,
    ServiceRestart,
    ServicesStatus,
    dump,
)
from portico_gateway.server import GatewayServer
from portico_gateway.services import ServiceMonitor
from portico_gateway.state import StateDir
from tests.conftest import FakeEngine, make_config
from tests.test_server import attach
from tests.test_turns import recv, recv_until

TS = "2026-10-28T12:00:00Z"
NOON = datetime(2026, 10, 28, 17, 5, tzinfo=UTC)


def svc(id: str, check: str, **kw: str) -> ServiceConfig:
    return ServiceConfig(id=id, name=kw.pop("name", id.title()), check=check, **kw)


class Recorder:
    """The monitor's ``publish``: every list it was handed, in order."""

    def __init__(self) -> None:
        self.calls: list[list[Service]] = []

    async def __call__(self, services: list[Service]) -> None:
        self.calls.append(services)


def monitor(services: list[ServiceConfig], timeout: float = 5.0) -> tuple[ServiceMonitor, Recorder]:
    rec = Recorder()
    return ServiceMonitor(services, interval=30, timeout=timeout, publish=rec, clock=lambda: NOON), rec


def local_hm(moment: datetime) -> str:
    local = moment.astimezone()
    return f"{local.hour}:{local.minute:02d}"


# --- the monitor ----------------------------------------------------------------


async def test_every_service_is_checking_until_its_first_check() -> None:
    mon, rec = monitor([svc("memory", "true"), svc("search", "false", restart="true")])
    snap = mon.snapshot()
    assert [(s.id, s.state, s.can_restart) for s in snap] == [("memory", "checking", False), ("search", "checking", True)]
    assert all(s.since == "2026-10-28T17:05:00Z" for s in snap)
    assert rec.calls == [], "nothing is published before a check answers"


async def test_first_check_publishes_down_first_with_detail() -> None:
    mon, rec = monitor(
        [
            svc("memory", "true", up_detail="recall and capture"),
            svc("search", "echo 'connection refused on :8888'; exit 7"),
        ]
    )
    await mon.check_all()
    assert len(rec.calls) == 1
    first, second = rec.calls[0]
    assert (first.id, first.state) == ("search", "down"), "down services come first"
    assert first.detail == f"not responding since {local_hm(NOON)} · connection refused on :8888"
    assert first.since == "2026-10-28T17:05:00Z"
    assert (second.id, second.state, second.detail) == ("memory", "up", "recall and capture")


async def test_up_without_up_detail_has_no_detail_and_silent_failure_has_no_suffix() -> None:
    mon, rec = monitor([svc("a", "true"), svc("b", "false")])
    await mon.check_all()
    got = {s.id: s for s in rec.calls[0]}
    assert got["a"].detail is None
    assert got["b"].detail == f"not responding since {local_hm(NOON)}"


async def test_only_changes_are_published() -> None:
    mon, rec = monitor([svc("a", "true"), svc("b", "false")])
    await mon.check_all()
    await mon.check_all()
    await mon.check("a")
    assert len(rec.calls) == 1, "the same states and details again publish nothing"


async def test_a_state_change_is_published(tmp_path: Path) -> None:
    flag = tmp_path / "up"
    mon, rec = monitor([svc("a", f"test -f {flag}")])
    await mon.check_all()
    assert rec.calls[-1][0].state == "down"
    flag.write_text("")
    await mon.check("a")
    assert len(rec.calls) == 2 and rec.calls[-1][0].state == "up" and rec.calls[-1][0].detail is None


async def test_a_long_last_line_is_cut_and_only_the_last_non_empty_line_counts() -> None:
    long = "x" * 200
    mon, rec = monitor([svc("a", f"echo first; echo {long}; echo; exit 1")])
    await mon.check_all()
    detail = rec.calls[0][0].detail
    assert detail is not None
    tail = detail.split(" · ", 1)[1]
    assert len(tail) == 80 and tail.endswith("…") and tail.startswith("xxx")


async def test_a_check_that_hangs_is_killed_at_the_timeout_and_is_down() -> None:
    mon, rec = monitor([svc("slow", "sleep 30")], timeout=0.3)
    started = asyncio.get_running_loop().time()
    await mon.check_all()
    assert asyncio.get_running_loop().time() - started < 5
    service = rec.calls[0][0]
    assert service.state == "down"
    assert service.detail is not None and "timed out after 0.3 s" in service.detail


async def test_a_hanging_check_keeps_its_last_line_when_it_printed_one() -> None:
    mon, rec = monitor([svc("slow", "echo still trying; sleep 30")], timeout=0.3)
    await mon.check_all()
    assert rec.calls[0][0].detail == f"not responding since {local_hm(NOON)} · still trying"


async def test_down_since_holds_across_checks_until_it_comes_up(tmp_path: Path) -> None:
    times = iter([datetime(2026, 10, 28, 9, m, tzinfo=UTC) for m in range(0, 60)])
    flag = tmp_path / "up"
    rec = Recorder()
    mon = ServiceMonitor([svc("a", f"test -f {flag}")], interval=30, timeout=5, publish=rec, clock=lambda: next(times))
    await mon.check_all()  # down at 9:01 (9:00 was the start)
    first = rec.calls[-1][0]
    await mon.check_all()
    await mon.check_all()
    assert len(rec.calls) == 1, "still down, same detail: nothing new"
    assert mon.snapshot()[0].since == first.since == "2026-10-28T09:01:00Z"
    flag.write_text("")
    await mon.check_all()
    assert rec.calls[-1][0].state == "up"
    flag.unlink()
    await mon.check_all()
    again = rec.calls[-1][0]
    assert again.state == "down" and again.since != first.since, "a new outage has its own start"


async def test_run_checks_at_start_and_every_interval(tmp_path: Path) -> None:
    counter = tmp_path / "count"
    rec = Recorder()
    mon = ServiceMonitor(
        [svc("a", f"echo x >> {counter}")], interval=0.1, timeout=5, publish=rec, clock=lambda: NOON
    )
    task = asyncio.create_task(mon.run())
    try:
        await asyncio.sleep(0.45)
    finally:
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    runs = len(counter.read_text().splitlines())
    assert runs >= 3, runs
    assert len(rec.calls) == 1, "checking -> up once; the same answer after that publishes nothing"


# --- restart --------------------------------------------------------------------


async def test_restart_runs_the_command_goes_through_checking_and_rechecks(tmp_path: Path) -> None:
    flag = tmp_path / "up"
    mon, rec = monitor([svc("memory", f"test -f {flag}", restart=f"touch {flag}"), svc("other", "true")])
    await mon.check_all()
    assert rec.calls[-1][0].id == "memory" and rec.calls[-1][0].state == "down"
    await mon.restart("memory")
    assert [s.state for s in rec.calls[-2] if s.id == "memory"] == ["checking"]
    assert [s.detail for s in rec.calls[-2] if s.id == "memory"] == ["restarting"]
    after = {s.id: s for s in rec.calls[-1]}
    assert after["memory"].state == "up"
    assert [s.id for s in rec.calls[-1]] == ["memory", "other"], "config order when nothing is down"


async def test_a_restart_that_does_not_help_stays_down_from_the_first_outage() -> None:
    times = iter([datetime(2026, 10, 28, 9, m, tzinfo=UTC) for m in range(0, 60)])
    rec = Recorder()
    mon = ServiceMonitor(
        [svc("memory", "false", restart="exit 3")], interval=30, timeout=5, publish=rec, clock=lambda: next(times)
    )
    await mon.check_all()
    outage = rec.calls[-1][0]
    await mon.restart("memory")
    after = rec.calls[-1][0]
    assert after.state == "down"
    assert after.since == outage.since and after.detail == outage.detail, "the outage began before the restart"
    assert len(rec.calls) == 3, "down, checking, down: the answer always arrives"


async def test_restart_refusals() -> None:
    mon, _ = monitor([svc("memory", "true")])
    with pytest.raises(ProtocolError) as e:
        await mon.restart("nope")
    assert e.value.code == "service.unknown"
    with pytest.raises(ProtocolError) as e:
        await mon.restart("memory")
    assert e.value.code == "service.no_restart"


async def test_a_restart_that_hangs_is_killed_and_the_service_rechecked() -> None:
    mon, rec = monitor([svc("memory", "true", restart="sleep 30")], timeout=0.3)
    await mon.restart("memory")
    assert rec.calls[-1][0].state == "up"


# --- the server -------------------------------------------------------------------


async def start(state_dir: StateDir, **config: object) -> GatewayServer:
    cfg = make_config(**config)
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=cfg.history_buffer)
    srv = GatewayServer(config=cfg, state=state_dir, registry=registry, engine_factory=FakeEngine, version=__version__)
    await srv.serve(0)
    return srv


@pytest.fixture
def gate(tmp_path: Path) -> Path:
    """The services' first checks wait for this file, so a test attaches before they answer."""
    return tmp_path / "gate"


@pytest.fixture
async def services_server(state_dir: StateDir, tmp_path: Path, gate: Path) -> AsyncIterator[GatewayServer]:
    flag = tmp_path / "memory-up"
    wait = f"while [ ! -f {gate} ]; do sleep 0.02; done; "
    srv = await start(
        state_dir,
        services=[
            {"id": "files", "name": "Files", "check": wait + "true", "up_detail": "watching"},
            {"id": "memory", "name": "Memory (Hindsight)", "check": wait + f"test -f {flag}", "restart": f"touch {flag}"},
        ],
    )
    try:
        yield srv
    finally:
        await srv.shutdown()


async def test_the_app_hears_services_after_hello_and_each_change(services_server: GatewayServer, gate: Path) -> None:
    conn = await attach(services_server)  # hello, chat.list, services.status (everything checking)
    try:
        assert [s.state for s in services_server.services.snapshot()] == ["checking", "checking"]
        gate.write_text("")
        frames = await recv_until(conn, ServicesStatus)
        status = frames[-1]
        assert isinstance(status, ServicesStatus)
        assert [(s.id, s.state) for s in status.services] == [("memory", "down"), ("files", "up")]
        memory = status.services[0]
        assert memory.can_restart and memory.detail and memory.detail.startswith("not responding since ")
        assert memory.since is not None and status.services[1].detail == "watching"

        await conn.send(dump(ServiceRestart(ts=TS, id="req-r", service="memory")))
        checking = await recv(conn)
        assert isinstance(checking, ServicesStatus)
        assert [s.state for s in checking.services if s.id == "memory"] == ["checking"]
        answer = await recv(conn)
        assert isinstance(answer, ServicesStatus)
        assert [(s.id, s.state) for s in answer.services] == [("files", "up"), ("memory", "up")]
    finally:
        await conn.close()


async def test_a_new_connection_gets_the_services_as_they_stand(services_server: GatewayServer, gate: Path) -> None:
    from websockets.asyncio.client import connect

    from portico_gateway.messages import HelloClient, parse_server
    from tests.test_server import ws_url

    gate.write_text("")
    await services_server.services.check_all()
    conn = await connect(ws_url(services_server, services_server.token))
    try:
        await conn.send(dump(HelloClient(ts=TS, app_version="0.4.0")))
        await conn.recv()  # hello
        await conn.recv()  # chat.list
        status = parse_server(await conn.recv())
        assert isinstance(status, ServicesStatus)
        assert [(s.id, s.state) for s in status.services] == [("memory", "down"), ("files", "up")]
    finally:
        await conn.close()


async def test_restart_refusals_over_the_socket(services_server: GatewayServer, gate: Path) -> None:
    conn = await attach(services_server)
    try:
        gate.write_text("")
        await recv_until(conn, ServicesStatus)  # the first check's answer
        await conn.send(dump(ServiceRestart(ts=TS, id="req-u", service="nope")))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "service.unknown" and err.id == "req-u"
        await conn.send(dump(ServiceRestart(ts=TS, id="req-n", service="files")))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "service.no_restart" and err.id == "req-n"
    finally:
        await conn.close()


async def test_without_services_the_list_is_empty_and_no_monitor_runs(state_dir: StateDir) -> None:
    srv = await start(state_dir)
    try:
        assert srv.services.snapshot() == []
        assert not any(t.get_name() == "portico-services" for t in srv._tasks)
    finally:
        await srv.shutdown()
