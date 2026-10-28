"""Check 5 (done-when), the gateway half: stop, detach mid-turn, a held card, two chats, restart.

Drives a real detached gateway process (``bin/portico-gateway run`` on a scratch state
directory) with the real model, so "the app closes" is this client's websocket going
away and "the gateway keeps going" is a process this test does not own the event loop
of. Gated exactly like ``tests/test_live_smoke.py``: ``PORTICO_LIVE=1`` and a provider
credential in the environment; skipped otherwise.

One test per assertion group, in file order; later groups build on earlier ones through
the module-level ``S`` and fail plainly when a prerequisite is missing:

- (a)  ``turn.stop`` interrupts a running turn: ``turn.finished outcome=stopped``, idle,
       nothing of the stopped turn trickles in afterwards, seqs gapless.
- (a2) ``chat.stop`` gives the ``stopped`` word; the next send restarts the engine.
- (b)  detach mid-turn with a chat-scoped Write allow; the gateway finishes the writes;
       reattach with ``since`` replays gaplessly, the artifacts included; continue the chat.
- (c)  a permission asked while detached is still open on reattach, replayed exactly, and
       answering it finishes the turn.
- (d)  two chats at once, each with its own state word in ``chat.list``.
- (e)  ``gateway.stop``, start again: the transcript replays with user texts, tools and
       stored artifacts; the engine resumes the session and remembers the files.

Run once here: ``PORTICO_LIVE=1 uv run pytest tests/test_live_check5.py -v``

Left to a person: quitting and reopening the real window with a turn running.
"""

from __future__ import annotations

import asyncio
import json
import os
import signal
import subprocess
import time
from collections.abc import Callable, Iterator
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection, connect
from websockets.exceptions import ConnectionClosed

from portico_gateway import REPO_ROOT
from portico_gateway.doctor import has_credential
from portico_gateway.messages import (
    ArtifactCreated,
    CardAnswer,
    CardAnswered,
    CardAsk,
    CardCancel,
    ChatAlias,
    ChatHistory,
    ChatList,
    ChatLive,
    ChatNew,
    ChatOpen,
    ChatState,
    ChatStop,
    Error,
    GatewayStop,
    HelloClient,
    HelloServer,
    MessageSend,
    ServerMessage,
    StatusSet,
    TextDelta,
    ToolFinished,
    ToolStarted,
    TurnFinished,
    TurnStarted,
    TurnStop,
    UserText,
    dump,
)
from portico_gateway.server import PROTOCOL_PATH, READY_PREFIX
from tests.test_turns import recv

pytestmark = pytest.mark.skipif(
    os.environ.get("PORTICO_LIVE") != "1" or not has_credential(os.environ),
    reason="live check 5: set PORTICO_LIVE=1 and a provider credential in the environment",
)

TS = "2026-10-28T12:00:00Z"
TURN_TIMEOUT = 180.0
NEW_CHAT_TIMEOUT = 90.0
DETACH_B_SECONDS = 40.0
DETACH_C_SECONDS = 20.0
COUNT_PROMPT = "Count slowly from 1 to 200, one number per line, in your reply."


# --- shared state across the ordered tests ----------------------------------------


class _State:
    run_dir: Path
    home: Path
    folder1: Path
    folder2: Path
    cli_config: Path
    proc: subprocess.Popen[bytes] | None = None
    launch = 0
    port = 0
    token = ""
    epoch = ""
    chat1: int | None = None
    chat2: int | None = None
    last_seq1: int | None = None  # last seq this client saw on chat 1
    turns1 = 0  # turns run on chat 1 in launch 1, as the gateway numbered them


S = _State()


def note(text: str) -> None:
    """Observations worth reading in ``-s`` output; not assertions."""
    print(f"NOTE: {text}")


# --- the gateway process -----------------------------------------------------------


def _log_path() -> Path:
    return S.run_dir / f"gateway-{S.launch}.log"


def start_gateway() -> None:
    """Launch ``bin/portico-gateway run`` in its own session and wait for the ready line."""
    S.launch += 1
    env = {k: v for k, v in os.environ.items() if k not in ("VIRTUAL_ENV", "UV_PROJECT_ENVIRONMENT")}
    env.update(PORTICO_HOME=str(S.home), CLAUDE_CONFIG_DIR=str(S.cli_config))
    with _log_path().open("ab") as log:
        proc = subprocess.Popen(
            [str(REPO_ROOT / "bin" / "portico-gateway"), "run", "--port", "0", "--state", str(S.home)],
            cwd=str(REPO_ROOT / "gateway"),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            start_new_session=True,
        )
    deadline = time.monotonic() + 60
    port = 0
    while not port and time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"gateway exited early with {proc.returncode}; see {_log_path()}")
        for line in _log_path().read_text(errors="replace").splitlines():
            if line.startswith(f"{READY_PREFIX} port="):
                port = int(line.split("=", 1)[1])
                break
        time.sleep(0.1)
    if not port:
        proc.kill()
        raise RuntimeError(f"gateway did not print {READY_PREFIX} within 60s; see {_log_path()}")
    S.proc = proc
    S.port = port
    S.token = (S.home / "token").read_text(encoding="ascii").strip()
    ledger = json.loads((S.home / "ledger.json").read_text(encoding="utf-8"))
    assert ledger["pid"] == proc.pid and ledger["port"] == port, ledger
    note(f"gateway launch {S.launch}: pid {proc.pid} port {port}")


def stop_gateway_if_alive() -> None:
    proc = S.proc
    if proc is None or proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        proc.kill()


@pytest.fixture(scope="module")
def gateway(tmp_path_factory: pytest.TempPathFactory) -> Iterator[None]:
    S.run_dir = tmp_path_factory.mktemp("check5")
    S.home = S.run_dir / "home"
    S.folder1 = S.run_dir / "folder"
    S.folder2 = S.run_dir / "folder2"
    S.cli_config = S.run_dir / "cli-config"
    for d in (S.home, S.folder1, S.folder2, S.cli_config):
        d.mkdir()
    for folder in (S.folder1, S.folder2):
        (folder / "CLAUDE.md").write_text(
            "This is a throwaway test folder. Do exactly what the message asks, briefly. "
            "Never ask questions; never use AskUserQuestion.\n",
            encoding="utf-8",
        )
    start_gateway()
    try:
        yield
    finally:
        stop_gateway_if_alive()


# --- websocket helpers -------------------------------------------------------------


async def send(conn: ClientConnection, msg: object) -> None:
    await conn.send(dump(msg))


async def recv_until(conn: ClientConnection, pred: Callable[[ServerMessage], bool], timeout: float) -> list[ServerMessage]:
    """Every frame up to and including the first for which ``pred`` holds; a gateway ``error`` fails."""
    got: list[ServerMessage] = []
    deadline = asyncio.get_running_loop().time() + timeout
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        assert remaining > 0, f"timed out after {timeout}s waiting; got {[type(m).__name__ for m in got]}"
        msg = await recv(conn, remaining)
        got.append(msg)
        assert not isinstance(msg, Error), f"gateway error: {msg.code}: {msg.message}"
        if pred(msg):
            return got


async def drain(conn: ClientConnection, seconds: float) -> list[ServerMessage]:
    """Whatever arrives in ``seconds``; used to prove nothing more comes."""
    got: list[ServerMessage] = []
    deadline = asyncio.get_running_loop().time() + seconds
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        if remaining <= 0:
            return got
        try:
            got.append(await recv(conn, remaining))
        except TimeoutError:
            return got


async def attach() -> tuple[ClientConnection, HelloServer, ChatList]:
    conn = await connect(f"ws://127.0.0.1:{S.port}{PROTOCOL_PATH}?token={S.token}")
    await send(conn, HelloClient(ts=TS, app_version="0.1.0"))
    hello = await recv(conn, 10.0)
    assert isinstance(hello, HelloServer), hello
    listing = await recv(conn, 10.0)
    assert isinstance(listing, ChatList), listing
    return conn, hello, listing


async def new_chat(conn: ClientConnection, folder: Path, id: str) -> int:
    await send(conn, ChatNew(ts=TS, id=id, folder=str(folder)))
    state = await recv(conn, NEW_CHAT_TIMEOUT)
    assert isinstance(state, ChatState) and state.state == "idle" and state.id == id, state
    listing = await recv(conn, 10.0)
    assert isinstance(listing, ChatList), listing
    return state.chat


def is_finished(chat: int) -> Callable[[ServerMessage], bool]:
    return lambda m: isinstance(m, TurnFinished) and m.chat == chat


def reply_text(events: list[ServerMessage], chat: int) -> str:
    return "".join(e.text for e in events if isinstance(e, TextDelta) and e.chat == chat)


def seqs_of(events: list[ServerMessage], chat: int) -> list[int]:
    return [e.seq for e in events if getattr(e, "chat", None) == chat and e.seq is not None]


def last_seq(events: list[ServerMessage], chat: int) -> int | None:
    seqs = seqs_of(events, chat)
    return max(seqs) if seqs else None


def assert_gapless(seqs: list[int], start_after: int) -> None:
    assert seqs == list(range(start_after + 1, start_after + 1 + len(seqs))), (start_after, seqs)


async def allow_once(conn: ClientConnection, card: CardAsk) -> None:
    await send(conn, CardAnswer(ts=TS, chat=card.chat, id=card.id, answer={"decision": "allow"}, scope="once"))


async def run_turn(conn: ClientConnection, chat: int, text: str, timeout: float = TURN_TIMEOUT) -> list[ServerMessage]:
    """Send ``text`` and collect to ``turn.finished`` plus the ``chat.state`` after it; allow any permission once."""
    await send(conn, MessageSend(ts=TS, chat=chat, text=text))
    got: list[ServerMessage] = []
    deadline = asyncio.get_running_loop().time() + timeout
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        assert remaining > 0, f"turn did not finish within {timeout}s: {[type(m).__name__ for m in got]}"
        msg = await recv(conn, remaining)
        got.append(msg)
        assert not isinstance(msg, Error), f"gateway error during turn: {msg.code}: {msg.message}"
        if isinstance(msg, CardAsk) and msg.chat == chat and msg.kind == "permission":
            await allow_once(conn, msg)
        if isinstance(msg, TurnFinished) and msg.chat == chat:
            after = await recv(conn, 10.0)
            got.append(after)
            assert isinstance(after, ChatState) and after.chat == chat, after
            return got


async def until_card(
    conn: ClientConnection, chat: int, want: Callable[[CardAsk], bool], seen: list[ServerMessage]
) -> CardAsk | None:
    """Read until a permission card satisfying ``want`` (answering others once), or ``None`` if the turn ends first."""
    while True:
        got = await recv_until(conn, lambda m: (isinstance(m, CardAsk) and m.chat == chat) or is_finished(chat)(m), TURN_TIMEOUT)
        seen.extend(got)
        m = got[-1]
        if isinstance(m, TurnFinished):
            seen.append(await recv(conn, 10.0))  # the chat.state after it
            return None
        assert isinstance(m, CardAsk)
        if m.kind == "permission" and want(m):
            return m
        note(f"card {m.id} ({m.kind}, {m.title}) came first; allowed once")
        seen.append(await recv(conn, 10.0))  # chat.state waiting on you
        await allow_once(conn, m)
        seen.extend(await recv_until(conn, lambda x: isinstance(x, ChatState) and x.state == "working", 10.0))


# =====================================================================================
# (a) turn.stop interrupts a running turn
# =====================================================================================


async def test_a_turn_stop_interrupts_a_running_turn(gateway: None) -> None:
    conn, hello, listing = await attach()
    S.epoch = hello.epoch
    try:
        assert listing.chats == [], "expected a fresh state directory with no chats"
        S.chat1 = await new_chat(conn, S.folder1, "new-1")
        chat = S.chat1

        await send(conn, MessageSend(ts=TS, chat=chat, text=COUNT_PROMPT))
        head = await recv_until(conn, lambda m: isinstance(m, ChatState) and m.state == "working", 30.0)
        assert [type(m) for m in head] == [TurnStarted, UserText, ChatState], head
        assert isinstance(head[0], TurnStarted) and head[0].turn == 1

        # A few deltas, then stop.
        deltas: list[TextDelta] = []
        seen = list(head)
        while len(deltas) < 3:
            m = await recv(conn, TURN_TIMEOUT)
            seen.append(m)
            assert not isinstance(m, Error), f"gateway error: {m.code}: {m.message}"
            assert not isinstance(m, CardAsk), f"unexpected card while counting: {m}"
            assert not isinstance(m, TurnFinished), f"the turn finished before three deltas arrived: {reply_text(seen, chat)!r}"
            if isinstance(m, TextDelta):
                deltas.append(m)
        t0 = time.monotonic()
        await send(conn, TurnStop(ts=TS, chat=chat))
        tail = await recv_until(conn, is_finished(chat), 30.0)
        stop_seconds = time.monotonic() - t0
        seen.extend(tail)
        finished = tail[-1]
        assert isinstance(finished, TurnFinished) and finished.outcome == "stopped" and finished.turn == 1, finished
        after = await recv(conn, 10.0)
        seen.append(after)
        # PROTOCOL.md turn.stop: the chat returns to idle (the word ``stopped`` belongs to chat.stop).
        assert isinstance(after, ChatState) and after.state == "idle", after
        assert stop_seconds < 20, f"stop took {stop_seconds:.1f}s (the grace is 15s)"
        note(f"(a) turn.stop -> turn.finished stopped in {stop_seconds:.2f}s after {len(deltas)} deltas")

        # Nothing of turn 1 trickles in afterwards.
        late = await drain(conn, 3.0)
        assert not [m for m in late if getattr(m, "turn", None) == 1], late
        assert_gapless(seqs_of(seen + late, chat), 1)  # chat.state idle from chat.new is seq 1
        S.last_seq1 = last_seq(seen + late, chat)
        S.turns1 = 1
    finally:
        await conn.close()


async def test_a2_chat_stop_gives_stopped_then_the_next_send_resumes(gateway: None) -> None:
    """The ``stopped`` state word is chat.stop's: the engine is closed and the next send restarts it."""
    assert S.chat1 is not None and S.last_seq1 is not None, "needs (a)"
    chat = S.chat1
    conn, _, listing = await attach()
    try:
        assert [c.state for c in listing.chats if c.chat == chat] == ["idle"], listing
        await send(conn, MessageSend(ts=TS, chat=chat, text=COUNT_PROMPT))
        seen = await recv_until(conn, lambda m: isinstance(m, TextDelta), TURN_TIMEOUT)
        assert isinstance(seen[0], TurnStarted) and seen[0].turn == 2, seen[0]
        await send(conn, ChatStop(ts=TS, chat=chat))
        tail = await recv_until(conn, is_finished(chat), 30.0)
        seen.extend(tail)
        assert isinstance(tail[-1], TurnFinished) and tail[-1].outcome == "stopped" and tail[-1].turn == 2
        after = await recv(conn, 10.0)
        seen.append(after)
        assert isinstance(after, ChatState) and after.state == "stopped", after
        late = await drain(conn, 2.0)
        seen.extend(late)
        assert not [m for m in late if getattr(m, "turn", None) == 2], late

        # The next send restarts the engine on the same session: idle -> working as usual.
        events = await run_turn(conn, chat, "Reply with exactly the word OKAY and nothing else.")
        seen.extend(events)
        assert isinstance(events[0], TurnStarted) and events[0].turn == 3, events[0]
        assert isinstance(events[-2], TurnFinished) and events[-2].outcome == "done", events[-2]
        assert isinstance(events[-1], ChatState) and events[-1].state == "idle"
        assert "OKAY" in reply_text(events, chat).upper(), reply_text(events, chat)
        assert_gapless(seqs_of(seen, chat), S.last_seq1)
        S.last_seq1 = last_seq(seen, chat)
        S.turns1 = 3
    finally:
        await conn.close()


# =====================================================================================
# (b) Detach mid-turn; the gateway keeps going; reattach replays gaplessly
# =====================================================================================

WRITE_PROMPT = (
    "Write the files a.md, b.md and c.md in this folder, each containing only its own file name. "
    "Use the Write tool, one file at a time in that order, waiting for each write to finish before starting the next. "
    "Do not ask questions. When done, reply with one short line."
)


def is_write_card(card: CardAsk) -> bool:
    return card.permission is not None and card.permission.tool == "Write"


async def test_b_detach_mid_turn_then_reattach_replays_gaplessly(gateway: None) -> None:
    assert S.chat1 is not None and S.last_seq1 is not None, "needs (a)"
    chat = S.chat1
    conn, _, _ = await attach()
    seen: list[ServerMessage] = []
    try:
        await send(conn, MessageSend(ts=TS, chat=chat, text=WRITE_PROMPT))
        card = await until_card(conn, chat, is_write_card, seen)
        if card is None:
            note("(b) the model finished without a Write card; retrying once with a more explicit prompt")
            S.turns1 += 1
            await send(conn, MessageSend(ts=TS, chat=chat, text="Use the Write tool now. " + WRITE_PROMPT))
            card = await until_card(conn, chat, is_write_card, seen)
        assert card is not None, f"no Write permission card was asked; reply {reply_text(seen, chat)!r}"
        assert card.permission is not None and card.permission.summary.endswith("a.md"), card.permission.summary
        state = await recv(conn, 10.0)
        seen.append(state)
        assert isinstance(state, ChatState) and state.state == "waiting on you", state

        # Allow for this chat: later writes in this chat need no card.
        await send(conn, CardAnswer(ts=TS, chat=chat, id=card.id, answer={"decision": "allow"}, scope="chat"))
        seen += await recv_until(conn, lambda m: isinstance(m, ChatState) and m.state == "working", 10.0)
        assert isinstance(seen[-2], CardAnswered) and seen[-2].id == card.id, seen[-2]

        # Stay until the first write lands, so the detach is demonstrably mid-turn. A card asked
        # in parallel before the chat-scoped allow was recorded is answered once and noted.
        extra_cards = 0
        while True:
            m = await recv(conn, 60.0)
            seen.append(m)
            assert not isinstance(m, Error), f"gateway error: {m.code}: {m.message}"
            assert not isinstance(m, TurnFinished), "the turn finished before we could detach; the task was too fast"
            if isinstance(m, CardAsk) and m.chat == chat:
                extra_cards += 1
                await allow_once(conn, m)
            if isinstance(m, ToolFinished) and m.chat == chat:
                break
        if extra_cards:
            note(f"(b) {extra_cards} further permission card(s) were asked before the chat-scoped allow landed; allowed once")
        before_detach = last_seq(seen, chat)
        assert before_detach is not None
        assert_gapless(seqs_of(seen, chat), S.last_seq1)
    finally:
        await conn.close()

    note(f"(b) detached at seq {before_detach} with the turn running; waiting {DETACH_B_SECONDS:.0f}s")
    await asyncio.sleep(DETACH_B_SECONDS)
    assert S.proc is not None and S.proc.poll() is None, "the gateway process died while detached"

    again, _, listing = await attach()
    try:
        note(f"(b) on reattach chat.list shows chat {chat} {[c.state for c in listing.chats if c.chat == chat]}")
        await send(again, ChatOpen(ts=TS, chat=chat, since=before_detach, id="open-b"))
        history = await recv(again, 30.0)
        assert isinstance(history, ChatHistory) and history.id == "open-b" and not history.truncated, history
        seqs = [e.seq for e in history.events]
        assert all(s is not None for s in seqs), "ring events must carry seq"
        assert_gapless([s for s in seqs if s is not None], before_detach)
        assert not any(isinstance(e, CardAsk) for e in history.events), "no card expected after the chat-scoped allow"
        replay: list[ServerMessage] = list(history.events)
        live = await recv(again, 10.0)
        assert isinstance(live, ChatLive) and live.seq == (seqs[-1] if seqs else before_detach), (live, seqs[-1:])
        if not any(isinstance(e, TurnFinished) for e in history.events):
            note("(b) turn still running at reattach; reading live to the finish")
            more = await recv_until(again, is_finished(chat), TURN_TIMEOUT)
            more.append(await recv(again, 10.0))
            replay += more
        assert_gapless(seqs_of(replay, chat), before_detach)
        fin = [e for e in replay if isinstance(e, TurnFinished)]
        assert len(fin) == 1 and fin[0].outcome == "done" and fin[0].turn == S.turns1 + 1, (fin, S.turns1)
        assert isinstance(replay[-1], ChatState) and replay[-1].state == "idle", replay[-1]
        arts = [e.artifact for e in replay if isinstance(e, ArtifactCreated)]
        names = sorted(Path(a.location).name for a in arts)
        assert names == ["a.md", "b.md", "c.md"], names
        assert all(a.source == "tool" and a.media == "markdown" and a.kind == "file" for a in arts), arts
        assert sum(1 for a in arts if a.open) == 1 and arts[-1].open, "the newest viewable artifact is the one that opens"
        idx_fin = replay.index(fin[0])
        assert all(replay.index(e) < idx_fin for e in replay if isinstance(e, ArtifactCreated)), "artifacts come before turn.finished"
        for name in ("a.md", "b.md", "c.md"):
            assert name in (S.folder1 / name).read_text(encoding="utf-8"), name
        nothing = await drain(again, 1.0)
        assert not nothing, f"unexpected frames after chat.live: {nothing}"
        rs = seqs_of(replay, chat)

        # Continue the chat.
        events = await run_turn(again, chat, "Reply with exactly the word PONG and nothing else.")
        assert isinstance(events[-2], TurnFinished) and events[-2].outcome == "done" and events[-2].turn == S.turns1 + 2
        assert "PONG" in reply_text(events, chat).upper(), reply_text(events, chat)
        assert_gapless(seqs_of(events, chat), rs[-1])
        S.last_seq1 = last_seq(events, chat)
        S.turns1 += 2
    finally:
        await again.close()


# =====================================================================================
# (c) A card asked while detached is waiting on reopen
# =====================================================================================

# Write was allowed for this chat in (b), and a chat-scoped allow lasts as long as the gateway
# runs, so a plain Write would not ask again. Bash asks: its chat-scoped allows are keyed on
# the command, and none was given.
HELD_PROMPT = (
    "Using the Bash tool, run exactly this one command and nothing else:  printf HELD > held.md  "
    "Do not use the Write tool. Do not read or check the file afterwards. Do not ask questions. "
    "Then reply with one short line."
)


def is_held_card(card: CardAsk) -> bool:
    return card.permission is not None and "held.md" in card.permission.summary


async def test_c_a_card_asked_while_detached_is_replayed_on_reopen(gateway: None) -> None:
    assert S.chat1 is not None and S.last_seq1 is not None, "needs (a)/(b)"
    chat = S.chat1
    conn, _, _ = await attach()
    seen: list[ServerMessage] = []
    try:
        await send(conn, MessageSend(ts=TS, chat=chat, text=HELD_PROMPT))
        card = await until_card(conn, chat, is_held_card, seen)
        if card is None:
            note(f"(c) the model finished without a held.md card (reply {reply_text(seen, chat)!r}); retrying once")
            S.turns1 += 1
            assert not (S.folder1 / "held.md").exists(), "held.md exists although no permission card was asked"
            await send(conn, MessageSend(ts=TS, chat=chat, text="Use the Bash tool now. " + HELD_PROMPT))
            card = await until_card(conn, chat, is_held_card, seen)
        assert card is not None, f"no permission card for held.md was asked; reply {reply_text(seen, chat)!r}"
        before_card = seqs_of(seen, chat)[-2]  # the seq just before the card.ask
        assert card.seq == before_card + 1
        waiting = await recv(conn, 10.0)
        seen.append(waiting)
        assert isinstance(waiting, ChatState) and waiting.state == "waiting on you", waiting
        assert_gapless(seqs_of(seen, chat), S.last_seq1)
    finally:
        # Close WITHOUT answering.
        await conn.close()

    note(f"(c) detached with card {card.id} (seq {card.seq}) open; waiting {DETACH_C_SECONDS:.0f}s")
    await asyncio.sleep(DETACH_C_SECONDS)
    assert S.proc is not None and S.proc.poll() is None, "the gateway process died while detached"
    assert not (S.folder1 / "held.md").exists(), "held.md was written while nobody allowed it"

    again, _, listing = await attach()
    try:
        assert [c.state for c in listing.chats if c.chat == chat] == ["waiting on you"], listing
        await send(again, ChatOpen(ts=TS, chat=chat, since=before_card, id="open-c"))
        history = await recv(again, 30.0)
        assert isinstance(history, ChatHistory) and not history.truncated, history
        assert_gapless([e.seq for e in history.events if e.seq is not None], before_card)
        assert [type(e) for e in history.events] == [CardAsk, ChatState], history.events
        replayed = history.events[0]
        assert isinstance(replayed, CardAsk) and replayed.id == card.id and replayed.seq == card.seq
        assert isinstance(history.events[1], ChatState) and history.events[1].state == "waiting on you"
        live = await recv(again, 10.0)
        assert isinstance(live, ChatLive) and live.seq == history.events[-1].seq, live
        # The open card again, after chat.live, unchanged.
        pinned = await recv(again, 10.0)
        assert isinstance(pinned, CardAsk) and pinned.id == card.id and pinned.seq == card.seq, pinned
        nothing = await drain(again, 1.0)
        assert not nothing, nothing

        await send(again, CardAnswer(ts=TS, chat=chat, id=card.id, answer={"decision": "allow"}, scope="once"))
        tail: list[ServerMessage] = []
        while True:
            m = await recv(again, TURN_TIMEOUT)
            tail.append(m)
            assert not isinstance(m, Error), f"gateway error: {m.code}: {m.message}"
            if isinstance(m, CardAsk) and m.chat == chat:
                await allow_once(again, m)
            if is_finished(chat)(m):
                break
        tail.append(await recv(again, 10.0))
        assert isinstance(tail[0], CardAnswered) and tail[0].id == card.id, tail[0]
        assert isinstance(tail[1], ChatState) and tail[1].state == "working", tail[1]
        assert isinstance(tail[-2], TurnFinished) and tail[-2].outcome == "done", tail[-2]
        assert isinstance(tail[-1], ChatState) and tail[-1].state == "idle"
        tools = [e for e in tail if isinstance(e, ToolFinished)]
        assert tools and all(t.ok for t in tools), tools
        assert not any(isinstance(e, CardCancel) for e in tail), tail
        assert (S.folder1 / "held.md").read_text(encoding="utf-8").strip() == "HELD"
        assert_gapless(seqs_of(tail, chat), live.seq or 0)
        S.last_seq1 = last_seq(tail, chat)
        S.turns1 += 1
    finally:
        await again.close()


# =====================================================================================
# (d) Two chats open at once, each with its own state word
# =====================================================================================


async def test_d_two_chats_each_with_their_own_state_word(gateway: None) -> None:
    assert S.chat1 is not None, "needs (a)"
    c1 = S.chat1
    conn, _, _ = await attach()
    try:
        S.chat2 = await new_chat(conn, S.folder2, "new-2")
        c2 = S.chat2
        assert c2 == c1 + 1, (c1, c2)

        await send(conn, MessageSend(ts=TS, chat=c1, text="Count slowly from 1 to 80, one number per line, in your reply."))
        head = await recv_until(conn, lambda m: isinstance(m, ChatState) and m.chat == c1 and m.state == "working", 30.0)
        assert isinstance(head[0], TurnStarted) and head[0].chat == c1

        # A chat.list snapshot while chat 1 works: chat.alias is the protocol's way to ask for one.
        await send(conn, ChatAlias(ts=TS, chat=c2, alias="probe"))
        got = await recv_until(conn, lambda m: isinstance(m, ChatList), 30.0)
        listing = got[-1]
        assert isinstance(listing, ChatList)
        words = {c.chat: c.state for c in listing.chats}
        assert words[c1] == "working" and words[c2] == "idle", words
        assert [c.alias for c in listing.chats if c.chat == c2] == ["probe"]

        # A turn in chat 2 while chat 1 still runs; both finish, both idle.
        await send(conn, MessageSend(ts=TS, chat=c2, text="Reply with exactly the word TWO and nothing else."))
        finished: dict[int, TurnFinished] = {}
        idle: dict[int, ChatState] = {}
        all_events: list[ServerMessage] = list(got[:-1])
        deadline = asyncio.get_running_loop().time() + TURN_TIMEOUT
        while len(idle) < 2:
            remaining = deadline - asyncio.get_running_loop().time()
            assert remaining > 0, f"both turns did not finish: finished={list(finished)} idle={list(idle)}"
            m = await recv(conn, remaining)
            all_events.append(m)
            assert not isinstance(m, Error), f"gateway error: {m.code}: {m.message}"
            if isinstance(m, CardAsk):
                await allow_once(conn, m)
            if isinstance(m, TurnFinished):
                finished[m.chat] = m
            if isinstance(m, ChatState) and m.state == "idle" and m.chat in finished:
                idle[m.chat] = m
        assert finished[c1].outcome == "done" and finished[c2].outcome == "done", finished
        assert "TWO" in reply_text(all_events, c2).upper(), reply_text(all_events, c2)
        assert_gapless(seqs_of(all_events, c2), 1)  # chat 2: seq 1 was its chat.state idle on chat.new

        await send(conn, ChatAlias(ts=TS, chat=c2))
        got = await recv_until(conn, lambda m: isinstance(m, ChatList), 30.0)
        listing = got[-1]
        assert isinstance(listing, ChatList)
        assert {c.chat: c.state for c in listing.chats} == {c1: "idle", c2: "idle"}
        S.last_seq1 = last_seq(all_events, c1) or S.last_seq1
        S.turns1 += 1
    finally:
        await conn.close()


# =====================================================================================
# (e) gateway.stop, start again, history from the transcript, the session resumes
# =====================================================================================


async def test_e_a_restart_replays_the_transcript_and_resumes_the_session(gateway: None) -> None:
    assert S.chat1 is not None and S.chat2 is not None, "needs (a)-(d)"
    c1, c2 = S.chat1, S.chat2
    old_epoch = S.epoch
    old_proc = S.proc
    assert old_proc is not None

    conn, _, _ = await attach()
    closed_code: int | None = None
    status_lines: list[str] = []
    try:
        await send(conn, GatewayStop(ts=TS))
        try:
            while True:
                m = await recv(conn, 60.0)
                if isinstance(m, StatusSet):
                    status_lines.append(m.text)
        except ConnectionClosed as closed:
            closed_code = closed.rcvd.code if closed.rcvd else None
    finally:
        await conn.close()
    assert closed_code == 1001, f"expected close code 1001, got {closed_code}; status lines {status_lines}"
    assert not status_lines, f"no turn was running; expected no status lines, got {status_lines}"
    assert old_proc.wait(timeout=60) == 0, f"gateway exit code {old_proc.returncode}"
    assert not (S.home / "ledger.json").exists(), "the ledger must be removed on a clean stop"
    index = json.loads((S.home / "index.json").read_text(encoding="utf-8"))
    assert sorted(c["chat"] for c in index["chats"]) == [c1, c2], index
    assert all(c["session_id"] for c in index["chats"]), "both chats must remember their engine session"

    start_gateway()
    conn, hello, listing = await attach()
    try:
        assert hello.epoch != old_epoch
        S.epoch = hello.epoch
        assert sorted(c.chat for c in listing.chats) == [c1, c2], listing
        assert all(c.state == "idle" for c in listing.chats), listing

        await send(conn, ChatOpen(ts=TS, chat=c1, id="open-e"))
        history = await recv(conn, 60.0)
        assert isinstance(history, ChatHistory) and history.id == "open-e" and not history.truncated, history
        assert history.events, "the transcript replay must not be empty"
        assert all(e.seq is None for e in history.events), "transcript events carry no seq"
        user_texts = [e.text for e in history.events if isinstance(e, UserText)]
        assert any("a.md" in t and "b.md" in t for t in user_texts), user_texts
        assert any("held.md" in t for t in user_texts), user_texts
        assert any("PONG" in t for t in user_texts), user_texts
        assistant = "".join(e.text for e in history.events if isinstance(e, TextDelta))
        assert "PONG" in assistant.upper() and "OKAY" in assistant.upper(), assistant[:500]
        writes = [e for e in history.events if isinstance(e, ToolStarted) and e.tool == "Write"]
        assert {Path(str(w.input.get("file_path", ""))).name for w in writes} >= {"a.md", "b.md", "c.md"}, writes
        starts = [e for e in history.events if isinstance(e, TurnStarted)]
        fins = [e for e in history.events if isinstance(e, TurnFinished)]
        assert len(starts) == len(fins) and all(f.outcome == "done" for f in fins), (len(starts), len(fins))
        assert [s.turn for s in starts] == list(range(1, len(starts) + 1)), [s.turn for s in starts]
        replayed_turns = len(starts)

        # Then the stored artifacts, open=false, then chat.live at seq 0.
        arts: list[ArtifactCreated] = []
        while True:
            m = await recv(conn, 10.0)
            if isinstance(m, ArtifactCreated):
                arts.append(m)
                continue
            assert isinstance(m, ChatLive) and m.chat == c1 and m.seq == 0, m
            break
        names = sorted(Path(a.artifact.location).name for a in arts)
        assert set(names) >= {"a.md", "b.md", "c.md"}, names
        assert all(not a.artifact.open and a.seq is None for a in arts), arts
        nothing = await drain(conn, 1.0)
        assert not nothing, nothing
        note(f"(e) transcript replay: {len(history.events)} events, {replayed_turns} turns (launch 1 ran {S.turns1})")

        # Continue: the engine resumes the session and remembers the files.
        events = await run_turn(conn, c1, "Which files did you create earlier in this conversation? List their names only.")
        assert isinstance(events[0], TurnStarted) and events[0].turn == replayed_turns + 1, (events[0], replayed_turns)
        assert isinstance(events[-2], TurnFinished) and events[-2].outcome == "done", events[-2]
        reply = reply_text(events, c1)
        for name in ("a.md", "b.md", "c.md"):
            assert name in reply, f"{name!r} not in reply: {reply!r}"
        assert_gapless(seqs_of(events, c1), 0)
    finally:
        await conn.close()
