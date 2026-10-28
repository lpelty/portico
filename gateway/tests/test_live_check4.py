"""Check 4 (done-when), the gateway half, against the live model.

(a) a markdown report written by the model: one ``artifact.created kind=file media=markdown
    open=true`` for ``report.md``, sent at turn end (after the last tool or text event,
    before ``turn.finished``) and replayed by ``chat.open``.
(b) an HTML page plus a static server on a local port: a ``kind=url open=true`` artifact
    for the URL in the reply, the HTML file listed too but not opened (the URL is newer).
(c) the producer endpoint mid-turn: ``artifact.created`` at once, ``open=true``, not
    repeated at turn end.
(d) the D15 edge: a reply that merely names an existing viewable path reports it from text.

Gated exactly like ``tests/test_live_smoke.py``: ``PORTICO_LIVE=1`` and a provider
credential in the environment; skipped otherwise. The real ``GatewayServer`` runs
in-process on ``SDKEngine`` (the smoke's ``server`` fixture).

Run once here: ``PORTICO_LIVE=1 uv run pytest tests/test_live_check4.py -v``

Left to a person: the report rendered and the URL shown in the viewer, and the
auto-open-off setting keeping the next artifact in the history only (an app setting; the
gateway reports ``open`` the same either way).
"""

from __future__ import annotations

import asyncio
import os
import socket
import subprocess
import time
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection

from portico_gateway.doctor import has_credential
from portico_gateway.messages import (
    ArtifactCreated,
    CardAnswer,
    CardAsk,
    ChatHistory,
    ChatLive,
    ChatOpen,
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
from tests.test_artifacts import http_post
from tests.test_live_smoke import isolated_cli_config, new_chat, reply_text, server  # noqa: F401 — the smoke's fixtures
from tests.test_server import attach
from tests.test_turns import recv

pytestmark = pytest.mark.skipif(
    os.environ.get("PORTICO_LIVE") != "1" or not has_credential(os.environ),
    reason="live check 4: set PORTICO_LIVE=1 and a provider credential in the environment",
)

TS = "2026-10-28T12:00:00Z"
TURN_TIMEOUT = 180.0


# --- fixtures -----------------------------------------------------------------


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    """A throwaway chat folder whose ``CLAUDE.md`` asks for brief, literal, question-free work."""
    folder = tmp_path / "project"
    folder.mkdir()
    (folder / "CLAUDE.md").write_text(
        "This is a throwaway test folder. Do exactly what the message asks, briefly, and never ask questions.\n",
        encoding="utf-8",
    )
    return folder


@pytest.fixture
def free_port() -> int:
    """A port nothing listens on right now, for the page the model serves; its listener is killed afterwards."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    yield port
    for pid in listeners_on(port):
        subprocess.run(["kill", str(pid)], check=False)


def listeners_on(port: int) -> list[int]:
    out = subprocess.run(["lsof", "-ti", f"tcp:{port}", "-sTCP:LISTEN"], capture_output=True, text=True)
    return [int(p) for p in out.stdout.split()]


# --- helpers ------------------------------------------------------------------


async def run_turn(conn: ClientConnection, chat: int, text: str, *, on_event=None, timeout: float = TURN_TIMEOUT) -> list[ServerMessage]:
    """Send ``text``; collect every frame to ``turn.finished`` (the idle state after it is drained); allow every permission once."""
    await conn.send(dump(MessageSend(ts=TS, chat=chat, text=text)))
    got: list[ServerMessage] = []
    deadline = asyncio.get_running_loop().time() + timeout
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        assert remaining > 0, f"turn did not finish within {timeout}s: {describe(got)}"
        msg = await recv(conn, remaining)
        got.append(msg)
        assert not isinstance(msg, Error), f"the gateway refused something mid-turn: {msg}"
        if isinstance(msg, CardAsk) and msg.kind == "permission":
            await conn.send(dump(CardAnswer(ts=TS, chat=chat, id=msg.id, answer={"decision": "allow"}, scope="once")))
        if on_event is not None:
            await on_event(msg)
        if isinstance(msg, TurnFinished) and msg.chat == chat:
            idle = await recv(conn, 10.0)
            assert isinstance(idle, ChatState) and idle.state == "idle", idle
            return got


def describe(events: list[ServerMessage]) -> list[str]:
    out = []
    for e in events:
        seq = getattr(e, "seq", None)
        if isinstance(e, TextDelta):
            out.append(f"text.delta seq={seq} {e.text[:60]!r}")
        elif isinstance(e, ToolStarted):
            out.append(f"tool.started seq={seq} {e.tool} {e.summary[:80]!r}")
        elif isinstance(e, ToolFinished):
            out.append(f"tool.finished seq={seq} ok={e.ok} {e.summary[:80]!r}")
        elif isinstance(e, ArtifactCreated):
            a = e.artifact
            out.append(f"artifact.created seq={seq} kind={a.kind} media={a.media} source={a.source} open={a.open} location={a.location}")
        else:
            out.append(f"{e.type} seq={seq}")
    return out


def artifacts_in(events: list[ServerMessage]) -> list[ArtifactCreated]:
    return [e for e in events if isinstance(e, ArtifactCreated)]


def assert_artifacts_at_turn_end(events: list[ServerMessage]) -> None:
    """Every ``artifact.created`` of the turn sits after the last tool or text event and before ``turn.finished``."""
    kinds = [type(e) for e in events]
    assert kinds[-1] is TurnFinished, kinds
    art_idx = [i for i, k in enumerate(kinds) if k is ArtifactCreated]
    busy_idx = [i for i, k in enumerate(kinds) if k in (ToolStarted, ToolFinished, TextDelta)]
    assert art_idx, "no artifact.created in the turn"
    assert min(art_idx) > max(busy_idx), describe(events)


async def open_chat(conn: ClientConnection, chat: int) -> tuple[ChatHistory, list[ArtifactCreated], ChatLive]:
    """``chat.open`` from the beginning: the history, any stored artifacts, then ``chat.live``."""
    await conn.send(dump(ChatOpen(ts=TS, chat=chat, id="req-open")))
    history = await recv(conn, 10.0)
    assert isinstance(history, ChatHistory), history
    stored: list[ArtifactCreated] = []
    while True:
        msg = await recv(conn, 10.0)
        if isinstance(msg, ChatLive):
            return history, stored, msg
        assert isinstance(msg, ArtifactCreated), msg
        stored.append(msg)


# --- (a) markdown report -------------------------------------------------------


async def test_a_markdown_report_opens_at_turn_end_and_replays(server: GatewayServer, folder: Path) -> None:
    conn = await attach(server)
    try:
        chat = await new_chat(conn, folder)
        events = await run_turn(
            conn, chat,
            "Write a short markdown report to report.md in this folder with a heading and two bullets, "
            "using the Write tool. Do not ask questions. Reply with one short sentence.",
        )
        if not (folder / "report.md").is_file():
            events = await run_turn(
                conn, chat,
                "Use the Write tool now to create the file report.md here containing:\n# Report\n\n- first\n- second\n\nThen reply done.",
            )
        assert isinstance(events[-1], TurnFinished) and events[-1].outcome == "done", describe(events)
        assert (folder / "report.md").is_file(), "the model did not write report.md"

        created = artifacts_in(events)
        reports = [e for e in created if e.artifact.location.endswith("report.md")]
        assert len(reports) == 1, describe(events)
        art = reports[0].artifact
        assert art.kind == "file" and art.media == "markdown" and art.open is True, art
        assert art.source in ("tool", "text"), art
        assert reports[0].seq is not None
        assert [e.artifact.open for e in created].count(True) == 1, describe(events)
        assert_artifacts_at_turn_end(events)
        seqs = [e.seq for e in events if getattr(e, "seq", None) is not None]
        assert seqs == sorted(seqs) and len(set(seqs)) == len(seqs), seqs

        # Replay: chat.open from the beginning carries the artifact.created in chat.history, from the ring.
        history, stored, live = await open_chat(conn, chat)
        replayed = [e for e in history.events if isinstance(e, ArtifactCreated)]
        assert [e.artifact.id for e in replayed] == [art.id], describe(history.events)
        assert replayed[0].seq == reports[0].seq
        assert stored == []  # same launch: served from the ring, not the index
        assert live.seq == server.registry.get(chat).seq
    finally:
        await conn.close()


# --- (b) HTML page served from a local port --------------------------------------


async def test_b_html_page_and_local_url_open(server: GatewayServer, folder: Path, free_port: int) -> None:
    url = f"http://127.0.0.1:{free_port}/"
    serve = f"nohup python3 -m http.server {free_port} --bind 127.0.0.1 >/dev/null 2>&1 &"
    conn = await attach(server)
    try:
        chat = await new_chat(conn, folder)
        events = await run_turn(
            conn, chat,
            "Do these two things and do not ask questions. "
            "1) Use the Write tool to create index.html in this folder containing the text HELLO PORTICO. "
            f"2) Run this exact Bash command to start a static server in the background: {serve} "
            f"Then reply with exactly: Served at {url}",
            timeout=240.0,
        )
        if not [e for e in artifacts_in(events) if e.artifact.kind == "url"] or not (folder / "index.html").is_file():
            events = await run_turn(
                conn, chat,
                "Use the Write tool to write index.html here with content <h1>HELLO PORTICO</h1>. "
                f"Then run the Bash command: {serve}\n"
                f"Finally reply with this exact text and nothing else: The page is at {url}",
            )
        assert isinstance(events[-1], TurnFinished), describe(events)
        assert (folder / "index.html").is_file(), "the model did not write index.html"
        assert "HELLO PORTICO" in (folder / "index.html").read_text(encoding="utf-8")

        created = artifacts_in(events)
        url_arts = [e for e in created if e.artifact.kind == "url"]
        assert len(url_arts) == 1, describe(events)
        page = url_arts[0].artifact
        assert page.location in (url, url.rstrip("/")), page
        assert page.media == "url" and page.source == "text" and page.open is True, page
        html = [e for e in created if e.artifact.location.endswith("index.html")]
        assert len(html) == 1, describe(events)
        assert html[0].artifact.kind == "file" and html[0].artifact.media == "html" and html[0].artifact.open is False
        assert [e.artifact.open for e in created].count(True) == 1
        assert_artifacts_at_turn_end(events)
        # The URL is the newest viewable: it comes after the HTML file in the list.
        assert created.index(html[0]) < created.index(url_arts[0])
    finally:
        await conn.close()


# --- (c) producer endpoint mid-turn ------------------------------------------------


async def test_c_producer_mid_turn_opens_immediately(server: GatewayServer, folder: Path, tmp_path: Path) -> None:
    produced = tmp_path / "produced" / "producer-note.md"
    produced.parent.mkdir()
    produced.write_text("# From a producer\n\nposted mid-turn\n", encoding="utf-8")
    conn = await attach(server)
    try:
        chat = await new_chat(conn, folder)
        posted: dict = {}

        async def on_event(msg: ServerMessage) -> None:
            # Post while the model's Bash sleep is running (after the tool started, before it finished).
            if isinstance(msg, ToolStarted) and msg.tool == "Bash" and not posted:
                status, body = await http_post(
                    server.port, "/v1/artifact", {"chat": chat, "location": str(produced), "title": "Producer note"}, server.token
                )
                posted.update(status=status, body=body, after_seq=msg.seq)

        events = await run_turn(
            conn, chat, "Run this exact Bash command: sleep 12 — then reply with exactly: SLEPT. Do not ask questions.", on_event=on_event
        )
        assert posted, f"no Bash tool.started seen, so the producer was never posted mid-turn: {describe(events)}"
        assert posted["status"] == 201, posted
        created = artifacts_in(events)
        producer = [e for e in created if e.artifact.source == "producer"]
        assert len(producer) == 1, describe(events)
        art = producer[0].artifact
        assert art.kind == "file" and art.media == "markdown" and art.open is True and art.title == "Producer note", art
        assert art.location == str(produced) and posted["body"]["artifact"]["id"] == art.id
        # Immediate: it arrived before the Bash tool.finished, so before turn.finished.
        assert events.index(producer[0]) < next(i for i, e in enumerate(events) if isinstance(e, ToolFinished)), describe(events)
        assert producer[0].seq is not None and producer[0].seq > posted["after_seq"]
        # No turn-end artifact for a turn that wrote nothing: the producer's is recorded once, not repeated.
        assert len(created) == 1, describe(events)
        assert [a.id for a in server.registry.get(chat).artifacts] == [art.id]
    finally:
        await conn.close()


# --- (d) D15 edge: prose that names an existing viewable path ------------------------


async def test_d_prose_naming_an_existing_viewable_path_reports_it(server: GatewayServer, folder: Path) -> None:
    existing = folder / "report.md"
    existing.write_text("# Existing\n\nmade by the test, not the model\n", encoding="utf-8")
    conn = await attach(server)
    try:
        chat = await new_chat(conn, folder)
        events = await run_turn(conn, chat, "Reply with exactly this text and nothing else, using no tools: Look at report.md")
        if "report.md" not in reply_text(events):
            events = await run_turn(conn, chat, "Without reading or writing anything, output exactly these three words: Look at report.md")
        assert "report.md" in reply_text(events), reply_text(events)
        created = artifacts_in(events)
        assert len(created) == 1, describe(events)
        art = created[0].artifact
        assert art.kind == "file" and art.location == str(existing) and art.media == "markdown", art
        assert art.source == "text" and art.open is True, art
        assert_artifacts_at_turn_end(events)
    finally:
        await conn.close()
