"""Task 4: engine abstraction, SDK adapter, event translation (no model)."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
from claude_agent_sdk import (
    AssistantMessage,
    PermissionResultAllow,
    PermissionResultDeny,
    PermissionUpdate,
    ResultMessage,
    StreamEvent,
    SystemMessage,
    TextBlock,
    ToolPermissionContext,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
)

from portico_gateway import engine as engine_mod
from portico_gateway.engine import (
    Engine,
    EngineCallbacks,
    SDKEngine,
    build_can_use_tool,
    build_options,
    read_history,
    summarize_tool,
    to_permission_result,
    translate,
)
from portico_gateway.messages import TextDelta, ToolFinished, ToolStarted, TurnFinished, parse_server, dump

from .conftest import AskPermission, AskQuestion, Block, FakeEngine, RecordingCallbacks

FOLDER = "/Users/someone/projects/demo"


def _text_delta(text: str) -> StreamEvent:
    return StreamEvent(
        uuid="u1",
        session_id="s1",
        event={"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}},
    )


def _result(is_error: bool = False) -> ResultMessage:
    return ResultMessage(
        subtype="error_during_execution" if is_error else "success",
        duration_ms=10,
        duration_api_ms=8,
        is_error=is_error,
        num_turns=1,
        session_id="s1",
    )


# --- translate ----------------------------------------------------------------


def test_text_delta_translates() -> None:
    out = translate(_text_delta("Hello"), chat=3, turn=2)
    assert len(out) == 1
    delta = out[0]
    assert isinstance(delta, TextDelta)
    assert delta.chat == 3 and delta.turn == 2 and delta.text == "Hello"
    assert delta.seq is None  # the chat stamps seq, not the engine
    assert delta.ts
    assert parse_server(dump(delta)) == delta


def test_other_stream_events_are_ignored() -> None:
    start = StreamEvent(uuid="u", session_id="s", event={"type": "content_block_start", "index": 0})
    thinking = StreamEvent(
        uuid="u",
        session_id="s",
        event={"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "hm"}},
    )
    assert translate(start, chat=1, turn=1) == []
    assert translate(thinking, chat=1, turn=1) == []
    # A subagent's text never reaches the conversation.
    sub = _text_delta("inner")
    sub.parent_tool_use_id = "toolu_parent"
    assert translate(sub, chat=1, turn=1) == []


def test_tool_use_and_result_pair_translates_with_summary() -> None:
    use = AssistantMessage(
        content=[
            TextBlock(text="Reading the notes."),
            ToolUseBlock(id="toolu_01", name="Read", input={"file_path": f"{FOLDER}/notes.md"}),
        ],
        model="m",
    )
    started = translate(use, chat=1, turn=2)
    assert len(started) == 1  # TextBlock is already streamed as deltas
    s = started[0]
    assert isinstance(s, ToolStarted)
    assert s.chat == 1 and s.turn == 2
    assert s.tool_use_id == "toolu_01" and s.tool == "Read"
    assert s.summary == f"{FOLDER}/notes.md"
    assert s.input == {"file_path": f"{FOLDER}/notes.md"}

    result = UserMessage(
        content=[ToolResultBlock(tool_use_id="toolu_01", content="line one\nline two", is_error=None)]
    )
    finished = translate(result, chat=1, turn=2)
    assert len(finished) == 1
    f = finished[0]
    assert isinstance(f, ToolFinished)
    assert f.tool_use_id == "toolu_01" and f.ok is True
    assert f.summary == "line one"

    failed = UserMessage(content=[ToolResultBlock(tool_use_id="toolu_02", content="boom", is_error=True)])
    (f2,) = translate(failed, chat=1, turn=2)
    assert isinstance(f2, ToolFinished) and f2.ok is False and f2.summary == "boom"

    # A plain user prompt is not an event.
    assert translate(UserMessage(content="hi"), chat=1, turn=2) == []


def test_tool_result_list_content_summarises_first_text() -> None:
    msg = UserMessage(
        content=[
            ToolResultBlock(
                tool_use_id="toolu_03",
                content=[{"type": "text", "text": "x" * 200}, {"type": "text", "text": "ignored"}],
            )
        ]
    )
    (f,) = translate(msg, chat=1, turn=1)
    assert isinstance(f, ToolFinished)
    assert len(f.summary) <= 80


def test_result_message_translates_outcome() -> None:
    (done,) = translate(_result(False), chat=1, turn=4)
    assert isinstance(done, TurnFinished)
    assert done.chat == 1 and done.turn == 4 and done.outcome == "done"
    (err,) = translate(_result(True), chat=1, turn=4)
    assert isinstance(err, TurnFinished) and err.outcome == "error"


def test_system_messages_produce_nothing() -> None:
    assert translate(SystemMessage(subtype="init", data={"session_id": "s1"}), chat=1, turn=1) == []


def test_summarize_tool_rules() -> None:
    assert summarize_tool("Write", {"file_path": "/a/b.md", "content": "x"}) == "/a/b.md"
    assert summarize_tool("Edit", {"file_path": "/a/c.py"}) == "/a/c.py"
    assert summarize_tool("Read", {"file_path": "/a/d.txt"}) == "/a/d.txt"
    assert summarize_tool("Bash", {"command": "ls -la"}) == "ls -la"
    assert summarize_tool("Bash", {"command": "x" * 200}) == "x" * 80
    assert summarize_tool("Bash", {"command": "echo hi\nmore"}) == "echo hi"
    assert summarize_tool("WebSearch", {"query": "q"}) == "WebSearch"
    assert summarize_tool("Write", {}) == "Write"


# --- permissions and questions -----------------------------------------------


def _ctx(suggestions: list[PermissionUpdate] | None = None, tool_use_id: str = "toolu_9") -> ToolPermissionContext:
    return ToolPermissionContext(suggestions=suggestions or [], tool_use_id=tool_use_id)


async def test_question_routes_to_on_question_and_returns_updated_input() -> None:
    cb = RecordingCallbacks(question_answers={"Which colour?": "Blue"})
    can_use_tool = build_can_use_tool(cb)
    questions = [
        {
            "question": "Which colour?",
            "header": "Colour",
            "options": [{"label": "Blue", "description": "b"}, {"label": "Red", "description": "r"}],
            "multiSelect": False,
        }
    ]
    result = await can_use_tool("AskUserQuestion", {"questions": questions}, _ctx())
    assert isinstance(result, PermissionResultAllow)
    assert result.updated_input == {"questions": questions, "answers": {"Which colour?": "Blue"}}
    assert result.updated_permissions is None
    assert cb.questions == [questions]
    assert cb.permissions == []  # never treated as a permission


async def test_permission_routes_to_on_permission_with_suggestions_as_dicts() -> None:
    cb = RecordingCallbacks(permission_decision="allow")
    can_use_tool = build_can_use_tool(cb)
    suggestion = PermissionUpdate(type="addRules", behavior="allow", destination="localSettings", rules=[])
    result = await can_use_tool("Bash", {"command": "ls"}, _ctx([suggestion], tool_use_id="toolu_42"))
    assert isinstance(result, PermissionResultAllow)
    assert result.updated_permissions is None and result.updated_input is None
    assert len(cb.permissions) == 1
    tool, inp, suggestions, tool_use_id = cb.permissions[0]
    assert tool == "Bash" and inp == {"command": "ls"} and tool_use_id == "toolu_42"
    assert suggestions == [suggestion.to_dict()]
    assert all(isinstance(s, dict) for s in suggestions)


async def test_always_returns_only_local_settings_suggestions() -> None:
    local = PermissionUpdate(type="addRules", behavior="allow", destination="localSettings", rules=[])
    user = PermissionUpdate(type="addRules", behavior="allow", destination="userSettings", rules=[])
    session = PermissionUpdate(type="addRules", behavior="allow", destination="session", rules=[])

    result = to_permission_result(("allow", "always"), [user, local, session])
    assert isinstance(result, PermissionResultAllow)
    assert result.updated_permissions == [local]

    # Through the closure too.
    cb = RecordingCallbacks(permission_decision=("allow", "always"))
    result2 = await build_can_use_tool(cb)("Edit", {"file_path": "/x"}, _ctx([user, local, session]))
    assert isinstance(result2, PermissionResultAllow) and result2.updated_permissions == [local]

    # No local suggestion: "always" still allows, with nothing to persist.
    result3 = to_permission_result(("allow", "always"), [user])
    assert isinstance(result3, PermissionResultAllow) and result3.updated_permissions == []


async def test_deny_carries_note() -> None:
    plain = to_permission_result("deny", [])
    assert isinstance(plain, PermissionResultDeny)
    assert plain.message == "denied by the user" and plain.interrupt is False

    noted = to_permission_result(("deny", "not that file"), [])
    assert isinstance(noted, PermissionResultDeny) and noted.message == "not that file"

    empty_note = to_permission_result(("deny", ""), [])
    assert empty_note.message == "denied by the user"

    cb = RecordingCallbacks(permission_decision=("deny", "ask first"))
    result = await build_can_use_tool(cb)("Bash", {"command": "rm -rf /"}, _ctx())
    assert isinstance(result, PermissionResultDeny) and result.message == "ask first"


def test_unknown_decision_is_refused() -> None:
    with pytest.raises(ValueError):
        to_permission_result("maybe", [])  # type: ignore[arg-type]


# --- options ------------------------------------------------------------------


def test_options_pin_the_sdk_facts(tmp_path: Path) -> None:
    cb = RecordingCallbacks()
    options = build_options(folder=tmp_path, resume="sess-1", setting_sources=["project"], callbacks=cb)
    assert str(options.cwd) == str(tmp_path)
    assert options.resume == "sess-1"
    assert options.setting_sources == ["project"]
    assert options.include_partial_messages is True
    assert options.verbatim_prompts is False  # slash text must keep dispatching
    assert options.can_use_tool is not None
    assert options.permission_mode is None  # never allow anything by default
    hooks = options.hooks or {}
    matchers = hooks.get("PreToolUse") or []
    assert any(m.matcher == "AskUserQuestion" and m.hooks for m in matchers)


async def test_noop_hook_continues() -> None:
    out = await engine_mod.noop_hook({"hook_event_name": "PreToolUse"}, "toolu_1", {"signal": None})  # type: ignore[arg-type]
    assert out == {"continue_": True}


def test_sdk_engine_satisfies_the_protocol() -> None:
    eng = SDKEngine(chat=7)
    assert isinstance(eng, Engine)
    assert eng.session_id is None and eng.chat == 7 and eng.turn == 0
    assert isinstance(FakeEngine(), Engine)
    assert isinstance(RecordingCallbacks(), EngineCallbacks)


# --- history ------------------------------------------------------------------


def test_read_history_wraps_the_sdk_reader(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    from claude_agent_sdk import SessionMessage

    calls: list[tuple[str, str | None]] = []

    def fake_reader(session_id: str, directory: str | None = None, **_: Any) -> list[SessionMessage]:
        calls.append((session_id, directory))
        return [
            SessionMessage(type="user", uuid="u1", session_id=session_id, message={"role": "user", "content": "hi"}),
            SessionMessage(
                type="assistant",
                uuid="u2",
                session_id=session_id,
                message={"role": "assistant", "content": [{"type": "text", "text": "hello"}]},
            ),
        ]

    monkeypatch.setattr(engine_mod, "get_session_messages", fake_reader)
    out = read_history("sess-1", tmp_path)
    assert calls == [("sess-1", str(tmp_path))]
    assert [m["type"] for m in out] == ["user", "assistant"]
    assert out[1]["message"]["content"][0]["text"] == "hello"
    assert all(isinstance(m, dict) for m in out)


def test_read_history_of_unknown_session_is_empty(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    # Point the SDK at an empty config dir so nothing on this machine leaks in.
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "cfg"))
    assert read_history("00000000-0000-0000-0000-000000000000", tmp_path / "folder") == []


# --- FakeEngine ---------------------------------------------------------------


async def test_fake_engine_scripts_a_turn(tmp_path: Path) -> None:
    fake = FakeEngine(chat=2)
    cb = RecordingCallbacks()
    sid = await fake.start(tmp_path, None, ["project"], cb)
    assert sid == fake.session_id and sid
    fake.script(_text_delta("Hi "), _text_delta("there"), _result())
    await fake.send("hello")
    await fake.wait_idle()
    assert fake.turn == 1
    assert [type(e).__name__ for e in cb.events] == ["TextDelta", "TextDelta", "TurnFinished"]
    assert all(e.chat == 2 and e.turn == 1 for e in cb.events)
    assert fake.calls[:2] == [("start", (tmp_path, None, ["project"])), ("send", "hello")]


async def test_fake_engine_asks_permission_and_question_mid_turn(tmp_path: Path) -> None:
    fake = FakeEngine()
    cb = RecordingCallbacks(permission_decision="deny", question_answers={"Q?": ["A", "B"]})
    await fake.start(tmp_path, None, ["project"], cb)
    fake.script(
        AskPermission("Bash", {"command": "ls"}, suggestions=[{"type": "addRules", "destination": "localSettings"}]),
        AskQuestion([{"question": "Q?", "header": "H", "options": [], "multiSelect": True}]),
        _result(),
    )
    await fake.send("go")
    await fake.wait_idle()
    assert cb.permissions[0][0] == "Bash"
    assert fake.decisions == ["deny"]
    assert fake.answers == [{"Q?": ["A", "B"]}]
    assert [type(e).__name__ for e in cb.events] == ["TurnFinished"]


async def test_fake_engine_blocks_until_interrupted(tmp_path: Path) -> None:
    fake = FakeEngine()
    cb = RecordingCallbacks()
    await fake.start(tmp_path, None, ["project"], cb)
    fake.script(_text_delta("working"), Block())
    await fake.send("go")
    await fake.wait_blocked()
    assert [type(e).__name__ for e in cb.events] == ["TextDelta"]
    await fake.interrupt()
    await fake.wait_idle()
    assert ("interrupt", None) in fake.calls
    assert [type(e).__name__ for e in cb.events] == ["TextDelta", "TurnFinished"]
    await fake.close()
    assert fake.closed
