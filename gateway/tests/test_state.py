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


def test_index_with_an_unknown_state_word_is_a_state_error(state: StateDir) -> None:
    # A hand-edited index ("Idle", "running") must refuse to start with the
    # same plain line as corrupt JSON, not a traceback from the registry.
    state.index_path.write_text(
        json.dumps(
            {
                "chats": [
                    {"chat": 1, "folder": "/Users/someone/projects/demo", "state": "Idle", "created": "2026-10-27T12:00:00Z"}
                ],
                "next_chat": 2,
            }
        )
    )
    with pytest.raises(StateError) as e:
        state.load_index()
    assert "index.json" in str(e.value) and "Move it aside" in str(e.value)

    # The record itself refuses any word outside the protocol's four.
    for bad in ("Idle", "running", "", "waiting_on_you"):
        with pytest.raises(ValueError):
            ChatRecord(chat=1, folder="/x", state=bad, created="2026-10-27T12:00:00Z")  # type: ignore[arg-type]
    for word in ("idle", "working", "waiting on you", "stopped"):
        assert ChatRecord(chat=1, folder="/x", state=word, created="2026-10-27T12:00:00Z").state == word


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


# --- v0.17 §5: the home folder chosen at install -------------------------------------


def fake_checkout(root: Path) -> Path:
    """A directory that looks like a Portico checkout to ``state.py``: it has ``bin/portico-gateway``."""
    (root / "bin").mkdir(parents=True)
    (root / "bin" / "portico-gateway").write_text("#!/bin/sh\n")
    return root


def test_home_order(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import portico_gateway.state as state_module

    checkout = fake_checkout(tmp_path / "checkout")
    monkeypatch.setattr(state_module, "REPO_ROOT", checkout)
    monkeypatch.setenv("HOME", str(tmp_path / "fake-home"))
    home_file = checkout / ".portico-home"
    home_file.write_text("/tmp/acme/app\n")

    # PORTICO_HOME first, over the checkout's file.
    monkeypatch.setenv("PORTICO_HOME", str(tmp_path / "from-env"))
    assert StateDir.default_path() == tmp_path / "from-env"
    assert StateDir.default_source() == "PORTICO_HOME"

    # Then the checkout's .portico-home.
    monkeypatch.delenv("PORTICO_HOME")
    assert StateDir.default_path() == Path("/tmp/acme/app")
    assert StateDir.default_source() == ".portico-home"

    # An empty file is no folder: ~/.portico.
    home_file.write_text("\n")
    assert StateDir.default_path() == tmp_path / "fake-home" / ".portico"
    assert StateDir.default_source() == "the default"

    # No file: ~/.portico.
    home_file.unlink()
    assert StateDir.default_path() == tmp_path / "fake-home" / ".portico"
    assert StateDir.default_source() == "the default"
    assert not (tmp_path / "fake-home").exists()  # resolving creates nothing


def test_the_home_file_is_read_only_in_a_checkout(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import portico_gateway.state as state_module

    not_a_checkout = tmp_path / "site-packages"
    not_a_checkout.mkdir()
    (not_a_checkout / ".portico-home").write_text("/tmp/acme/app\n")
    monkeypatch.setattr(state_module, "REPO_ROOT", not_a_checkout)
    monkeypatch.delenv("PORTICO_HOME", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path / "fake-home"))
    assert StateDir.default_path() == tmp_path / "fake-home" / ".portico"


def test_index_stores_state_folder_paths_relative_and_loads_old_absolute_ones(tmp_path: Path) -> None:
    folder = tmp_path / "portico-home"
    state = StateDir(folder)
    inside = str(folder / "spaces" / "plan.md")
    outside = "/Users/someone/projects/demo/summary.md"
    index = Index(
        chats=[
            ChatRecord(
                chat=1,
                folder=str(folder / "spaces"),
                state="idle",
                created="2026-11-02T12:00:00Z",
                artifacts=[
                    Artifact(id="a", kind="file", location=inside, media="markdown", title="plan.md", source="tool", open=True),
                    Artifact(id="b", kind="file", location=outside, media="markdown", title="summary.md", source="tool", open=True),
                ],
            )
        ],
        next_chat=2,
    )
    state.save_index(index)
    on_disk = json.loads(state.index_path.read_text())
    chat = on_disk["chats"][0]
    assert chat["folder"] == "@state/spaces"
    assert chat["artifacts"][0]["location"] == "@state/spaces/plan.md"
    assert chat["artifacts"][1]["location"] == outside  # outside the folder: as it was
    assert state.load_index() == index

    # An index from before v0.17 holds absolute paths: it loads as written.
    old = {
        "chats": [
            {
                "chat": 1,
                "folder": str(folder / "spaces"),
                "state": "idle",
                "created": "2026-11-02T12:00:00Z",
                "artifacts": [
                    {"id": "a", "kind": "file", "location": inside, "media": "markdown", "title": "plan.md", "source": "tool", "open": True}
                ],
            }
        ],
        "next_chat": 2,
    }
    state.index_path.write_text(json.dumps(old))
    loaded = state.load_index()
    assert loaded.chats[0].folder == str(folder / "spaces")
    assert loaded.chats[0].artifacts[0].location == inside


async def test_no_absolute_state_paths_survive_a_move(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from portico_gateway import __version__
    from portico_gateway.chats import ChatRegistry
    from portico_gateway.messages import ChatNew, dump
    from portico_gateway.server import GatewayServer
    from tests.conftest import make_config
    from tests.test_server import TS
    from tests.test_spaces import frames_until, hello
    from tests.test_turns import EngineFactory

    a = tmp_path / "a"
    monkeypatch.setenv("PORTICO_HOME", str(a))
    work = tmp_path / "work"
    work.mkdir()

    state_a = StateDir(a)
    config = make_config(setting_sources=["project"])
    registry = ChatRegistry(index=state_a.load_index(), state=state_a, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_a, registry=registry, engine_factory=EngineFactory(), version=__version__)
    page = a / "spaces" / "plan.md"
    page.parent.mkdir(parents=True, exist_ok=True)
    page.write_text("---\ntitle: Plan\n---\n", encoding="utf-8")
    await srv.serve(0)
    try:
        assert state_a.token_path.is_file() and state_a.ledger_path.is_file()
        conn = await hello(srv)
        try:
            await conn.send(dump(ChatNew(ts=TS, id="req-new", folder=str(work))))
            number = (await frames_until(conn, "chat.state")).chat
            assert await srv.show_files(srv.registry.get(number), [str(page)]) is None
            await frames_until(conn, "artifact.created")
        finally:
            await conn.close()
    finally:
        await srv.shutdown()

    for name in ("index.json", "ledger.json", "token"):
        path = a / name
        if path.exists():
            text = path.read_text(encoding="utf-8")
            assert str(a) not in text and str(a.resolve()) not in text, f"{name} holds the folder's absolute path"

    b = tmp_path / "b"
    a.rename(b)
    monkeypatch.setenv("PORTICO_HOME", str(b))
    state_b = StateDir(b)
    registry_b = ChatRegistry(index=state_b.load_index(), state=state_b, history_buffer=config.history_buffer)
    srv_b = GatewayServer(config=make_config(setting_sources=["project"]), state=state_b, registry=registry_b, engine_factory=EngineFactory(), version=__version__)
    await srv_b.serve(0)
    try:
        locations = [art.location for art in srv_b.registry.get(number).artifacts]
        assert str((b / "spaces" / "plan.md").resolve()) in locations
    finally:
        await srv_b.shutdown()
