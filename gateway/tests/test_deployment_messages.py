"""v0.22: messages from the deployment, a drop folder polled by the gateway and the ``message`` command.

Every folder is under ``tmp_path``; the gateway runs in-process with no model.
"""

from __future__ import annotations

import asyncio
import json
import os
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest

from portico_gateway import __version__
from portico_gateway import deployment_messages as dm
from portico_gateway.__main__ import main
from portico_gateway.chats import ChatRegistry
from portico_gateway.messages import DeploymentMessage, HelloClient, dump, parse_server
from portico_gateway.server import GatewayServer, for_app
from portico_gateway.state import StateDir
from tests.conftest import make_config
from tests.test_server import TS, connect, ws_url
from tests.test_turns import EngineFactory

CAP = "messages.deployment.v1"

# --- the files ---------------------------------------------------------------------


def drop(folder: Path, name: str, body: Any, age: float = 0.0) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / name
    path.write_text(body if isinstance(body, str) else json.dumps(body), encoding="utf-8")
    if age:
        os.utime(path, (path.stat().st_atime - age, path.stat().st_mtime - age))
    return path


def test_write_message_makes_one_atomic_json_file(tmp_path: Path) -> None:
    path = dm.write_message(tmp_path / "state", "Standup moved", title="Heads up", notify=True, space="meeting-prep")
    assert path.parent == tmp_path / "state" / "messages" and path.suffix == ".json"
    body = json.loads(path.read_text())
    assert body["text"] == "Standup moved" and body["title"] == "Heads up" and body["notify"] is True
    assert body["space"] == "meeting-prep" and body["id"] and body["ts"].endswith("Z")
    assert [p.name for p in (tmp_path / "state" / "messages").iterdir()] == [path.name], "no temporary file is left"
    plain = json.loads(dm.write_message(tmp_path / "state", "Hi").read_text())
    assert set(plain) == {"id", "ts", "text"}, "optional keys are left out"


def test_read_message_fills_id_and_ts_and_ignores_unknown_keys(tmp_path: Path) -> None:
    path = drop(tmp_path, "from-a-script.json", {"text": "Hello", "extra": 1})
    msg = dm.read_message(path)
    assert isinstance(msg, DeploymentMessage) and msg.id == "from-a-script" and msg.text == "Hello" and msg.ts.endswith("Z")
    full = dm.read_message(drop(tmp_path, "b.json", {"id": "x1", "ts": "2026-11-05T10:00:00Z", "text": "T", "title": "H", "notify": True, "space": "s"}))
    assert (full.id, full.ts, full.title, full.notify, full.space) == ("x1", "2026-11-05T10:00:00Z", "H", True, "s")


@pytest.mark.parametrize(
    "body",
    ["not json", "[1]", {"title": "no text"}, {"text": "  "}, {"text": 3}, {"text": "a", "notify": "yes"}, {"text": "a", "title": 4}, {"text": "a", "space": 4}, {"text": "a", "id": 4}],
)
def test_read_message_refuses_what_does_not_parse(tmp_path: Path, body: Any) -> None:
    with pytest.raises(dm.DropError):
        dm.read_message(drop(tmp_path, "bad.json", body))


def test_pending_is_oldest_first_and_skips_temporary_and_other_files(tmp_path: Path) -> None:
    drop(tmp_path, "b.json", {"text": "b"}, age=10)
    drop(tmp_path, "a.json", {"text": "a"}, age=5)
    drop(tmp_path, ".half.json", {"text": "x"})
    drop(tmp_path, "note.txt", "x")
    (tmp_path / "failed").mkdir()
    assert [p.name for p in dm.pending(tmp_path)] == ["b.json", "a.json"]


# --- through the gateway -----------------------------------------------------------


@pytest.fixture
async def server(state_dir: StateDir, monkeypatch: pytest.MonkeyPatch) -> AsyncIterator[GatewayServer]:
    monkeypatch.setattr(dm, "POLL_SECONDS", 0.05)
    config = make_config(setting_sources=["project"])
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=EngineFactory(), version=__version__)
    await srv.serve(0)
    try:
        yield srv
    finally:
        await srv.shutdown()


async def hello(server: GatewayServer, capabilities: list[str]):
    conn = await connect(ws_url(server, server.token))
    await conn.send(dump(HelloClient(ts=TS, app_version="0.22.0", capabilities=capabilities)))
    return conn


async def next_message(conn: Any, timeout: float = 2) -> DeploymentMessage:
    while True:
        msg = parse_server(await asyncio.wait_for(conn.recv(), timeout))
        if msg.type == "deployment.message":
            return msg


def folder_of(server: GatewayServer) -> Path:
    return server.state.path / "messages"


async def test_gateway_makes_the_folder_and_advertises_the_capability(server: GatewayServer) -> None:
    assert folder_of(server).is_dir()
    conn = await hello(server, [CAP])
    try:
        frame = parse_server(await asyncio.wait_for(conn.recv(), 2))
        assert frame.type == "hello" and CAP in frame.capabilities
    finally:
        await conn.close()


async def test_a_dropped_file_is_broadcast_then_deleted(server: GatewayServer) -> None:
    conn = await hello(server, ["spaces.v1", CAP])
    try:
        path = dm.write_message(server.state.path, "Standup moved to **10:30**", title="Heads up", notify=True, space="meeting-prep")
        msg = await next_message(conn)
        assert (msg.text, msg.title, msg.notify, msg.space) == ("Standup moved to **10:30**", "Heads up", True, "meeting-prep")
        assert msg.id == json.loads(json.dumps({"id": msg.id}))["id"] and msg.ts
        for _ in range(40):
            if not path.exists():
                break
            await asyncio.sleep(0.05)
        assert not path.exists()
    finally:
        await conn.close()


async def test_an_unparseable_file_goes_to_failed_and_the_rest_still_arrive(server: GatewayServer) -> None:
    conn = await hello(server, [CAP])
    try:
        bad = drop(folder_of(server), "a-bad.json", "{nope", age=5)
        dm.write_message(server.state.path, "after the bad one")
        msg = await next_message(conn)
        assert msg.text == "after the bad one"
        assert not bad.exists() and (folder_of(server) / "failed" / "a-bad.json").read_text() == "{nope"
    finally:
        await conn.close()


async def test_files_wait_without_an_app_and_come_on_the_next_hello_oldest_first(server: GatewayServer) -> None:
    folder = folder_of(server)
    drop(folder, "second.json", {"text": "second"}, age=1)
    drop(folder, "first.json", {"text": "first"}, age=9)
    await asyncio.sleep(0.3)  # several polls with nobody attached
    assert {p.name for p in folder.glob("*.json")} == {"first.json", "second.json"}
    conn = await hello(server, [CAP])
    try:
        assert [(await next_message(conn)).text, (await next_message(conn)).text] == ["first", "second"]
    finally:
        await conn.close()


async def test_an_app_without_the_capability_is_sent_nothing_and_the_files_stay(server: GatewayServer) -> None:
    conn = await hello(server, ["spaces.v1"])  # the capabilities a v0.21 app sends
    try:
        dm.write_message(server.state.path, "for a newer app")
        await asyncio.sleep(0.3)
        assert len(list(folder_of(server).glob("*.json"))) == 1
        with pytest.raises(TimeoutError):
            while True:
                assert parse_server(await asyncio.wait_for(conn.recv(), 0.3)).type != "deployment.message"
    finally:
        await conn.close()
    assert for_app(DeploymentMessage(ts=TS, id="m", text="t"), frozenset()) is None
    assert for_app(DeploymentMessage(ts=TS, id="m", text="t"), frozenset({CAP})) is not None


async def test_at_most_fifty_wait_and_the_oldest_are_dropped(server: GatewayServer) -> None:
    folder = folder_of(server)
    for n in range(53):
        drop(folder, f"m{n:02d}.json", {"text": str(n)}, age=1000 - n)
    await asyncio.sleep(0.3)
    left = sorted(p.name for p in folder.glob("*.json"))
    assert len(left) == dm.HOLD_MAX == 50 and left[0] == "m03.json" and left[-1] == "m52.json"


def test_the_message_command_writes_the_drop_file(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    home = tmp_path / "home"
    assert main(["message", "Prep is ready", "--title", "Meeting", "--notify", "--space", "meeting-prep", "--state", str(home)]) == 0
    files = list((home / "messages").glob("*.json"))
    assert len(files) == 1 and files[0].name in capsys.readouterr().out
    body = json.loads(files[0].read_text())
    assert (body["text"], body["title"], body["notify"], body["space"]) == ("Prep is ready", "Meeting", True, "meeting-prep")


def test_the_message_command_refuses_an_empty_text(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["message", "   ", "--state", str(tmp_path / "home")]) == 2
    assert "text" in capsys.readouterr().err
    assert not (tmp_path / "home" / "messages").exists() or not list((tmp_path / "home" / "messages").glob("*.json"))
