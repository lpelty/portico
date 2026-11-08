"""The agent's system prompt is the deployment's (v0.10 decision 7).

``system_prompt = "claude_code"`` (the default) is Claude Code's own prompt,
so the agent behaves as it does in a terminal; ``"none"`` is the SDK's empty
prompt, as before v0.10. ``system_prompt_append`` is a file of the
deployment's added after it, read at each engine start. The viewer line
always comes last.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import Config, ConfigError, load_config
from portico_gateway.engine import (
    OPEN_THREAD_TOOL_NAME,
    SHOW_TOOL_NAME,
    VIEWER_PROMPT,
    append_prompt_line,
    build_show_tool,
    build_options,
    deployment_system_prompt,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from portico_gateway.threads import MAIN_PROMPT
from portico_gateway.viewer import QUEUE_NOTE, ViewerBridge, build_viewer_tools
from tests.conftest import make_config
from tests.test_server import attach
from tests.test_turns import EngineFactory, new_chat

PRESET = {"type": "preset", "preset": "claude_code"}


class PlainCallbacks:
    """An owner that cannot show files: no viewer line."""


class ShowingCallbacks:
    async def on_show(self, paths: list[Path]) -> str | None:
        return None


# --- config ---------------------------------------------------------------------


def test_claude_codes_prompt_is_the_default() -> None:
    cfg = Config()
    assert cfg.system_prompt == "claude_code" and cfg.system_prompt_append is None


def test_the_keys_load(tmp_path: Path) -> None:
    extra = tmp_path / "prompt.md"
    extra.write_text("You are Acme.\n", encoding="utf-8")
    path = tmp_path / "config.toml"
    path.write_text(f'system_prompt = "none"\nsystem_prompt_append = "{extra}"\n', encoding="utf-8")
    cfg = load_config(path)
    assert cfg.system_prompt == "none" and cfg.system_prompt_append == str(extra)


def test_an_unknown_prompt_kind_is_refused(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text('system_prompt = "mine"\n', encoding="utf-8")
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert "system_prompt" in str(e.value)


def test_the_append_file_must_exist_and_be_absolute(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text(f'system_prompt_append = "{tmp_path / "missing.md"}"\n', encoding="utf-8")
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert "system_prompt_append" in str(e.value) and "is not a file" in str(e.value)
    path.write_text('system_prompt_append = "prompt.md"\n', encoding="utf-8")
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert "is relative" in str(e.value)


def test_a_blank_append_is_unset() -> None:
    assert Config(system_prompt_append="  ").system_prompt_append is None


# --- what the engine is given ---------------------------------------------------


def test_claude_code_alone_is_the_bare_preset() -> None:
    assert deployment_system_prompt("claude_code", None) == PRESET


def test_the_append_file_follows_claude_code(tmp_path: Path) -> None:
    extra = tmp_path / "prompt.md"
    extra.write_text("\nYou are Acme.\n\n", encoding="utf-8")
    assert deployment_system_prompt("claude_code", str(extra)) == {**PRESET, "append": "You are Acme."}


def test_none_is_empty_or_the_append_alone(tmp_path: Path) -> None:
    assert deployment_system_prompt("none", None) is None
    extra = tmp_path / "prompt.md"
    extra.write_text("You are Acme.", encoding="utf-8")
    assert deployment_system_prompt("none", str(extra)) == "You are Acme."


def test_an_edit_applies_at_the_next_start(tmp_path: Path) -> None:
    extra = tmp_path / "prompt.md"
    extra.write_text("First.", encoding="utf-8")
    assert deployment_system_prompt("claude_code", str(extra))["append"] == "First."
    extra.write_text("Second.", encoding="utf-8")
    assert deployment_system_prompt("claude_code", str(extra))["append"] == "Second."


def test_an_unreadable_append_is_left_out(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    gone = tmp_path / "gone.md"
    assert deployment_system_prompt("claude_code", str(gone)) == PRESET
    assert "could not be read" in caplog.text


def test_the_viewer_line_says_files_and_web_pages() -> None:
    assert VIEWER_PROMPT == (
        "The person sees files and web pages in Portico's viewer beside this conversation. To show one, "
        "call show_in_viewer with its path or its http(s) address; don't open files with the `open` command "
        "or a browser."
    )


def test_every_viewer_description_ends_with_the_queue_note() -> None:
    async def send(conn: object, act: object) -> None: ...

    tools = [build_show_tool(ShowingCallbacks()), *build_viewer_tools(ViewerBridge(send), 1)]  # type: ignore[arg-type]
    assert len(tools) == 8
    for t in tools:
        assert t.description.endswith(QUEUE_NOTE), t.name


def test_the_viewer_line_comes_last(tmp_path: Path) -> None:
    base = {**PRESET, "append": "You are Acme."}
    options = build_options(tmp_path, None, ["project"], ShowingCallbacks(), system_prompt=base)  # type: ignore[arg-type]
    assert options.system_prompt == {**PRESET, "append": f"You are Acme.\n\n{VIEWER_PROMPT}"}
    bare = build_options(tmp_path, None, ["project"], ShowingCallbacks(), system_prompt=PRESET)  # type: ignore[arg-type]
    assert bare.system_prompt == {**PRESET, "append": VIEWER_PROMPT}


def test_without_a_viewer_the_prompt_is_passed_as_is(tmp_path: Path) -> None:
    options = build_options(tmp_path, None, ["project"], PlainCallbacks(), system_prompt=PRESET)  # type: ignore[arg-type]
    assert options.system_prompt == PRESET
    empty = build_options(tmp_path, None, ["project"], PlainCallbacks())  # type: ignore[arg-type]
    assert empty.system_prompt is None


def test_append_prompt_line() -> None:
    assert append_prompt_line(None, "Line.") == "Line."
    assert append_prompt_line("", "Line.") == "Line."
    assert append_prompt_line("Mine.", "Line.") == "Mine.\n\nLine."
    assert append_prompt_line(PRESET, "Line.") == {**PRESET, "append": "Line."}
    assert append_prompt_line({**PRESET, "append": "Acme."}, "Line.") == {**PRESET, "append": "Acme.\n\nLine."}
    assert append_prompt_line({"type": "custom", "prompt": "Mine."}, "Line.") == {"type": "custom", "prompt": "Mine.\n\nLine."}
    unknown = {"type": "file", "path": "/x"}
    assert append_prompt_line(unknown, "Line.") == unknown


class MainCallbacks(ShowingCallbacks):
    async def on_open_thread(self, brief: str, files: list[str]) -> str:
        return "Proposed."

    def note_thread_use(self, tool_use_id: str, tool_input: dict[str, object]) -> None:
        pass


class ThreadOnlyCallbacks:
    async def on_open_thread(self, brief: str, files: list[str]) -> str:
        return "Proposed."

    def note_thread_use(self, tool_use_id: str, tool_input: dict[str, object]) -> None:
        pass


def test_mains_line_comes_before_the_viewer_line(tmp_path: Path) -> None:
    base = append_prompt_line(PRESET, MAIN_PROMPT)
    options = build_options(tmp_path, None, ["project"], MainCallbacks(), system_prompt=base)  # type: ignore[arg-type]
    assert options.system_prompt == {**PRESET, "append": f"{MAIN_PROMPT}\n\n{VIEWER_PROMPT}"}
    assert options.allowed_tools == [SHOW_TOOL_NAME, OPEN_THREAD_TOOL_NAME]
    matchers = [m.matcher for m in options.hooks["PreToolUse"]]  # type: ignore[index]
    assert OPEN_THREAD_TOOL_NAME in matchers


def test_the_thread_tool_without_a_viewer(tmp_path: Path) -> None:
    options = build_options(tmp_path, None, ["project"], ThreadOnlyCallbacks(), system_prompt=PRESET)  # type: ignore[arg-type]
    assert options.allowed_tools == [OPEN_THREAD_TOOL_NAME]
    assert options.system_prompt == PRESET, "no viewer line without a viewer"
    assert "portico" in options.mcp_servers  # type: ignore[operator]


# --- the gateway sets it on every engine ----------------------------------------


async def start_server(state_dir: StateDir, factory: EngineFactory, **overrides: object) -> GatewayServer:
    cfg: Config = make_config(**overrides)
    registry = ChatRegistry(
        index=state_dir.load_index(), state=state_dir, history_buffer=cfg.history_buffer, default_mode=cfg.permission_mode
    )
    srv = GatewayServer(config=cfg, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    return srv


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = tmp_path / "demo"
    path.mkdir()
    return path


async def new_engine(srv: GatewayServer, factory: EngineFactory, folder: Path) -> object:
    conn = await attach(srv)
    try:
        await new_chat(conn, folder)
        return factory.last.system_prompt
    finally:
        await conn.close()


async def test_a_new_engine_gets_claude_codes_prompt(state_dir: StateDir, factory: EngineFactory, folder: Path) -> None:
    srv = await start_server(state_dir, factory)
    try:
        assert await new_engine(srv, factory, folder) == PRESET
    finally:
        await srv.shutdown()


async def test_none_starts_the_engine_with_no_prompt(state_dir: StateDir, factory: EngineFactory, folder: Path) -> None:
    srv = await start_server(state_dir, factory, system_prompt="none")
    try:
        assert await new_engine(srv, factory, folder) is None
    finally:
        await srv.shutdown()


async def test_the_append_reaches_the_engine(state_dir: StateDir, factory: EngineFactory, folder: Path, tmp_path: Path) -> None:
    extra = tmp_path / "prompt.md"
    extra.write_text("You are Acme.", encoding="utf-8")
    srv = await start_server(state_dir, factory, system_prompt_append=str(extra))
    try:
        assert await new_engine(srv, factory, folder) == {**PRESET, "append": "You are Acme."}
    finally:
        await srv.shutdown()


# --- v0.24 §3: the modes ------------------------------------------------------------

from portico_gateway.engine import (  # noqa: E402
    custom_prompt_text,
    materialize_prompt,
    prompt_fingerprint,
    prompt_header_version,
    session_prompt,
)

INVENTED = "You are a careful helper for a made-up shop.\nKeep answers short."
HEADER = "<!-- captured from Claude Code 9.9.1 · model test-model · 2026-11-07 -->"


def _prompt_file(tmp_path: Path, text: str = INVENTED, name: str = "custom.md") -> Path:
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return path


def test_default_is_claude_code() -> None:
    assert Config(system_prompt="default").system_prompt == "claude_code"


def test_custom_needs_a_file() -> None:
    with pytest.raises(ConfigError) as e:
        load_config_text('system_prompt = "custom"\n')
    assert "system_prompt" in str(e.value) and "system_prompt_file" in str(e.value)


def load_config_text(text: str, folder: Path | None = None) -> Config:
    import tempfile

    with tempfile.TemporaryDirectory() as d:
        path = Path(folder or d) / "config.toml"
        path.write_text(text, encoding="utf-8")
        return load_config(path)


def test_custom_file_must_exist(tmp_path: Path) -> None:
    missing = tmp_path / "missing.md"
    with pytest.raises(ConfigError) as e:
        load_config_text(f'system_prompt = "custom"\nsystem_prompt_file = "{missing}"\n')
    assert str(e.value) == f"system_prompt_file: {missing} is not a file"
    with pytest.raises(ConfigError) as e:
        load_config_text('system_prompt = "custom"\nsystem_prompt_file = "prompt.md"\n')
    assert "is relative" in str(e.value)


def test_file_without_custom_is_ignored(tmp_path: Path) -> None:
    path = _prompt_file(tmp_path)
    cfg = load_config_text(f'system_prompt_file = "{path}"\n')
    assert cfg.system_prompt == "claude_code" and cfg.system_prompt_file == str(path)
    chosen = session_prompt(cfg.system_prompt, None, cfg.system_prompt_file, tmp_path / "out.md")
    assert chosen.prompt == PRESET and chosen.mode == "claude_code" and chosen.source == "claude_code"


def test_custom_is_a_file_prompt_with_append_then_lines(tmp_path: Path) -> None:
    path = _prompt_file(tmp_path)
    extra = _prompt_file(tmp_path, "Mention the shop's hours.", "extra.md")
    out = tmp_path / "running" / "chat-1.md"
    chosen = session_prompt("custom", str(extra), str(path), out)
    assert chosen.mode == "custom" and chosen.source == str(path) and not chosen.fell_back
    prompt = append_prompt_line(chosen.prompt, MAIN_PROMPT)
    options = build_options(tmp_path, None, ["project"], ShowingCallbacks(), system_prompt=prompt)  # type: ignore[arg-type]
    assert options.system_prompt == {"type": "file", "path": str(out)}
    assert out.read_text(encoding="utf-8") == f"{INVENTED}\n\nMention the shop's hours.\n\n{MAIN_PROMPT}\n\n{VIEWER_PROMPT}"
    assert oct(out.stat().st_mode & 0o777) == "0o600"


def test_header_and_markers_are_stripped(tmp_path: Path) -> None:
    raw = f"{HEADER}\nFirst line.\n<!-- machine-specific: names this computer's folders -->\nMemory lives in /x/y.\nLast."
    assert custom_prompt_text(raw) == "First line.\nMemory lives in /x/y.\nLast."
    path = _prompt_file(tmp_path, raw)
    assert prompt_header_version(path) == "9.9.1"
    assert prompt_header_version(_prompt_file(tmp_path, INVENTED, "plain.md")) is None


def test_custom_edit_applies_next_start(tmp_path: Path) -> None:
    path = _prompt_file(tmp_path, "First.")
    out = tmp_path / "out.md"
    assert materialize_prompt(session_prompt("custom", None, str(path), out).prompt)
    assert out.read_text(encoding="utf-8") == "First."
    path.write_text("Second.", encoding="utf-8")
    materialize_prompt(session_prompt("custom", None, str(path), out).prompt)
    assert out.read_text(encoding="utf-8") == "Second."


def test_fingerprint_is_8_hex_and_changes_with_text(tmp_path: Path) -> None:
    import re

    out = tmp_path / "out.md"
    one = prompt_fingerprint(session_prompt("custom", None, str(_prompt_file(tmp_path, "One.")), out).prompt)
    two = prompt_fingerprint(session_prompt("custom", None, str(_prompt_file(tmp_path, "Two.", "b.md")), out).prompt)
    assert re.fullmatch(r"[0-9a-f]{8}", one) and one != two
    assert prompt_fingerprint(PRESET) != prompt_fingerprint({**PRESET, "append": "x"})
    assert prompt_fingerprint(None) == prompt_fingerprint("")


async def test_custom_reaches_the_engine(state_dir: StateDir, factory: EngineFactory, folder: Path, tmp_path: Path) -> None:
    path = _prompt_file(tmp_path)
    srv = await start_server(state_dir, factory, system_prompt="custom", system_prompt_file=str(path))
    try:
        prompt = await new_engine(srv, factory, folder)
        assert isinstance(prompt, dict) and prompt["type"] == "file"
        assert prompt["path"].startswith(str(state_dir.path / "prompts" / "running"))
        assert prompt["text"].startswith(INVENTED)
    finally:
        await srv.shutdown()


async def test_unreadable_custom_falls_back_once(
    state_dir: StateDir, factory: EngineFactory, folder: Path, tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    from portico_gateway.messages import StatusSet

    path = _prompt_file(tmp_path)
    srv = await start_server(state_dir, factory, system_prompt="custom", system_prompt_file=str(path))
    sent: list[object] = []
    real = srv.broadcast

    async def broadcast(msg: object) -> None:
        sent.append(msg)
        if not isinstance(msg, StatusSet):  # kept off the wire so new_chat reads its own replies
            await real(msg)  # type: ignore[arg-type]

    srv.broadcast = broadcast  # type: ignore[method-assign]
    path.unlink()
    try:
        assert await new_engine(srv, factory, folder) == PRESET
        assert await new_engine(srv, factory, folder) == PRESET
        statuses = [m for m in sent if isinstance(m, StatusSet) and "custom system prompt" in m.text]
        assert len(statuses) == 1
        assert "Claude Code's prompt" in statuses[0].text
        assert "could not be read" in caplog.text
    finally:
        await srv.shutdown()


async def test_none_logs_the_legacy_note(state_dir: StateDir, factory: EngineFactory, caplog: pytest.LogCaptureFixture) -> None:
    import logging

    caplog.set_level(logging.INFO)
    srv = await start_server(state_dir, factory, system_prompt="none")
    try:
        assert 'system_prompt = "none" is kept for older configs' in caplog.text
    finally:
        await srv.shutdown()


# --- review fixes -------------------------------------------------------------------


@pytest.mark.parametrize("raw", ["", "   \n\t\n", f"{HEADER}\n", f"{HEADER}\n<!-- machine-specific: x -->\n  \n"])
def test_an_empty_custom_prompt_falls_back(tmp_path: Path, raw: str, caplog: pytest.LogCaptureFixture) -> None:
    path = _prompt_file(tmp_path, raw)
    chosen = session_prompt("custom", None, str(path), tmp_path / "out.md")
    assert chosen.fell_back and chosen.prompt == PRESET and chosen.mode == "claude_code"
    assert "empty" in caplog.text


async def test_an_empty_custom_prompt_says_so_once(state_dir: StateDir, factory: EngineFactory, folder: Path, tmp_path: Path) -> None:
    from portico_gateway.messages import StatusSet

    path = _prompt_file(tmp_path, f"{HEADER}\n")
    srv = await start_server(state_dir, factory, system_prompt="custom", system_prompt_file=str(path))
    sent: list[object] = []
    real = srv.broadcast

    async def broadcast(msg: object) -> None:
        sent.append(msg)
        if not isinstance(msg, StatusSet):
            await real(msg)  # type: ignore[arg-type]

    srv.broadcast = broadcast  # type: ignore[method-assign]
    try:
        assert await new_engine(srv, factory, folder) == PRESET
        assert await new_engine(srv, factory, folder) == PRESET
        assert len([m for m in sent if isinstance(m, StatusSet)]) == 1
    finally:
        await srv.shutdown()


def test_a_billing_header_line_is_stripped() -> None:
    raw = "x-anthropic-billing-header: cc_version=1; cch=abc;\nYou are a helper.\n"
    assert custom_prompt_text(raw) == "You are a helper."


def test_an_unknown_version_header_is_no_recorded_version(tmp_path: Path) -> None:
    raw = "<!-- captured from Claude Code (version unknown) · model m · 2026-11-07 -->\nInvented."
    path = _prompt_file(tmp_path, raw)
    assert prompt_header_version(path) is None
    assert custom_prompt_text(raw) == "Invented."
