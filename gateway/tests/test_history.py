"""Task 10: history replay from the engine's transcript.

``history_events`` is a pure translation and is tested on hand-built
session messages. The server tests write a real transcript file where the
SDK's session reader looks for it (``CLAUDE_CONFIG_DIR``), so the replay
path is exercised end to end without a model: a chat restored from the
index, opened by a freshly attached app, replays the transcript and its
stored artifacts, then goes live.
"""

from __future__ import annotations

import json
import uuid
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest
from websockets.asyncio.client import ClientConnection

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import Config
from portico_gateway.engine import history_events, read_history
from portico_gateway.messages import (
    Artifact,
    ArtifactCreated,
    ChatHistory,
    ChatLive,
    ChatOpen,
    ChatState,
    MessageSend,
    TextDelta,
    ToolFinished,
    ToolStarted,
    TurnFinished,
    TurnStarted,
    UserText,
    dump,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import ChatRecord, Index, StateDir
from tests.conftest import fake_result, make_config
from tests.test_server import attach
from tests.test_turns import EngineFactory, new_chat, recv, recv_until, text_delta

TS = "2026-10-27T12:00:00Z"
SESSION = "550e8400-e29b-41d4-a716-446655440000"


# --- session-message builders (the shape ``read_history`` returns) ------------


def user(content: str | list[dict[str, Any]]) -> dict[str, Any]:
    return {"type": "user", "uuid": str(uuid.uuid4()), "session_id": SESSION, "message": {"role": "user", "content": content}}


def assistant(*blocks: dict[str, Any]) -> dict[str, Any]:
    return {
        "type": "assistant",
        "uuid": str(uuid.uuid4()),
        "session_id": SESSION,
        "message": {"role": "assistant", "content": list(blocks)},
    }


def text(t: str) -> dict[str, Any]:
    return {"type": "text", "text": t}


def tool_use(id: str, name: str, input: dict[str, Any]) -> dict[str, Any]:
    return {"type": "tool_use", "id": id, "name": name, "input": input}


def tool_result(id: str, content: str, is_error: bool = False) -> dict[str, Any]:
    return {"type": "tool_result", "tool_use_id": id, "content": content, "is_error": is_error}


def two_turn_session(folder: Path) -> list[dict[str, Any]]:
    """Turn 1: text, a Write, its result, more text. Turn 2: a plain reply."""
    return [
        user("Write the summary."),
        assistant({"type": "thinking", "thinking": "..."}, text("On it.")),
        assistant(tool_use("toolu_1", "Write", {"file_path": str(folder / "summary.md"), "content": "# S"})),
        user([tool_result("toolu_1", "File created successfully")]),
        assistant(text("Done.")),
        user([text("Thanks."), text("<system-reminder>ignored</system-reminder>")]),
        assistant(text("Any time.")),
    ]


# --- history_events (pure) ------------------------------------------------------


def test_transcript_translates_to_turns(tmp_path: Path) -> None:
    events = history_events(two_turn_session(tmp_path), chat=3)
    assert [type(e) for e in events] == [
        TurnStarted, UserText, TextDelta, ToolStarted, ToolFinished, TextDelta, TurnFinished,
        TurnStarted, UserText, TextDelta, TurnFinished,
    ]
    assert all(e.chat == 3 and e.seq is None for e in events)
    assert [e.turn for e in events] == [1] * 7 + [2] * 4

    first, user_text, delta, started, finished, more, done = events[:7]
    assert isinstance(user_text, UserText) and user_text.text == "Write the summary."
    assert isinstance(delta, TextDelta) and delta.text == "On it."
    assert isinstance(started, ToolStarted)
    assert started.tool == "Write" and started.tool_use_id == "toolu_1"
    assert started.summary == str(tmp_path / "summary.md") and started.input["content"] == "# S"
    assert isinstance(finished, ToolFinished) and finished.ok and finished.tool_use_id == "toolu_1"
    assert finished.summary == "File created successfully"
    assert isinstance(more, TextDelta) and more.text == "Done."
    assert isinstance(done, TurnFinished) and done.outcome == "done"

    second_user = events[8]
    assert isinstance(second_user, UserText) and second_user.text == "Thanks."  # the reminder block is dropped


def test_tool_error_and_resultless_turn_translate() -> None:
    events = history_events(
        [
            user("run it"),
            assistant(tool_use("toolu_9", "Bash", {"command": "false\nsecond line"})),
            user([tool_result("toolu_9", "exit 1", is_error=True)]),
        ],
        chat=1,
    )
    assert [type(e) for e in events] == [TurnStarted, UserText, ToolStarted, ToolFinished, TurnFinished]
    assert isinstance(events[2], ToolStarted) and events[2].summary == "false"
    assert isinstance(events[3], ToolFinished) and not events[3].ok
    assert isinstance(events[4], TurnFinished) and events[4].outcome == "done"


def test_empty_and_meta_only_transcripts_translate_to_nothing() -> None:
    assert history_events([], chat=1) == []
    assert history_events([user("<local-command-stdout>x</local-command-stdout>")], chat=1) == []
    assert history_events([user([text("<system-reminder>only</system-reminder>")])], chat=1) == []


def test_history_events_start_turns_from_first_turn() -> None:
    events = history_events([user("a"), assistant(text("b"))], chat=1, first_turn=4)
    assert isinstance(events[0], TurnStarted) and events[0].turn == 4


# --- the transcript on disk ------------------------------------------------------


def _sanitized(folder: Path) -> str:
    import re

    return re.sub(r"[^a-zA-Z0-9]", "-", str(folder.resolve()))


def write_transcript(config_dir: Path, folder: Path, session_id: str, messages: list[dict[str, Any]]) -> Path:
    """A JSONL transcript where the SDK's reader finds it: a parentUuid chain, oldest first."""
    project_dir = config_dir / "projects" / _sanitized(folder)
    project_dir.mkdir(parents=True, exist_ok=True)
    path = project_dir / f"{session_id}.jsonl"
    lines: list[str] = []
    parent: str | None = None
    for m in messages:
        entry = {
            "type": m["type"],
            "uuid": m["uuid"],
            "parentUuid": parent,
            "sessionId": session_id,
            "isSidechain": False,
            "timestamp": TS,
            "cwd": str(folder),
            "message": m["message"],
        }
        lines.append(json.dumps(entry))
        parent = m["uuid"]
    path.write_text("\n".join(lines) + "\n")
    return path


@pytest.fixture
def config_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    home = tmp_path / "engine-home"
    home.mkdir()
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(home))
    return home


def test_read_history_returns_dicts_oldest_first(config_dir: Path, tmp_path: Path) -> None:
    folder = tmp_path / "demo"
    folder.mkdir()
    write_transcript(config_dir, folder, SESSION, [user("hi"), assistant(text("hello"))])
    got = read_history(SESSION, folder)
    assert [m["type"] for m in got] == ["user", "assistant"]
    assert got[0]["message"]["content"] == "hi"
    assert got[1]["message"]["content"][0]["text"] == "hello"


def test_read_history_is_empty_when_nothing_is_there(config_dir: Path, tmp_path: Path) -> None:
    assert read_history(SESSION, tmp_path) == []
    assert read_history("not-a-uuid", tmp_path) == []


# --- the server ---------------------------------------------------------------------


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = tmp_path / "demo"
    path.mkdir()
    return path


def restored_index(state_dir: StateDir, folder: Path, session_id: str | None, artifacts: list[Artifact] | None = None) -> None:
    """What a previous launch left behind: one chat, its session, its artifacts."""
    state_dir.save_index(
        Index(
            chats=[
                ChatRecord(
                    chat=1,
                    folder=str(folder),
                    session_id=session_id,
                    alias=None,
                    state="idle",
                    created=TS,
                    artifacts=list(artifacts or []),
                )
            ],
            next_chat=2,
        )
    )


async def start_server(state_dir: StateDir, factory: EngineFactory) -> GatewayServer:
    config: Config = make_config(setting_sources=["project"])
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    return srv


@pytest.fixture
async def server(state_dir: StateDir, factory: EngineFactory) -> AsyncIterator[GatewayServer]:
    srv = await start_server(state_dir, factory)
    try:
        yield srv
    finally:
        await srv.shutdown()


async def test_open_after_restart_replays_transcript_and_artifacts(
    state_dir: StateDir, factory: EngineFactory, folder: Path, config_dir: Path
) -> None:
    summary = Artifact(
        id="art-1", kind="file", location=str(folder / "summary.md"), media="markdown", title="summary.md", source="tool", open=True
    )
    restored_index(state_dir, folder, SESSION, [summary])
    write_transcript(config_dir, folder, SESSION, two_turn_session(folder))
    srv = await start_server(state_dir, factory)
    conn = await attach(srv)
    try:
        await conn.send(dump(ChatOpen(ts=TS, chat=1, id="req-open")))
        history = await recv(conn)
        assert isinstance(history, ChatHistory)
        assert history.chat == 1 and history.id == "req-open" and not history.truncated
        assert [type(e) for e in history.events] == [
            TurnStarted, UserText, TextDelta, ToolStarted, ToolFinished, TextDelta, TurnFinished,
            TurnStarted, UserText, TextDelta, TurnFinished,
        ]
        assert all(e.chat == 1 for e in history.events)

        # The stored artifacts come back, listed but not opened, then the chat goes live.
        created = await recv(conn)
        assert isinstance(created, ArtifactCreated)
        assert created.chat == 1 and created.artifact.id == "art-1" and created.artifact.open is False
        live = await recv(conn)
        assert isinstance(live, ChatLive) and live.chat == 1 and live.id == "req-open"

        # Opening is a read: no engine was started, nothing was stamped.
        assert factory.engines == []
        assert srv.registry.get(1).seq == 0
        # Live turns continue the transcript's numbering.
        assert srv.registry.get(1).turn == 2

        # The next real turn carries turn 3 and resumes the same session.
        await conn.send(dump(MessageSend(ts=TS, chat=1, text="more")))
        started = await recv(conn)
        assert isinstance(started, TurnStarted) and started.turn == 3
        assert factory.last.calls[0] == ("start", (folder, SESSION, ["project"]))
        await recv_until(conn, TurnFinished)
        idle = await recv(conn)
        assert isinstance(idle, ChatState) and idle.state == "idle"
    finally:
        await conn.close()
        await srv.shutdown()


async def test_open_with_since_in_ring_uses_ring(
    server: GatewayServer, factory: EngineFactory, folder: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    reads: list[tuple[str, Path]] = []

    def spy(session_id: str, folder: Path) -> list[dict[str, Any]]:
        reads.append((session_id, folder))
        return []

    monkeypatch.setattr(server, "history_reader", spy)
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        factory.last.script(text_delta("one"), text_delta("two"), fake_result())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
        await recv_until(conn, TurnFinished)
        idle = await recv(conn)
        assert isinstance(idle, ChatState) and idle.seq is not None
        last_seq = idle.seq

        await conn.send(dump(ChatOpen(ts=TS, chat=number, since=2)))
        history = await recv(conn)
        assert isinstance(history, ChatHistory) and not history.truncated
        assert [m.seq for m in history.events] == list(range(3, last_seq + 1))
        assert isinstance(await recv(conn), ChatLive)

        # A chat created this launch, opened from the beginning, is also served by the ring.
        await conn.send(dump(ChatOpen(ts=TS, chat=number)))
        history = await recv(conn)
        assert isinstance(history, ChatHistory) and [m.seq for m in history.events] == list(range(1, last_seq + 1))
        assert isinstance(await recv(conn), ChatLive)
        assert reads == []
    finally:
        await conn.close()


async def test_open_with_since_off_the_ring_replays_transcript(
    state_dir: StateDir, factory: EngineFactory, folder: Path, config_dir: Path
) -> None:
    config = make_config(history_buffer=3)
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=3)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    conn = await attach(srv)
    try:
        number = await new_chat(conn, folder)
        factory.last._session_id = SESSION  # the engine names a real session id
        factory.last.session_id = SESSION
        srv.registry.get(number).session_id = SESSION
        write_transcript(config_dir, folder, SESSION, [user("go"), assistant(text("abc"))])
        factory.last.script(text_delta("a"), text_delta("b"), text_delta("c"), fake_result())
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
        await recv_until(conn, TurnFinished)
        await recv(conn)  # idle

        await conn.send(dump(ChatOpen(ts=TS, chat=number, since=1)))
        history = await recv(conn)
        assert isinstance(history, ChatHistory) and not history.truncated
        assert [type(e) for e in history.events] == [TurnStarted, UserText, TextDelta, TurnFinished]
        assert isinstance(await recv(conn), ChatLive)
    finally:
        await conn.close()
        await srv.shutdown()


async def test_missing_transcript_gives_empty_history_not_error(
    state_dir: StateDir, factory: EngineFactory, folder: Path, config_dir: Path
) -> None:
    restored_index(state_dir, folder, SESSION)  # a session id, but no transcript on disk
    srv = await start_server(state_dir, factory)
    conn = await attach(srv)
    try:
        await conn.send(dump(ChatOpen(ts=TS, chat=1, id="req-open")))
        history = await recv(conn)
        assert isinstance(history, ChatHistory)
        assert history.events == [] and not history.truncated and history.id == "req-open"
        assert isinstance(await recv(conn), ChatLive)
    finally:
        await conn.close()
        await srv.shutdown()


async def test_restored_chat_without_session_opens_empty(
    state_dir: StateDir, factory: EngineFactory, folder: Path, config_dir: Path
) -> None:
    restored_index(state_dir, folder, None)
    srv = await start_server(state_dir, factory)
    conn = await attach(srv)
    try:
        await conn.send(dump(ChatOpen(ts=TS, chat=1)))
        history = await recv(conn)
        assert isinstance(history, ChatHistory) and history.events == [] and not history.truncated
        assert isinstance(await recv(conn), ChatLive)
    finally:
        await conn.close()
        await srv.shutdown()
