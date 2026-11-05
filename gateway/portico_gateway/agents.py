"""Subagents and workflows (v0.10): the engine's task messages as ``agent.*`` and ``workflow.*`` frames.

The engine reports work it hands off as *tasks*. ``AgentTracker`` follows
them for one engine and turns them into protocol events:

- A **subagent** task (``task_type`` ``local_agent``; ``subagent`` and
  ``remote_agent`` are taken the same way) is an agent: ``agent.started``
  when it starts, ``agent.progress`` on the engine's progress reports and on
  each of its own tool calls, ``agent.finished`` when it ends. Its own
  tool calls (``parent_tool_use_id`` is the call that started it) become
  tool rows carrying ``agent_id``.
- A **workflow** task (``local_workflow`` or ``workflow``) is a
  ``workflow.started`` named by the engine's ``workflow_name``. Its
  progress reports carry ``workflow_progress``: the phases (``index`` from
  1, ``title``) and the workflow's agents (``label``, ``phaseIndex``,
  ``state`` ``start``/``progress``/``done``, ``lastToolName``,
  ``lastToolSummary``, ``toolCalls``, ``durationMs``, ``resultPreview``).
  Each agent becomes ``agent.started kind=workflow`` with ``workflow_id``
  and ``phase`` (an index from 0 into the phases); a phase's state follows
  its agents (``workflow.phase``); the task's end is ``workflow.finished``.
  A workflow's agents send no messages of their own: their steps are only
  what the progress reports say.
- A subagent's own subagent (``spawn_depth`` above 1) is not an agent of
  its own: its start is the parent's ``Agent`` step, and its messages are
  kept out like any subagent the gateway never heard start.
- A **background command or Monitor** (v0.21; ``task_type`` ``local_bash``
  or ``monitor``) is ``agent.started`` with ``task`` ``shell`` or
  ``monitor``, ending like a background agent. One the engine marks
  ``ambient`` or ``skip_transcript`` is housekeeping and stays out; a
  command started in the foreground (its Bash row shows it) is announced
  only if a ``task_updated`` moves it to the background.
- A subagent **resumed** (SendMessage) keeps its task id and starts a new
  run (``run_id``): ``agent.started`` again, with ``run`` 2, 3, …, in the
  turn that resumed it. A frame naming an earlier run is late and dropped.
- Anything else is left alone.

A task ends with a ``task_notification`` (which carries the summary) or,
for background work, possibly only with a ``task_updated`` whose status is
terminal. A foreground subagent's or a workflow's ``task_updated`` comes
just before its notification, so it is held for the summary; whatever the
turn's result finds still open in the foreground of that turn is ended
then. A workflow held longer than ``HOLD_SECONDS``, or past the next
message that is not a task's, ends without the summary. Background agents
end on whichever comes first; they and workflows may outlive their turn.

``close_all`` ends everything still open, for an engine that is going
away (closed, or its process gone): background work dies with it.
"""

from __future__ import annotations

import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from pathlib import PurePosixPath
from typing import Any

from claude_agent_sdk import (
    AssistantMessage,
    Message,
    ResultMessage,
    TaskNotificationMessage,
    TaskProgressMessage,
    TaskStartedMessage,
    TaskUpdatedMessage,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
)

from .messages import (
    AgentFinished,
    AgentOutcome,
    AgentProgress,
    AgentStarted,
    PhaseState,
    ServerMessage,
    TaskKind,
    ToolFinished,
    ToolStarted,
    WorkflowFinished,
    WorkflowPhase,
    WorkflowStarted,
)

SUBAGENT_TASK_TYPES: frozenset[str] = frozenset({"local_agent", "subagent", "remote_agent"})
WORKFLOW_TASK_TYPES: frozenset[str] = frozenset({"local_workflow", "workflow"})
# v0.21: background work that is not an agent, by the engine's task type -> ``agent.started.task``.
TASK_KINDS: dict[str, TaskKind] = {"local_bash": "shell", "shell": "shell", "monitor": "monitor"}
WORKFLOW_AGENT_KIND = "workflow"
DEFAULT_AGENT_KIND = "agent"
STEP_TARGET_LIMIT = 48

# The engine's own internal tools, in plain words when one is a subagent's step.
INTERNAL_TOOL_WORDS: dict[str, str] = {
    "SubagentHandback": "Reporting back",
}

# A progress frame repeating the last one's step and steps is sent only once
# its elapsed time has moved on by at least this much (seconds).
PROGRESS_ELAPSED_STEP = 1.0


def _tool_word(tool: str) -> str:
    return INTERNAL_TOOL_WORDS.get(tool, tool)
SUMMARY_LIMIT = 120
# The longest a workflow's terminal ``task_updated`` waits for the notification's summary.
HOLD_SECONDS = 5.0

# A task's end status (``task_notification`` or a terminal ``task_updated``) -> outcome.
_TASK_OUTCOMES: dict[str, AgentOutcome] = {
    "completed": "done",
    "failed": "failed",
    "stopped": "stopped",
    "killed": "stopped",
}
# A workflow agent's ``state`` that means it ended -> outcome; any other state is running.
_WORKFLOW_AGENT_OUTCOMES: dict[str, AgentOutcome] = {
    "done": "done",
    "completed": "done",
    "failed": "failed",
    "error": "failed",
    "stopped": "stopped",
    "killed": "stopped",
    "cancelled": "stopped",
    "canceled": "stopped",
}


def _clip(text: str, limit: int) -> str:
    line = text.strip().split("\n", 1)[0].strip()
    return line if len(line) <= limit else line[: limit - 1] + "…"


def _short_path(path: str) -> str:
    """The last two parts of a path (``transcripts/p11.md``), so a step stays readable."""
    parts = PurePosixPath(path.strip()).parts
    tail = [p for p in parts if p != "/"][-2:]
    return "/".join(tail) if tail else path.strip()


def step_text(tool: str, input: Mapping[str, Any]) -> str:
    """One short line for a subagent's step: the tool and its target (a file, a command's head, a pattern)."""
    if tool in INTERNAL_TOOL_WORDS:
        return INTERNAL_TOOL_WORDS[tool]
    target: Any = None
    if tool in ("Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "NotebookRead"):
        target = input.get("file_path") or input.get("notebook_path")
        if isinstance(target, str) and target:
            target = _short_path(target)
    elif tool == "Bash":
        target = input.get("command")
    elif tool in ("Grep", "Glob"):
        target = input.get("pattern")
    elif tool == "WebFetch":
        target = input.get("url")
    elif tool == "WebSearch":
        target = input.get("query")
    elif tool in ("Agent", "Task"):
        target = input.get("description")
    if isinstance(target, str) and target.strip():
        return f"{tool} {_clip(target, STEP_TARGET_LIMIT)}"
    return tool


def _summary_target(summary: Any) -> str | None:
    """A workflow agent's ``lastToolSummary`` made short: a path's last parts, else its first words."""
    if not isinstance(summary, str) or not summary.strip():
        return None
    text = summary.strip()
    if "/" in text and " " not in text:
        if text.endswith("…"):
            return None  # a path the engine already cut short: its last parts would mislead
        return _clip(_short_path(text), STEP_TARGET_LIMIT)
    return _clip(text, STEP_TARGET_LIMIT)


def _task_type(msg: TaskStartedMessage) -> str:
    kind = msg.task_type or (msg.data.get("task_type") if isinstance(msg.data, Mapping) else None)
    return kind if isinstance(kind, str) else ""


def _data(msg: Message) -> Mapping[str, Any]:
    data = getattr(msg, "data", None)
    return data if isinstance(data, Mapping) else {}


def _run_id(msg: Message) -> str | None:
    value = _data(msg).get("run_id")
    return value if isinstance(value, str) and value else None


def _number(value: Any) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return None


@dataclass
class _Agent:
    id: str
    turn: int
    tool_use_id: str
    started: float  # monotonic, when the gateway first heard of it
    background: bool = False
    workflow_id: str | None = None
    phase: int | None = None
    steps: int = 0
    # A subagent's own tool calls counted from its messages, and the count the engine last reported.
    calls: int = 0
    reported: int = 0
    step: str | None = None
    description: str = ""
    elapsed: float = 0.0
    finished: bool = False
    # A terminal ``task_updated`` seen for a foreground agent: held for the notification's summary.
    pending_outcome: AgentOutcome | None = None
    # The last progress frame sent: (step, steps, elapsed).
    last_sent: tuple[str | None, int, float] | None = None
    # v0.21: a background command or Monitor (``shell``/``monitor``), else ``None`` for an agent.
    task: TaskKind | None = None
    # A command started in the foreground: not announced until it moves to the background.
    announced: bool = True
    # The engine's id of the run under way, and which run it is (2 and on: resumed).
    run_id: str | None = None
    run: int = 1
    kind: str = DEFAULT_AGENT_KIND


@dataclass
class _Workflow:
    id: str
    turn: int
    tool_use_id: str
    name: str
    phases: list[str] = field(default_factory=list)
    phase_states: list[PhaseState] = field(default_factory=list)
    agents: dict[int, _Agent] = field(default_factory=dict)  # by the engine's agent index
    finished: bool = False
    # A terminal ``task_updated`` seen: held for the notification's summary since ``held_at``.
    pending_outcome: AgentOutcome | None = None
    held_at: float = 0.0


class AgentTracker:
    """One engine's subagents and workflows; ``translate`` handles the messages that are theirs.

    ``clock`` is monotonic seconds (a test can drive it).
    """

    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self.clock = clock
        self._agents: dict[str, _Agent] = {}  # subagents by task id
        self._by_tool_use: dict[str, _Agent] = {}  # subagents by the call that started them
        self._workflows: dict[str, _Workflow] = {}

    # --- entry point ------------------------------------------------------------

    def translate(self, msg: Message, chat: int, turn: int, ts: str) -> list[ServerMessage] | None:
        """Events for ``msg`` when it is a task's or a subagent's; ``None`` when it is not (translate it as before)."""
        if isinstance(msg, TaskStartedMessage):
            return self._started(msg, chat, turn, ts)
        if isinstance(msg, (TaskProgressMessage, TaskNotificationMessage, TaskUpdatedMessage)) and self._late(msg):
            return []
        if isinstance(msg, TaskProgressMessage):
            return self._progress(msg, chat, ts)
        if isinstance(msg, TaskNotificationMessage):
            return self._ended(msg.task_id, msg.status, msg.summary, chat, ts, notified=True)
        if isinstance(msg, TaskUpdatedMessage):
            out = self._backgrounded(msg, chat, ts)
            if msg.status is not None:
                out.extend(self._ended(msg.task_id, msg.status, None, chat, ts, notified=False))
            return out
        if isinstance(msg, AssistantMessage) and msg.parent_tool_use_id is not None:
            return self._subagent_calls(msg, chat, ts)
        if isinstance(msg, UserMessage) and msg.parent_tool_use_id is not None:
            return self._subagent_results(msg, chat, ts)
        if isinstance(msg, ResultMessage):
            return self._turn_ended(chat, turn, ts)
        return None

    def overdue(self, msg: Message, chat: int, ts: str) -> list[ServerMessage]:
        """Before ``msg``: end the held workflows whose notification is not coming (no summary).

        A notification follows its ``task_updated`` at once, so a held
        workflow ends without one at the first message that is not a task's,
        or once it has waited ``HOLD_SECONDS``.
        """
        task_message = isinstance(msg, (TaskStartedMessage, TaskProgressMessage, TaskNotificationMessage, TaskUpdatedMessage))
        now = self.clock()
        out: list[ServerMessage] = []
        for wf in self._workflows.values():
            if wf.finished or wf.pending_outcome is None:
                continue
            if not task_message or now - wf.held_at >= HOLD_SECONDS:
                out.extend(self._finish_workflow(wf, wf.pending_outcome, None, chat, ts))
        return out

    def close_all(self, chat: int, ts: str, outcome: AgentOutcome = "stopped") -> list[ServerMessage]:
        """End every agent and workflow still open: the engine is going away and its work with it.

        Something already known to have ended (a held ``task_updated``)
        ends as it did; the rest ends ``outcome``. Idempotent.
        """
        out: list[ServerMessage] = []
        for wf in self._workflows.values():
            if not wf.finished:
                out.extend(self._finish_workflow(wf, wf.pending_outcome or outcome, None, chat, ts))
        for agent in self._agents.values():
            if not agent.finished:
                if not agent.announced:
                    agent.finished = True
                    continue
                out.append(self._finish(agent, agent.pending_outcome or outcome, None, chat, ts))
        return out

    # --- subagents ----------------------------------------------------------------

    def _started(self, msg: TaskStartedMessage, chat: int, turn: int, ts: str) -> list[ServerMessage]:
        kind = _task_type(msg)
        data = msg.data if isinstance(msg.data, Mapping) else {}
        if kind in SUBAGENT_TASK_TYPES:
            if msg.task_id in self._agents:
                return self._resumed(self._agents[msg.task_id], msg, data, chat, turn, ts)
            depth = data.get("spawn_depth")
            if isinstance(depth, int) and not isinstance(depth, bool) and depth > 1:
                return []  # a subagent's own: its parent's Agent step stands for it
            subagent_type = data.get("subagent_type")
            agent = _Agent(
                id=msg.task_id,
                turn=turn,
                tool_use_id=msg.tool_use_id or "",
                started=self.clock(),
                background=bool(data.get("is_backgrounded")),
                description=msg.description,
                run_id=_run_id(msg),
                kind=subagent_type if isinstance(subagent_type, str) and subagent_type else DEFAULT_AGENT_KIND,
            )
            self._agents[agent.id] = agent
            if agent.tool_use_id:
                self._by_tool_use[agent.tool_use_id] = agent
            return [
                AgentStarted(
                    ts=ts,
                    chat=chat,
                    turn=turn,
                    id=agent.id,
                    tool_use_id=agent.tool_use_id,
                    description=msg.description,
                    kind=agent.kind,
                    background=True if agent.background else None,
                )
            ]
        if kind in WORKFLOW_TASK_TYPES:
            if msg.task_id in self._workflows:
                return []
            name = data.get("workflow_name")
            wf = _Workflow(
                id=msg.task_id,
                turn=turn,
                tool_use_id=msg.tool_use_id or "",
                name=name if isinstance(name, str) and name else msg.description,
            )
            self._workflows[wf.id] = wf
            return [WorkflowStarted(ts=ts, chat=chat, turn=turn, id=wf.id, name=wf.name, phases=[])]
        if kind in TASK_KINDS:
            return self._task_started(msg, TASK_KINDS[kind], data, chat, turn, ts)
        return []  # the rest: not shown

    def _progress(self, msg: TaskProgressMessage, chat: int, ts: str) -> list[ServerMessage]:
        agent = self._agents.get(msg.task_id)
        if agent is not None:
            if agent.finished or not agent.announced:
                return []
            usage = msg.usage if isinstance(msg.usage, Mapping) else {}
            uses = usage.get("tool_uses")
            if isinstance(uses, int) and uses > agent.reported:
                agent.reported = uses
            agent.steps = max(agent.calls, agent.reported)
            if agent.calls == 0:
                # No call of its own seen yet: the engine's own words for what it is doing
                # ("Reading alpha.md"), else the tool it last used.
                if msg.description and msg.description != agent.description:
                    agent.step = _clip(msg.description, STEP_TARGET_LIMIT + 12)
                elif msg.last_tool_name:
                    agent.step = _tool_word(msg.last_tool_name)
            duration = _number(usage.get("duration_ms"))
            agent.elapsed = round(duration / 1000, 1) if duration is not None else self._elapsed(agent)
            return self._progress_events(agent, chat, ts)
        wf = self._workflows.get(msg.task_id)
        if wf is not None and not wf.finished:
            report = msg.data.get("workflow_progress") if isinstance(msg.data, Mapping) else None
            if isinstance(report, list):
                return self._workflow_report(wf, report, chat, ts)
        return []

    def _subagent_calls(self, msg: AssistantMessage, chat: int, ts: str) -> list[ServerMessage]:
        agent = self._by_tool_use.get(msg.parent_tool_use_id or "")
        if agent is None:
            return []  # a subagent the gateway never heard start: kept out, as before v0.10
        out: list[ServerMessage] = []
        for block in msg.content:
            if not isinstance(block, ToolUseBlock):
                continue
            agent.calls += 1
            agent.steps = max(agent.calls, agent.reported)
            agent.step = step_text(block.name, block.input)
            out.append(
                ToolStarted(
                    ts=ts,
                    chat=chat,
                    turn=agent.turn,
                    tool_use_id=block.id,
                    tool=block.name,
                    summary=_engine.summarize_tool(block.name, block.input),
                    input=dict(block.input),
                    agent_id=agent.id,
                )
            )
        if out and not agent.finished:
            agent.elapsed = max(agent.elapsed, self._elapsed(agent))
            out.extend(self._progress_events(agent, chat, ts))
        return out

    def _subagent_results(self, msg: UserMessage, chat: int, ts: str) -> list[ServerMessage]:
        agent = self._by_tool_use.get(msg.parent_tool_use_id or "")
        if agent is None or isinstance(msg.content, str):
            return []
        return [
            ToolFinished(
                ts=ts,
                chat=chat,
                turn=agent.turn,
                tool_use_id=block.tool_use_id,
                ok=not bool(block.is_error),
                summary=_engine.result_summary(block.content),
                permission="blocked" if _engine.blocked_by_auto_mode(block.is_error, block.content) else None,
                agent_id=agent.id,
            )
            for block in msg.content
            if isinstance(block, ToolResultBlock)
        ]

    def _ended(
        self, task_id: str, status: str, summary: str | None, chat: int, ts: str, *, notified: bool
    ) -> list[ServerMessage]:
        outcome = _TASK_OUTCOMES.get(status)
        if outcome is None:
            return []  # pending, running, paused
        agent = self._agents.get(task_id)
        if agent is not None:
            if agent.finished:
                return []
            if not agent.announced:
                agent.finished = True  # a foreground command, never shown: its Bash row has the end
                return []
            if not notified and not agent.background:
                agent.pending_outcome = outcome  # its notification follows with the summary
                return []
            return [self._finish(agent, outcome, summary, chat, ts)]
        wf = self._workflows.get(task_id)
        if wf is not None and not wf.finished:
            if not notified:
                if wf.pending_outcome is None:
                    wf.pending_outcome, wf.held_at = outcome, self.clock()
                return []  # its notification follows with the summary
            return self._finish_workflow(wf, outcome, summary, chat, ts)
        return []

    def _turn_ended(self, chat: int, turn: int, ts: str) -> list[ServerMessage]:
        """Turn ``turn``'s result: a foreground subagent of that turn still open ended with it."""
        out: list[ServerMessage] = []
        for agent in self._agents.values():
            if not agent.finished and not agent.background and agent.turn == turn:
                if not agent.announced:
                    agent.finished = True
                    continue
                out.append(self._finish(agent, agent.pending_outcome or "stopped", None, chat, ts))
        return out

    # --- background commands, Monitors and resumed runs (v0.21) ------------------------

    def _task_started(
        self, msg: TaskStartedMessage, task: TaskKind, data: Mapping[str, Any], chat: int, turn: int, ts: str
    ) -> list[ServerMessage]:
        if msg.task_id in self._agents or data.get("ambient") is True or data.get("skip_transcript") is True:
            return []  # seen already, or housekeeping the engine says is not activity
        foreground = task == "shell" and data.get("is_backgrounded") is False
        agent = _Agent(
            id=msg.task_id,
            turn=turn,
            tool_use_id=msg.tool_use_id or "",
            started=self.clock(),
            background=not foreground,
            description=msg.description,
            task=task,
            announced=not foreground,
            run_id=_run_id(msg),
        )
        self._agents[agent.id] = agent
        return [self._start_event(agent, chat, ts)] if agent.announced else []

    def _backgrounded(self, msg: TaskUpdatedMessage, chat: int, ts: str) -> list[ServerMessage]:
        """A foreground command moved to the background: shown from now on."""
        agent = self._agents.get(msg.task_id)
        patch = msg.patch if isinstance(msg.patch, Mapping) else {}
        if agent is None or agent.finished or patch.get("is_backgrounded") is not True or agent.background:
            return []
        agent.background = True
        # Announced already (a foreground agent): the start again, now background, so the app
        # does not end it with its turn. The app keeps what a re-sent start's agent already did.
        agent.announced = True
        return [self._start_event(agent, chat, ts)]

    def _resumed(
        self, agent: _Agent, msg: TaskStartedMessage, data: Mapping[str, Any], chat: int, turn: int, ts: str
    ) -> list[ServerMessage]:
        """A start for a known subagent: a new run when its run id is later, or (without run ids) once it ended."""
        run_id = _run_id(msg)
        if run_id is not None and agent.run_id is not None:
            if run_id <= agent.run_id:
                return []  # the same run again, or a late one
        elif not agent.finished:
            return []
        agent.run += 1
        agent.run_id = run_id
        agent.turn = turn
        agent.finished = False
        agent.pending_outcome = None
        agent.started = self.clock()
        agent.elapsed = 0.0
        agent.last_sent = None
        # "A resumed subagent is always registered in the background", unless the call that resumed it waits.
        agent.background = data.get("awaited") is not True and data.get("is_backgrounded") is not False
        if msg.tool_use_id:
            self._by_tool_use[msg.tool_use_id] = agent
        # The call that first started it, not the resuming one: an app before v0.21 takes this as a
        # re-sent start and keeps its rows where they were.
        return [self._start_event(agent, chat, ts)]

    def _late(self, msg: Message) -> bool:
        """A task frame naming a run before the one under way."""
        task_id = getattr(msg, "task_id", None)
        agent = self._agents.get(task_id) if isinstance(task_id, str) else None
        run_id = _run_id(msg)
        return agent is not None and agent.run_id is not None and run_id is not None and run_id < agent.run_id

    @staticmethod
    def _start_event(agent: _Agent, chat: int, ts: str) -> AgentStarted:
        return AgentStarted(
            ts=ts,
            chat=chat,
            turn=agent.turn,
            id=agent.id,
            tool_use_id=agent.tool_use_id,
            description=agent.description,
            kind=agent.task or agent.kind,
            background=True if agent.background else None,
            task=agent.task,
            run=agent.run if agent.run > 1 else None,
        )

    # --- workflows ------------------------------------------------------------------

    def _workflow_report(self, wf: _Workflow, report: list[Any], chat: int, ts: str) -> list[ServerMessage]:
        out: list[ServerMessage] = []
        phases = sorted(
            (
                e
                for e in report
                if isinstance(e, Mapping) and e.get("type") == "workflow_phase" and isinstance(e.get("index"), int)
            ),
            key=lambda e: e["index"],
        )
        titles = [str(e.get("title") or f"Phase {e['index']}") for e in phases]
        if titles and titles != wf.phases:
            wf.phases = titles
            wf.phase_states = (wf.phase_states + ["pending"] * len(titles))[: len(titles)]
            out.append(WorkflowStarted(ts=ts, chat=chat, turn=wf.turn, id=wf.id, name=wf.name, phases=titles))
        positions = {e["index"]: i for i, e in enumerate(phases)}
        for entry in report:
            if not isinstance(entry, Mapping) or entry.get("type") != "workflow_agent":
                continue
            index = entry.get("index")
            if not isinstance(index, int):
                continue
            out.extend(self._workflow_agent(wf, index, entry, positions, chat, ts))
        out.extend(self._phase_changes(wf, chat, ts))
        return out

    def _workflow_agent(
        self, wf: _Workflow, index: int, entry: Mapping[str, Any], positions: Mapping[int, int], chat: int, ts: str
    ) -> list[ServerMessage]:
        out: list[ServerMessage] = []
        agent = wf.agents.get(index)
        if agent is None:
            phase_index = entry.get("phaseIndex")
            phase = positions.get(phase_index) if isinstance(phase_index, int) else None
            agent = _Agent(
                id=f"{wf.id}.{index}",
                turn=wf.turn,
                tool_use_id=wf.tool_use_id,
                started=self.clock(),
                background=True,
                workflow_id=wf.id,
                phase=phase,
            )
            wf.agents[index] = agent
            label = entry.get("label")
            out.append(
                AgentStarted(
                    ts=ts,
                    chat=chat,
                    turn=wf.turn,
                    id=agent.id,
                    tool_use_id=agent.tool_use_id,
                    description=str(label) if label else f"Agent {index}",
                    kind=WORKFLOW_AGENT_KIND,
                    workflow_id=wf.id,
                    phase=phase,
                    background=True,
                )
            )
        if agent.finished:
            return out
        tool = entry.get("lastToolName")
        step = agent.step
        if isinstance(tool, str) and tool:
            target = _summary_target(entry.get("lastToolSummary"))
            if tool in INTERNAL_TOOL_WORDS:
                step = INTERNAL_TOOL_WORDS[tool]
            else:
                step = f"{tool} {target}" if target else tool
        calls = entry.get("toolCalls")
        steps = calls if isinstance(calls, int) and calls > agent.steps else agent.steps
        duration = _number(entry.get("durationMs"))
        began, last = _number(entry.get("startedAt")), _number(entry.get("lastProgressAt"))
        if duration is not None:
            elapsed = round(duration / 1000, 1)
        elif began is not None and last is not None and last >= began:
            elapsed = round((last - began) / 1000, 1)
        else:
            elapsed = agent.elapsed
        if step != agent.step or steps != agent.steps or elapsed != agent.elapsed:
            agent.step, agent.steps, agent.elapsed = step, steps, elapsed
            out.extend(self._progress_events(agent, chat, ts))
        state = entry.get("state")
        outcome = _WORKFLOW_AGENT_OUTCOMES.get(state) if isinstance(state, str) else None
        if outcome is not None:
            preview = entry.get("resultPreview")
            out.append(self._finish(agent, outcome, preview if isinstance(preview, str) else None, chat, ts))
        return out

    def _phase_changes(self, wf: _Workflow, chat: int, ts: str) -> list[ServerMessage]:
        out: list[ServerMessage] = []
        for i in range(len(wf.phases)):
            members = [a for a in wf.agents.values() if a.phase == i]
            state: PhaseState
            if not members:
                state = wf.phase_states[i] if wf.finished else "pending"
            elif any(not a.finished for a in members):
                state = "running"
            elif any(a.pending_outcome == "failed" for a in members):
                state = "failed"
            else:
                state = "done"
            if state != wf.phase_states[i]:
                wf.phase_states[i] = state
                out.append(WorkflowPhase(ts=ts, chat=chat, id=wf.id, index=i, state=state))
        return out

    def _finish_workflow(
        self, wf: _Workflow, outcome: AgentOutcome, summary: str | None, chat: int, ts: str
    ) -> list[ServerMessage]:
        out: list[ServerMessage] = []
        for agent in wf.agents.values():
            if not agent.finished:
                out.append(self._finish(agent, "done" if outcome == "done" else "stopped", None, chat, ts))
        wf.finished = True
        out.extend(self._phase_changes(wf, chat, ts))
        out.append(
            WorkflowFinished(
                ts=ts, chat=chat, id=wf.id, outcome=outcome, summary=_clip(summary, SUMMARY_LIMIT) if summary else None
            )
        )
        return out

    # --- shared ------------------------------------------------------------------------

    def _elapsed(self, agent: _Agent) -> float:
        return round(max(0.0, self.clock() - agent.started), 1)

    @staticmethod
    def _progress_events(agent: _Agent, chat: int, ts: str) -> list[ServerMessage]:
        """The agent's progress frame, unless it would repeat the last one sent.

        A frame goes when the step or the step count changed, or the elapsed
        time moved on by ``PROGRESS_ELAPSED_STEP``; the engine reports one
        call both as the subagent's message and as a progress report.
        """
        last = agent.last_sent
        if last is not None and last[0] == agent.step and last[1] == agent.steps:
            if agent.elapsed - last[2] < PROGRESS_ELAPSED_STEP:
                return []
        agent.last_sent = (agent.step, agent.steps, agent.elapsed)
        return [AgentProgress(ts=ts, chat=chat, id=agent.id, step=agent.step, steps=agent.steps, elapsed=agent.elapsed)]

    @staticmethod
    def _finish(agent: _Agent, outcome: AgentOutcome, summary: str | None, chat: int, ts: str) -> AgentFinished:
        agent.finished = True
        agent.pending_outcome = outcome
        text = _clip(summary, SUMMARY_LIMIT) if summary and summary.strip() else None
        return AgentFinished(ts=ts, chat=chat, id=agent.id, outcome=outcome, summary=text)


# Last, so either module can be imported first: the engine imports this one,
# and this one uses the engine's tool-row helpers only at call time.
from . import engine as _engine  # noqa: E402
