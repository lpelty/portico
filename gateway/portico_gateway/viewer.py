"""v0.12: the agent's tools for the viewer, and the ``viewer.act`` / ``viewer.result`` round trip.

``ViewerBridge`` is the gateway's one line to the app: a tool call becomes a
``viewer.act`` sent to the app that most recently sent ``viewer.settings``, and
the call waits (10 s) for the ``viewer.result`` carrying the same id. Nothing
here touches the page: the app carries the action out in the viewer the person
is looking at. Whatever goes wrong (no app, an old app, the setting off, no
answer, the app leaving) the agent gets a plain sentence, never a hang.

v0.17: a conversation's viewer calls run one at a time, in the order they
arrive (``queue``), and a show waits for the app to say the page has loaded
(``show``, the ``viewer.act "show"`` round trip, only to an app that declared
``viewer.show.v1``).
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from claude_agent_sdk import SdkMcpTool, tool

from .messages import Artifact, ViewerAct, ViewerResult

log = logging.getLogger(__name__)

VIEWER_CAPABILITY = "viewer.v1"
MARKS_CAPABILITY = "viewer.marks.v1"
ACT_TIMEOUT = 10.0
# v0.17: the app answers ``viewer.act "show"`` once the page has loaded.
SHOW_CAPABILITY = "viewer.show.v1"
SHOW_TIMEOUT = ACT_TIMEOUT
# Appended to every viewer tool's description, and to show_in_viewer's.
QUEUE_NOTE = " Viewer calls run one at a time, in the order you send them."

NOT_AVAILABLE = "The viewer isn't available right now (Portico isn't open)."
SETTING_OFF = "The person has turned off the agent's view of the viewer in Settings."
NEEDS_UPDATE = "This Portico can't show marks yet; it needs updating."
MARK_COUNT = "Mark 1 to 9 things at a time."
MARK_ITEM = "Each mark needs a target, and a note of at most 60 characters."
MARK_NOTE_LIMIT = 60
NO_ANSWER = "The viewer didn't answer in 10 s."
# v0.17: a call that waited in the queue while its turn was stopped does not act.
STOPPED = "Stopped."

# Tool names as the agent sees them (the tool server is ``portico``, beside ``show_in_viewer``).
VIEWER_SERVER = "portico"
VIEWER_TOOLS = ("viewer_look", "viewer_click", "viewer_type", "viewer_scroll", "viewer_back", "viewer_mark", "viewer_clear_marks")
VIEWER_TOOL_NAMES = tuple(f"mcp__{VIEWER_SERVER}__{name}" for name in VIEWER_TOOLS)

Send = Callable[[Any, ViewerAct], Awaitable[None]]
# ``turn_live(chat)`` -> whether the turn that is running on ``chat`` now is still running when asked later.
TurnLive = Callable[[int], Callable[[], bool]]


def _no_turn(chat: int) -> Callable[[], bool]:
    return lambda: True


def _error(text: str) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}], "is_error": True}


@dataclass
class _Pending:
    conn: Any
    future: asyncio.Future[ViewerResult | None]


class ViewerBridge:
    """Sends ``viewer.act`` to the app and waits for its ``viewer.result``.

    ``send(conn, act)`` delivers a frame; ``capable(conn)`` says whether that
    app declared ``viewer.v1``, ``show_capable(conn)`` whether it declared
    ``viewer.show.v1``. ``turn_live(chat)`` captures the chat's running turn
    and answers whether it is still running (a stopped turn's queued calls
    do not act). ``defaults`` are the deployment's two switches
    (``can_see``, ``check_html``), in force until an app sends
    ``viewer.settings``; the app is what applies the person's choice.
    """

    def __init__(
        self,
        send: Send,
        capable: Callable[[Any], bool] = lambda conn: True,
        defaults: tuple[bool, bool] = (True, True),
        marks_capable: Callable[[Any], bool] = lambda conn: True,
        show_capable: Callable[[Any], bool] = lambda conn: True,
        turn_live: TurnLive = _no_turn,
    ) -> None:
        self._send = send
        self._capable = capable
        self._defaults = defaults
        self._marks_capable = marks_capable
        # (chat, tool_use_id, tool_input) of viewer_mark calls the PreToolUse hook has seen, not yet taken.
        self._mark_uses: list[tuple[int, str, dict[str, Any]]] = []
        self._show_capable = show_capable
        self._turn_live = turn_live
        # v0.17: one lock per chat; every viewer call holds it while it runs (asyncio.Lock is FIFO).
        self._queues: dict[int, asyncio.Lock] = {}
        self._target: Any = None
        self._pending: dict[str, _Pending] = {}
        # (can_see, check_html) as the target app last sent them; ``None`` until one does.
        self.settings: tuple[bool, bool] | None = None

    @property
    def has_target(self) -> bool:
        """An app that declared ``viewer.v1`` has sent ``viewer.settings``: an act would reach it."""
        return self._target is not None and self.settings is not None and self._capable(self._target)

    @property
    def can_see(self) -> bool:
        return (self.settings or self._defaults)[0]

    @property
    def check_html(self) -> bool:
        return (self.settings or self._defaults)[1]

    def set_target(self, conn: Any, can_see: bool, check_html: bool) -> None:
        """``conn`` is now the app acts go to (the one that most recently sent ``viewer.settings``)."""
        self._target = conn
        self.settings = (can_see, check_html)

    def drop(self, conn: Any) -> None:
        """``conn`` is gone: its pending acts answer "not available" now; it stops being the target."""
        for pending in list(self._pending.values()):
            if pending.conn is conn and not pending.future.done():
                pending.future.set_result(None)
        if self._target is conn:
            self._target = None
            self.settings = None

    def resolve(self, conn: Any, result: ViewerResult) -> None:
        """The app's ``viewer.result``. Unknown ids, and answers from an app other than the one asked, are ignored."""
        pending = self._pending.get(result.id)
        if pending is None or pending.conn is not conn or pending.future.done():
            return
        pending.future.set_result(result)

    def queue(self, chat: int) -> asyncio.Lock:
        """``chat``'s viewer queue: hold it for the whole of a viewer call, so calls run in the order they arrive."""
        lock = self._queues.get(chat)
        if lock is None:
            lock = self._queues[chat] = asyncio.Lock()
        return lock

    @asynccontextmanager
    async def queued(self, chat: int) -> AsyncIterator[bool]:
        """Hold ``chat``'s queue for one viewer call; yields whether the turn it was made in is still running.

        The turn is the one running when the call arrives; it is checked
        once the call's turn in the queue comes, so a call that waited
        through a stop answers ``STOPPED`` instead of acting.
        """
        live = self._turn_live(chat)
        async with self.queue(chat):
            yield live()

    async def show(self, chat: int, artifact: Artifact) -> bool | None:
        """Ask the app to say when ``artifact`` (just announced) has loaded.

        ``True`` loaded; ``False`` not within ``SHOW_TIMEOUT``, the app
        answered not ok, the send failed or the app left mid-show; ``None``
        when no round trip is possible (no target, an app without
        ``viewer.show.v1``), which the caller treats as today's immediate
        "shown". The person's
        "agent can see" switch does not apply: the answer says only that a
        page loaded, never what is on it.
        """
        conn = self._target
        if conn is None or not self._capable(conn) or not self._show_capable(conn):
            return None
        args = {"artifact": artifact.id, "location": artifact.location}
        try:
            result = await self._round_trip(conn, chat, "show", args, SHOW_TIMEOUT)
        except asyncio.TimeoutError:
            return False
        return result is not None and result.ok

    def note_mark_use(self, chat: int, tool_use_id: str, tool_input: dict[str, Any]) -> None:
        """The hook saw a ``viewer_mark`` call: remember its id so the handler can pass it to the app."""
        self._mark_uses.append((chat, tool_use_id, tool_input))
        del self._mark_uses[:-50]  # a call whose handler never ran must not pile up

    def take_mark_use(self, chat: int, args: dict[str, Any]) -> str | None:
        """The first noted id for ``chat`` whose input equals ``args``; it is removed."""
        for i, (c, tool_use_id, tool_input) in enumerate(self._mark_uses):
            if c == chat and tool_input == args:
                del self._mark_uses[i]
                return tool_use_id
        return None

    async def act(
        self,
        chat: int,
        action: str,
        args: dict[str, Any],
        timeout: float = ACT_TIMEOUT,
        needs_marks: bool = False,
    ) -> dict[str, Any]:
        """One act as MCP tool content: ``{"content": [text, image?], "is_error"?: True}``."""
        conn = self._target
        if conn is None or not self._capable(conn):
            return _error(NOT_AVAILABLE)
        if not self.can_see:
            return _error(SETTING_OFF)
        if needs_marks and not self._marks_capable(conn):
            return _error(NEEDS_UPDATE)
        try:
            result = await self._round_trip(conn, chat, action, args, timeout)
        except asyncio.TimeoutError:
            return _error(NO_ANSWER)
        if result is None:
            return _error(NOT_AVAILABLE)
        if not result.ok:
            return _error(result.error or result.text)
        content: list[dict[str, Any]] = [{"type": "text", "text": result.text}]
        if result.image is not None:
            content.append({"type": "image", "data": result.image.data, "mimeType": result.image.media_type})
        return {"content": content}

    async def _round_trip(
        self, conn: Any, chat: int, action: str, args: dict[str, Any], timeout: float
    ) -> ViewerResult | None:
        """Send one act to ``conn`` and wait for its result; ``None`` when the send failed or the app left.

        Raises ``asyncio.TimeoutError`` when no answer comes within ``timeout``.
        """
        act_id = uuid.uuid4().hex
        future: asyncio.Future[ViewerResult | None] = asyncio.get_running_loop().create_future()
        self._pending[act_id] = _Pending(conn, future)

        async def round_trip() -> ViewerResult | None:
            try:
                await self._send(conn, ViewerAct(ts=_now(), id=act_id, chat=chat, action=action, args=args))  # type: ignore[arg-type]
            except Exception:
                log.warning("sending viewer.act (%s) failed", action, exc_info=True)
                return None
            return await future

        try:
            # One budget for the send and the wait together: a stalled send still answers in time.
            return await asyncio.wait_for(round_trip(), timeout)
        finally:
            self._pending.pop(act_id, None)


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _args(args: dict[str, Any], *keys: str) -> dict[str, Any]:
    return {k: args[k] for k in keys if k in args and args[k] is not None}


def build_viewer_tools(bridge: ViewerBridge, chat: int) -> list[SdkMcpTool[Any]]:
    """The seven viewer tools for ``chat``: look, click, type, scroll, back, mark, clear_marks."""

    def schema(properties: dict[str, Any], required: list[str]) -> dict[str, Any]:
        return {"type": "object", "properties": properties, "required": required}

    @tool(
        "viewer_look",
        "Look at the viewer the person is looking at: a screenshot, what is open, an outline of the page "
        "with a ref (e12) for each heading, link, button and field, and any page errors since the last look."
        + QUEUE_NOTE,
        schema({}, []),
    )
    async def viewer_look(args: dict[str, Any]) -> dict[str, Any]:
        async with bridge.queued(chat) as live:
            if not live:
                return _error(STOPPED)
            return await bridge.act(chat, "look", {})

    @tool(
        "viewer_click",
        "Click something in the viewer. target is a ref from the last viewer_look (e12) or the visible text "
        "of a button or link." + QUEUE_NOTE,
        schema({"target": {"type": "string"}}, ["target"]),
    )
    async def viewer_click(args: dict[str, Any]) -> dict[str, Any]:
        async with bridge.queued(chat) as live:
            if not live:
                return _error(STOPPED)
            return await bridge.act(chat, "click", _args(args, "target"))

    @tool(
        "viewer_type",
        "Type into a field in the viewer. target is a ref from the last viewer_look or the field's visible "
        "label. submit presses Return afterwards." + QUEUE_NOTE,
        schema(
            {"target": {"type": "string"}, "text": {"type": "string"}, "submit": {"type": "boolean"}},
            ["target", "text"],
        ),
    )
    async def viewer_type(args: dict[str, Any]) -> dict[str, Any]:
        wire = _args(args, "target", "text")
        wire["submit"] = args.get("submit") is True  # the string "false" must not press Return
        async with bridge.queued(chat) as live:
            if not live:
                return _error(STOPPED)
            return await bridge.act(chat, "type", wire)

    @tool(
        "viewer_scroll",
        "Scroll the viewer: direction is up, down, top or bottom; or target (a ref or visible text) to bring "
        "an element into view." + QUEUE_NOTE,
        schema(
            {"direction": {"type": "string", "enum": ["up", "down", "top", "bottom"]}, "target": {"type": "string"}},
            [],
        ),
    )
    async def viewer_scroll(args: dict[str, Any]) -> dict[str, Any]:
        async with bridge.queued(chat) as live:
            if not live:
                return _error(STOPPED)
            return await bridge.act(chat, "scroll", _args(args, "direction", "target"))

    @tool("viewer_back", "Go back in the viewer's own history." + QUEUE_NOTE, schema({}, []))
    async def viewer_back(args: dict[str, Any]) -> dict[str, Any]:
        async with bridge.queued(chat) as live:
            if not live:
                return _error(STOPPED)
            return await bridge.act(chat, "back", {})

    @tool(
        "viewer_mark",
        "Mark parts of the page in the viewer so the person can see what you mean: each mark is a numbered "
        "accent box with a short note (at most 60 characters). target is a ref from your last viewer_look "
        "(e12), or any text the person can see on the page. Tie each finding to a ref when you look, and mark by that ref, not by "
        "guessing from the screenshot. Marks stay until cleared; numbers carry on across pages; viewer_look "
        "lists the marks in use. replace clears all marks first." + QUEUE_NOTE,
        schema(
            {
                "marks": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 9,
                    "items": {
                        "type": "object",
                        "properties": {"target": {"type": "string"}, "note": {"type": "string"}},
                        "required": ["target"],
                    },
                },
                "replace": {"type": "boolean"},
            },
            ["marks"],
        ),
    )
    async def viewer_mark(args: dict[str, Any]) -> dict[str, Any]:
        marks = args.get("marks")
        if not isinstance(marks, list) or not 1 <= len(marks) <= 9:
            return _error(MARK_COUNT)  # the schema is advisory
        for item in marks:
            note = item.get("note") if isinstance(item, dict) else None
            target = item.get("target") if isinstance(item, dict) else None
            if (
                not isinstance(target, str)
                or not target.strip()
                or (note is not None and (not isinstance(note, str) or len(note) > MARK_NOTE_LIMIT))
            ):
                return _error(MARK_ITEM)
        wire: dict[str, Any] = {"marks": marks, "replace": args.get("replace") is True}
        tool_use_id = bridge.take_mark_use(chat, args)
        if tool_use_id is not None:
            wire["tool_use_id"] = tool_use_id
        async with bridge.queued(chat) as live:
            if not live:
                return _error(STOPPED)
            return await bridge.act(chat, "mark", wire, needs_marks=True)

    @tool("viewer_clear_marks", "Clear every mark in the viewer." + QUEUE_NOTE, schema({}, []))
    async def viewer_clear_marks(args: dict[str, Any]) -> dict[str, Any]:
        async with bridge.queued(chat) as live:
            if not live:
                return _error(STOPPED)
            return await bridge.act(chat, "clear_marks", {}, needs_marks=True)

    return [viewer_look, viewer_click, viewer_type, viewer_scroll, viewer_back, viewer_mark, viewer_clear_marks]
