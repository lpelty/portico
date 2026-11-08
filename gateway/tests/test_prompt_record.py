"""v0.24 §3: each session records its prompt; ``sessions`` lists it; the version-change warning."""

from __future__ import annotations

import json
import logging
from pathlib import Path

import pytest

from portico_gateway.__main__ import main
from portico_gateway.doctor import check_system_prompt
from portico_gateway.engine import final_system_prompt, prompt_fingerprint
from portico_gateway.state import ChatRecord, PromptRecord, StateDir
from tests.test_server import attach
from tests.test_system_prompt import PRESET, ShowingCallbacks, factory, folder, start_server  # noqa: F401 - fixtures
from tests.test_turns import EngineFactory, new_chat

INVENTED = "You are a careful helper for a made-up shop."


def _custom(tmp_path: Path, header: str | None = None) -> Path:
    path = tmp_path / "custom.md"
    path.write_text((header + "\n" if header else "") + INVENTED, encoding="utf-8")
    return path


def _header(version: str) -> str:
    return f"<!-- captured from Claude Code {version} · model test-model · 2026-11-07 -->"


async def _one_session(srv, factory: EngineFactory, folder: Path) -> int:  # noqa: ANN001
    conn = await attach(srv)
    try:
        return await new_chat(conn, folder)
    finally:
        await conn.close()


async def test_new_session_records_the_prompt(state_dir: StateDir, factory: EngineFactory, folder: Path, tmp_path: Path) -> None:
    path = _custom(tmp_path)
    srv = await start_server(state_dir, factory, system_prompt="custom", system_prompt_file=str(path))
    srv.claude_code_version = lambda: None
    try:
        number = await _one_session(srv, factory, folder)
        record = next(r for r in state_dir.load_index().chats if r.chat == number)
        assert record.prompt is not None
        assert (record.prompt.mode, record.prompt.source) == ("custom", str(path))
        engine = factory.last
        showing = ShowingCallbacks()
        showing.spaces_folder = srv.config.spaces.folder  # type: ignore[attr-defined]
        final = final_system_prompt(engine.system_prompt, showing)
        assert record.prompt.sha == prompt_fingerprint(final)
        assert len(record.prompt.sha) == 8
    finally:
        await srv.shutdown()


async def test_claude_code_session_records_claude_code(state_dir: StateDir, factory: EngineFactory, folder: Path) -> None:
    srv = await start_server(state_dir, factory)
    try:
        number = await _one_session(srv, factory, folder)
        record = srv.registry.get(number).prompt
        assert record is not None and (record.mode, record.source) == ("claude_code", "claude_code")
    finally:
        await srv.shutdown()


async def test_resume_keeps_the_record(state_dir: StateDir, factory: EngineFactory, folder: Path, tmp_path: Path) -> None:
    path = _custom(tmp_path)
    srv = await start_server(state_dir, factory, system_prompt="custom", system_prompt_file=str(path))
    srv.claude_code_version = lambda: None
    try:
        number = await _one_session(srv, factory, folder)
        chat = srv.registry.get(number)
        first = chat.prompt
        assert first is not None
        chat.session_id = "resumed-session"
        path.write_text("A different prompt now.", encoding="utf-8")
        await srv._close_engine(chat)
        await srv._start_engine(chat)
        assert chat.prompt == first, "a resumed engine keeps the prompt it recorded at the session's start"
    finally:
        await srv.shutdown()


def test_older_index_loads() -> None:
    record = ChatRecord.model_validate({"chat": 1, "folder": "/x", "state": "idle", "created": "2026-11-07T00:00:00Z"})
    assert record.prompt is None


async def test_version_warning_logged_once_per_version(
    state_dir: StateDir, factory: EngineFactory, folder: Path, tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.WARNING)
    path = _custom(tmp_path, _header("1.0.0"))
    srv = await start_server(state_dir, factory, system_prompt="custom", system_prompt_file=str(path))
    current = ["1.0.0"]
    srv.claude_code_version = lambda: current[0]
    try:
        await _one_session(srv, factory, folder)
        assert "may have changed" not in caplog.text
        current[0] = "1.1.0"
        await _one_session(srv, factory, folder)
        await _one_session(srv, factory, folder)
        assert caplog.text.count("may have changed since your custom prompt was copied (v1.0.0 → v1.1.0)") == 1
        assert "run capture-prompt to compare" in caplog.text
    finally:
        await srv.shutdown()


def _config(tmp_path: Path, text: str) -> Path:
    path = tmp_path / "config.toml"
    path.write_text(text, encoding="utf-8")
    return path


def test_doctor_warns_on_version_change(tmp_path: Path) -> None:
    prompt = _custom(tmp_path, _header("1.0.0"))
    path = _config(tmp_path, f'system_prompt = "custom"\nsystem_prompt_file = "{prompt}"\n')
    check = check_system_prompt(path, version=lambda: "1.2.0")
    assert check.ok and check.warn
    assert "(v1.0.0 → v1.2.0)" in check.line
    same = check_system_prompt(path, version=lambda: "1.0.0")
    assert same.ok and not same.warn and "1.0.0" in same.line


def test_doctor_says_header_missing(tmp_path: Path) -> None:
    prompt = _custom(tmp_path)
    path = _config(tmp_path, f'system_prompt = "custom"\nsystem_prompt_file = "{prompt}"\n')
    check = check_system_prompt(path, version=lambda: pytest.fail("no header: nothing to compare"))
    assert check.ok and not check.warn and "no capture header" in check.line


def test_doctor_claude_code_needs_no_version(tmp_path: Path) -> None:
    check = check_system_prompt(_config(tmp_path, ""), version=lambda: pytest.fail("not asked"))
    assert check.ok and "Claude Code's own prompt" in check.line


def test_sessions_lists_the_prompt(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    state = StateDir(tmp_path / "home")
    index = state.load_index()
    index.chats = [
        ChatRecord(chat=1, folder="/work/a", state="idle", created="2026-11-06T09:00:00Z", title="Older one", ended="2026-11-06T10:00:00Z"),
        ChatRecord(
            chat=2,
            folder="/work/b",
            state="idle",
            created="2026-11-07T09:00:00Z",
            title="Newer one",
            prompt=PromptRecord(mode="custom", source="/p/custom.md", sha="a1b2c3d4", at="2026-11-07T09:00:00Z"),
        ),
    ]
    state.save_index(index)
    for argv in (["sessions", "--state", str(state.path)], ["sessions", "list", "--state", str(state.path)]):
        assert main(argv) == 0
        out = capsys.readouterr().out.splitlines()
        assert out[0].startswith("#2") and "Newer one" in out[0] and "prompt custom custom.md a1b2c3d4" in out[0]
        assert out[1].startswith("#1") and "ended" in out[1] and "prompt" not in out[1]


def test_sessions_json(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    state = StateDir(tmp_path / "home")
    index = state.load_index()
    index.chats = [
        ChatRecord(
            chat=3, folder="/w", state="idle", created="2026-11-07T09:00:00Z",
            prompt=PromptRecord(mode="claude_code", source="claude_code", sha="00ff00ff", at="2026-11-07T09:00:00Z"),
        )
    ]
    state.save_index(index)
    assert main(["sessions", "list", "--json", "--state", str(state.path)]) == 0
    rows = json.loads(capsys.readouterr().out)
    assert rows[0]["chat"] == 3 and rows[0]["prompt"]["sha"] == "00ff00ff"
