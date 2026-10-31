"""v0.12: the viewer tools and the ``viewer.act`` / ``viewer.result`` round trip.

The bridge is driven with a fake app connection; the server tests use a real
WebSocket client. No model: tool handlers are called directly.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest

from portico_gateway.engine import SHOW_SERVER, SHOW_TOOL_NAME, build_options
from portico_gateway.messages import (
    HelloClient,
    HelloServer,
    ViewerAct,
    ViewerImage,
    ViewerResult,
    ViewerSettings,
    dump,
    parse_server,
)
from portico_gateway.viewer import (
    NO_ANSWER,
    NOT_AVAILABLE,
    SETTING_OFF,
    VIEWER_TOOL_NAMES,
    ViewerBridge,
    build_viewer_tools,
)
from tests.conftest import RecordingCallbacks
from tests.test_server import TS, connect, make_server, ws_url

PNG = "iVBORw0KGgo="


class FakeApp:
    """A fake app connection: records the acts it is sent; answers them when ``reply`` is set."""

    def __init__(self, bridge: ViewerBridge, reply: ViewerResult | None = None) -> None:
        self.bridge = bridge
        self.acts: list[ViewerAct] = []
        self.reply = reply

    async def send(self, conn: Any, act: ViewerAct) -> None:
        self.acts.append(act)
        if self.reply is not None:
            self.bridge.resolve(conn, self.reply.model_copy(update={"id": act.id}))


def make_bridge(reply: ViewerResult | None = None, capable: bool = True, defaults: tuple[bool, bool] = (True, True)):
    holder: dict[str, FakeApp] = {}

    async def send(conn: Any, act: ViewerAct) -> None:
        await holder["app"].send(conn, act)

    bridge = ViewerBridge(send, capable=lambda conn: capable, defaults=defaults)
    holder["app"] = FakeApp(bridge, reply)
    return bridge, holder["app"]


def ok(text: str = "Done.", image: ViewerImage | None = None) -> ViewerResult:
    return ViewerResult(ts=TS, id="x", ok=True, text=text, image=image)


def by_name(tools: list[Any]) -> dict[str, Any]:
    return {t.name: t for t in tools}


# --- the round trip ---------------------------------------------------------------


async def test_look_returns_text_and_image_content() -> None:
    bridge, app = make_bridge(ok("trail-detail.html\ne1 heading Trails", ViewerImage(data=PNG, media_type="image/png")))
    conn = object()
    bridge.set_target(conn, True, True)
    tools = by_name(build_viewer_tools(bridge, 3))
    out = await tools["viewer_look"].handler({})
    assert out == {
        "content": [
            {"type": "text", "text": "trail-detail.html\ne1 heading Trails"},
            {"type": "image", "data": PNG, "mimeType": "image/png"},
        ]
    }
    assert [(a.chat, a.action, a.args) for a in app.acts] == [(3, "look", {})]


async def test_wire_args_per_action() -> None:
    bridge, app = make_bridge(ok())
    bridge.set_target(object(), True, True)
    tools = by_name(build_viewer_tools(bridge, 1))
    await tools["viewer_click"].handler({"target": "e12"})
    await tools["viewer_type"].handler({"target": "e3", "text": "hi"})
    await tools["viewer_type"].handler({"target": "e3", "text": "hi", "submit": True})
    await tools["viewer_scroll"].handler({"direction": "down"})
    await tools["viewer_scroll"].handler({"target": "Pricing"})
    await tools["viewer_back"].handler({})
    assert [(a.action, a.args) for a in app.acts] == [
        ("click", {"target": "e12"}),
        ("type", {"target": "e3", "text": "hi", "submit": False}),
        ("type", {"target": "e3", "text": "hi", "submit": True}),
        ("scroll", {"direction": "down"}),
        ("scroll", {"target": "Pricing"}),
        ("back", {}),
    ]


async def test_not_ok_result_is_an_error_with_its_words() -> None:
    bridge, _ = make_bridge(ViewerResult(ts=TS, id="x", ok=False, text="", error="Not found — look again"))
    bridge.set_target(object(), True, True)
    out = await by_name(build_viewer_tools(bridge, 1))["viewer_click"].handler({"target": "e99"})
    assert out == {"content": [{"type": "text", "text": "Not found — look again"}], "is_error": True}


async def test_no_app_answers_not_available() -> None:
    bridge, app = make_bridge(ok())
    out = await by_name(build_viewer_tools(bridge, 1))["viewer_look"].handler({})
    assert out == {"content": [{"type": "text", "text": NOT_AVAILABLE}], "is_error": True}
    assert NOT_AVAILABLE == "The viewer isn't available right now (Portico isn't open)."
    assert app.acts == []


async def test_old_app_without_capability_answers_not_available() -> None:
    bridge, app = make_bridge(ok(), capable=False)
    bridge.set_target(object(), True, True)
    out = await by_name(build_viewer_tools(bridge, 1))["viewer_look"].handler({})
    assert out["content"][0]["text"] == NOT_AVAILABLE and out["is_error"] is True
    assert app.acts == []


async def test_setting_off_refuses_every_tool_but_show() -> None:
    bridge, app = make_bridge(ok())
    bridge.set_target(object(), False, True)
    tools = by_name(build_viewer_tools(bridge, 1))
    assert set(tools) == {"viewer_look", "viewer_click", "viewer_type", "viewer_scroll", "viewer_back"}
    for name, args in [
        ("viewer_look", {}),
        ("viewer_click", {"target": "e1"}),
        ("viewer_type", {"target": "e1", "text": "x"}),
        ("viewer_scroll", {"direction": "up"}),
        ("viewer_back", {}),
    ]:
        out = await tools[name].handler(args)
        assert out == {"content": [{"type": "text", "text": SETTING_OFF}], "is_error": True}, name
    assert SETTING_OFF == "The person has turned off the agent's view of the viewer in Settings."
    assert app.acts == []


async def test_config_defaults_apply_until_the_app_sends_settings() -> None:
    bridge, _ = make_bridge(ok(), defaults=(False, False))
    conn = object()
    bridge._target = conn  # an app is there but has sent no settings (older than this rule: tests the default only)
    assert bridge.settings is None and bridge.can_see is False and bridge.check_html is False
    out = await by_name(build_viewer_tools(bridge, 1))["viewer_look"].handler({})
    assert out["content"][0]["text"] == SETTING_OFF
    bridge.set_target(conn, True, True)  # the person's choice wins
    assert bridge.can_see is True and bridge.check_html is True


async def test_timeout_answers_after_10s() -> None:
    bridge, app = make_bridge(None)  # the app never answers
    bridge.set_target(object(), True, True)
    out = await bridge.act(1, "look", {}, timeout=0.05)
    assert out == {"content": [{"type": "text", "text": NO_ANSWER}], "is_error": True}
    assert NO_ANSWER == "The viewer didn't answer in 10 s."
    assert len(app.acts) == 1 and bridge._pending == {}


async def test_disconnect_fails_pending_act() -> None:
    bridge, app = make_bridge(None)
    conn = object()
    bridge.set_target(conn, True, True)
    task = asyncio.create_task(bridge.act(1, "look", {}, timeout=5))
    await asyncio.sleep(0.01)
    assert len(app.acts) == 1
    bridge.drop(conn)
    out = await asyncio.wait_for(task, 1)
    assert out == {"content": [{"type": "text", "text": NOT_AVAILABLE}], "is_error": True}
    # and nothing is targeted any more
    assert (await bridge.act(1, "look", {}))["content"][0]["text"] == NOT_AVAILABLE


async def test_acts_go_to_latest_settings_sender() -> None:
    sent: list[tuple[Any, ViewerAct]] = []
    bridge: ViewerBridge

    async def send(conn: Any, act: ViewerAct) -> None:
        sent.append((conn, act))
        bridge.resolve(conn, ViewerResult(ts=TS, id=act.id, ok=True, text="ok"))

    bridge = ViewerBridge(send)
    first, second = object(), object()
    bridge.set_target(first, True, True)
    bridge.set_target(second, True, False)
    await bridge.act(1, "back", {})
    assert [c for c, _ in sent] == [second]
    assert bridge.settings == (True, False)
    # the first leaving changes nothing for the second
    bridge.drop(first)
    await bridge.act(1, "back", {})
    assert [c for c, _ in sent] == [second, second]


async def test_a_result_from_another_app_is_ignored() -> None:
    bridge, _ = make_bridge(None)
    conn, other = object(), object()
    bridge.set_target(conn, True, True)
    task = asyncio.create_task(bridge.act(1, "look", {}, timeout=0.1))
    await asyncio.sleep(0.01)
    (act_id,) = bridge._pending
    bridge.resolve(other, ViewerResult(ts=TS, id=act_id, ok=True, text="spoofed"))
    bridge.resolve(conn, ViewerResult(ts=TS, id="unknown", ok=True, text="stray"))
    out = await task
    assert out["content"][0]["text"] == NO_ANSWER


# --- registered beside show_in_viewer -------------------------------------------------


class WithBridge(RecordingCallbacks):
    def __init__(self, bridge: ViewerBridge, chat: int = 4) -> None:
        super().__init__()
        self.viewer_bridge = bridge
        self.viewer_chat = chat


def test_tools_registered_with_show_in_viewer(tmp_path: Path) -> None:
    bridge, _ = make_bridge()
    options = build_options(tmp_path, None, ["project"], WithBridge(bridge))
    server = (options.mcp_servers or {})[SHOW_SERVER]  # type: ignore[index]
    assert server["type"] == "sdk" and server["name"] == SHOW_SERVER
    assert options.allowed_tools == [SHOW_TOOL_NAME, *VIEWER_TOOL_NAMES]
    assert VIEWER_TOOL_NAMES[0] == "mcp__portico__viewer_look"


def test_no_bridge_leaves_the_show_tool_alone(tmp_path: Path) -> None:
    options = build_options(tmp_path, None, ["project"], RecordingCallbacks())
    assert options.allowed_tools == [SHOW_TOOL_NAME]


def test_tool_names_and_schemas() -> None:
    bridge, _ = make_bridge()
    tools = by_name(build_viewer_tools(bridge, 1))
    assert [f"mcp__portico__{n}" for n in tools] == list(VIEWER_TOOL_NAMES)
    assert tools["viewer_scroll"].input_schema["required"] == []
    assert tools["viewer_type"].input_schema["required"] == ["target", "text"]
    assert tools["viewer_click"].input_schema["required"] == ["target"]


# --- through the server -------------------------------------------------------------------


@pytest.fixture
async def server(state_dir, config) -> AsyncIterator[Any]:
    srv = make_server(state_dir, config)
    await srv.serve(0)
    try:
        yield srv
    finally:
        await srv.shutdown()


async def attach_app(server: Any, capabilities: list[str]):
    conn = await connect(ws_url(server, server.token))
    await conn.send(dump(HelloClient(ts=TS, app_version="0.12.0", capabilities=capabilities)))
    assert isinstance(parse_server(await conn.recv()), HelloServer)
    return conn


async def until(predicate, seconds: float = 2.0) -> None:
    async def poll() -> None:
        while not predicate():
            await asyncio.sleep(0.01)

    await asyncio.wait_for(poll(), seconds)


async def frames_until(conn, type_name: str) -> Any:
    while True:
        msg = parse_server(await asyncio.wait_for(conn.recv(), 2))
        if msg.type == type_name:
            return msg


async def test_server_round_trip(server: Any) -> None:
    conn = await attach_app(server, ["viewer.v1"])
    await conn.send(dump(ViewerSettings(ts=TS, can_see=True, check_html=False)))
    await until(lambda: server.viewer.settings is not None)
    assert server.viewer.settings == (True, False)
    task = asyncio.create_task(server.viewer.act(7, "look", {}))
    act = await frames_until(conn, "viewer.act")
    assert (act.chat, act.action, act.args) == (7, "look", {})
    await conn.send(dump(ViewerResult(
        ts=TS, id=act.id, ok=True, text="hello", image=ViewerImage(data=PNG, media_type="image/png"))))
    out = await asyncio.wait_for(task, 2)
    assert out["content"][0] == {"type": "text", "text": "hello"}
    assert out["content"][1]["mimeType"] == "image/png"
    await conn.close()


async def test_server_old_app_gets_no_act(server: Any) -> None:
    conn = await attach_app(server, [])
    await conn.send(dump(ViewerSettings(ts=TS, can_see=True, check_html=True)))
    await until(lambda: server.viewer.settings is not None)
    out = await server.viewer.act(1, "look", {})
    assert out["content"][0]["text"] == NOT_AVAILABLE
    await conn.close()


async def test_server_app_disconnect_fails_pending_act(server: Any) -> None:
    conn = await attach_app(server, ["viewer.v1"])
    await conn.send(dump(ViewerSettings(ts=TS, can_see=True, check_html=True)))
    await until(lambda: server.viewer.settings is not None)
    task = asyncio.create_task(server.viewer.act(1, "look", {}, timeout=5))
    await frames_until(conn, "viewer.act")
    await conn.close()
    out = await asyncio.wait_for(task, 2)
    assert out["content"][0]["text"] == NOT_AVAILABLE
    assert server.viewer.settings is None


async def test_server_second_app_takes_over_pending_stays_with_first(server: Any) -> None:
    first = await attach_app(server, ["viewer.v1"])
    await first.send(dump(ViewerSettings(ts=TS, can_see=True, check_html=True)))
    await until(lambda: server.viewer.settings is not None)
    task = asyncio.create_task(server.viewer.act(1, "look", {}, timeout=0.5))
    await frames_until(first, "viewer.act")
    second = await attach_app(server, ["viewer.v1"])  # the first is replaced and closed
    await asyncio.wait_for(task, 3)  # answers within the timeout, never hangs
    await second.send(dump(ViewerSettings(ts=TS, can_see=True, check_html=True)))
    await until(lambda: server.viewer._target is not None)
    task2 = asyncio.create_task(server.viewer.act(1, "back", {}))
    act = await frames_until(second, "viewer.act")
    assert act.action == "back"
    await second.send(dump(ViewerResult(ts=TS, id=act.id, ok=True, text="back")))
    assert (await asyncio.wait_for(task2, 2))["content"][0]["text"] == "back"
    await second.close()
