"""Check 9 (done-when), the gateway half: a configured root, ``files.list``, an attached file
read by the agent.

Gated exactly like ``tests/test_live_smoke.py``: ``PORTICO_LIVE=1`` and a provider
credential in the environment; skipped otherwise. The real ``GatewayServer`` runs
in-process on ``SDKEngine`` with a ``config.toml`` written into the test's state
directory, the way a deployment configures a root. One test per assertion group:

- (a) ``hello`` carries the root; ``files.list`` on the root and on ``notes/`` in the
  documented shape; escapes and unknowns refused with the documented codes
- (b) an attached file reaches the engine in the exact ``user.text`` form and the agent reads it
- (c) a missing attachment (and a directory, and a relative path) is refused with
  ``attachment.missing`` before any turn starts, and the chat stays usable
- (d) a path with a space and a path with unicode are both read

Run once here: ``PORTICO_LIVE=1 uv run pytest tests/test_live_check9.py -v``

Left to a person: browsing the tree, the file in the viewer, and "Add to chat" in the window.
"""

from __future__ import annotations

import asyncio
import json
import os
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection, connect

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import load_config
from portico_gateway.doctor import has_credential
from portico_gateway.engine import SDKEngine
from portico_gateway.messages import (
    CardAnswer,
    CardAsk,
    ChatList,
    ChatState,
    Error,
    FilesList,
    FilesListRequest,
    HelloClient,
    HelloServer,
    MessageSend,
    ServerMessage,
    ToolFinished,
    ToolStarted,
    TurnFinished,
    TurnStarted,
    UserText,
    dump,
    parse_server,
)
from portico_gateway.server import PROTOCOL_PATH, GatewayServer
from portico_gateway.state import StateDir
from tests.test_live_smoke import isolated_cli_config, new_chat, reply_text  # noqa: F401 — the smoke's fixture and helpers
from tests.test_turns import recv

pytestmark = pytest.mark.skipif(
    os.environ.get("PORTICO_LIVE") != "1" or not has_credential(os.environ),
    reason="live check 9: set PORTICO_LIVE=1 and a provider credential in the environment",
)

TS = "2026-10-28T12:00:00Z"
TURN_TIMEOUT = 180.0
PASSWORD = "QUINCE"
FRUIT = "MEDLAR"
COLOUR = "CERULEAN"


# --- fixtures -----------------------------------------------------------------


class Vault:
    """The configured root: ``notes/`` with a plain, a spaced and a unicode file, each holding one word."""

    def __init__(self, path: Path) -> None:
        self.path = path
        notes = path / "notes"
        notes.mkdir(parents=True)
        self.alpha = notes / "alpha.md"
        self.spaced = notes / "with space.md"
        self.unicode = notes / "ünïcödé-名前.md"
        self.alpha.write_text(f"The password word is {PASSWORD}.\n", encoding="utf-8")
        self.spaced.write_text(f"The fruit word is {FRUIT}.\n", encoding="utf-8")
        self.unicode.write_text(f"The colour word is {COLOUR}.\n", encoding="utf-8")


@pytest.fixture
def vault(tmp_path: Path) -> Vault:
    return Vault(tmp_path / "vault")


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    folder = tmp_path / "project"
    folder.mkdir()
    (folder / "CLAUDE.md").write_text(
        "You are a terse test agent. Follow the instruction exactly; reply in one short line; never ask questions.\n",
        encoding="utf-8",
    )
    return folder


@pytest.fixture
async def server(state_dir: StateDir, isolated_cli_config: Path, vault: Vault) -> AsyncIterator[GatewayServer]:
    """Like the smoke's server, but on a ``config.toml`` in the state directory that names one root, ``vault``."""
    state_dir.path.mkdir(parents=True, exist_ok=True)
    state_dir.config_path.write_text(
        'presentation = "multiple"\npermission_mode = "default"\n'
        '[brand]\nname = "Portico"\nagent_name = "Agent"\n\n[[roots]]\nname = "vault"\npath = ' + json.dumps(str(vault.path)) + "\n",
        encoding="utf-8",
    )
    config = load_config(state_dir.config_path)
    assert [r.name for r in config.roots] == ["vault"], config.roots
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=SDKEngine, version=__version__)
    await srv.serve(0)
    try:
        yield srv
    finally:
        await srv.shutdown()


# --- helpers ------------------------------------------------------------------


async def attach_raw(server: GatewayServer) -> tuple[ClientConnection, HelloServer, dict]:
    """Connect and hello; returns the parsed hello plus its raw JSON, for shape checks."""
    conn = await connect(f"ws://127.0.0.1:{server.port}{PROTOCOL_PATH}?token={server.token}")
    await conn.send(dump(HelloClient(ts=TS, app_version="0.1.0")))
    raw_hello = await asyncio.wait_for(conn.recv(), 10.0)
    hello = parse_server(raw_hello)
    assert isinstance(hello, HelloServer), hello
    listing = await recv(conn, 10.0)
    assert isinstance(listing, ChatList), listing
    return conn, hello, json.loads(raw_hello)


async def run_turn(conn: ClientConnection, chat: int, text: str, attachments: list[str]) -> list[ServerMessage]:
    """Send with ``attachments``; collect every event to ``turn.finished``; allow any permission card once."""
    await conn.send(dump(MessageSend(ts=TS, chat=chat, id="req-send", text=text, attachments=attachments)))
    got: list[ServerMessage] = []
    deadline = asyncio.get_running_loop().time() + TURN_TIMEOUT
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        assert remaining > 0, f"turn did not finish within {TURN_TIMEOUT}s: {got}"
        msg = await recv(conn, remaining)
        got.append(msg)
        assert not isinstance(msg, Error), f"the gateway refused the send: {msg}"
        if isinstance(msg, CardAsk) and msg.kind == "permission":
            await conn.send(dump(CardAnswer(ts=TS, chat=chat, id=msg.id, answer={"decision": "allow"}, scope="once")))
        if isinstance(msg, TurnFinished) and msg.chat == chat:
            return got


def reads_of(events: list[ServerMessage], path: Path) -> list[tuple[ToolStarted, ToolFinished | None]]:
    """Every ``tool.started`` Read of ``path`` paired with its ``tool.finished`` (by ``tool_use_id``)."""
    finished = {e.tool_use_id: e for e in events if isinstance(e, ToolFinished)}
    return [
        (e, finished.get(e.tool_use_id))
        for e in events
        if isinstance(e, ToolStarted) and e.tool == "Read" and e.input.get("file_path") == str(path)
    ]


def describe(events: list[ServerMessage]) -> str:
    rows = []
    for e in events:
        if isinstance(e, ToolStarted):
            rows.append(f"{e.type} seq={e.seq} {e.tool} {e.summary}")
        elif isinstance(e, ToolFinished):
            rows.append(f"{e.type} seq={e.seq} ok={e.ok} {e.summary[:60]!r}")
        else:
            rows.append(f"{e.type} seq={getattr(e, 'seq', None)}")
    return "\n".join(rows)


async def turn_with_retry(
    conn: ClientConnection, chat: int, prompts: list[str], attachments: list[str], want: list[str], paths: list[Path]
) -> list[ServerMessage]:
    """Try each prompt in turn until the reply carries every ``want`` word and every path was read; else the last turn."""
    last: list[ServerMessage] = []
    for prompt in prompts:
        last = await run_turn(conn, chat, prompt, attachments)
        text = reply_text(last)
        if all(w in text for w in want) and all(reads_of(last, p) for p in paths):
            return last
        state = await recv(conn, 10.0)  # the idle after a turn that did not satisfy; the next prompt follows
        assert isinstance(state, ChatState) and state.state == "idle", state
    return last


# --- (a) hello + files.list -------------------------------------------------


async def test_a_hello_carries_the_root_and_files_list_has_the_documented_shape(server: GatewayServer, vault: Vault) -> None:
    conn, hello, raw = await attach_raw(server)
    try:
        assert hello.protocol == 1
        assert [(r.name, r.path) for r in hello.roots] == [("vault", str(vault.path))]
        assert raw["roots"] == [{"name": "vault", "path": str(vault.path)}]
        assert "files" in hello.capabilities

        # The root itself: one directory, no files, no hidden entries.
        await conn.send(dump(FilesListRequest(ts=TS, id="req-root", root="vault", path="")))
        raw_reply = await asyncio.wait_for(conn.recv(), 10.0)
        reply = parse_server(raw_reply)
        assert isinstance(reply, FilesList), reply
        assert (reply.id, reply.root, reply.path) == ("req-root", "vault", "")
        assert [(e.name, e.dir, e.size) for e in reply.entries] == [("notes", True, None)]
        j = json.loads(raw_reply)
        assert set(j) == {"type", "id", "ts", "root", "path", "entries"}, j  # no chat, no seq: a direct reply
        assert j["entries"] == [{"name": "notes", "dir": True}], j  # size absent on a directory, not null

        # notes/: three files, case-insensitive name order, size in bytes on each.
        await conn.send(dump(FilesListRequest(ts=TS, id="req-notes", root="vault", path="notes")))
        raw_reply = await asyncio.wait_for(conn.recv(), 10.0)
        reply = parse_server(raw_reply)
        assert isinstance(reply, FilesList), reply
        assert (reply.id, reply.root, reply.path) == ("req-notes", "vault", "notes")
        expected = sorted(
            [(p.name, False, p.stat().st_size) for p in (vault.alpha, vault.spaced, vault.unicode)], key=lambda t: t[0].casefold()
        )
        assert [(e.name, e.dir, e.size) for e in reply.entries] == expected
        assert all(set(e) == {"name", "dir", "size"} for e in json.loads(raw_reply)["entries"]), raw_reply

        # A trailing slash and a dotted form normalise to the same listing.
        await conn.send(dump(FilesListRequest(ts=TS, id="req-notes2", root="vault", path="./notes/")))
        again = await recv(conn, 10.0)
        assert isinstance(again, FilesList) and again.path == "notes" and again.entries == reply.entries, again

        # Escapes and unknowns are refused with the documented codes.
        for req_id, root, path, code in (
            ("req-up", "vault", "..", "files.outside_root"),
            ("req-nf", "vault", "nope", "files.not_found"),
            ("req-ur", "attic", "", "files.unknown_root"),
        ):
            await conn.send(dump(FilesListRequest(ts=TS, id=req_id, root=root, path=path)))
            err = await recv(conn, 10.0)
            assert isinstance(err, Error) and err.code == code and err.id == req_id, err
    finally:
        await conn.close()


# --- (b) the attached file is read ------------------------------------------


async def test_b_an_attached_file_is_read_by_the_agent(server: GatewayServer, vault: Vault, folder: Path) -> None:
    conn, _hello, _raw = await attach_raw(server)
    try:
        chat = await new_chat(conn, folder)
        events = await turn_with_retry(
            conn, chat,
            [
                "Read the attached file and reply with only the password word it contains.",
                f"Use the Read tool on the file {vault.alpha} and reply with only the password word written in it. Do not ask questions.",
            ],
            [str(vault.alpha)], [PASSWORD], [vault.alpha],
        )
        # The gateway's side: turn.started, user.text in the exact protocol form, working, ..., finished done, idle.
        assert isinstance(events[0], TurnStarted), events[0]
        user = events[1]
        assert isinstance(user, UserText), user
        assert user.text.endswith(f"\n\nAttached files:\n- {vault.alpha}"), user.text
        assert isinstance(events[2], ChatState) and events[2].state == "working", events[2]
        assert isinstance(events[-1], TurnFinished) and events[-1].outcome == "done", events[-1]
        seqs = [e.seq for e in events if getattr(e, "seq", None) is not None]
        assert seqs == sorted(seqs) and len(set(seqs)) == len(seqs), seqs

        reads = reads_of(events, vault.alpha)
        assert reads, f"no tool.started Read of {vault.alpha}:\n{describe(events)}"
        started, done = reads[0]
        assert started.summary == str(vault.alpha), started
        assert done is not None and done.ok, (started, done)
        assert PASSWORD in reply_text(events), reply_text(events)

        state = await recv(conn, 10.0)
        assert isinstance(state, ChatState) and state.state == "idle", state
    finally:
        await conn.close()


# --- (c) a missing attachment is refused before any turn ---------------------


async def test_c_a_missing_attachment_is_refused_before_any_turn(server: GatewayServer, vault: Vault, folder: Path) -> None:
    conn, _hello, _raw = await attach_raw(server)
    try:
        chat = await new_chat(conn, folder)
        missing = str(vault.path / "notes" / "does-not-exist.md")
        await conn.send(dump(MessageSend(ts=TS, chat=chat, id="req-miss", text="Read the attached file.", attachments=[str(vault.alpha), missing])))
        raw = await asyncio.wait_for(conn.recv(), 10.0)
        err = parse_server(raw)
        assert isinstance(err, Error) and err.code == "attachment.missing", err
        assert err.id == "req-miss" and err.chat == chat, err
        assert missing in err.message, err.message
        assert "seq" not in json.loads(raw), raw  # a refusal is a reply, not history
        # Nothing else arrives: no turn.started, no user.text, no state change.
        with pytest.raises(TimeoutError):
            await recv(conn, 5.0)

        # A directory and a relative path are refused the same way.
        for req_id, attachment in (("req-dir", str(vault.path / "notes")), ("req-rel", "notes/alpha.md")):
            await conn.send(dump(MessageSend(ts=TS, chat=chat, id=req_id, text="Read it.", attachments=[attachment])))
            err = await recv(conn, 10.0)
            assert isinstance(err, Error) and err.code == "attachment.missing" and err.id == req_id, err
            with pytest.raises(TimeoutError):
                await recv(conn, 3.0)

        # The chat is still idle and usable: a valid send after the refusals starts turn 1, not 2.
        await conn.send(dump(MessageSend(ts=TS, chat=chat, id="req-ok", text="Reply with exactly the word READY and nothing else.")))
        started = await recv(conn, 10.0)
        assert isinstance(started, TurnStarted) and started.turn == 1, started
        got: list[ServerMessage] = [started]
        deadline = asyncio.get_running_loop().time() + TURN_TIMEOUT
        while not isinstance(got[-1], TurnFinished):
            got.append(await recv(conn, max(1.0, deadline - asyncio.get_running_loop().time())))
        assert got[-1].outcome == "done", got[-1]
    finally:
        await conn.close()


# --- (d) a spaced path and a unicode path are both read ----------------------


async def test_d_a_spaced_path_and_a_unicode_path_are_both_read(server: GatewayServer, vault: Vault, folder: Path) -> None:
    conn, _hello, _raw = await attach_raw(server)
    try:
        chat = await new_chat(conn, folder)
        events = await turn_with_retry(
            conn, chat,
            [
                "Read both attached files and reply with only the fruit word and the colour word they contain, separated by a space.",
                f"Use the Read tool on each of these two files: {vault.spaced} and {vault.unicode}. Then reply with only the fruit word "
                "from the first and the colour word from the second, separated by a space. Do not ask questions.",
            ],
            [str(vault.spaced), str(vault.unicode)], [FRUIT, COLOUR], [vault.spaced, vault.unicode],
        )
        user = events[1]
        assert isinstance(user, UserText), user
        assert user.text.endswith(f"\n\nAttached files:\n- {vault.spaced}\n- {vault.unicode}"), user.text
        for path in (vault.spaced, vault.unicode):
            reads = reads_of(events, path)
            assert reads, f"no tool.started Read of {path}:\n{describe(events)}"
            started, done = reads[0]
            assert started.summary == str(path), started
            assert done is not None and done.ok, (started, done)
        text = reply_text(events)
        assert FRUIT in text and COLOUR in text, text
        assert isinstance(events[-1], TurnFinished) and events[-1].outcome == "done", events[-1]
    finally:
        await conn.close()
