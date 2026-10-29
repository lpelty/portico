"""Check 2 (done-when), the gateway half: a file write asks a permission card; deny leaves
no file and the agent says so; allow writes it and the markdown artifact opens; and a
chat-scoped allow on the Write tool covers the next write in that chat (D16).

Gated exactly like ``tests/test_live_smoke.py``: ``PORTICO_LIVE=1`` and a provider
credential in the environment; skipped otherwise. The real ``GatewayServer`` runs
in-process on ``SDKEngine`` (the smoke's ``server`` fixture) and a websockets client
drives the protocol against the live model. One test per assertion group:

- (a) deny: a ``card.ask kind=permission`` for the Write tool, ``waiting on you`` right
  after it, a deny with the note ``not now`` leaves no file, the tool row is not ok and
  the reply says the write was refused.
- (b) allow once: the file holds the content, one ``artifact.created kind=file
  media=markdown open=true`` arrives before ``turn.finished``, the chat returns to idle.
- (c) scope chat: a write answered ``allow`` with scope ``chat``; a later write to a
  different file in the same chat asks no Write card (PROTOCOL.md ``card.answer``: for a
  tool that names a file, the scope covers the tool).

Run once here: ``PORTICO_LIVE=1 uv run pytest tests/test_live_check2.py -v``

Left to a person: the card in the window and the file opening in the viewer.
"""

from __future__ import annotations

import asyncio
import os
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest
from websockets.asyncio.client import ClientConnection

from portico_gateway.doctor import has_credential
from portico_gateway.messages import (
    ArtifactCreated,
    CardAnswer,
    CardAnswered,
    CardAsk,
    ChatState,
    Error,
    MessageSend,
    ServerMessage,
    TextDelta,
    ToolFinished,
    ToolStarted,
    TurnFinished,
    dump,
)
from portico_gateway.server import GatewayServer
from tests.test_live_smoke import isolated_cli_config, new_chat, server  # noqa: F401 — the smoke's fixtures
from tests.test_server import attach
from tests.test_turns import recv

pytestmark = pytest.mark.skipif(
    os.environ.get("PORTICO_LIVE") != "1" or not has_credential(os.environ),
    reason="live check 2: set PORTICO_LIVE=1 and a provider credential in the environment",
)

TS = "2026-10-28T12:00:00Z"
TURN_TIMEOUT = 180.0
WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}


# --- fixtures ------------------------------------------------------------------


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    """A throwaway chat folder whose ``CLAUDE.md`` asks for brief, literal, question-free work."""
    folder = tmp_path / "project"
    folder.mkdir()
    (folder / "CLAUDE.md").write_text(
        "This is a scratch folder for a protocol test. Do exactly what the message asks, "
        "briefly, without asking questions. When a tool use is denied, say so plainly.\n",
        encoding="utf-8",
    )
    return folder


# --- helpers -------------------------------------------------------------------


class Turn:
    """Everything observed in one turn, with the state word seen right after each card."""

    def __init__(self) -> None:
        self.events: list[ServerMessage] = []
        self.cards: list[CardAsk] = []
        self.state_after_card: dict[str, str] = {}
        self.answers_sent: list[dict[str, Any]] = []

    @property
    def text(self) -> str:
        return "".join(e.text for e in self.events if isinstance(e, TextDelta))

    @property
    def finished(self) -> TurnFinished | None:
        return next((e for e in self.events if isinstance(e, TurnFinished)), None)

    @property
    def states(self) -> list[str]:
        return [e.state for e in self.events if isinstance(e, ChatState)]

    @property
    def artifacts(self) -> list[ArtifactCreated]:
        return [e for e in self.events if isinstance(e, ArtifactCreated)]

    @property
    def tools(self) -> list[tuple[str, str]]:
        return [(e.tool, e.summary) for e in self.events if isinstance(e, ToolStarted)]

    @property
    def permission_cards(self) -> list[CardAsk]:
        return [c for c in self.cards if c.kind == "permission"]

    def kinds(self) -> list[str]:
        return [type(e).__name__ for e in self.events]


Answerer = Callable[[CardAsk], dict[str, Any]]  # card -> {"answer": ..., "scope"?: ..., "note"?: ...}


async def run_turn(conn: ClientConnection, chat: int, text: str, answer_for: Answerer) -> Turn:
    """Send ``text``; answer every card with ``answer_for(card)``; collect to ``turn.finished`` and the state after it."""
    await conn.send(dump(MessageSend(ts=TS, chat=chat, text=text)))
    turn = Turn()
    loop = asyncio.get_running_loop()
    deadline = loop.time() + TURN_TIMEOUT
    done = False
    while True:
        remaining = deadline - loop.time()
        assert remaining > 0, f"turn did not finish within {TURN_TIMEOUT}s: {turn.kinds()}"
        msg = await recv(conn, remaining)
        turn.events.append(msg)
        assert not isinstance(msg, Error), f"the gateway refused something mid-turn: {msg}"
        if isinstance(msg, CardAsk):
            turn.cards.append(msg)
            # The protocol sends ``chat.state waiting on you`` right after the card; read it before answering.
            after = await recv(conn, 10.0)
            turn.events.append(after)
            if isinstance(after, ChatState):
                turn.state_after_card[msg.id] = after.state
            spec = answer_for(msg)
            answer = CardAnswer(ts=TS, chat=chat, id=msg.id, answer=spec["answer"], scope=spec.get("scope"), note=spec.get("note"))
            turn.answers_sent.append({"card": msg.id, "tool": msg.permission.tool if msg.permission else None, **spec})
            await conn.send(dump(answer))
        if isinstance(msg, TurnFinished) and msg.chat == chat:
            done = True
        if done and isinstance(msg, ChatState):
            return turn


def deny_all(card: CardAsk) -> dict[str, Any]:
    return {"answer": {"decision": "deny"}, "note": "not now"}


def allow_once_all(card: CardAsk) -> dict[str, Any]:
    return {"answer": {"decision": "allow"}, "scope": "once"}


def allow_chat_for_write(card: CardAsk) -> dict[str, Any]:
    if card.kind == "permission" and card.permission is not None and card.permission.tool in WRITE_TOOLS:
        return {"answer": {"decision": "allow"}, "scope": "chat"}
    return allow_once_all(card)


# --- (a) deny -------------------------------------------------------------------


async def test_a_deny_leaves_no_file_and_the_agent_says_so(server: GatewayServer, folder: Path) -> None:
    conn = await attach(server)
    try:
        chat = await new_chat(conn, folder)
        turn = await run_turn(
            conn, chat, "Create the file denied.md in this folder containing the line NOPE. Do not ask questions.", deny_all
        )
        cards = turn.permission_cards
        assert cards, f"no permission card arrived; events: {turn.kinds()}; text: {turn.text!r}"
        first = cards[0]
        assert first.permission is not None and first.permission.tool in WRITE_TOOLS, first.permission
        assert first.title == "Create denied.md?", first.title
        assert "denied.md" in first.permission.summary, first.permission.summary
        assert turn.state_after_card.get(first.id) == "waiting on you", turn.state_after_card
        assert any(isinstance(e, CardAnswered) and e.id == first.id for e in turn.events), turn.kinds()
        assert turn.finished is not None and turn.finished.outcome == "done", turn.finished
        assert turn.states[-1] == "idle", turn.states
        assert not (folder / "denied.md").exists(), "denied.md exists after a deny"
        assert any(isinstance(e, ToolFinished) and not e.ok for e in turn.events), turn.kinds()
        low = turn.text.lower()
        assert any(w in low for w in ("denied", "deny", "not now", "permission", "declined", "not allowed")), turn.text
    finally:
        await conn.close()


# --- (b) allow once -------------------------------------------------------------


async def test_b_allow_once_writes_and_the_markdown_artifact_opens(server: GatewayServer, folder: Path) -> None:
    conn = await attach(server)
    try:
        chat = await new_chat(conn, folder)
        turn = await run_turn(
            conn, chat, "Create the file allowed.md in this folder containing the line YES. Do not ask questions.", allow_once_all
        )
        cards = turn.permission_cards
        assert cards and cards[0].permission is not None and cards[0].permission.tool in WRITE_TOOLS, turn.kinds()
        assert turn.state_after_card.get(cards[0].id) == "waiting on you", turn.state_after_card
        assert turn.finished is not None and turn.finished.outcome == "done", turn.finished
        target = folder / "allowed.md"
        assert target.is_file(), "allowed.md missing after allow"
        assert target.read_text(encoding="utf-8").strip() == "YES", target.read_text(encoding="utf-8")

        arts = turn.artifacts
        md = [a for a in arts if a.artifact.kind == "file" and a.artifact.media == "markdown" and a.artifact.location.endswith("allowed.md")]
        assert md, f"no markdown file artifact for allowed.md: {[dump(a) for a in arts]}"
        assert md[-1].artifact.open is True and md[-1].artifact.source == "tool" and md[-1].artifact.title == "allowed.md", dump(md[-1])
        assert sum(1 for a in arts if a.artifact.open) == 1, [dump(a) for a in arts]
        # Sent together just before turn.finished.
        last_artifact = max(i for i, e in enumerate(turn.events) if isinstance(e, ArtifactCreated))
        finished_at = next(i for i, e in enumerate(turn.events) if isinstance(e, TurnFinished))
        assert last_artifact < finished_at, turn.kinds()
        assert turn.states[-1] == "idle", turn.states
        assert any(isinstance(e, ToolFinished) and e.ok for e in turn.events), turn.kinds()
    finally:
        await conn.close()


# --- (c) allow for this chat ----------------------------------------------------


async def test_c_chat_scoped_allow_covers_the_next_write_in_the_chat(server: GatewayServer, folder: Path) -> None:
    conn = await attach(server)
    try:
        chat = await new_chat(conn, folder)
        third = await run_turn(
            conn, chat, "Create the file third.md in this folder containing the line THIRD. Do not ask questions.", allow_chat_for_write
        )
        cards = third.permission_cards
        assert cards and cards[0].permission is not None and cards[0].permission.tool in WRITE_TOOLS, third.kinds()
        assert any(a.get("scope") == "chat" for a in third.answers_sent), third.answers_sent
        assert third.finished is not None and third.finished.outcome == "done", third.finished
        assert (folder / "third.md").read_text(encoding="utf-8").strip() == "THIRD"

        fourth = await run_turn(
            conn, chat, "Create the file fourth.md in this folder containing the line FOURTH. Do not ask questions.", allow_once_all
        )
        assert fourth.finished is not None and fourth.finished.outcome == "done", fourth.finished
        assert (folder / "fourth.md").read_text(encoding="utf-8").strip() == "FOURTH"
        assert any(tool in WRITE_TOOLS for tool, _ in fourth.tools), fourth.tools
        write_cards = [c for c in fourth.permission_cards if c.permission is not None and c.permission.tool in WRITE_TOOLS]
        assert not write_cards, f"a Write card appeared again after a chat-scoped allow: {[dump(c) for c in write_cards]}"
        assert "waiting on you" not in fourth.states, fourth.states
    finally:
        await conn.close()
