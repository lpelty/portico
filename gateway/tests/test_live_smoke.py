"""Task 13: the opt-in live smoke — the probe's parity check through the gateway (done-when 6).

Runs only with ``PORTICO_LIVE=1`` and a provider credential in the
environment; otherwise every test here is skipped. It starts the real
gateway in-process on the SDK engine, opens a chat in a throwaway folder
whose ``CLAUDE.md`` holds a codeword and whose ``.claude/settings.json``
carries a ``PreToolUse`` hook denying every Bash call, then checks that the
codeword comes back and that the hook's denial reaches the model.

Run once here: ``PORTICO_LIVE=1 uv run pytest tests/test_live_smoke.py -v``
"""

from __future__ import annotations

import asyncio
import json
import os
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import Config
from portico_gateway.doctor import has_credential
from portico_gateway.engine import SDKEngine
from portico_gateway.messages import (
    CardAnswer,
    CardAsk,
    ChatList,
    ChatNew,
    ChatState,
    Error,
    MessageSend,
    ServerMessage,
    TextDelta,
    ToolFinished,
    TurnFinished,
    dump,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from tests.test_server import attach
from tests.test_turns import recv

pytestmark = pytest.mark.skipif(
    os.environ.get("PORTICO_LIVE") != "1" or not has_credential(os.environ),
    reason="live smoke: set PORTICO_LIVE=1 and a provider credential in the environment",
)

TS = "2026-10-27T12:00:00Z"
CODEWORD = "HELIOTROPE"
DENIAL = "PROBE-HOOK fired: denied"
TURN_TIMEOUT = 120.0


# --- the probe's fixture -------------------------------------------------------


def make_fixture(folder: Path) -> None:
    """The probe's throwaway project: a codeword in ``CLAUDE.md`` and a hook denying Bash."""
    (folder / ".claude").mkdir(parents=True, exist_ok=True)
    (folder / "CLAUDE.md").write_text(
        f"The probe codeword is {CODEWORD}. Say it when asked for the codeword.\n", encoding="utf-8"
    )
    hook = folder / ".claude" / "deny.sh"
    decision = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": DENIAL,
        }
    }
    hook.write_text("#!/bin/sh\ncat >/dev/null\necho '" + json.dumps(decision) + "'\n", encoding="utf-8")
    hook.chmod(0o755)
    settings = {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": str(hook)}]}]}}
    (folder / ".claude" / "settings.json").write_text(json.dumps(settings, indent=1), encoding="utf-8")


@pytest.fixture
def fixture_folder(tmp_path: Path) -> Path:
    folder = tmp_path / "fixture-project"
    folder.mkdir()
    make_fixture(folder)
    return folder


@pytest.fixture
def isolated_cli_config(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Like the probe: a scratch ``CLAUDE_CONFIG_DIR`` so no user plugins, hooks or settings mix in."""
    config_dir = tmp_path / "cli-config"
    config_dir.mkdir()
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config_dir))
    return config_dir


@pytest.fixture
async def server(state_dir: StateDir, isolated_cli_config: Path) -> AsyncIterator[GatewayServer]:
    # Defaults (setting_sources=["project"], no lifecycle commands), except the two v0.3 changed:
    # the checks built on this fixture open several chats and expect a card for every step.
    config = Config(presentation="multiple", permission_mode="default")
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=SDKEngine, version=__version__)
    await srv.serve(0)
    try:
        yield srv
    finally:
        await srv.shutdown()


# --- helpers ------------------------------------------------------------------


async def new_chat(conn: ClientConnection, folder: Path) -> int:
    """``chat.new`` against the real engine: the CLI starts and the engine waits its init timeout first."""
    await conn.send(dump(ChatNew(ts=TS, id="req-new", folder=str(folder))))
    state = await recv(conn, 60.0)
    assert isinstance(state, ChatState) and state.state == "idle", state
    listing = await recv(conn, 10.0)
    assert isinstance(listing, ChatList), listing
    return state.chat


async def run_turn(conn: ClientConnection, chat: int, text: str) -> list[ServerMessage]:
    """Send ``text`` and collect every event up to ``turn.finished``, allowing any permission card once.

    An ``error`` frame during the turn fails at once: the gateway refuses a
    card answer in the wrong shape and keeps the card open, so the turn
    would otherwise sit until ``TURN_TIMEOUT`` with a misleading message.
    ``tests/test_cards.py`` drives this helper against the fake engine, so
    its card branch is checked without a model even though the smoke's own
    deny hook keeps a permission card from ever being asked.
    """
    await conn.send(dump(MessageSend(ts=TS, chat=chat, text=text)))
    got: list[ServerMessage] = []
    deadline = asyncio.get_running_loop().time() + TURN_TIMEOUT
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        assert remaining > 0, f"turn did not finish within {TURN_TIMEOUT}s: {got}"
        msg = await recv(conn, remaining)
        got.append(msg)
        assert not isinstance(msg, Error), f"the gateway refused something mid-turn: {msg}"
        if isinstance(msg, CardAsk) and msg.kind == "permission":
            # The hook, not the person, is what this test exercises: let the
            # tool through so the hook's own denial is the one observed. The
            # answer is the protocol's: {"decision": "allow"} with scope once.
            await conn.send(
                dump(CardAnswer(ts=TS, chat=chat, id=msg.id, answer={"decision": "allow"}, scope="once"))
            )
        if isinstance(msg, TurnFinished) and msg.chat == chat:
            return got


def reply_text(events: list[ServerMessage]) -> str:
    return "".join(e.text for e in events if isinstance(e, TextDelta))


# --- the smoke ----------------------------------------------------------------


async def test_live_smoke(server: GatewayServer, fixture_folder: Path) -> None:
    conn = await attach(server)
    try:
        chat = await new_chat(conn, fixture_folder)

        # The folder's CLAUDE.md loaded (setting_sources default ["project"]).
        events = await run_turn(conn, chat, "Tell me the probe codeword if you know one; otherwise say NONE.")
        assert isinstance(events[-1], TurnFinished) and events[-1].outcome == "done", events[-1]
        assert CODEWORD in reply_text(events), reply_text(events)

        # The folder's deny hook fires through the gateway and its reason reaches the model.
        events = await run_turn(
            conn, chat, "Run this exact Bash command: echo probe-bash-ran  — and report exactly what happened."
        )
        assert isinstance(events[-1], TurnFinished), events[-1]
        finished = [e for e in events if isinstance(e, ToolFinished)]
        denied_in_tool = any((not e.ok) and DENIAL in e.summary for e in finished)
        denied_in_reply = DENIAL in reply_text(events) or "denied" in reply_text(events).lower()
        assert denied_in_tool or denied_in_reply, (finished, reply_text(events))
        assert "probe-bash-ran" not in "".join(e.summary for e in finished if e.ok)
    finally:
        await conn.close()
