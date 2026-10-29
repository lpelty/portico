"""Check 1 (done-when), the window-free half: a fresh clone through ``bin/install`` and
``bin/doctor``, a detached gateway with its ready line and ledger, one streamed reply over
the protocol, the token gate, and ``gateway.stop`` exiting and clearing the ledger.

Gated exactly like ``tests/test_live_smoke.py``: ``PORTICO_LIVE=1`` and a provider
credential in the environment; skipped otherwise. The clone is ``git clone`` of this
repository's HEAD into pytest's temporary directory, so what is tested is what a person
would get, not this working tree. The gateway is the clone's ``bin/portico-gateway run``
in its own session, a process this test does not own the event loop of; the tests run in
file order and share it through module fixtures.

Run once here: ``PORTICO_LIVE=1 uv run pytest tests/test_live_check1.py -v``

Left to a person: the real window (``swift run``), picking a folder in it, and the reply
streaming on screen. ``bin/install`` builds the app here when ``swift`` is on PATH, so the
clone compiles; it is not run.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection, connect
from websockets.exceptions import ConnectionClosed, InvalidStatus

from portico_gateway import REPO_ROOT
from portico_gateway.doctor import has_credential
from portico_gateway.messages import (
    ChatList,
    ChatNew,
    ChatState,
    Error,
    GatewayStop,
    HelloClient,
    HelloServer,
    MessageSend,
    ServerMessage,
    TextDelta,
    TurnFinished,
    TurnStarted,
    UserText,
    dump,
)
from portico_gateway.server import PROTOCOL_PATH, READY_PREFIX
from tests.test_server import http_get
from tests.test_turns import recv

pytestmark = pytest.mark.skipif(
    os.environ.get("PORTICO_LIVE") != "1" or not has_credential(os.environ),
    reason="live check 1: set PORTICO_LIVE=1 and a provider credential in the environment",
)

TS = "2026-10-28T12:00:00Z"
PROMPT = "Reply with the single word PORTICO and nothing else."
TURN_TIMEOUT = 180.0
NEW_CHAT_TIMEOUT = 90.0


# --- the clone and its gateway ----------------------------------------------------


def _subprocess_env(**extra: str) -> dict[str, str]:
    """The test's environment for the clone's own tools: the outer ``uv run`` venv must not leak in."""
    env = {k: v for k, v in os.environ.items() if k not in ("VIRTUAL_ENV", "UV_PROJECT_ENVIRONMENT")}
    env.update(extra)
    return env


@pytest.fixture(scope="module")
def clone(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """``git clone`` of HEAD, then ``bin/install`` (``uv sync``, and ``swift build -c release`` when swift is there)."""
    root = tmp_path_factory.mktemp("check1")
    clone = root / "clone"
    subprocess.run(["git", "clone", "--quiet", str(REPO_ROOT), str(clone)], check=True, capture_output=True)
    log = root / "install.log"
    with log.open("wb") as out:
        result = subprocess.run(
            [str(clone / "bin" / "install")],
            cwd=clone,
            env=_subprocess_env(),
            stdin=subprocess.DEVNULL,
            stdout=out,
            stderr=subprocess.STDOUT,
            timeout=600,
        )
    assert result.returncode == 0, f"bin/install failed in the clone; see {log}"
    assert (clone / "gateway" / ".venv" / "bin" / "portico-gateway").is_file(), "install left no gateway CLI"
    if shutil.which("swift"):
        assert (clone / "app" / ".build" / "release" / "Portico").is_file(), f"install built no app; see {log}"
    return clone


@dataclass
class Gateway:
    """The clone's detached gateway: its process, where it listens, and the state directory it uses."""

    clone: Path
    home: Path
    folder: Path
    log: Path
    proc: subprocess.Popen[bytes]
    port: int = 0
    token: str = ""
    epoch: str = ""
    chats: list[int] = field(default_factory=list)


@pytest.fixture(scope="module")
def gateway(clone: Path, tmp_path_factory: pytest.TempPathFactory) -> Gateway:
    """``bin/portico-gateway run`` from the clone in its own session, with a scratch state directory."""
    root = tmp_path_factory.mktemp("check1-run")
    home, folder, cli_config = root / "home", root / "throwaway-folder", root / "cli-config"
    for d in (home, folder, cli_config):
        d.mkdir()
    (folder / "CLAUDE.md").write_text("This is a throwaway test folder. Do exactly what the message asks.\n", encoding="utf-8")
    # The done-when checks predate v0.3's defaults: a list of chats, and a card for every step.
    (home / "config.toml").write_text('presentation = "multiple"\npermission_mode = "default"\n', encoding="utf-8")
    log = root / "gateway.log"
    with log.open("ab") as out:
        proc = subprocess.Popen(
            [str(clone / "bin" / "portico-gateway"), "run", "--port", "0", "--state", str(home)],
            cwd=clone,
            env=_subprocess_env(PORTICO_HOME=str(home), CLAUDE_CONFIG_DIR=str(cli_config)),
            stdin=subprocess.DEVNULL,
            stdout=out,
            stderr=out,
            start_new_session=True,
        )
    gw = Gateway(clone=clone, home=home, folder=folder, log=log, proc=proc)
    try:
        yield gw
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                proc.kill()


def ready_port(gw: Gateway, timeout: float = 60.0) -> int:
    """The port from the ``PORTICO_READY port=<n>`` line on the gateway's stdout."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert gw.proc.poll() is None, f"the gateway exited early with {gw.proc.returncode}; see {gw.log}"
        for line in gw.log.read_text(errors="replace").splitlines():
            if line.startswith(f"{READY_PREFIX} port="):
                return int(line.split("=", 1)[1])
        time.sleep(0.1)
    raise AssertionError(f"no {READY_PREFIX} line within {timeout}s; see {gw.log}")


async def attach(gw: Gateway) -> tuple[ClientConnection, HelloServer, ChatList]:
    conn = await connect(f"ws://127.0.0.1:{gw.port}{PROTOCOL_PATH}?token={gw.token}")
    await conn.send(dump(HelloClient(ts=TS, app_version="0.1.0")))
    hello = await recv(conn, 10.0)
    assert isinstance(hello, HelloServer), hello
    listing = await recv(conn, 10.0)
    assert isinstance(listing, ChatList), listing
    return conn, hello, listing


# --- (a) install and doctor ----------------------------------------------------------


def test_a_doctor_passes_from_the_clone_and_names_a_missing_credential(clone: Path, tmp_path: Path) -> None:
    """``bin/doctor`` in the clone: every check ``ok`` with the credential; exactly the credential line fails without it."""
    home = tmp_path / "home"
    home.mkdir()
    cmd = [str(clone / "bin" / "doctor")]
    with_credential = subprocess.run(
        cmd, env=_subprocess_env(PORTICO_HOME=str(home)), stdin=subprocess.DEVNULL, capture_output=True, text=True
    )
    lines = with_credential.stdout.splitlines()
    assert with_credential.returncode == 0, with_credential.stdout + with_credential.stderr
    assert lines and all(line.startswith("ok ") for line in lines[:-1]), lines
    assert lines[-1].startswith("all ") and lines[-1].endswith("checks passed"), lines[-1]

    # The same environment with every credential variable removed (named by the doctor's own list, not here).
    bare = {k: v for k, v in _subprocess_env(PORTICO_HOME=str(home)).items() if not has_credential({k: v})}
    without = subprocess.run(cmd, env=bare, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    failed = [line for line in without.stdout.splitlines() if line.startswith("FAIL")]
    assert without.returncode == 1, without.stdout + without.stderr
    assert len(failed) == 1 and failed[0].startswith("FAIL credential:"), without.stdout


# --- (b) ready line, ledger, health without a token, websocket 401 without one ------------


async def test_b_ready_line_ledger_health_and_token_gate(gateway: Gateway) -> None:
    gateway.port = ready_port(gateway)
    ledger = json.loads((gateway.home / "ledger.json").read_text(encoding="utf-8"))
    assert ledger["host"] == "127.0.0.1" and ledger["port"] == gateway.port and ledger["pid"] == gateway.proc.pid, ledger
    gateway.epoch = ledger["epoch"]
    token_path = gateway.home / "token"
    assert token_path.stat().st_mode & 0o777 == 0o600, oct(token_path.stat().st_mode)
    gateway.token = token_path.read_text(encoding="ascii").strip()
    assert gateway.token

    status, _headers, body = await http_get(gateway.port, "/v1/health")
    assert status == 200, (status, body)
    health = json.loads(body)
    assert health["protocol"] == 1 and health["epoch"] == gateway.epoch, health

    for url in (
        f"ws://127.0.0.1:{gateway.port}{PROTOCOL_PATH}",
        f"ws://127.0.0.1:{gateway.port}{PROTOCOL_PATH}?token=nope",
    ):
        with pytest.raises(InvalidStatus) as refused:
            async with connect(url):
                pass
        assert refused.value.response.status_code == 401, url


# --- (c) the protocol conversation: a reply streams ------------------------------------------


async def test_c_conversation_streams_a_reply(gateway: Gateway) -> None:
    assert gateway.port and gateway.token, "needs (b)"
    conn, hello, listing = await attach(gateway)
    try:
        assert hello.protocol == 1 and hello.epoch == gateway.epoch, hello
        assert listing.chats == [], listing

        await conn.send(dump(ChatNew(ts=TS, id="req-new", folder=str(gateway.folder))))
        state = await recv(conn, NEW_CHAT_TIMEOUT)
        assert isinstance(state, ChatState) and state.state == "idle" and state.id == "req-new", state
        chat = state.chat
        listing = await recv(conn, 10.0)
        assert isinstance(listing, ChatList) and [c.chat for c in listing.chats] == [chat], listing
        gateway.chats.append(chat)

        await conn.send(dump(MessageSend(ts=TS, chat=chat, id="req-send", text=PROMPT)))
        got: list[ServerMessage] = []
        deadline = asyncio.get_running_loop().time() + TURN_TIMEOUT
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            assert remaining > 0, f"turn did not finish within {TURN_TIMEOUT}s: {[m.type for m in got]}"
            msg = await recv(conn, remaining)
            got.append(msg)
            assert not isinstance(msg, Error), f"the gateway refused something mid-turn: {msg}"
            if isinstance(msg, TurnFinished) and msg.chat == chat:
                break
        after = await recv(conn, 10.0)
        assert isinstance(after, ChatState) and after.state == "idle", after

        assert isinstance(got[0], TurnStarted) and got[0].turn == 1, got[0]
        assert isinstance(got[1], UserText) and got[1].text == PROMPT, got[1]
        assert isinstance(got[2], ChatState) and got[2].state == "working", got[2]
        deltas = [m for m in got if isinstance(m, TextDelta)]
        assert deltas, [m.type for m in got]
        assert "PORTICO" in "".join(d.text for d in deltas), [d.text for d in deltas]
        finished = got[-1]
        assert isinstance(finished, TurnFinished) and finished.outcome == "done" and finished.turn == 1, finished
        seqs = [m.seq for m in got + [after] if getattr(m, "seq", None) is not None]
        assert seqs == list(range(seqs[0], seqs[0] + len(seqs))), seqs
    finally:
        await conn.close()


# --- (d) gateway.stop: the connection closes, the process exits, the ledger is cleared ----------


async def test_d_gateway_stop_exits_and_clears_the_ledger(gateway: Gateway) -> None:
    assert gateway.port and gateway.token, "needs (b)"
    conn, _hello, _listing = await attach(gateway)
    close_code: int | None = None
    try:
        await conn.send(dump(GatewayStop(ts=TS)))
        try:
            while True:
                await recv(conn, 30.0)
        except ConnectionClosed as closed:
            close_code = closed.rcvd.code if closed.rcvd else None
    finally:
        await conn.close()
    assert close_code == 1001, close_code

    assert gateway.proc.wait(timeout=60) == 0, f"gateway exit code {gateway.proc.returncode}; see {gateway.log}"
    assert not (gateway.home / "ledger.json").exists(), "the ledger must be cleared on a clean stop"
    assert (gateway.home / "token").exists() and (gateway.home / "index.json").exists()
    index = json.loads((gateway.home / "index.json").read_text(encoding="utf-8"))
    assert [c["chat"] for c in index["chats"]] == gateway.chats, index
