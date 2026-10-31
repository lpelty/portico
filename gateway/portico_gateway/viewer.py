"""v0.12: the agent's tools for the viewer, and the ``viewer.act`` / ``viewer.result`` round trip.

``ViewerBridge`` is the gateway's one line to the app: a tool call becomes a
``viewer.act`` sent to the app that most recently sent ``viewer.settings``, and
the call waits (10 s) for the ``viewer.result`` carrying the same id. Nothing
here touches the page: the app carries the action out in the viewer the person
is looking at. Whatever goes wrong (no app, an old app, the setting off, no
answer, the app leaving) the agent gets a plain sentence, never a hang.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from claude_agent_sdk import SdkMcpTool, tool

from .messages import ViewerAct, ViewerResult

log = logging.getLogger(__name__)

VIEWER_CAPABILITY = "viewer.v1"
ACT_TIMEOUT = 10.0

NOT_AVAILABLE = "The viewer isn't available right now (Portico isn't open)."
SETTING_OFF = "The person has turned off the agent's view of the viewer in Settings."
NO_ANSWER = "The viewer didn't answer in 10 s."

# Tool names as the agent sees them (the tool server is ``portico``, beside ``show_in_viewer``).
VIEWER_SERVER = "portico"
VIEWER_TOOLS = ("viewer_look", "viewer_click", "viewer_type", "viewer_scroll", "viewer_back")
VIEWER_TOOL_NAMES = tuple(f"mcp__{VIEWER_SERVER}__{name}" for name in VIEWER_TOOLS)

Send = Callable[[Any, ViewerAct], Awaitable[None]]


def _error(text: str) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}], "is_error": True}


@dataclass
class _Pending:
    conn: Any
    future: asyncio.Future[ViewerResult | None]


class ViewerBridge:
    """Sends ``viewer.act`` to the app and waits for its ``viewer.result``.

    ``send(conn, act)`` delivers a frame; ``capable(conn)`` says whether that
    app declared ``viewer.v1``. ``defaults`` are the deployment's two switches
    (``can_see``, ``check_html``), in force until an app sends
    ``viewer.settings``; the app is what applies the person's choice.
    """

    def __init__(
        self,
        send: Send,
        capable: Callable[[Any], bool] = lambda conn: True,
        defaults: tuple[bool, bool] = (True, True),
    ) -> None:
        self._send = send
        self._capable = capable
        self._defaults = defaults
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

    async def act(self, chat: int, action: str, args: dict[str, Any], timeout: float = ACT_TIMEOUT) -> dict[str, Any]:
        """One act as MCP tool content: ``{"content": [text, image?], "is_error"?: True}``."""
        conn = self._target
        if conn is None or not self._capable(conn):
            return _error(NOT_AVAILABLE)
        if not self.can_see:
            return _error(SETTING_OFF)
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
            result = await asyncio.wait_for(round_trip(), timeout)
        except asyncio.TimeoutError:
            return _error(NO_ANSWER)
        finally:
            self._pending.pop(act_id, None)
        if result is None:
            return _error(NOT_AVAILABLE)
        if not result.ok:
            return _error(result.error or result.text)
        content: list[dict[str, Any]] = [{"type": "text", "text": result.text}]
        if result.image is not None:
            content.append({"type": "image", "data": result.image.data, "mimeType": result.image.media_type})
        return {"content": content}


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _args(args: dict[str, Any], *keys: str) -> dict[str, Any]:
    return {k: args[k] for k in keys if k in args and args[k] is not None}


def build_viewer_tools(bridge: ViewerBridge, chat: int) -> list[SdkMcpTool[Any]]:
    """The five viewer tools for ``chat``: look, click, type, scroll, back."""

    def schema(properties: dict[str, Any], required: list[str]) -> dict[str, Any]:
        return {"type": "object", "properties": properties, "required": required}

    @tool(
        "viewer_look",
        "Look at the viewer the person is looking at: a screenshot, what is open, an outline of the page "
        "with a ref (e12) for each heading, link, button and field, and any page errors since the last look.",
        schema({}, []),
    )
    async def viewer_look(args: dict[str, Any]) -> dict[str, Any]:
        return await bridge.act(chat, "look", {})

    @tool(
        "viewer_click",
        "Click something in the viewer. target is a ref from the last viewer_look (e12) or the visible text "
        "of a button or link.",
        schema({"target": {"type": "string"}}, ["target"]),
    )
    async def viewer_click(args: dict[str, Any]) -> dict[str, Any]:
        return await bridge.act(chat, "click", _args(args, "target"))

    @tool(
        "viewer_type",
        "Type into a field in the viewer. target is a ref from the last viewer_look or the field's visible "
        "label. submit presses Return afterwards.",
        schema(
            {"target": {"type": "string"}, "text": {"type": "string"}, "submit": {"type": "boolean"}},
            ["target", "text"],
        ),
    )
    async def viewer_type(args: dict[str, Any]) -> dict[str, Any]:
        wire = _args(args, "target", "text")
        wire["submit"] = args.get("submit") is True  # the string "false" must not press Return
        return await bridge.act(chat, "type", wire)

    @tool(
        "viewer_scroll",
        "Scroll the viewer: direction is up, down, top or bottom; or target (a ref or visible text) to bring "
        "an element into view.",
        schema(
            {"direction": {"type": "string", "enum": ["up", "down", "top", "bottom"]}, "target": {"type": "string"}},
            [],
        ),
    )
    async def viewer_scroll(args: dict[str, Any]) -> dict[str, Any]:
        return await bridge.act(chat, "scroll", _args(args, "direction", "target"))

    @tool("viewer_back", "Go back in the viewer's own history.", schema({}, []))
    async def viewer_back(args: dict[str, Any]) -> dict[str, Any]:
        return await bridge.act(chat, "back", {})

    return [viewer_look, viewer_click, viewer_type, viewer_scroll, viewer_back]
