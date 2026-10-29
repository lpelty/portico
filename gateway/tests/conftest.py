"""Shared test helpers: a scripted FakeEngine, recording callbacks, state/config factories.

Everything here is model-free. ``FakeEngine`` speaks the ``Engine`` protocol
from ``portico_gateway.engine`` and emits SDK-shaped messages through the
real ``translate`` so the layers above see exactly what the SDK adapter
would produce.
"""

from __future__ import annotations

import asyncio
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import pytest
from claude_agent_sdk import ResultMessage

from portico_gateway.config import Config
from portico_gateway.engine import EngineCallbacks, PermissionDecision, QuestionDeclined, translate
from portico_gateway.messages import Action, Brand, Root, ServerMessage
from portico_gateway.state import StateDir

# --- script items -------------------------------------------------------------


@dataclass
class AskPermission:
    """Mid-turn: the engine asks ``on_permission`` for ``tool``."""

    tool: str
    input: dict[str, Any]
    suggestions: list[dict[str, Any]] = field(default_factory=list)
    tool_use_id: str = "toolu_fake"


@dataclass
class AskQuestion:
    """Mid-turn: the engine asks ``on_question``."""

    questions: list[dict[str, Any]]


@dataclass
class Block:
    """Mid-turn: the engine hangs until ``interrupt()``; then the turn ends.

    A ``stubborn`` block ignores ``interrupt()`` and never ends on its own
    (only ``close()`` ends it): a wedged engine, for the stop watchdog.
    """

    stubborn: bool = False


@dataclass
class Compact:
    """Mid-turn: the engine is about to summarize earlier conversation (its ``PreCompact`` hook fires)."""

    trigger: str = "auto"


def fake_result(is_error: bool = False, session_id: str = "fake-session") -> ResultMessage:
    return ResultMessage(
        subtype="error_during_execution" if is_error else "success",
        duration_ms=1,
        duration_api_ms=1,
        is_error=is_error,
        num_turns=1,
        session_id=session_id,
    )


# --- fakes --------------------------------------------------------------------


class RecordingCallbacks:
    """An ``EngineCallbacks`` that records everything and answers from presets."""

    def __init__(
        self,
        permission_decision: PermissionDecision = "allow",
        question_answers: dict[str, str | list[str]] | None = None,
    ) -> None:
        self.permission_decision = permission_decision
        self.question_answers = question_answers or {}
        self.events: list[ServerMessage] = []
        self.permissions: list[tuple[str, dict[str, Any], list[dict[str, Any]], str]] = []
        self.questions: list[list[dict[str, Any]]] = []
        self.compactions: list[str] = []

    async def on_compacted(self, trigger: str) -> None:
        self.compactions.append(trigger)

    async def on_event(self, event: ServerMessage) -> None:
        self.events.append(event)

    async def on_permission(
        self, tool: str, input: dict[str, Any], suggestions: list[dict[str, Any]], tool_use_id: str
    ) -> PermissionDecision:
        self.permissions.append((tool, input, suggestions, tool_use_id))
        return self.permission_decision

    async def on_question(self, questions: list[dict[str, Any]]) -> dict[str, str | list[str]]:
        self.questions.append(questions)
        return dict(self.question_answers)


class FakeEngine:
    """Scripted ``Engine``: one script (a list of SDK messages and ask items) per ``send``.

    Records every call in ``calls``; decisions and answers it received in
    ``decisions`` / ``answers``. ``wait_idle()`` awaits the running turn;
    ``wait_blocked()`` returns once a ``Block`` item is reached.
    """

    def __init__(self, chat: int = 0, session_id: str = "fake-session", late_session: bool = False) -> None:
        self.chat = chat
        self.turn = 0
        self.session_id: str | None = None
        self.permission_mode = "default"
        # The slash commands the engine knows; ``None``: it cannot say.
        self.commands: set[str] | None = None
        # Every ``set_permission_mode`` call, in order (not in ``calls``).
        self.mode_changes: list[str] = []
        self._session_id = session_id
        # Like the real engine: ``start`` names no session; the id arrives
        # with the first turn's messages.
        self.late_session = late_session
        self.callbacks: EngineCallbacks | None = None
        self.scripts: deque[list[Any]] = deque()
        self.calls: list[tuple[str, Any]] = []
        self.decisions: list[PermissionDecision] = []
        self.answers: list[dict[str, str | list[str]] | tuple[str, str]] = []
        self.started = False
        self.closed = False
        self._task: asyncio.Task[None] | None = None
        self._interrupted = asyncio.Event()
        self._blocked = asyncio.Event()
        # What ``context_usage`` answers: ``(percent, model)``, ``None`` for
        # unavailable; ``context_error`` makes it raise instead.
        self.context: tuple[float, str | None] | None = None
        self.context_error: Exception | None = None
        self.context_reads = 0

    def script(self, *items: Any) -> None:
        self.scripts.append(list(items))

    def slash_commands(self) -> set[str] | None:
        return set(self.commands) if self.commands is not None else None

    async def set_permission_mode(self, mode: str) -> None:
        self.mode_changes.append(mode)
        self.permission_mode = mode

    async def start(self, folder: Path, resume: str | None, setting_sources: list[str], callbacks: EngineCallbacks) -> str:
        self.calls.append(("start", (folder, resume, list(setting_sources))))
        self.started_mode = self.permission_mode
        self.callbacks = callbacks
        self.started = True
        self.session_id = resume or (None if self.late_session else self._session_id)
        return self.session_id or ""

    async def send(self, text: str) -> None:
        self.calls.append(("send", text))
        if self.callbacks is None:
            raise RuntimeError("FakeEngine.send before start")
        self.turn += 1
        if self.session_id is None:
            self.session_id = self._session_id
        self._interrupted.clear()
        self._blocked.clear()
        items = self.scripts.popleft() if self.scripts else [fake_result(session_id=self.session_id or "fake")]
        self._task = asyncio.create_task(self._run(items))

    async def _run(self, items: list[Any]) -> None:
        assert self.callbacks is not None
        cb = self.callbacks
        for item in items:
            if isinstance(item, AskPermission):
                decision = await cb.on_permission(item.tool, item.input, list(item.suggestions), item.tool_use_id)
                self.decisions.append(decision)
            elif isinstance(item, AskQuestion):
                try:
                    self.answers.append(await cb.on_question(item.questions))
                except QuestionDeclined as e:
                    self.answers.append(("declined", str(e)))
            elif isinstance(item, Compact):
                await cb.on_compacted(item.trigger)
            elif isinstance(item, Block):
                self._blocked.set()
                if item.stubborn:
                    await asyncio.Event().wait()
                await self._interrupted.wait()
                for ev in translate(fake_result(session_id=self.session_id or "fake"), self.chat, self.turn):
                    await cb.on_event(ev)
                return
            else:
                for ev in translate(item, self.chat, self.turn):
                    await cb.on_event(ev)

    async def context_usage(self) -> tuple[float, str | None] | None:
        self.context_reads += 1  # not in ``calls``: tests read ``calls[-1]`` as the last send
        if self.context_error is not None:
            raise self.context_error
        return self.context

    async def interrupt(self) -> None:
        self.calls.append(("interrupt", None))
        self._interrupted.set()

    async def close(self) -> None:
        self.calls.append(("close", None))
        self.closed = True
        self._interrupted.set()
        if self._task is not None and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except (asyncio.CancelledError, Exception):
                pass

    async def wait_idle(self, timeout: float = 5.0) -> None:
        if self._task is not None:
            await asyncio.wait_for(self._task, timeout)

    async def wait_blocked(self, timeout: float = 5.0) -> None:
        await asyncio.wait_for(self._blocked.wait(), timeout)


# --- fixtures -----------------------------------------------------------------


@pytest.fixture
def state_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> StateDir:
    """A fresh state directory, also exported as ``PORTICO_HOME``."""
    home = tmp_path / "portico-home"
    monkeypatch.setenv("PORTICO_HOME", str(home))
    return StateDir(home)


def make_config(**overrides: Any) -> Config:
    """A ``Config`` with a visible brand and one action/root unless overridden.

    Tests open several chats side by side, so they run in ``multiple``
    presentation unless they ask for ``single`` (the v0.3 default).
    """
    base: dict[str, Any] = {
        "presentation": "multiple",
        "brand": Brand(name="Portico", agent_name="Agent"),
        "actions": [Action(label="Review", text="/review")],
        "roots": [Root(name="projects", path="/Users/someone/projects")],
    }
    base.update(overrides)
    return Config(**base)


@pytest.fixture
def config() -> Config:
    return make_config()


@pytest.fixture
def fake_engine() -> FakeEngine:
    return FakeEngine()
