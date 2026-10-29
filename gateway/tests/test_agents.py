"""v0.10: subagents and workflows as ``agent.*`` / ``workflow.*`` frames (no model).

Driven by the SDK messages a live probe recorded (``fixtures/sdk_agents_probe.json``:
a three-subagent fan-out and a two-phase background workflow, rebuilt with
the SDK's own parser) and by small synthetic sequences for the endings the
probe did not show.
"""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest
from claude_agent_sdk import (
    AssistantMessage,
    Message,
    TaskNotificationMessage,
    TaskProgressMessage,
    TaskStartedMessage,
    TaskUpdatedMessage,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
)
from claude_agent_sdk._internal.message_parser import parse_message
from websockets.asyncio.client import ClientConnection, connect

from portico_gateway import __version__
from portico_gateway.agents import AgentTracker, step_text
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import Config
from portico_gateway.engine import translate
from portico_gateway.messages import (
    AGENTS_CAPABILITY,
    AgentFinished,
    AgentProgress,
    AgentStarted,
    ChatHistory,
    ChatList,
    ChatLive,
    ChatOpen,
    HelloClient,
    HelloServer,
    MessageSend,
    ServerMessage,
    ServicesStatus,
    ToolFinished,
    ToolStarted,
    TurnFinished,
    WorkflowFinished,
    WorkflowPhase,
    WorkflowStarted,
    dump,
    parse_client,
    parse_server,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir

from .conftest import fake_result, make_config
from .test_server import ws_url
from .test_turns import EngineFactory, new_chat, recv, recv_until

TS = "2026-10-27T12:00:00Z"
FIXTURE = Path(__file__).parent / "fixtures" / "sdk_agents_probe.json"


def recorded(name: str) -> list[Message]:
    raw = json.loads(FIXTURE.read_text(encoding="utf-8"))[name]
    return [m for m in (parse_message(r) for r in raw) if m is not None]


class Clock:
    def __init__(self) -> None:
        self.now = 100.0

    def __call__(self) -> float:
        return self.now


def run(messages: list[Message], tracker: AgentTracker | None = None, turn: int = 1) -> list[ServerMessage]:
    tracker = tracker if tracker is not None else AgentTracker()
    out: list[ServerMessage] = []
    for msg in messages:
        out.extend(translate(msg, chat=1, turn=turn, agents=tracker))
    return out


def of(events: list[ServerMessage], kind: type) -> list[Any]:
    return [e for e in events if isinstance(e, kind)]


# --- synthetic SDK messages -------------------------------------------------------


def started(task_id: str, tool_use_id: str, task_type: str = "local_agent", **data: Any) -> TaskStartedMessage:
    raw = {"type": "system", "subtype": "task_started", "task_id": task_id, "tool_use_id": tool_use_id,
           "description": f"task {task_id}", "task_type": task_type, "uuid": "u", "session_id": "s", **data}
    return TaskStartedMessage(subtype="task_started", data=raw, task_id=task_id, description=raw["description"],
                              uuid="u", session_id="s", tool_use_id=tool_use_id, task_type=task_type)


def progress(task_id: str, tool_uses: int = 0, duration_ms: int = 0, last_tool: str | None = None,
             description: str = "", **data: Any) -> TaskProgressMessage:
    usage = {"total_tokens": 0, "tool_uses": tool_uses, "duration_ms": duration_ms}
    raw = {"type": "system", "subtype": "task_progress", "task_id": task_id, "usage": usage,
           "description": description, **data}
    return TaskProgressMessage(subtype="task_progress", data=raw, task_id=task_id, description=description,
                               usage=usage, uuid="u", session_id="s", last_tool_name=last_tool)  # type: ignore[arg-type]


def notified(task_id: str, status: str, summary: str = "") -> TaskNotificationMessage:
    return TaskNotificationMessage(subtype="task_notification", data={}, task_id=task_id, status=status,  # type: ignore[arg-type]
                                   output_file="", summary=summary, uuid="u", session_id="s")


def updated(task_id: str, status: str) -> TaskUpdatedMessage:
    return TaskUpdatedMessage(subtype="task_updated", data={}, task_id=task_id, patch={"status": status},
                              status=status)  # type: ignore[arg-type]


def sub_call(parent: str, tool_use_id: str, tool: str, input: dict[str, Any]) -> AssistantMessage:
    return AssistantMessage(content=[ToolUseBlock(id=tool_use_id, name=tool, input=input)], model="m",
                            parent_tool_use_id=parent)


def sub_result(parent: str, tool_use_id: str, content: str = "ok", is_error: bool = False) -> UserMessage:
    return UserMessage(content=[ToolResultBlock(tool_use_id=tool_use_id, content=content, is_error=is_error)],
                       parent_tool_use_id=parent)


# --- the recorded fan-out -----------------------------------------------------------


def test_three_parallel_subagents_start_progress_and_finish() -> None:
    events = run(recorded("agents"))
    starts = of(events, AgentStarted)
    assert [s.description for s in starts] == ["Read alpha.md number", "Read beta.md number", "Read gamma.md number"]
    assert all(s.kind == "general-purpose" and s.turn == 1 and s.background is None for s in starts)
    assert all(s.workflow_id is None and s.phase is None for s in starts)
    ids = [s.id for s in starts]
    # Each agent's id names the call that started it, a main-conversation Agent row.
    agent_rows = {t.tool_use_id: t for t in of(events, ToolStarted) if t.agent_id is None and t.tool == "Agent"}
    assert {s.tool_use_id for s in starts} == set(agent_rows)

    finishes = of(events, AgentFinished)
    assert sorted(f.id for f in finishes) == sorted(ids)
    assert all(f.outcome == "done" for f in finishes)
    assert {f.summary for f in finishes} == {"2779", "18333", "10281"}

    for agent in ids:
        own = [e for e in events if getattr(e, "id", None) == agent or getattr(e, "agent_id", None) == agent]
        # started first, finished last, never anything after it
        assert isinstance(own[0], AgentStarted) and isinstance(own[-1], AgentFinished)
        steps = of(own, AgentProgress)
        assert steps and steps[-1].steps == 1  # one Read each: counted once, not once per report
        assert steps[-1].step and steps[-1].step.startswith("Read ") and steps[-1].step.endswith(".md")
        assert all(p.elapsed >= 0 for p in steps)
        rows = [e for e in own if isinstance(e, (ToolStarted, ToolFinished))]
        assert [type(r) for r in rows] == [ToolStarted, ToolFinished]
        assert rows[0].tool == "Read" and rows[1].ok


def test_without_a_tracker_subagents_stay_out_as_before() -> None:
    events: list[ServerMessage] = []
    for msg in recorded("agents"):
        events.extend(translate(msg, chat=1, turn=1))
    assert not [e for e in events if e.type.startswith(("agent.", "workflow."))]
    assert not [e for e in events if getattr(e, "agent_id", None)]


def test_subagent_step_and_elapsed_from_its_own_calls() -> None:
    clock = Clock()
    tracker = AgentTracker(clock=clock)
    events = run([started("t1", "call-1", subagent_type="Explore")], tracker)
    assert of(events, AgentStarted)[0].kind == "Explore"
    events = run([progress("t1", description="Reading notes", last_tool="Read")], tracker)
    assert of(events, AgentProgress)[-1].step == "Reading notes"  # the engine's words until its own call is seen
    clock.now += 4.25
    events = run([sub_call("call-1", "c1", "Bash", {"command": "grep -rn quote transcripts/\nmore"})], tracker)
    row, step = events
    assert isinstance(row, ToolStarted) and row.agent_id == "t1" and row.turn == 1
    assert isinstance(step, AgentProgress) and step.step == "Bash grep -rn quote transcripts/" and step.steps == 1
    assert step.elapsed == 4.2
    events = run([sub_call("call-1", "c2", "Read", {"file_path": "/x/y/transcripts/p11.md"})], tracker)
    assert of(events, AgentProgress)[0].step == "Read transcripts/p11.md"
    assert of(events, AgentProgress)[0].steps == 2
    finished = run([sub_result("call-1", "c2", "boom", is_error=True)], tracker)
    assert isinstance(finished[0], ToolFinished) and finished[0].agent_id == "t1" and not finished[0].ok


def test_step_text() -> None:
    assert step_text("Read", {"file_path": "/a/b/c/d.md"}) == "Read c/d.md"
    assert step_text("Glob", {"pattern": "**/*.py"}) == "Glob **/*.py"
    assert step_text("Mystery", {"x": 1}) == "Mystery"
    assert len(step_text("Bash", {"command": "x" * 200})) <= len("Bash ") + 48


# --- endings --------------------------------------------------------------------------


def test_failed_and_stopped_notifications() -> None:
    tracker = AgentTracker()
    run([started("a", "c-a"), started("b", "c-b")], tracker)
    events = run([notified("a", "failed", "could not read\nsecond line"), notified("b", "stopped")], tracker)
    by_id = {f.id: f for f in of(events, AgentFinished)}
    assert by_id["a"].outcome == "failed" and by_id["a"].summary == "could not read"
    assert by_id["b"].outcome == "stopped" and by_id["b"].summary is None


def test_background_agent_ends_on_a_terminal_task_updated_alone() -> None:
    tracker = AgentTracker()
    events = run([started("bg", "c-bg", is_backgrounded=True)], tracker)
    assert of(events, AgentStarted)[0].background is True
    assert run([updated("bg", "running")], tracker) == []
    events = run([updated("bg", "killed")], tracker)
    assert [(f.id, f.outcome) for f in of(events, AgentFinished)] == [("bg", "stopped")]
    # The notification that sometimes follows changes nothing.
    assert run([notified("bg", "stopped", "late")], tracker) == []
    # A background agent outlives its turn's result.
    tracker2 = AgentTracker()
    run([started("bg2", "c", is_backgrounded=True)], tracker2)
    assert not of(run([fake_result()], tracker2), AgentFinished)


def test_foreground_task_updated_waits_for_the_notifications_summary() -> None:
    tracker = AgentTracker()
    run([started("fg", "c-fg")], tracker)
    assert run([updated("fg", "completed")], tracker) == []
    events = run([notified("fg", "completed", "6 findings")], tracker)
    assert [(f.outcome, f.summary) for f in of(events, AgentFinished)] == [("done", "6 findings")]


def test_turn_result_ends_foreground_agents_still_open() -> None:
    tracker = AgentTracker()
    run([started("x", "c-x"), started("y", "c-y")], tracker)
    run([updated("y", "failed")], tracker)  # its notification never came
    events = run([fake_result(is_error=True)], tracker)
    assert [type(e) for e in events] == [AgentFinished, AgentFinished, TurnFinished]
    assert {(f.id, f.outcome) for f in of(events, AgentFinished)} == {("x", "stopped"), ("y", "failed")}


def test_shell_and_monitor_tasks_are_not_agents() -> None:
    tracker = AgentTracker()
    events = run(
        [
            started("sh", "c-sh", task_type="local_bash"),
            started("mon", "c-mon", task_type="monitor"),
            progress("sh", tool_uses=1),
            notified("sh", "completed", "done"),
            updated("mon", "killed"),
        ],
        tracker,
    )
    assert events == []


def test_unknown_parent_stays_out() -> None:
    assert run([sub_call("nobody", "c1", "Read", {"file_path": "/a"}), sub_result("nobody", "c1")]) == []


# --- workflows ----------------------------------------------------------------------------


def test_recorded_workflow_maps_phases_agents_and_its_end() -> None:
    events = run(recorded("workflow"))
    flows = of(events, WorkflowStarted)
    # Named when it starts; sent again once the engine reports its phases.
    assert [(w.name, w.phases) for w in flows] == [("read-and-sum", []), ("read-and-sum", ["read", "sum"])]
    wid = flows[0].id
    starts = of(events, AgentStarted)
    assert [(a.description, a.phase) for a in starts] == [("read:alpha", 0), ("read:beta", 0), ("sum", 1)]
    assert all(a.kind == "workflow" and a.workflow_id == wid and a.background for a in starts)
    call = next(t.tool_use_id for t in of(events, ToolStarted) if t.tool == "Workflow")
    assert {a.tool_use_id for a in starts} == {call}
    assert [(p.index, p.state) for p in of(events, WorkflowPhase)] == [(0, "running"), (0, "done"), (1, "running"), (1, "done")]
    assert {(f.id, f.outcome, f.summary) for f in of(events, AgentFinished)} == {
        (f"{wid}.1", "done", "2779"), (f"{wid}.2", "done", "18333"), (f"{wid}.3", "done", "21112"),
    }
    ended = of(events, WorkflowFinished)
    assert [(w.id, w.outcome) for w in ended] == [(wid, "done")]
    # The workflow runs in the background: its turn's result arrives first and ends none of it.
    first_result = next(i for i, e in enumerate(events) if isinstance(e, TurnFinished))
    assert events.index(ended[0]) > first_result
    assert not [f for f in of(events, AgentFinished) if events.index(f) < first_result]


def test_workflow_without_phases_has_agents_without_a_phase() -> None:
    tracker = AgentTracker()
    events = run([started("w", "c-w", task_type="local_workflow", workflow_name="sweep")], tracker)
    assert [(w.name, w.phases) for w in of(events, WorkflowStarted)] == [("sweep", [])]
    report = [{"type": "workflow_agent", "index": 1, "label": "scan", "state": "start"}]
    events = run([progress("w", workflow_progress=report)], tracker)
    assert [(a.id, a.phase, a.workflow_id) for a in of(events, AgentStarted)] == [("w.1", None, "w")]
    assert not of(events, WorkflowPhase) and not of(events, WorkflowStarted)
    report = [{"type": "workflow_agent", "index": 1, "label": "scan", "state": "failed", "toolCalls": 3}]
    events = run([progress("w", workflow_progress=report)], tracker)
    assert of(events, AgentProgress)[0].steps == 3
    assert [(f.id, f.outcome) for f in of(events, AgentFinished)] == [("w.1", "failed")]
    events = run([updated("w", "failed")], tracker)
    assert [(w.id, w.outcome) for w in of(events, WorkflowFinished)] == [("w", "failed")]
    assert run([notified("w", "failed", "x")], tracker) == []


def test_workflow_stopped_ends_its_open_agents_and_marks_a_failed_phase() -> None:
    tracker = AgentTracker()
    run([started("w", "c-w", task_type="local_workflow", workflow_name="audit")], tracker)
    report = [
        {"type": "workflow_phase", "index": 1, "title": "find"},
        {"type": "workflow_phase", "index": 2, "title": "verify"},
        {"type": "workflow_agent", "index": 1, "label": "f1", "phaseIndex": 1, "state": "failed"},
        {"type": "workflow_agent", "index": 2, "label": "f2", "phaseIndex": 1, "state": "progress",
         "lastToolName": "Grep", "lastToolSummary": "quote"},
    ]
    events = run([progress("w", workflow_progress=report)], tracker)
    assert of(events, AgentProgress)[-1].step == "Grep quote"
    assert [(p.index, p.state) for p in of(events, WorkflowPhase)] == [(0, "running")]
    events = run([notified("w", "stopped", "Workflow stopped")], tracker)
    assert [(f.id, f.outcome) for f in of(events, AgentFinished)] == [("w.2", "stopped")]
    assert [(p.index, p.state) for p in of(events, WorkflowPhase)] == [(0, "failed")]
    assert [(w.outcome, w.summary) for w in of(events, WorkflowFinished)] == [("stopped", "Workflow stopped")]


# --- the protocol -------------------------------------------------------------------------


def test_new_frames_round_trip_and_hello_capabilities() -> None:
    for msg in run(recorded("workflow")) + run(recorded("agents")):
        assert parse_server(dump(msg)) == msg
    hello = parse_client(dump(HelloClient(ts=TS, app_version="0.10.0", capabilities=[AGENTS_CAPABILITY])))
    assert isinstance(hello, HelloClient) and hello.capabilities == ["agents.v1"]
    old = parse_client('{"type":"hello","protocol":1,"app_version":"0.9.0","ts":"2026-10-27T12:00:00Z"}')
    assert isinstance(old, HelloClient) and not old.capabilities


# --- through the gateway --------------------------------------------------------------------


@pytest.fixture
async def server(state_dir: StateDir) -> AsyncIterator[GatewayServer]:
    config: Config = make_config()
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=EngineFactory(), version=__version__)
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


async def attach_app(server: GatewayServer, capabilities: list[str]) -> ClientConnection:
    conn = await connect(ws_url(server, server.token))
    await conn.send(dump(HelloClient(ts=TS, app_version="0.10.0", capabilities=capabilities)))
    hello = parse_server(await conn.recv())
    assert isinstance(hello, HelloServer) and AGENTS_CAPABILITY in hello.capabilities
    assert isinstance(parse_server(await conn.recv()), ChatList)
    assert isinstance(parse_server(await conn.recv()), ServicesStatus)
    return conn


async def run_fan_out(server: GatewayServer, conn: ClientConnection, folder: Path) -> tuple[int, list[ServerMessage]]:
    number = await new_chat(conn, folder)
    engine = server.registry.get(number).engine
    engine.script(*recorded("agents"))  # type: ignore[union-attr]
    await conn.send(dump(MessageSend(ts=TS, chat=number, id="req", text="fan out")))
    frames = await recv_until(conn, TurnFinished)
    await recv(conn)  # chat.state idle
    return number, frames


async def open_chat(conn: ClientConnection, number: int) -> ChatHistory:
    await conn.send(dump(ChatOpen(ts=TS, chat=number, id="req-open")))
    history = await recv(conn)
    assert isinstance(history, ChatHistory)
    assert isinstance(await recv(conn), ChatLive)
    await recv(conn)  # chat.state
    return history


async def test_a_capable_app_gets_the_agents_live_and_in_replay(server: GatewayServer, folder: Path) -> None:
    conn = await attach_app(server, [AGENTS_CAPABILITY])
    try:
        number, frames = await run_fan_out(server, conn, folder)
        assert len(of(frames, AgentStarted)) == 3 and len(of(frames, AgentFinished)) == 3
        inner = [f for f in frames if isinstance(f, (ToolStarted, ToolFinished)) and f.agent_id]
        assert len(inner) == 6
        seqs = [f.seq for f in frames]
        assert all(s is not None for s in seqs) and seqs == sorted(seqs)

        history = await open_chat(conn, number)
        replayed = [e for e in history.events if e.seq in set(seqs)]
        assert [dump(e) for e in replayed] == [dump(f) for f in frames]  # the ring kept them, as sent
    finally:
        await conn.close()


async def test_an_older_app_sees_the_conversation_as_before(server: GatewayServer, folder: Path) -> None:
    conn = await attach_app(server, [])
    try:
        number, frames = await run_fan_out(server, conn, folder)
        assert not [f for f in frames if f.type.startswith(("agent.", "workflow."))]
        assert not [f for f in frames if getattr(f, "agent_id", None)]
        # The main conversation's own rows are all there: three Agent calls, started and finished.
        assert [t.tool for t in of(frames, ToolStarted)] == ["Agent", "Agent", "Agent"]
        assert len(of(frames, ToolFinished)) == 3

        history = await open_chat(conn, number)
        assert not [e for e in history.events if e.type.startswith(("agent.", "workflow."))]
        assert not [e for e in history.events if getattr(e, "agent_id", None)]
        # ... while the ring holds everything for an app that can show it.
        ring = list(server.registry.get(number).ring)
        assert len(of(ring, AgentStarted)) == 3
    finally:
        await conn.close()


async def test_background_workflow_frames_after_the_turn_are_kept(server: GatewayServer, folder: Path) -> None:
    conn = await attach_app(server, [AGENTS_CAPABILITY])
    try:
        number = await new_chat(conn, folder)
        engine = server.registry.get(number).engine
        messages = recorded("workflow")
        first_result = next(i for i, m in enumerate(messages) if type(m).__name__ == "ResultMessage")
        # Turn 1 ends with the workflow still running ...
        engine.script(*messages[: first_result + 1])  # type: ignore[union-attr]
        await conn.send(dump(MessageSend(ts=TS, chat=number, id="r1", text="run it")))
        frames = await recv_until(conn, TurnFinished)
        await recv(conn)
        assert of(frames, WorkflowStarted) and not of(frames, WorkflowFinished)
        # ... and reports the rest during turn 2: kept, under the turn that started it.
        engine.script(*messages[first_result + 1 :], fake_result())  # type: ignore[union-attr]
        await conn.send(dump(MessageSend(ts=TS, chat=number, id="r2", text="and then")))
        later = await recv_until(conn, WorkflowFinished)
        assert {a.turn for a in of(later, AgentStarted)} == {1}
        assert len(of(later, AgentFinished)) == 3
    finally:
        await conn.close()
