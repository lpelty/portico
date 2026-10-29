"""v0.8: ``[deployment]`` — one status and one restart for all the deployment's services.

The status and restart commands are real shell commands (``printf``,
``false``, ``touch``) run through ``lifecycle.run_command``; plug-in hooks
are throwaway modules in ``tmp_path``. The server tests use a real
``websockets`` client. Nothing here touches a model.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import RESTART_ALL_CAPABILITY, ConfigError, hello_for, load_config
from portico_gateway.messages import Error, ProtocolError, ServicesRestartAll, ServicesStatus, dump
from portico_gateway.plugins import Plugins, load_plugins
from portico_gateway.server import GatewayServer
from portico_gateway.services import (
    STATUS_FAILED_ID,
    ServiceMonitor,
    SourceFailed,
    command_restart,
    command_status,
    parse_status,
)
from portico_gateway.state import StateDir
from tests.conftest import FakeEngine, make_config
from tests.test_server import attach
from tests.test_services import NOON, Recorder, svc
from tests.test_turns import recv, recv_until

TS = "2026-10-29T12:00:00Z"


@pytest.fixture(autouse=True)
def clean_imports(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(sys, "path", list(sys.path))
    monkeypatch.setattr(sys, "modules", dict(sys.modules))


def status_json(*rows: dict[str, object]) -> str:
    return json.dumps({"services": list(rows)})


def printing(path: Path, text: str) -> str:
    """A command that prints ``text`` (written to ``path`` first, so no quoting gets in the way)."""
    path.write_text(text)
    return f"cat {path}"


def status_monitor(command: str, services: list | None = None, restart: str | None = None) -> tuple[ServiceMonitor, Recorder]:
    rec = Recorder()
    mon = ServiceMonitor(
        services or [],
        interval=30,
        timeout=5,
        publish=rec,
        clock=lambda: NOON,
        status=command_status(command, 5),
        restart_all=command_restart(restart, 5) if restart else None,
    )
    return mon, rec


# --- config -------------------------------------------------------------------------


def test_deployment_is_optional_and_blank_is_unset(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text("")
    assert load_config(path).deployment.restart is None
    path.write_text('[deployment]\nrestart = "  "\nstatus = "deploy status"\n')
    config = load_config(path)
    assert config.deployment.restart is None and config.deployment.status == "deploy status"


def test_deployment_refuses_unknown_keys(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text('[deployment]\nrestrat = "x"\n')
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert "deployment" in e.value.keys


def test_titles_config(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text("")
    config = load_config(path)
    assert config.titles == "generated" and config.title_model is None
    path.write_text('titles = "first_line"\ntitle_model = "claude-small-x"\n')
    config = load_config(path)
    assert config.titles == "first_line" and config.title_model == "claude-small-x"
    path.write_text('titles = "sometimes"\n')
    with pytest.raises(ConfigError):
        load_config(path)


def test_hello_advertises_restart_all_only_when_there_is_one(tmp_path: Path) -> None:
    assert RESTART_ALL_CAPABILITY == "services.restart_all"
    assert RESTART_ALL_CAPABILITY not in hello_for(make_config(), "e", "0").capabilities
    assert RESTART_ALL_CAPABILITY not in hello_for(make_config(deployment={"status": "x"}), "e", "0").capabilities
    assert RESTART_ALL_CAPABILITY in hello_for(make_config(deployment={"restart": "x"}), "e", "0").capabilities
    (tmp_path / "pp_restart.py").write_text("PORTICO_PLUGIN_API = 1\ndef restart_services():\n    return True\n")
    plugins = load_plugins(["pp_restart"], [str(tmp_path)])
    assert RESTART_ALL_CAPABILITY in hello_for(make_config(), "e", "0", plugins).capabilities


# --- parsing the status ----------------------------------------------------------------


def test_parse_status_reads_rows_text_or_dict() -> None:
    rows = parse_status(status_json({"id": "memory", "name": "Memory", "up": True, "detail": "recall"}, {"id": "b", "name": "B", "up": False}))
    assert [(r.id, r.name, r.up, r.detail) for r in rows] == [("memory", "Memory", True, "recall"), ("b", "B", False, None)]
    assert parse_status({"services": []}) == []


@pytest.mark.parametrize(
    "raw",
    [
        "not json",
        "[]",
        '{"services": {}}',
        '{"services": [1]}',
        '{"services": [{"name": "A", "up": true}]}',
        '{"services": [{"id": "a", "up": true}]}',
        '{"services": [{"id": "a", "name": "A", "up": "yes"}]}',
        '{"services": [{"id": "a", "name": "A", "up": true, "detail": 3}]}',
        '{"services": [{"id": "a", "name": "A", "up": true}, {"id": "a", "name": "A2", "up": true}]}',
    ],
)
def test_parse_status_refuses_what_is_not_the_format(raw: str) -> None:
    with pytest.raises(SourceFailed):
        parse_status(raw)


# --- the monitor with a status command --------------------------------------------------


async def test_status_rows_replace_the_checks_and_keep_restart_from_matching_services(tmp_path: Path) -> None:
    ran = tmp_path / "check-ran"
    command = printing(
        tmp_path / "status.json",
        status_json(
            {"id": "files", "name": "Files", "up": True, "detail": "watching"},
            {"id": "memory", "name": "Memory", "up": False, "detail": "port closed"},
        ),
    )
    mon, rec = status_monitor(command, services=[svc("memory", f"touch {ran}", restart="true")])
    assert mon.active and mon.snapshot() == [], "no rows until the status is read"
    await mon.check_all()
    assert not ran.exists(), "the [[services]] check never runs while status is set"
    rows = rec.calls[-1]
    assert [(s.id, s.name, s.state) for s in rows] == [("memory", "Memory", "down"), ("files", "Files", "up")]
    assert rows[0].detail and rows[0].detail.startswith("not responding since ") and rows[0].detail.endswith(" · port closed")
    assert rows[1].detail == "watching"
    assert [s.can_restart for s in rows] == [True, False], "Restart only where a [[services]] entry gives one"


@pytest.mark.parametrize(
    ("command", "reason"),
    [
        ("echo broken; exit 4", "exited 4: broken"),
        ("echo not json", "not JSON"),
        ("echo '{\"services\": [{\"id\": \"a\"}]}'", "has no name"),
    ],
)
async def test_a_status_that_cannot_be_read_is_one_row_saying_so(command: str, reason: str) -> None:
    mon, rec = status_monitor(command)
    await mon.check_all()
    rows = rec.calls[-1]
    assert len(rows) == 1
    row = rows[0]
    assert row.id == STATUS_FAILED_ID and row.state == "down" and not row.can_restart
    assert row.detail is not None and row.detail.startswith("status command failed · ") and reason in row.detail


async def test_a_status_that_times_out_is_one_row_saying_so() -> None:
    rec = Recorder()
    mon = ServiceMonitor([], interval=30, timeout=5, publish=rec, status=command_status("sleep 5", 0.2))
    await mon.check_all()
    assert rec.calls[-1][0].detail == "status command failed · timed out after 0.2 s"


async def test_rows_that_leave_the_status_leave_the_menu(tmp_path: Path) -> None:
    out = tmp_path / "status.json"
    out.write_text(status_json({"id": "a", "name": "A", "up": True}, {"id": "b", "name": "B", "up": True}))
    mon, rec = status_monitor(f"cat {out}")
    await mon.check_all()
    out.write_text(status_json({"id": "b", "name": "B", "up": True}))
    await mon.check_all()
    assert [s.id for s in rec.calls[-1]] == ["b"]


async def test_a_row_restart_with_a_status_reads_the_status_again(tmp_path: Path) -> None:
    flag = tmp_path / "up"
    out = tmp_path / "status.sh"
    out.write_text(
        f'if [ -f {flag} ]; then echo \'{{"services": [{{"id": "memory", "name": "Memory", "up": true}}]}}\'; '
        f'else echo \'{{"services": [{{"id": "memory", "name": "Memory", "up": false}}]}}\'; fi\n'
    )
    mon, rec = status_monitor(f"sh {out}", services=[svc("memory", "false", restart=f"touch {flag}")])
    await mon.check_all()
    assert rec.calls[-1][0].state == "down"
    await mon.restart("memory")
    assert [s.state for s in rec.calls[-2]] == ["checking"]
    assert rec.calls[-1][0].state == "up"


# --- restart all ---------------------------------------------------------------------


async def test_restart_all_publishes_once_after_the_command_and_rechecks(tmp_path: Path) -> None:
    flag = tmp_path / "restarted"
    mon = ServiceMonitor(
        [svc("files", f"test -f {flag}"), svc("memory", "true")],
        interval=30,
        timeout=5,
        publish=(rec := Recorder()),
        clock=lambda: NOON,
        restart_all=command_restart(f"touch {flag}", 5),
    )
    await mon.check_all()
    before = len(rec.calls)
    await mon.restart_all()
    assert len(rec.calls) == before + 1, "one list, after the command: no interim checking"
    assert {(s.id, s.state) for s in rec.calls[-1]} == {("files", "up"), ("memory", "up")}


async def test_nothing_is_published_while_restart_all_runs(tmp_path: Path) -> None:
    import asyncio

    gate = tmp_path / "gate"
    rec = Recorder()
    mon = ServiceMonitor(
        [svc("files", "true")],
        interval=30,
        timeout=5,
        publish=rec,
        restart_all=command_restart(f"while [ ! -f {gate} ]; do sleep 0.02; done", 5),
    )
    task = asyncio.create_task(mon.restart_all())
    await asyncio.sleep(0.1)
    await mon.check_all()  # the periodic check, meanwhile: found, not published
    assert rec.calls == []
    gate.write_text("")
    await task
    assert [[(s.id, s.state) for s in c] for c in rec.calls] == [[("files", "up")]]


async def test_restart_all_always_answers_with_a_status_even_unchanged() -> None:
    rec = Recorder()
    mon = ServiceMonitor([], interval=30, timeout=5, publish=rec, restart_all=command_restart("true", 5))
    await mon.restart_all()
    assert rec.calls == [[]], "a deployment with no rows still hears the answer"


async def test_a_failed_restart_all_reads_again_then_raises(tmp_path: Path) -> None:
    command = printing(tmp_path / "status.json", status_json({"id": "a", "name": "A", "up": True}))
    mon, rec = status_monitor(command, restart="echo no permission; exit 2")
    await mon.check_all()
    with pytest.raises(ProtocolError) as e:
        await mon.restart_all()
    assert e.value.code == "services.restart_failed" and "exited 2: no permission" in e.value.message
    assert rec.calls[-1][0].state == "up", "the status after the attempt was published first"


async def test_restart_all_without_a_restart_is_refused() -> None:
    mon = ServiceMonitor([], interval=30, timeout=5, publish=Recorder())
    with pytest.raises(ProtocolError) as e:
        await mon.restart_all()
    assert e.value.code == "services.no_restart_all"


# --- plug-in hooks ---------------------------------------------------------------------


def write_plugin(where: Path, name: str, body: str) -> Plugins:
    (where / f"{name}.py").write_text("PORTICO_PLUGIN_API = 1\n" + body)
    return load_plugins([name], [str(where)])


async def start(state_dir: StateDir, plugins: Plugins | None = None, **config: object) -> GatewayServer:
    cfg = make_config(**config)
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=cfg.history_buffer)
    srv = GatewayServer(
        config=cfg, state=state_dir, registry=registry, engine_factory=FakeEngine, version=__version__, plugins=plugins
    )
    await srv.serve(0)
    return srv


def test_the_hooks_load_and_the_last_naming_them_wins(tmp_path: Path) -> None:
    (tmp_path / "pp_one.py").write_text("PORTICO_PLUGIN_API = 1\ndef services_status():\n    return 1\n")
    (tmp_path / "pp_two.py").write_text(
        "PORTICO_PLUGIN_API = 1\nasync def services_status():\n    return 2\ndef restart_services():\n    pass\n"
    )
    plugins = load_plugins(["pp_one", "pp_two"], [str(tmp_path)])
    assert plugins.services_status is not None and plugins.services_status.__module__ == "pp_two"
    assert plugins.restart_services is not None


def test_a_hook_that_is_not_callable_is_refused(tmp_path: Path) -> None:
    from portico_gateway.plugins import PluginError

    (tmp_path / "pp_bad.py").write_text("PORTICO_PLUGIN_API = 1\nservices_status = 3\n")
    with pytest.raises(PluginError):
        load_plugins(["pp_bad"], [str(tmp_path)])


async def test_plugin_hooks_take_precedence_over_the_config(tmp_path: Path, state_dir: StateDir) -> None:
    marker = tmp_path / "config-restart-ran"
    plugins = write_plugin(
        tmp_path,
        "pp_services",
        "CALLS = []\n"
        "async def services_status():\n"
        "    return {'services': [{'id': 'hooked', 'name': 'Hooked', 'up': True}]}\n"
        "def restart_services():\n"
        "    CALLS.append('restart')\n",
    )
    srv = await start(
        state_dir, plugins, deployment={"status": "echo nope; exit 1", "restart": f"touch {marker}"}
    )
    try:
        await srv.services.check_all()
        assert [s.id for s in srv.services.snapshot()] == ["hooked"]
        await srv.services.restart_all()
        assert sys.modules["pp_services"].CALLS == ["restart"] and not marker.exists()
    finally:
        await srv.shutdown()


async def test_a_failing_status_hook_is_one_row_and_a_false_restart_hook_fails(tmp_path: Path, state_dir: StateDir) -> None:
    plugins = write_plugin(
        tmp_path,
        "pp_failing",
        "def services_status():\n    raise RuntimeError('socket gone')\n"
        "async def restart_services():\n    return False\n",
    )
    srv = await start(state_dir, plugins)
    try:
        await srv.services.check_all()
        rows = srv.services.snapshot()
        assert [r.id for r in rows] == [STATUS_FAILED_ID]
        assert rows[0].detail == "status plug-in failed · RuntimeError: socket gone"
        with pytest.raises(ProtocolError) as e:
            await srv.services.restart_all()
        assert e.value.code == "services.restart_failed"
    finally:
        await srv.shutdown()


# --- over the socket --------------------------------------------------------------------


async def test_restart_all_over_the_socket(tmp_path: Path, state_dir: StateDir) -> None:
    flag = tmp_path / "restarted"
    status = tmp_path / "status.sh"
    status.write_text(
        f'if [ -f {flag} ]; then up=true; else up=false; fi\n'
        'echo "{\\"services\\": [{\\"id\\": \\"memory\\", \\"name\\": \\"Memory\\", \\"up\\": $up}]}"\n'
    )
    srv = await start(state_dir, deployment={"status": f"sh {status}", "restart": f"touch {flag}"})
    conn = await attach(srv)  # hello, chat.list, services.status
    try:
        assert any(t.get_name() == "portico-services" for t in srv._tasks), "a status alone starts the monitor"
        await srv.services.check_all()
        await conn.send(dump(ServicesRestartAll(ts=TS, id="req-all")))
        got = await recv_until(conn, ServicesStatus)
        while not (isinstance(got[-1], ServicesStatus) and got[-1].services and got[-1].services[0].state == "up"):
            got.append(await recv(conn))
        assert not [m for m in got if isinstance(m, Error)]
        assert [(s.id, s.state) for s in got[-1].services] == [("memory", "up")]
    finally:
        await conn.close()
        await srv.shutdown()


async def test_restart_all_refusals_and_failure_over_the_socket(tmp_path: Path, state_dir: StateDir) -> None:
    srv = await start(state_dir)
    conn = await attach(srv)
    try:
        await conn.send(dump(ServicesRestartAll(ts=TS, id="req-none")))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "services.no_restart_all" and err.id == "req-none"
    finally:
        await conn.close()
        await srv.shutdown()

    srv = await start(state_dir, deployment={"restart": "echo denied; exit 3"})
    conn = await attach(srv)
    try:
        await conn.send(dump(ServicesRestartAll(ts=TS, id="req-fail")))
        got = await recv_until(conn, Error)
        err = got[-1]
        assert isinstance(err, Error) and err.code == "services.restart_failed" and err.id == "req-fail"
        assert "exited 3: denied" in err.message
        assert any(isinstance(m, ServicesStatus) for m in got), "the status after the attempt comes first"
    finally:
        await conn.close()
        await srv.shutdown()
