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
from portico_gateway.engine import VIEWER_PROMPT, build_options, deployment_system_prompt
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
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
