"""Check 3 (done-when), the gateway half: a question the agent puts back to the person.

Gated exactly like ``tests/test_live_smoke.py``: ``PORTICO_LIVE=1`` and a provider
credential in the environment; skipped otherwise. The real ``GatewayServer`` runs
in-process on ``SDKEngine`` (the smoke's ``server`` fixture); the model is asked to use
its question tool, the ``card.ask kind=question`` that arrives is checked for shape and
lifecycle, answered in the protocol's exact form, and the reply must echo the choice.

Three assertion groups: single-select, multi-select, and "Other" free text (which the
app sends as a label the card did not offer; the gateway passes it through as-is).
A model is free to answer without asking, so each group tries a plainer prompt once
before failing.

Run once here: ``PORTICO_LIVE=1 uv run pytest tests/test_live_check3.py -v``

Left to a person: the card in the window and picking the answer there.
"""

from __future__ import annotations

import asyncio
import os
from collections.abc import Callable
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection

from portico_gateway.doctor import has_credential
from portico_gateway.messages import (
    CardAnswer,
    CardAnswered,
    CardAsk,
    ChatState,
    Error,
    MessageSend,
    ServerMessage,
    ToolFinished,
    ToolStarted,
    TurnFinished,
    dump,
)
from portico_gateway.server import GatewayServer
from tests.test_live_smoke import isolated_cli_config, new_chat, reply_text, server  # noqa: F401 — the smoke's fixtures
from tests.test_server import attach
from tests.test_turns import recv

pytestmark = pytest.mark.skipif(
    os.environ.get("PORTICO_LIVE") != "1" or not has_credential(os.environ),
    reason="live check 3: set PORTICO_LIVE=1 and a provider credential in the environment",
)

TS = "2026-10-28T12:00:00Z"
TURN_TIMEOUT = 180.0

PROMPT_SINGLE = (
    "Before doing anything, use your question tool to ask me which colour I prefer, "
    "offering exactly the options Red, Green and Blue. "
    "After I answer, reply with only the line CHOSEN: <my answer>."
)
PROMPT_SINGLE_RETRY = (
    "Call the AskUserQuestion tool now, with one question 'Which colour do you prefer?' "
    "and exactly three options labelled Red, Green, Blue (single select). Do not write any text first. "
    "When the tool result arrives, reply with only the line CHOSEN: <the label I picked>."
)
PROMPT_MULTI = (
    "Before doing anything, use your question tool to ask me which TWO colours I prefer, "
    "as ONE multi-select question offering exactly the options Red, Green and Blue. "
    "After I answer, reply with only the line CHOSEN: <my answers, comma separated, in the order I gave them>."
)
PROMPT_MULTI_RETRY = (
    "Call the AskUserQuestion tool now, with one question 'Which two colours do you prefer?' "
    "with multiSelect true and exactly three options labelled Red, Green, Blue. Do not write any text first. "
    "When the tool result arrives, reply with only the line CHOSEN: <the labels I picked, comma separated>."
)

Pick = Callable[[CardAsk], dict[str, str | list[str]]]


# --- fixtures ------------------------------------------------------------------


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    """Neutral on purpose: nothing here names the question tool, so a call to it comes from the prompt alone."""
    folder = tmp_path / "project"
    folder.mkdir()
    (folder / "CLAUDE.md").write_text("This is a throwaway test folder. Do exactly what the message asks, briefly.\n", encoding="utf-8")
    return folder


# --- helpers ---------------------------------------------------------------------


async def ask_until_card(conn: ClientConnection, chat: int, prompts: list[str], pick: Pick) -> tuple[list[ServerMessage], CardAsk]:
    """Try each prompt in turn until a question card arrives; ``pick(card)`` builds the answer from the card's own options."""
    last: list[ServerMessage] = []
    for prompt in prompts:
        got: list[ServerMessage] = []
        cards: list[CardAsk] = []
        await conn.send(dump(MessageSend(ts=TS, chat=chat, text=prompt)))
        deadline = asyncio.get_running_loop().time() + TURN_TIMEOUT
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            assert remaining > 0, f"turn did not finish within {TURN_TIMEOUT}s: {[type(m).__name__ for m in got]}"
            msg = await recv(conn, remaining)
            got.append(msg)
            assert not isinstance(msg, Error), f"the gateway refused something mid-turn: {msg}"
            if isinstance(msg, CardAsk):
                cards.append(msg)
                if msg.kind == "permission":
                    await conn.send(dump(CardAnswer(ts=TS, chat=chat, id=msg.id, answer={"decision": "allow"}, scope="once")))
                elif msg.kind == "question":
                    await conn.send(dump(CardAnswer(ts=TS, chat=chat, id=msg.id, answer={"answers": pick(msg)})))
            if isinstance(msg, TurnFinished) and msg.chat == chat:
                break
        last = got
        questions = [c for c in cards if c.kind == "question"]
        if questions:
            return got, questions[0]
    pytest.fail(
        f"the model never called the question tool after {len(prompts)} prompts; last reply: {reply_text(last)!r}; "
        f"tools: {[e.tool for e in last if isinstance(e, ToolStarted)]}"
    )


def assert_card_shape(card: CardAsk, multi: bool) -> None:
    assert card.kind == "question" and card.questions, card
    question = card.questions[0]
    assert sorted(o.label for o in question.options) == ["Blue", "Green", "Red"], [o.label for o in question.options]
    assert question.multi_select is multi, (question.multi_select, multi)
    assert question.header, "the card's first question has no header"
    assert card.title == question.header, (card.title, question.header)
    assert card.seq is not None, "card.ask carries no seq"


def assert_card_lifecycle(events: list[ServerMessage], card: CardAsk) -> None:
    """``waiting on you`` after the card; ``card.answered`` then ``working``; the tool finished ok; the turn done."""
    after = events[events.index(card) + 1 :]
    assert isinstance(after[0], ChatState) and after[0].state == "waiting on you", after[0]
    answered = next((e for e in after if isinstance(e, CardAnswered) and e.id == card.id), None)
    assert answered is not None, "no card.answered for the question card"
    following = [e for e in after[after.index(answered) + 1 :] if isinstance(e, ChatState)]
    assert following and following[0].state == "working", following
    started = [e for e in events if isinstance(e, ToolStarted) and e.tool == "AskUserQuestion"]
    assert started, "no tool.started for AskUserQuestion"
    finished = [e for e in events if isinstance(e, ToolFinished) and e.tool_use_id == started[-1].tool_use_id]
    assert finished and finished[0].ok, finished
    assert isinstance(events[-1], TurnFinished) and events[-1].outcome == "done", events[-1]


# --- the checks ---------------------------------------------------------------------


async def test_single_select_answer_reaches_the_agent(server: GatewayServer, folder: Path) -> None:
    conn = await attach(server)
    try:
        chat = await new_chat(conn, folder)
        events, card = await ask_until_card(
            conn, chat, [PROMPT_SINGLE, PROMPT_SINGLE_RETRY], lambda c: {c.questions[0].question: "Green"}
        )
        assert_card_shape(card, multi=False)
        assert_card_lifecycle(events, card)
        assert "CHOSEN: Green" in reply_text(events), reply_text(events)
    finally:
        await conn.close()


async def test_multi_select_answers_reach_the_agent(server: GatewayServer, folder: Path) -> None:
    conn = await attach(server)
    try:
        chat = await new_chat(conn, folder)
        events, card = await ask_until_card(
            conn, chat, [PROMPT_MULTI, PROMPT_MULTI_RETRY], lambda c: {c.questions[0].question: ["Red", "Blue"]}
        )
        assert_card_shape(card, multi=True)
        assert_card_lifecycle(events, card)
        text = reply_text(events)
        assert "CHOSEN:" in text, text
        chosen = text.split("CHOSEN:", 1)[1]
        assert "Red" in chosen and "Blue" in chosen and "Green" not in chosen, text
    finally:
        await conn.close()


async def test_other_free_text_reaches_the_agent(server: GatewayServer, folder: Path) -> None:
    """The app's "Other" field sends the typed text as the label; the gateway must pass it through as-is."""
    conn = await attach(server)
    try:
        chat = await new_chat(conn, folder)
        events, card = await ask_until_card(
            conn, chat, [PROMPT_SINGLE, PROMPT_SINGLE_RETRY], lambda c: {c.questions[0].question: "Purple"}
        )
        assert_card_shape(card, multi=False)
        assert_card_lifecycle(events, card)
        assert "CHOSEN: Purple" in reply_text(events), reply_text(events)
    finally:
        await conn.close()
