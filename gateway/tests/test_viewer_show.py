"""v0.10 decision 6: the agent shows its work in the viewer.

``show_in_viewer`` (an in-process tool), a caught ``open <file>`` (a
``PreToolUse`` hook on ``Bash``), the line appended to the system prompt,
and the server side both reach (``show_files``). Model-free: the tool and
the hook are called directly, the server runs with the scripted
``FakeEngine``.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import Config
from portico_gateway.engine import (
    OPEN_SHOWN_REASON,
    READ_ONLY_TOOLS,
    SHOW_SERVER,
    SHOW_TOOL,
    SHOW_TOOL_NAME,
    SHOWN_TEXT,
    VIEWER_PROMPT,
    build_open_hook,
    build_options,
    build_show_tool,
    open_command_paths,
    summarize_tool,
    with_viewer_prompt,
)
from portico_gateway.messages import ArtifactCreated, Root
from portico_gateway.server import ChatCallbacks, GatewayServer
from portico_gateway.state import StateDir
from tests.conftest import RecordingCallbacks, Show, make_config
from tests.test_artifacts import run_turn, touch, write_tool
from tests.test_server import attach
from tests.test_turns import EngineFactory, new_chat, recv, text_delta, tool_result

MODES = ("default", "acceptEdits", "plan", "auto")


class PlainCallbacks:
    """An owner from before v0.10: no ``on_show``."""

    async def on_event(self, event: Any) -> None: ...

    async def on_permission(self, tool: str, input: dict, suggestions: list, tool_use_id: str) -> Any:
        return "allow"

    async def on_question(self, questions: list) -> dict:
        return {}

    async def on_compacted(self, trigger: str) -> None: ...


def bash(command: str) -> dict[str, Any]:
    return {"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": command}, "tool_use_id": "t1"}


# --- the options -----------------------------------------------------------------


@pytest.mark.parametrize("mode", MODES)
def test_every_mode_gets_the_tool_allowed_the_hook_and_the_line(tmp_path: Path, mode: str) -> None:
    options = build_options(tmp_path, None, ["project"], RecordingCallbacks(), permission_mode=mode)  # type: ignore[arg-type]
    server = (options.mcp_servers or {})[SHOW_SERVER]  # type: ignore[index]
    assert server["type"] == "sdk" and server["name"] == SHOW_SERVER
    # Allowed outright: no permission card, whatever the mode.
    assert options.allowed_tools == [SHOW_TOOL_NAME]
    assert SHOW_TOOL_NAME == f"mcp__portico__{SHOW_TOOL}"
    assert SHOW_TOOL_NAME in READ_ONLY_TOOLS  # its row carries no permission outcome
    # Hooks run before the permission decision, so auto mode catches `open` too.
    matchers = (options.hooks or {})["PreToolUse"]
    assert [m.matcher for m in matchers] == ["AskUserQuestion", "Bash"]
    # Appended to the SDK's default (an empty prompt), not replacing anything.
    assert options.system_prompt == VIEWER_PROMPT


def test_an_owner_without_on_show_gets_none_of_it(tmp_path: Path) -> None:
    options = build_options(tmp_path, None, ["project"], PlainCallbacks())  # type: ignore[arg-type]
    assert options.mcp_servers == {} and options.allowed_tools == [] and options.system_prompt is None
    assert [m.matcher for m in (options.hooks or {})["PreToolUse"]] == ["AskUserQuestion"]


def test_the_line_is_appended_never_replacing() -> None:
    assert with_viewer_prompt(None) == VIEWER_PROMPT
    assert with_viewer_prompt("") == VIEWER_PROMPT
    assert with_viewer_prompt("Be brief.") == f"Be brief.\n\n{VIEWER_PROMPT}"
    preset = {"type": "preset", "preset": "claude_code"}
    assert with_viewer_prompt(preset) == {**preset, "append": VIEWER_PROMPT}
    assert with_viewer_prompt({**preset, "append": "House rules."}) == {**preset, "append": f"House rules.\n\n{VIEWER_PROMPT}"}
    assert with_viewer_prompt({"type": "custom", "prompt": "Mine."}) == {"type": "custom", "prompt": f"Mine.\n\n{VIEWER_PROMPT}"}
    as_file = {"type": "file", "path": "/x/prompt.md"}
    assert with_viewer_prompt(as_file) == as_file
    assert "show_in_viewer" in VIEWER_PROMPT and "`open`" in VIEWER_PROMPT


# --- show_in_viewer -------------------------------------------------------------------


async def test_the_tool_shows_and_says_so() -> None:
    cb = RecordingCallbacks()
    tool = build_show_tool(cb)
    assert tool.name == SHOW_TOOL and tool.input_schema == {"path": str}
    out = await tool.handler({"path": " site/login.html "})
    assert out == {"content": [{"type": "text", "text": SHOWN_TEXT}]}
    assert cb.shown == [["site/login.html"]]


def test_the_tool_row_names_the_file() -> None:
    assert summarize_tool(SHOW_TOOL_NAME, {"path": "site/login.html"}) == "site/login.html"


async def test_the_tool_passes_a_refusal_back_as_an_error() -> None:
    cb = RecordingCallbacks()
    cb.show_refusal = "Not shown: /etc/hosts is outside this session's folders."
    out = await build_show_tool(cb).handler({"path": "/etc/hosts"})
    assert out["is_error"] is True and out["content"][0]["text"] == cb.show_refusal
    blank = await build_show_tool(cb).handler({"path": "  "})
    assert blank["is_error"] is True and cb.shown == [["/etc/hosts"]]


# --- catching `open` ----------------------------------------------------------------------


@pytest.mark.parametrize(
    ("command", "paths"),
    [
        ("open login.html", ["login.html"]),
        ("open site/a.html notes.md", ["site/a.html", "notes.md"]),
        ("/usr/bin/open /tmp/demo/a.png", ["/tmp/demo/a.png"]),
        ("  open   login.html  ", ["login.html"]),
        ("open", None),
        ("open -a Safari login.html", None),
        ("open -R login.html", None),
        ("open http://localhost:3000/", None),
        ("open https://example.com", None),
        ("open file:///tmp/a.html", None),
        ("open *.html", None),
        ("open login.html && echo done", None),
        ("open login.html; ls", None),
        ("open login.html | cat", None),
        ("open $PWD/login.html", None),
        ("open ~/login.html", None),
        ("open 'my page.html'", None),
        ("open login.html\nrm x", None),
        ("xdg-open login.html", None),
        ("cat login.html", None),
        (None, None),
    ],
)
def test_only_a_plain_open_of_paths_is_caught(command: Any, paths: list[str] | None) -> None:
    assert open_command_paths(command) == paths


async def test_a_caught_open_is_denied_with_the_reason_after_showing() -> None:
    cb = RecordingCallbacks()
    out = await build_open_hook(cb)(bash("open login.html"), "t1", {"signal": None})
    assert out == {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": OPEN_SHOWN_REASON,
        }
    }
    assert OPEN_SHOWN_REASON == "Shown in Portico's viewer instead of opening it."
    assert cb.shown == [["login.html"]]


async def test_an_open_the_owner_refuses_runs_as_before() -> None:
    cb = RecordingCallbacks()
    cb.show_refusal = "Not shown: outside."
    hook = build_open_hook(cb)
    assert await hook(bash("open /etc/hosts.html"), "t1", {"signal": None}) == {"continue_": True}
    # Not an `open` at all: the owner is never asked.
    assert await hook(bash("open -a Safari x.html"), "t1", {"signal": None}) == {"continue_": True}
    assert await hook(bash("ls"), "t1", {"signal": None}) == {"continue_": True}
    assert await hook({"tool_name": "Bash"}, "t1", {"signal": None}) == {"continue_": True}
    assert cb.shown == [["/etc/hosts.html"]]


async def test_a_failing_owner_never_blocks_the_command() -> None:
    class Failing(RecordingCallbacks):
        async def on_show(self, paths: list[str]) -> str | None:
            raise RuntimeError("app gone")

    assert await build_open_hook(Failing())(bash("open a.html"), "t1", {"signal": None}) == {"continue_": True}


# --- the server: show_files ------------------------------------------------------------


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
def shared(tmp_path: Path) -> Path:
    path = tmp_path / "shared"
    path.mkdir()
    return path


@pytest.fixture
async def server(state_dir: StateDir, factory: EngineFactory, shared: Path) -> AsyncIterator[GatewayServer]:
    config: Config = make_config(setting_sources=["project"], roots=[Root(name="shared", path=str(shared))])
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    try:
        yield srv
    finally:
        await srv.shutdown()


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = tmp_path / "demo"
    path.mkdir()
    return path


async def test_show_files_reports_open_artifacts_from_the_folder_and_the_roots(
    server: GatewayServer, folder: Path, shared: Path, state_dir: StateDir
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        chat = server.registry.get(number)
        page = touch(folder / "site" / "login.html")
        chart = touch(shared / "chart.png")

        assert await server.show_files(chat, ["site/login.html"]) is None
        event = await recv(conn)
        assert isinstance(event, ArtifactCreated) and event.seq is not None
        art = event.artifact
        assert art.location == str(page.resolve()) and art.media == "html" and art.title == "login.html"
        assert art.source == "tool" and art.open is True and art.id.startswith("art-")

        assert await server.show_files(chat, [str(chart)]) is None
        assert (await recv(conn)).artifact.location == str(chart.resolve())  # type: ignore[union-attr]

        assert [a.location for a in chat.artifacts] == [str(page.resolve()), str(chart.resolve())]
        assert any(isinstance(m, ArtifactCreated) for m in chat.ring)
        assert [a.id for a in state_dir.load_index().chats[0].artifacts] == [a.id for a in chat.artifacts]
    finally:
        await conn.close()


async def test_show_files_refuses_clearly_and_shows_nothing(
    server: GatewayServer, folder: Path, tmp_path: Path
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        chat = server.registry.get(number)
        outside = touch(tmp_path / "elsewhere" / "x.html")
        inside = touch(folder / "a.html")
        code = touch(folder / "main.py")
        (folder / "dir.html").mkdir()
        escape = folder / "link.html"
        escape.symlink_to(outside)

        assert await server.show_files(chat, ["missing.html"]) == "Not shown: there is no file at missing.html."
        assert await server.show_files(chat, ["dir.html"]) == "Not shown: there is no file at dir.html."
        assert await server.show_files(chat, [str(outside)]) == f"Not shown: {outside} is outside this session's folders."
        assert await server.show_files(chat, ["../elsewhere/x.html"]) == "Not shown: ../elsewhere/x.html is outside this session's folders."
        assert await server.show_files(chat, ["link.html"]) == "Not shown: link.html is outside this session's folders."
        assert (await server.show_files(chat, ["main.py"]) or "").startswith("Not shown: the viewer shows pages")
        # All or none: one refused path shows nothing of the rest.
        assert await server.show_files(chat, [str(inside), "missing.html"]) is not None
        with pytest.raises(TimeoutError):
            await recv(conn, timeout=0.2)
        assert chat.artifacts == []
    finally:
        await conn.close()


async def test_a_caught_open_through_the_server_shows_the_file(server: GatewayServer, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        chat = server.registry.get(number)
        page = touch(folder / "login.html")
        hook = build_open_hook(ChatCallbacks(server, chat))

        out = await hook(bash("open login.html"), "t1", {"signal": None})
        assert out["hookSpecificOutput"]["permissionDecision"] == "deny"
        event = await recv(conn)
        assert isinstance(event, ArtifactCreated) and event.artifact.location == str(page.resolve()) and event.artifact.open

        # Outside the folders, or a URL: runs as before, nothing shown.
        assert await hook(bash("open /etc/hosts"), "t1", {"signal": None}) == {"continue_": True}
        assert await hook(bash("open http://localhost:3000"), "t1", {"signal": None}) == {"continue_": True}
        with pytest.raises(TimeoutError):
            await recv(conn, timeout=0.2)
    finally:
        await conn.close()


async def test_a_file_shown_mid_turn_is_not_reported_again_at_the_end(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        page = touch(folder / "login.html")
        frames = await run_turn(
            conn,
            number,
            engine,
            write_tool(page, "toolu_1"),
            tool_result("toolu_1", "ok"),
            Show(["login.html"]),
            text_delta("Shown login.html."),
        )
        assert engine.show_answers == [None]
        created = [m.artifact for m in frames if isinstance(m, ArtifactCreated)]
        assert [(a.location, a.open) for a in created] == [(str(page.resolve()), True)], "once, when shown"
        assert len(server.registry.get(number).artifacts) == 1
    finally:
        await conn.close()
