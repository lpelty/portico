"""Task 2: the state directory — token, ledger, index, lock."""

import json
import os
import stat
from pathlib import Path

import pytest

from portico_gateway.messages import Artifact
from portico_gateway.state import ChatRecord, Index, Ledger, StateDir, StateError


@pytest.fixture
def state(tmp_path: Path) -> StateDir:
    return StateDir(tmp_path / "portico-home")


def test_paths_live_under_the_state_dir(state: StateDir, tmp_path: Path) -> None:
    home = tmp_path / "portico-home"
    assert state.path == home
    assert home.is_dir()
    assert state.token_path == home / "token"
    assert state.ledger_path == home / "ledger.json"
    assert state.index_path == home / "index.json"
    assert state.lock_path == home / "gateway.lock"
    assert state.config_path == home / "config.toml"


def test_token_is_0600_and_rotates(state: StateDir) -> None:
    assert state.read_token() is None

    first = state.write_token()
    assert isinstance(first, str) and len(first) >= 32
    assert state.read_token() == first
    assert stat.S_IMODE(state.token_path.stat().st_mode) == 0o600

    # Loosen the mode behind the gateway's back; the next write restores 0600.
    os.chmod(state.token_path, 0o644)
    second = state.write_token()
    assert second != first
    assert state.read_token() == second
    assert stat.S_IMODE(state.token_path.stat().st_mode) == 0o600

    # A token is one line of URL-safe text, nothing a shell would choke on.
    assert state.token_path.read_text() == second + "\n"
    assert "\n" not in second and " " not in second


def test_ledger_round_trip(state: StateDir) -> None:
    assert state.read_ledger() is None

    state.write_ledger(host="127.0.0.1", port=45123, pid=4242, epoch="7f1c4a2e-3b5d-4c6e-9a8b-0d1e2f3a4b5c")
    ledger = state.read_ledger()
    assert ledger == Ledger(
        host="127.0.0.1", port=45123, pid=4242, epoch="7f1c4a2e-3b5d-4c6e-9a8b-0d1e2f3a4b5c"
    )

    # The file is plain JSON another tool (the app, doctor) can read directly.
    on_disk = json.loads(state.ledger_path.read_text())
    assert on_disk == {"host": "127.0.0.1", "port": 45123, "pid": 4242, "epoch": "7f1c4a2e-3b5d-4c6e-9a8b-0d1e2f3a4b5c"}

    # A ledger is a hint, never trusted: garbage reads as "no ledger".
    state.ledger_path.write_text("{not json")
    assert state.read_ledger() is None
    state.ledger_path.write_text('{"host": "127.0.0.1"}')
    assert state.read_ledger() is None


def test_index_atomic_save_and_load_defaults(state: StateDir) -> None:
    index = state.load_index()
    assert index == Index()
    assert index.chats == [] and index.next_chat == 1
    assert not state.index_path.exists()  # loading defaults writes nothing

    artifact = Artifact(
        id="art-1",
        kind="file",
        location="/Users/someone/projects/demo/summary.md",
        media="markdown",
        title="summary.md",
        source="tool",
        open=True,
    )
    index.chats.append(
        ChatRecord(
            chat=1,
            folder="/Users/someone/projects/demo",
            session_id="sess-1",
            alias="report draft",
            state="idle",
            created="2026-10-27T12:00:00Z",
            artifacts=[artifact],
        )
    )
    index.chats.append(
        ChatRecord(chat=2, folder="/Users/someone/projects/other", state="stopped", created="2026-10-27T12:01:00Z")
    )
    index.next_chat = 3
    state.save_index(index)

    assert state.load_index() == index
    reloaded = state.load_index()
    assert reloaded.chats[1].session_id is None
    assert reloaded.chats[1].alias is None
    assert reloaded.chats[1].artifacts == []
    assert reloaded.chats[0].artifacts[0] == artifact

    # Atomic: the write goes through a rename, so no temp file lingers and the
    # final file is complete JSON.
    leftovers = [p for p in state.path.iterdir() if p.name not in {"index.json"}]
    assert leftovers == []
    json.loads(state.index_path.read_text())


def test_corrupt_index_is_an_error_not_a_silent_reset(state: StateDir) -> None:
    # Silently resetting would re-number chats from 1 and collide with folders
    # the engine already has sessions for; say so instead.
    state.index_path.write_text("{this is not json")
    with pytest.raises(StateError) as e:
        state.load_index()
    assert "index.json" in str(e.value)


def test_second_lock_fails(tmp_path: Path) -> None:
    home = tmp_path / "portico-home"
    first = StateDir(home)
    second = StateDir(home)

    assert first.acquire_lock() is True
    assert second.acquire_lock() is False

    first.release_lock()
    assert second.acquire_lock() is True
    second.release_lock()


def test_portico_home_env_overrides(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    override = tmp_path / "elsewhere"
    monkeypatch.setenv("PORTICO_HOME", str(override))
    assert StateDir().path == override
    assert override.is_dir()

    monkeypatch.delenv("PORTICO_HOME")
    monkeypatch.setenv("HOME", str(tmp_path / "fake-home"))
    assert StateDir().path == tmp_path / "fake-home" / ".portico"

    # An explicit path wins over both.
    explicit = tmp_path / "explicit"
    monkeypatch.setenv("PORTICO_HOME", str(override))
    assert StateDir(explicit).path == explicit
