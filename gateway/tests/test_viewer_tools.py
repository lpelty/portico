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

from portico_gateway import viewer as viewer_mod
from portico_gateway.artifacts import artifact_for_location
from portico_gateway.engine import SHOW_SERVER, SHOW_TOOL_NAME, build_check_html_hook, build_options
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
    NEEDS_UPDATE,
    NO_ANSWER,
    NOT_AVAILABLE,
    QUEUE_NOTE,
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


def make_bridge(
    reply: ViewerResult | None = None,
    capable: bool = True,
    defaults: tuple[bool, bool] = (True, True),
    marks_capable: bool = True,
    show_capable: bool = True,
):
    holder: dict[str, FakeApp] = {}

    async def send(conn: Any, act: ViewerAct) -> None:
        await holder["app"].send(conn, act)

    bridge = ViewerBridge(
        send,
        capable=lambda conn: capable,
        defaults=defaults,
        marks_capable=lambda conn: marks_capable,
        show_capable=lambda conn: show_capable,
    )
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
    assert set(tools) == {
        "viewer_look",
        "viewer_click",
        "viewer_type",
        "viewer_scroll",
        "viewer_back",
        "viewer_mark",
        "viewer_clear_marks",
    }
    for name, args in [
        ("viewer_look", {}),
        ("viewer_click", {"target": "e1"}),
        ("viewer_type", {"target": "e1", "text": "x"}),
        ("viewer_scroll", {"direction": "up"}),
        ("viewer_back", {}),
        ("viewer_mark", {"marks": [{"target": "e1"}]}),
        ("viewer_clear_marks", {}),
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


# --- v0.17: the show round trip, and one viewer call at a time per conversation ----------


def web_page(url: str = "https://acme.example/pricing"):
    return artifact_for_location(url, source="tool", open=True)


async def settle() -> None:
    """Let every ready task run up to its next wait."""
    for _ in range(5):
        await asyncio.sleep(0)


async def test_show_round_trip_waits_for_the_app() -> None:
    bridge, app = make_bridge(None, show_capable=True)
    conn = object()
    bridge.set_target(conn, True, True)
    art = web_page()
    task = asyncio.create_task(bridge.show(1, art))
    await settle()
    assert [(a.chat, a.action, a.args) for a in app.acts] == [
        (1, "show", {"artifact": art.id, "location": art.location})
    ]
    assert not task.done()  # pending until the app says the page loaded
    bridge.resolve(conn, ok().model_copy(update={"id": app.acts[0].id}))
    assert await asyncio.wait_for(task, 1) is True
    assert bridge._pending == {}


async def test_show_answered_not_ok_is_false() -> None:
    bridge, app = make_bridge(ViewerResult(ts=TS, id="x", ok=False, text="Shown; still loading."))
    bridge.set_target(object(), True, True)
    assert await bridge.show(1, web_page()) is False
    assert len(app.acts) == 1


async def test_show_when_the_app_leaves_mid_show_is_false() -> None:
    bridge, app = make_bridge(None)
    conn = object()
    bridge.set_target(conn, True, True)
    task = asyncio.create_task(bridge.show(1, web_page()))
    await settle()
    assert [a.action for a in app.acts] == ["show"]
    bridge.drop(conn)
    assert await asyncio.wait_for(task, 1) is False


async def test_show_when_the_send_fails_is_false() -> None:
    async def send(conn: Any, act: ViewerAct) -> None:
        raise ConnectionError("closed")

    bridge = ViewerBridge(send)
    bridge.set_target(object(), True, True)
    assert await bridge.show(1, web_page()) is False


async def test_show_without_the_capability_sends_nothing() -> None:
    bridge, app = make_bridge(ok(), show_capable=False)
    bridge.set_target(object(), True, True)
    assert await bridge.show(1, web_page()) is None
    assert app.acts == []
    # No target at all: no round trip possible either.
    bridge2, app2 = make_bridge(ok())
    assert await bridge2.show(1, web_page()) is None
    assert app2.acts == []


async def test_show_ignores_the_setting_off() -> None:
    bridge, app = make_bridge(ok(), defaults=(False, True))
    bridge.set_target(object(), False, True)
    assert await bridge.show(1, web_page()) is True
    assert [a.action for a in app.acts] == ["show"]


async def test_a_show_that_times_out_releases_the_queue(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(viewer_mod, "SHOW_TIMEOUT", 0.2)
    bridge, app = make_bridge(None)  # the app never answers the show
    conn = object()
    bridge.set_target(conn, True, True)
    tools = by_name(build_viewer_tools(bridge, 1))
    shown: list[bool | None] = []

    async def show() -> None:
        async with bridge.queue(1):
            shown.append(await bridge.show(1, web_page()))

    show_task = asyncio.create_task(show())
    await settle()
    click_task = asyncio.create_task(tools["viewer_click"].handler({"target": "e3"}))
    await settle()
    assert [a.action for a in app.acts] == ["show"]  # the click waits behind the show
    await asyncio.wait_for(show_task, 2)
    assert shown == [False]
    await until(lambda: len(app.acts) == 2)
    assert app.acts[1].action == "click"
    bridge.resolve(conn, ok("Clicked.").model_copy(update={"id": app.acts[1].id}))
    assert (await asyncio.wait_for(click_task, 1))["content"][0]["text"] == "Clicked."


async def test_calls_run_in_the_order_sent() -> None:
    bridge, app = make_bridge(None)
    conn = object()
    bridge.set_target(conn, True, True)
    tools = by_name(build_viewer_tools(bridge, 1))
    other = by_name(build_viewer_tools(bridge, 2))

    async def show() -> bool | None:
        async with bridge.queue(1):
            return await bridge.show(1, web_page())

    tasks = [asyncio.create_task(show())]
    await settle()
    tasks.append(asyncio.create_task(tools["viewer_click"].handler({"target": "e1"})))
    await settle()
    tasks.append(asyncio.create_task(tools["viewer_click"].handler({"target": "e2"})))
    await settle()
    tasks.append(asyncio.create_task(tools["viewer_look"].handler({})))
    await settle()
    # Another conversation's look is not held by chat 1's queue.
    elsewhere = asyncio.create_task(other["viewer_look"].handler({}))
    await settle()
    assert [(a.chat, a.action) for a in app.acts] == [(1, "show"), (2, "look")]
    bridge.resolve(conn, ok().model_copy(update={"id": app.acts[1].id}))
    await asyncio.wait_for(elsewhere, 1)
    chat_one = [app.acts[0]]
    for expected in ("click", "click", "look"):
        bridge.resolve(conn, ok().model_copy(update={"id": chat_one[-1].id}))
        await until(lambda: len([a for a in app.acts if a.chat == 1]) == len(chat_one) + 1)
        await settle()
        sent = [a for a in app.acts if a.chat == 1]
        assert len(sent) == len(chat_one) + 1  # one at a time
        chat_one.append(sent[-1])
        assert sent[-1].action == expected
    assert [a.args for a in chat_one[1:3]] == [{"target": "e1"}, {"target": "e2"}]
    bridge.resolve(conn, ok().model_copy(update={"id": chat_one[-1].id}))
    await asyncio.wait_for(asyncio.gather(*tasks), 1)
    assert tasks[0].result() is True


def test_every_viewer_tool_says_calls_run_in_order() -> None:
    bridge, _ = make_bridge()
    for t in build_viewer_tools(bridge, 1):
        assert t.description.endswith(QUEUE_NOTE), t.name
    assert QUEUE_NOTE == " Viewer calls run one at a time, in the order you send them."


def test_mark_target_is_any_text_the_person_can_see() -> None:
    bridge, _ = make_bridge()
    mark = by_name(build_viewer_tools(bridge, 1))["viewer_mark"]
    assert "target is a ref from your last viewer_look (e12), or any text the person can see on the page." in mark.description


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


async def test_server_accepts_a_result_over_1_mib(server: Any) -> None:
    """A full-size screenshot in ``viewer.result`` is bigger than the WebSocket default 1 MiB; the gateway takes it."""
    conn = await attach_app(server, ["viewer.v1"])
    await conn.send(dump(ViewerSettings(ts=TS, can_see=True, check_html=False)))
    await until(lambda: server.viewer.settings is not None)
    task = asyncio.create_task(server.viewer.act(1, "look", {}))
    act = await frames_until(conn, "viewer.act")
    big = "A" * (3 * 2**20)
    await conn.send(dump(ViewerResult(
        ts=TS, id=act.id, ok=True, text="big", image=ViewerImage(data=big, media_type="image/png"))))
    out = await asyncio.wait_for(task, 5)
    assert out["content"][1]["data"] == big
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


async def test_a_refused_show_releases_the_queue(server: Any, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from tests.test_turns import new_chat, recv_until
    from portico_gateway.messages import ServicesStatus

    conn = await attach_app(server, ["viewer.v1", "viewer.show.v1"])
    await recv_until(conn, ServicesStatus)
    await conn.send(dump(ViewerSettings(ts=TS, can_see=True, check_html=True)))
    await until(lambda: server.viewer.settings is not None)
    folder = tmp_path / "demo"
    folder.mkdir()
    number = await new_chat(conn, folder)
    chat = server.registry.get(number)
    look = by_name(build_viewer_tools(server.viewer, number))["viewer_look"]

    assert await server.show_files(chat, ["missing.html"]) == "Not shown: there is no file at missing.html."
    task = asyncio.create_task(look.handler({}))
    act = await frames_until(conn, "viewer.act")
    assert act.action == "look"
    await conn.send(dump(ViewerResult(ts=TS, id=act.id, ok=True, text="looked")))
    assert (await asyncio.wait_for(task, 2))["content"][0]["text"] == "looked"

    # A show that raises inside the queue releases it too.
    def broken(chat: Any, raw: str) -> Any:
        raise RuntimeError("disk gone")

    monkeypatch.setattr(server, "_showable", broken)
    with pytest.raises(RuntimeError):
        await server.show_files(chat, ["a.html"])
    task = asyncio.create_task(look.handler({}))
    act = await frames_until(conn, "viewer.act")
    await conn.send(dump(ViewerResult(ts=TS, id=act.id, ok=True, text="again")))
    assert (await asyncio.wait_for(task, 2))["content"][0]["text"] == "again"
    await conn.close()


async def test_stalled_send_is_bounded_by_the_same_timeout() -> None:
    async def send(conn: Any, act: ViewerAct) -> None:
        await asyncio.sleep(30)  # the socket write never completes

    bridge = ViewerBridge(send)
    bridge.set_target(object(), True, True)
    out = await asyncio.wait_for(bridge.act(1, "look", {}, timeout=0.05), 2)
    assert out == {"content": [{"type": "text", "text": NO_ANSWER}], "is_error": True}
    assert bridge._pending == {}


async def test_failed_send_is_logged_then_not_available(caplog: pytest.LogCaptureFixture) -> None:
    async def send(conn: Any, act: ViewerAct) -> None:
        raise ConnectionError("closed")

    bridge = ViewerBridge(send)
    bridge.set_target(object(), True, True)
    with caplog.at_level("WARNING"):
        out = await bridge.act(1, "look", {})
    assert out["is_error"] is True and out["content"][0]["text"] == NOT_AVAILABLE
    assert any(r.levelname == "WARNING" and "viewer.act" in r.getMessage() for r in caplog.records)


# --- the check-HTML hook (v0.12 section 3.3) -------------------------------------------

CHECK_SENTENCE = (
    "Before you reply, show {file} in the viewer and look at it with viewer_look; "
    "tell the person what you saw and fix what's broken."
)


def write_input(path: Path, tool: str = "Write") -> dict[str, Any]:
    return {"hook_event_name": "PostToolUse", "tool_name": tool, "tool_input": {"file_path": str(path)}, "cwd": str(path.parent)}


def context_of(out: dict[str, Any]) -> str | None:
    return out.get("hookSpecificOutput", {}).get("additionalContext")


def ready_bridge(capable: bool = True):
    """A bridge with an app attached that declared ``viewer.v1`` (when ``capable``) and sent ``viewer.settings``."""
    bridge, app = make_bridge(capable=capable)
    bridge.set_target(object(), True, True)
    return bridge, app


async def test_html_write_in_folder_adds_context(tmp_path: Path) -> None:
    bridge, _ = ready_bridge()
    hook = build_check_html_hook(bridge, tmp_path, [])
    page = tmp_path / "index.html"
    for tool in ("Write", "Edit", "MultiEdit"):
        out = await hook(write_input(page, tool), "t1", None)
        assert out["hookSpecificOutput"]["hookEventName"] == "PostToolUse"
        assert context_of(out) == CHECK_SENTENCE.format(file=page.resolve())
    htm = await hook(write_input(tmp_path / "old.HTM"), "t2", None)
    assert context_of(htm) is not None


async def test_html_in_a_root_adds_context(tmp_path: Path) -> None:
    bridge, _ = ready_bridge()
    folder, root = tmp_path / "chat", tmp_path / "root"
    folder.mkdir(), root.mkdir()
    hook = build_check_html_hook(bridge, folder, [root])
    assert context_of(await hook(write_input(root / "a.html"), "t", None)) is not None


async def test_md_write_no_context(tmp_path: Path) -> None:
    bridge, _ = ready_bridge()
    hook = build_check_html_hook(bridge, tmp_path, [])
    assert await hook(write_input(tmp_path / "notes.md"), "t", None) == {}


async def test_html_outside_roots_no_context(tmp_path: Path) -> None:
    bridge, _ = ready_bridge()
    folder, other = tmp_path / "chat", tmp_path / "elsewhere"
    folder.mkdir(), other.mkdir()
    hook = build_check_html_hook(bridge, folder, [])
    assert await hook(write_input(other / "a.html"), "t", None) == {}
    assert await hook({"tool_name": "Write", "tool_input": {}}, "t", None) == {}


async def test_setting_read_live(tmp_path: Path) -> None:
    bridge, _ = ready_bridge()
    hook = build_check_html_hook(bridge, tmp_path, [])
    page = write_input(tmp_path / "a.html")
    assert context_of(await hook(page, "t", None)) is not None
    bridge.settings = (True, False)
    assert await hook(page, "t", None) == {}
    bridge.settings = (True, True)
    assert context_of(await hook(page, "t", None)) is not None


async def test_check_off_when_can_see_off(tmp_path: Path) -> None:
    bridge, _ = ready_bridge()
    hook = build_check_html_hook(bridge, tmp_path, [])
    bridge.settings = (False, True)
    assert await hook(write_input(tmp_path / "a.html"), "t", None) == {}


async def test_no_context_without_a_capable_app(tmp_path: Path) -> None:
    page = write_input(tmp_path / "a.html")
    bridge, _ = make_bridge()  # no app has sent viewer.settings
    assert await build_check_html_hook(bridge, tmp_path, [])(page, "t", None) == {}
    old, _ = ready_bridge(capable=False)  # an app without viewer.v1
    assert await build_check_html_hook(old, tmp_path, [])(page, "t", None) == {}
    bridge.set_target(object(), True, True)
    assert context_of(await build_check_html_hook(bridge, tmp_path, [])(page, "t", None)) is not None


async def test_type_submits_only_on_true() -> None:
    bridge, app = make_bridge(ok())
    bridge.set_target(object(), True, True)
    viewer_type = by_name(build_viewer_tools(bridge, 1))["viewer_type"]
    for given, expect in (("false", False), ("true", False), (1, False), (True, True), (None, False)):
        args = {"target": "e1", "text": "x"} | ({} if given is None else {"submit": given})
        await viewer_type.handler(args)
        assert app.acts[-1].args["submit"] is expect, given


def test_hook_registered_on_write_edit_multiedit(tmp_path: Path) -> None:
    bridge, _ = make_bridge()
    options = build_options(tmp_path, None, ["project"], WithBridge(bridge))
    matchers = (options.hooks or {})["PostToolUse"]
    assert [m.matcher for m in matchers] == ["Write|Edit|MultiEdit|Bash"]
    plain = build_options(tmp_path, None, ["project"], RecordingCallbacks())
    assert "PostToolUse" not in (plain.hooks or {})


async def test_a_jpeg_look_becomes_a_jpeg_image_item() -> None:
    bridge, _app = make_bridge(ok("shot", ViewerImage(data=PNG, media_type="image/jpeg")))
    bridge.set_target(object(), True, True)
    out = await by_name(build_viewer_tools(bridge, 3))["viewer_look"].handler({})
    assert out["content"][1] == {"type": "image", "data": PNG, "mimeType": "image/jpeg"}


def bash_input(command: str, cwd: Path) -> dict[str, Any]:
    return {"hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": {"command": command}, "cwd": str(cwd)}


async def test_bash_heredoc_html_write_adds_context(tmp_path: Path) -> None:
    bridge, _ = ready_bridge()
    hook = build_check_html_hook(bridge, tmp_path, [])
    (tmp_path / "proto").mkdir()
    page = tmp_path / "proto" / "hello.html"
    page.write_text("<p>hi</p>")
    command = "cat > proto/hello.html <<'EOF'\n<p>hi</p>\nEOF"
    assert context_of(await hook(bash_input(command, tmp_path), "t", None)) == CHECK_SENTENCE.format(file=page.resolve())


async def test_bash_several_html_names_each(tmp_path: Path) -> None:
    bridge, _ = ready_bridge()
    hook = build_check_html_hook(bridge, tmp_path, [])
    for name in ("a.html", "b.html"):
        (tmp_path / name).write_text("x")
    text = context_of(await hook(bash_input("cp tpl.html a.html && cp tpl.html b.html", tmp_path), "t", None))
    assert text is not None and str((tmp_path / "a.html").resolve()) in text and str((tmp_path / "b.html").resolve()) in text


async def test_bash_md_write_no_context(tmp_path: Path) -> None:
    bridge, _ = ready_bridge()
    hook = build_check_html_hook(bridge, tmp_path, [])
    (tmp_path / "notes.md").write_text("x")
    assert await hook(bash_input("echo hi > notes.md", tmp_path), "t", None) == {}


async def test_bash_html_outside_roots_no_context(tmp_path: Path) -> None:
    bridge, _ = ready_bridge()
    folder, other = tmp_path / "chat", tmp_path / "elsewhere"
    folder.mkdir(), other.mkdir()
    (other / "a.html").write_text("x")
    hook = build_check_html_hook(bridge, folder, [])
    assert await hook(bash_input(f"echo hi > {other / 'a.html'}", folder), "t", None) == {}


async def test_bash_read_of_old_html_no_context(tmp_path: Path) -> None:
    import os

    bridge, _ = ready_bridge()
    hook = build_check_html_hook(bridge, tmp_path, [])
    (tmp_path / "proto").mkdir()
    old = tmp_path / "proto" / "old.html"
    old.write_text("x")
    stamp = old.stat().st_mtime - 3600
    os.utime(old, (stamp, stamp))
    assert await hook(bash_input("cat proto/old.html", tmp_path), "t", None) == {}


# --- v0.14: marks ------------------------------------------------------------------

MARKS = [{"target": "e3", "note": "No axis labels"}]


def marks_tools(bridge: ViewerBridge) -> dict[str, Any]:
    return by_name(build_viewer_tools(bridge, 1))


async def test_mark_sends_act_with_marks_and_replace() -> None:
    bridge, app = make_bridge(ok())
    bridge.set_target(object(), True, True)
    await marks_tools(bridge)["viewer_mark"].handler({"marks": MARKS})
    assert [(a.action, a.args) for a in app.acts] == [("mark", {"marks": MARKS, "replace": False})]


async def test_mark_replace_string_false_is_false() -> None:
    bridge, app = make_bridge(ok())
    bridge.set_target(object(), True, True)
    tool = marks_tools(bridge)["viewer_mark"]
    for given, expect in (("false", False), ("true", False), (True, True), (False, False)):
        await tool.handler({"marks": MARKS, "replace": given})
        assert app.acts[-1].args["replace"] is expect, given


@pytest.mark.parametrize("marks", [[], [{"target": f"e{i}"} for i in range(10)]])
async def test_mark_rejects_zero_and_ten(marks: list[dict[str, str]]) -> None:
    bridge, app = make_bridge(ok())
    bridge.set_target(object(), True, True)
    out = await marks_tools(bridge)["viewer_mark"].handler({"marks": marks})
    assert out == {"content": [{"type": "text", "text": "Mark 1 to 9 things at a time."}], "is_error": True}
    assert app.acts == []


@pytest.mark.parametrize(
    "marks",
    [
        [{"note": "no target"}],
        [{"target": ""}],
        [{"target": "   "}],
        [{"target": 3}],
        [{"target": "e1", "note": "x" * 61}],
        [{"target": "e1", "note": 7}],
        ["e1"],
        [{"target": "e1"}, {"target": "e2", "note": "y" * 61}],
    ],
)
async def test_mark_rejects_bad_items_without_asking_the_app(marks: list[Any]) -> None:
    bridge, app = make_bridge(ok())
    bridge.set_target(object(), True, True)
    out = await marks_tools(bridge)["viewer_mark"].handler({"marks": marks})
    text = "Each mark needs a target, and a note of at most 60 characters."
    assert out == {"content": [{"type": "text", "text": text}], "is_error": True}
    assert app.acts == []


async def test_mark_accepts_a_note_of_exactly_sixty() -> None:
    bridge, app = make_bridge(ok())
    bridge.set_target(object(), True, True)
    items = [{"target": "e1", "note": "x" * 60}, {"target": "e2"}]
    await marks_tools(bridge)["viewer_mark"].handler({"marks": items})
    assert [a.action for a in app.acts] == ["mark"]


async def test_mark_without_marks_capability_says_update() -> None:
    bridge, app = make_bridge(ok(), marks_capable=False)
    bridge.set_target(object(), True, True)
    tools = marks_tools(bridge)
    for name, args in (("viewer_mark", {"marks": MARKS}), ("viewer_clear_marks", {})):
        out = await tools[name].handler(args)
        assert out == {"content": [{"type": "text", "text": NEEDS_UPDATE}], "is_error": True}, name
    assert NEEDS_UPDATE == "This Portico can't show marks yet; it needs updating."
    assert app.acts == []
    # the other viewer tools still work on such an app
    await tools["viewer_look"].handler({})
    assert [a.action for a in app.acts] == ["look"]


async def test_marks_order_of_refusals() -> None:
    bridge, _ = make_bridge(ok(), marks_capable=False)
    tool = marks_tools(bridge)["viewer_mark"]
    out = await tool.handler({"marks": MARKS})
    assert out["content"][0]["text"] == NOT_AVAILABLE  # no app
    bridge.set_target(object(), False, True)
    out = await tool.handler({"marks": MARKS})
    assert out["content"][0]["text"] == SETTING_OFF  # setting off
    bridge.set_target(object(), True, True)
    out = await tool.handler({"marks": MARKS})
    assert out["content"][0]["text"] == NEEDS_UPDATE


async def test_clear_marks_sends_clear_marks() -> None:
    bridge, app = make_bridge(ok())
    bridge.set_target(object(), True, True)
    await marks_tools(bridge)["viewer_clear_marks"].handler({})
    assert [(a.action, a.args) for a in app.acts] == [("clear_marks", {})]


async def test_mark_carries_noted_tool_use_id() -> None:
    bridge, app = make_bridge(ok())
    bridge.set_target(object(), True, True)
    tool = marks_tools(bridge)["viewer_mark"]
    bridge.note_mark_use(1, "toolu_1", {"marks": MARKS})
    await tool.handler({"marks": MARKS})
    await tool.handler({"marks": MARKS})
    assert app.acts[0].args["tool_use_id"] == "toolu_1"
    assert "tool_use_id" not in app.acts[1].args


def test_take_mark_use_matches_chat_and_input_once() -> None:
    bridge, _ = make_bridge()
    bridge.note_mark_use(1, "a", {"marks": MARKS})
    assert bridge.take_mark_use(2, {"marks": MARKS}) is None
    assert bridge.take_mark_use(1, {"marks": [{"target": "e9"}]}) is None
    assert bridge.take_mark_use(1, {"marks": MARKS}) == "a"
    assert bridge.take_mark_use(1, {"marks": MARKS}) is None


def test_viewer_tool_names_include_marks() -> None:
    assert "mcp__portico__viewer_mark" in VIEWER_TOOL_NAMES
    assert "mcp__portico__viewer_clear_marks" in VIEWER_TOOL_NAMES


async def test_mark_hook_notes_the_tool_use_id() -> None:
    from portico_gateway.engine import build_mark_hook

    bridge, _ = make_bridge()
    hook = build_mark_hook(bridge, 4)
    out = await hook({"tool_name": "mcp__portico__viewer_mark", "tool_input": {"marks": MARKS}, "tool_use_id": "toolu_9"}, "toolu_9", None)
    assert out == {}
    assert bridge.take_mark_use(4, {"marks": MARKS}) == "toolu_9"


def test_build_options_hooks_viewer_mark(tmp_path: Path) -> None:
    bridge, _ = make_bridge()
    options = build_options(tmp_path, None, ["project"], WithBridge(bridge))
    matchers = [m.matcher for m in options.hooks["PreToolUse"]]
    assert "mcp__portico__viewer_mark" in matchers
