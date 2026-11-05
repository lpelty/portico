"""v0.12: spaces, files the agent keeps current in the deployment's spaces folder.

The scan, the watcher, rename / remove / refresh, and the pieces of the server
and engine that know about the folder. Model-free; every folder is under
``tmp_path`` and ``HOME`` is faked, so the real Trash is never touched.
"""

from __future__ import annotations

import asyncio
import os
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest

from portico_gateway import __version__
from portico_gateway.artifacts import TurnCollector
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import Config, SpacesConfig
from portico_gateway.engine import SPACES_PROMPT, build_options
from portico_gateway.messages import (
    ArtifactCreated,
    ChatNew,
    Error,
    HelloClient,
    HelloServer,
    SpaceAct,
    SpaceRefresh,
    SpaceRemove,
    SpaceRename,
    SpacesList,
    dump,
    parse_server,
)
from portico_gateway.server import GatewayServer
from portico_gateway.spaces import (
    DEFAULT_ICON,
    Space,
    SpaceError,
    SpacesWatcher,
    act,
    refresh,
    remove,
    rename,
    scan,
    space_id_for,
)
from portico_gateway.state import StateDir
from tests.conftest import RecordingCallbacks, make_config
from tests.test_artifacts import make_chat
from tests.test_server import TS, connect, ws_url
from tests.test_turns import EngineFactory, new_chat, recv

# --- helpers --------------------------------------------------------------------


def put(folder: Path, name: str, text: str = "body\n") -> Path:
    path = folder / name
    path.write_text(text, encoding="utf-8")
    return path


def ids(spaces: list[Space]) -> list[str]:
    return [s.id for s in spaces]


@pytest.fixture
def spaces_dir(tmp_path: Path) -> Path:
    path = tmp_path / "spaces"
    path.mkdir()
    return path


@pytest.fixture
def fake_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    return home


# --- scan -----------------------------------------------------------------------


def test_scan_front_matter_md(spaces_dir: Path) -> None:
    put(
        spaces_dir,
        "meeting-prep.md",
        "---\ntitle: Meeting prep\nicon: calendar-clock     # an SF Symbol\norder: 2\n---\n\n# Today\n",
    )
    [space] = scan(spaces_dir)
    assert space.id == "meeting-prep" and space.title == "Meeting prep"
    assert space.icon == "calendar-clock" and space.order == 2
    assert space.location == str((spaces_dir / "meeting-prep.md").resolve())
    assert space.media == "markdown"
    assert space.updated.endswith("Z") and space.updated.startswith("20")


def test_scan_defaults_icon_and_title(spaces_dir: Path) -> None:
    put(spaces_dir, "brief.markdown", "No front matter.\n")
    [space] = scan(spaces_dir)
    assert (space.id, space.title, space.icon, space.order) == ("brief", "brief", DEFAULT_ICON, None)
    assert DEFAULT_ICON == "doc.text"


def test_scan_html_comment_block(spaces_dir: Path) -> None:
    put(spaces_dir, "board.html", "<!-- title: Acme board\nicon: chart.bar\norder: 1 -->\n<html><body>hi</body></html>\n")
    [space] = scan(spaces_dir)
    assert (space.title, space.icon, space.order, space.media) == ("Acme board", "chart.bar", 1, "html")


def test_scan_ignores_dot_underscore(spaces_dir: Path) -> None:
    put(spaces_dir, ".hidden.md")
    put(spaces_dir, "_draft.md")
    put(spaces_dir, "notes.txt")
    (spaces_dir / "sub.md").mkdir()
    put(spaces_dir, "real.htm", "<p>x</p>")
    assert ids(scan(spaces_dir)) == ["real"]


def test_scan_ignores_a_same_named_subfolder(spaces_dir: Path) -> None:
    """v0.14 §6b.6: subfolders of the spaces folder are ignored; nothing inside them is listed."""
    put(spaces_dir, "brief.html", "<!-- title: Brief -->\n<p>Acme</p>\n")
    (spaces_dir / "brief").mkdir()
    put(spaces_dir / "brief", "x.html", "<p>script output</p>")
    put(spaces_dir / "brief", "y.md", "---\ntitle: Y\n---\n")
    [space] = scan(spaces_dir)
    assert (space.id, space.title) == ("brief", "Brief")
    assert space.location == str((spaces_dir / "brief.html").resolve())


def test_scan_bad_front_matter_listed_by_stem(spaces_dir: Path) -> None:
    put(spaces_dir, "oops.md", "---\ntitle Missing colon\nicon: x\n---\ntext\n")
    put(spaces_dir, "open.md", "---\ntitle: Never closed\n\ntext\n")
    put(spaces_dir, "badorder.md", "---\ntitle: Fine\norder: soon\n---\n")
    got = {s.id: s for s in scan(spaces_dir)}
    assert set(got) == {"oops", "open", "badorder"}
    for stem, space in got.items():
        assert (space.title, space.icon, space.order) == (stem, DEFAULT_ICON, None)


def test_scan_non_utf8_listed_by_stem(spaces_dir: Path) -> None:
    (spaces_dir / "latin.md").write_bytes(b"---\ntitle: Caf\xe9\n---\n")
    [space] = scan(spaces_dir)
    assert (space.id, space.title) == ("latin", "latin")


def test_scan_survives_a_file_deleted_mid_scan(spaces_dir: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    put(spaces_dir, "gone.md")
    put(spaces_dir, "kept.md")
    real_stat = Path.stat

    def flaky(self: Path, *a: Any, **kw: Any):
        if self.name == "gone.md":
            raise FileNotFoundError(self)
        return real_stat(self, *a, **kw)

    monkeypatch.setattr(Path, "stat", flaky)
    assert ids(scan(spaces_dir)) == ["kept"]


def test_scan_missing_folder_is_empty(tmp_path: Path) -> None:
    assert scan(tmp_path / "nowhere") == []


def test_sort_order_then_title(spaces_dir: Path) -> None:
    put(spaces_dir, "z.md", "---\ntitle: Zed\norder: 1\n---\n")
    put(spaces_dir, "a.md", "---\ntitle: Alpha\n---\n")
    put(spaces_dir, "b.md", "---\ntitle: beta\n---\n")
    put(spaces_dir, "m.md", "---\ntitle: Mid\norder: 1\n---\n")
    put(spaces_dir, "f.md", "---\ntitle: First\norder: 0\n---\n")
    assert ids(scan(spaces_dir)) == ["f", "m", "z", "a", "b"]


# --- watcher --------------------------------------------------------------------


async def test_watcher_fires_on_add_change_remove(spaces_dir: Path) -> None:
    seen: list[list[Space]] = []

    async def on_change(spaces: list[Space]) -> None:
        seen.append(spaces)

    watcher = SpacesWatcher(spaces_dir, on_change)
    await watcher.poll()
    assert seen == []  # nothing changed since the baseline
    path = put(spaces_dir, "brief.md", "---\ntitle: Brief\n---\n")
    await watcher.poll()
    assert [ids(s) for s in seen] == [["brief"]]
    await watcher.poll()
    assert len(seen) == 1  # no difference, no call
    os.utime(path, (1_900_000_000, 1_900_000_000))
    await watcher.poll()
    assert len(seen) == 2 and seen[-1][0].updated.startswith("2030")
    path.unlink()
    await watcher.poll()
    assert seen[-1] == [] and len(seen) == 3


async def test_watcher_ignores_changes_inside_a_subfolder(spaces_dir: Path) -> None:
    """v0.14 §6b.6: nothing inside a subfolder is watched: adding, changing or removing there sends no list."""
    seen: list[list[Space]] = []

    async def on_change(spaces: list[Space]) -> None:
        seen.append(spaces)

    put(spaces_dir, "brief.html", "<p>Acme</p>")
    sub = spaces_dir / "brief"
    sub.mkdir()
    x = put(sub, "x.html", "<p>one</p>")
    watcher = SpacesWatcher(spaces_dir, on_change)
    assert ids(watcher.spaces) == ["brief"]
    put(sub, "y.md", "---\ntitle: Y\n---\n")
    await watcher.poll()
    x.write_text("<p>two</p>")
    os.utime(x, (1_900_000_000, 1_900_000_000))
    os.utime(sub, (1_900_000_000, 1_900_000_000))
    await watcher.poll()
    (sub / "deeper").mkdir()
    put(sub / "deeper", "z.htm", "<p>z</p>")
    await watcher.poll()
    x.unlink()
    await watcher.poll()
    assert seen == [], "no spaces.list for a change inside brief/"


# --- rename ---------------------------------------------------------------------


def test_rename_preserves_other_keys(spaces_dir: Path) -> None:
    path = put(spaces_dir, "p.md", "---\ntitle: Old\nicon: calendar  # keep\norder: 3\n---\n\nBody: here\n")
    rename(spaces_dir, "p", "New: title")
    assert path.read_text(encoding="utf-8") == '---\ntitle: "New: title"\nicon: calendar  # keep\norder: 3\n---\n\nBody: here\n'
    [space] = scan(spaces_dir)
    assert (space.title, space.icon, space.order) == ("New: title", "calendar", 3)


def test_rename_adds_the_key_or_the_block(spaces_dir: Path) -> None:
    a = put(spaces_dir, "a.md", "---\nicon: x\n---\ntext\n")
    b = put(spaces_dir, "b.md", "just text\n")
    c = put(spaces_dir, "c.html", "<html></html>\n")
    d = put(spaces_dir, "d.html", "<!-- icon: y -->\n<p>x</p>\n")
    for sid in "abcd":
        rename(spaces_dir, sid, "Fresh")
    assert a.read_text() == "---\nicon: x\ntitle: Fresh\n---\ntext\n"
    assert b.read_text() == "---\ntitle: Fresh\n---\njust text\n"
    assert c.read_text() == "<!-- title: Fresh -->\n<html></html>\n"
    assert d.read_text() == "<!-- icon: y\ntitle: Fresh -->\n<p>x</p>\n"
    assert {s.id: s.title for s in scan(spaces_dir)} == {x: "Fresh" for x in "abcd"}


def test_rename_refuses_unknown_or_empty(spaces_dir: Path) -> None:
    put(spaces_dir, "a.md")
    with pytest.raises(SpaceError):
        rename(spaces_dir, "nope", "X")
    with pytest.raises(SpaceError):
        rename(spaces_dir, "a", "   ")
    with pytest.raises(SpaceError):
        rename(spaces_dir, "../a", "X")


# --- remove / refresh -----------------------------------------------------------


async def test_remove_trashes_and_runs_command_with_env(spaces_dir: Path, fake_home: Path, tmp_path: Path) -> None:
    put(spaces_dir, "brief.md", "one")
    trash = fake_home / ".Trash"
    trash.mkdir()
    (trash / "brief.md").write_text("an older one")
    out = tmp_path / "seen.txt"
    await remove(spaces_dir, "brief", f'printf %s "$PORTICO_SPACE" > {out}')
    assert not (spaces_dir / "brief.md").exists()
    assert (trash / "brief.md").read_text() == "an older one"  # not overwritten
    assert sorted(p.name for p in trash.iterdir()) == ["brief 2.md", "brief.md"]
    assert (trash / "brief 2.md").read_text() == "one"
    assert out.read_text() == "brief"


async def test_remove_without_command_and_failing_command(spaces_dir: Path, fake_home: Path) -> None:
    put(spaces_dir, "a.md")
    await remove(spaces_dir, "a", None)
    assert (fake_home / ".Trash" / "a.md").exists()
    put(spaces_dir, "b.md")
    with pytest.raises(SpaceError) as e:
        await remove(spaces_dir, "b", "exit 3")
    assert "exited 3" in str(e.value)
    assert (fake_home / ".Trash" / "b.md").exists()  # the file was trashed first


async def test_refresh_command_timeout_answers_error(tmp_path: Path) -> None:
    with pytest.raises(SpaceError) as e:
        await refresh("brief", "sleep 5", timeout=0.2)
    assert "did not finish in 0.2 s" in str(e.value)


async def test_refresh_runs_with_env(tmp_path: Path) -> None:
    out = tmp_path / "seen.txt"
    await refresh("brief", f'printf %s "$PORTICO_SPACE" > {out}')
    assert out.read_text() == "brief"
    with pytest.raises(SpaceError) as e:
        await refresh("brief", "echo bad >&2; exit 2")
    assert "exited 2" in str(e.value)


# --- show / auto-open -----------------------------------------------------------


def test_turn_write_in_spaces_folder_not_auto_opened(tmp_path: Path, spaces_dir: Path) -> None:
    chat_folder = tmp_path / "work"
    chat_folder.mkdir()
    written = put(spaces_dir, "brief.md")
    other = put(chat_folder, "notes.md")
    for order in ([written], [other, written], [written, other]):
        collector = TurnCollector(make_chat(chat_folder))
        for p in order:
            collector.note_tool("Write", {"file_path": str(p)})
        found = collector.finish(
            chat_folder, open_within=[chat_folder.resolve(), spaces_dir.resolve()], never_open=[spaces_dir.resolve()]
        )
        opened = [Path(a.location).name for a in found if a.open]
        assert opened == ([] if order == [written] else ["notes.md"])
        assert "brief.md" in [Path(a.location).name for a in found]


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
async def server(
    state_dir: StateDir, factory: EngineFactory, spaces_dir: Path
) -> AsyncIterator[GatewayServer]:
    config: Config = make_config(setting_sources=["project"], spaces=SpacesConfig(folder=str(spaces_dir)))
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    try:
        yield srv
    finally:
        await srv.shutdown()


async def test_show_space_file_sets_artifact_space(server: GatewayServer, spaces_dir: Path, tmp_path: Path) -> None:
    folder = tmp_path / "work"
    folder.mkdir()
    conn = await hello(server)
    await frames_until(conn, "spaces.list")
    try:
        await conn.send(dump(ChatNew(ts=TS, id="req-new", folder=str(folder))))
        number = (await frames_until(conn, "chat.state")).chat
        chat = server.registry.get(number)
        page = put(spaces_dir, "meeting-prep.md", "---\ntitle: Meeting prep\n---\n")
        plain = put(folder, "notes.md")
        assert await server.show_files(chat, [str(page)]) is None
        event = await frames_until(conn, "artifact.created")
        assert isinstance(event, ArtifactCreated) and event.artifact.space == "meeting-prep"
        assert event.artifact.open is True and event.artifact.location == str(page.resolve())
        assert await server.show_files(chat, [str(plain)]) is None
        event = await frames_until(conn, "artifact.created")
        assert isinstance(event, ArtifactCreated) and event.artifact.space is None
        assert '"space"' not in dump(event)  # None is left out of the wire form
    finally:
        await conn.close()


def test_spaces_folder_in_add_dirs(tmp_path: Path, spaces_dir: Path) -> None:
    cb = RecordingCallbacks()
    cb.spaces_folder = spaces_dir  # type: ignore[attr-defined]
    cb.viewer_roots = [spaces_dir]  # type: ignore[attr-defined]
    options = build_options(tmp_path, None, ["project"], cb)
    assert options.add_dirs == [spaces_dir]
    assert build_options(tmp_path, None, ["project"], RecordingCallbacks()).add_dirs == []


def test_prompt_line_only_when_configured(tmp_path: Path, spaces_dir: Path) -> None:
    plain = build_options(tmp_path, None, ["project"], RecordingCallbacks())
    assert "spaces" not in str(plain.system_prompt)
    cb = RecordingCallbacks()
    cb.spaces_folder = spaces_dir  # type: ignore[attr-defined]
    options = build_options(tmp_path, None, ["project"], cb, system_prompt={"type": "preset", "preset": "claude_code"})
    line = SPACES_PROMPT.format(folder=spaces_dir)
    assert line.startswith("The person's spaces are files in ")
    assert line.endswith("how it is kept up to date is the deployment's.")
    assert options.system_prompt["append"].endswith(line)  # type: ignore[index]
    assert options.system_prompt["append"].index("show_in_viewer") < options.system_prompt["append"].index("spaces")  # type: ignore[index]


# --- through the server ---------------------------------------------------------


async def hello(server: GatewayServer, capabilities: list[str] | None = None):
    conn = await connect(ws_url(server, server.token))
    caps = ["spaces.v1"] if capabilities is None else capabilities
    await conn.send(dump(HelloClient(ts=TS, app_version="0.12.0", capabilities=caps)))
    return conn


async def frames_until(conn: Any, type_name: str) -> Any:
    while True:
        msg = parse_server(await asyncio.wait_for(conn.recv(), 2))
        if msg.type == type_name:
            return msg


async def test_hello_sends_spaces_list_after_services_status(server: GatewayServer, spaces_dir: Path) -> None:
    put(spaces_dir, "brief.md", "---\ntitle: Brief\nicon: sun.max\n---\n")
    conn = await hello(server)
    try:
        types = []
        while "spaces.list" not in types:
            types.append(parse_server(await asyncio.wait_for(conn.recv(), 2)).type)
        assert types.index("services.status") < types.index("spaces.list")
        assert types[0] == "hello"
    finally:
        await conn.close()


async def test_no_folder_set_still_sends_an_empty_spaces_list(state_dir: StateDir, tmp_path: Path) -> None:
    """v0.14: no ``[spaces] folder`` means the default folder, so an app with spaces.v1 gets a (empty) list."""
    from tests.test_server import make_server

    srv = make_server(state_dir, make_config())
    await srv.serve(0)
    conn = await hello(srv)
    try:
        listing = await frames_until(conn, "spaces.list")
        assert listing.spaces == []
    finally:
        await conn.close()
        await srv.shutdown()


async def test_change_is_broadcast_and_actions_answer(server: GatewayServer, spaces_dir: Path, fake_home: Path) -> None:
    conn = await hello(server)
    try:
        first = await frames_until(conn, "spaces.list")
        assert isinstance(first, SpacesList) and first.spaces == []
        put(spaces_dir, "brief.md", "---\ntitle: Brief\n---\n")
        await server.spaces_watcher.poll()  # what the 5 s loop does
        got = await frames_until(conn, "spaces.list")
        assert [s.id for s in got.spaces] == ["brief"]

        await conn.send(dump(SpaceRename(ts=TS, id="brief", title="Morning brief")))
        got = await frames_until(conn, "spaces.list")
        assert got.spaces[0].title == "Morning brief"

        await conn.send(dump(SpaceRefresh(ts=TS, id="brief")))  # no refresh command configured
        err = await frames_until(conn, "error")
        assert isinstance(err, Error) and err.code == "space.no_refresh" and err.id == "brief"

        await conn.send(dump(SpaceRename(ts=TS, id="nope", title="X")))
        err = await frames_until(conn, "error")
        assert err.code == "space.not_found"

        await conn.send(dump(SpaceRemove(ts=TS, id="brief")))
        got = await frames_until(conn, "spaces.list")
        assert got.spaces == [] and (fake_home / ".Trash" / "brief.md").exists()
    finally:
        await conn.close()


async def test_app_without_spaces_v1_gets_no_spaces_list(server: GatewayServer, spaces_dir: Path) -> None:
    old = await hello(server, [])
    try:
        types: list[str] = []
        with pytest.raises(TimeoutError):
            while True:
                types.append(parse_server(await asyncio.wait_for(old.recv(), 0.4)).type)
        assert "services.status" in types and "spaces.list" not in types
        put(spaces_dir, "x.md")
        await server.spaces_watcher.poll()
        with pytest.raises(TimeoutError):
            await asyncio.wait_for(old.recv(), 0.4)
    finally:
        await old.close()


def test_rename_quotes_titles_yaml_would_not_read_as_text(spaces_dir: Path) -> None:
    for i, title in enumerate(["true", "No", "null", "~", "123", "1.5", "0x1F", "Fine title"]):
        path = put(spaces_dir, f"s{i}.md", "body\n")
        rename(spaces_dir, f"s{i}", title)
        expect = title if title == "Fine title" else f'"{title}"'
        assert path.read_text().splitlines()[1] == f"title: {expect}", title
        assert scan(spaces_dir)  # still reads back
    assert {s.title for s in scan(spaces_dir)} >= {"true", "123", "Fine title"}


async def test_failed_remove_command_says_the_file_is_in_the_trash(spaces_dir: Path, fake_home: Path) -> None:
    put(spaces_dir, "b.md")
    with pytest.raises(SpaceError) as e:
        await remove(spaces_dir, "b", "exit 3")
    assert str(e.value).endswith("(the file is already in the Trash)")


async def test_action_that_changes_the_list_broadcasts_it_once(server: GatewayServer, spaces_dir: Path) -> None:
    conn = await hello(server)
    try:
        await frames_until(conn, "spaces.list")
        put(spaces_dir, "a.md", "---\ntitle: A\n---\n")
        await conn.send(dump(SpaceRename(ts=TS, id="a", title="B")))
        await frames_until(conn, "spaces.list")
        with pytest.raises(TimeoutError):
            await asyncio.wait_for(conn.recv(), 0.4)  # no second copy
    finally:
        await conn.close()


# --- final review fixes -----------------------------------------------------------


async def test_symlinked_file_is_not_a_space(spaces_dir: Path, tmp_path: Path, fake_home: Path) -> None:
    outside = tmp_path / "outside.md"
    original = "---\ntitle: Elsewhere\n---\nbody\n"
    outside.write_text(original, encoding="utf-8")
    (spaces_dir / "x.md").symlink_to(outside)
    put(spaces_dir, "real.md")
    assert ids(scan(spaces_dir)) == ["real"]
    with pytest.raises(SpaceError) as e:
        rename(spaces_dir, "x", "New")
    assert e.value.code == "space.not_found"
    with pytest.raises(SpaceError) as e:
        await remove(spaces_dir, "x", None)
    assert e.value.code == "space.not_found"
    assert outside.read_text(encoding="utf-8") == original
    assert (spaces_dir / "x.md").is_symlink()


def test_rename_refuses_double_dash_in_a_comment_block(spaces_dir: Path) -> None:
    page = put(spaces_dir, "p.html", "<!-- title: Page -->\n<p>hi</p>\n")
    bare = put(spaces_dir, "q.htm", "<p>hi</p>\n")
    for id in ("p", "q"):
        with pytest.raises(SpaceError) as e:
            rename(spaces_dir, id, "A --> B")
        assert e.value.code == "space.invalid"
    assert page.read_text() == "<!-- title: Page -->\n<p>hi</p>\n" and bare.read_text() == "<p>hi</p>\n"
    put(spaces_dir, "m.md", "body\n")
    rename(spaces_dir, "m", "A -- B")  # front matter has no comment to end
    assert "A -- B" in {s.title for s in scan(spaces_dir)}


async def test_slow_refresh_does_not_hold_up_other_frames(
    state_dir: StateDir, factory: EngineFactory, spaces_dir: Path
) -> None:
    from portico_gateway.messages import ViewerResult, ViewerSettings

    config = make_config(
        setting_sources=["project"], spaces=SpacesConfig(folder=str(spaces_dir), refresh="sleep 2"))
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    put(spaces_dir, "brief.md")
    await srv.spaces_watcher.poll()
    conn = await hello(srv, ["spaces.v1", "viewer.v1"])
    try:
        await frames_until(conn, "spaces.list")
        await conn.send(dump(ViewerSettings(ts=TS, can_see=True, check_html=True)))
        await conn.send(dump(SpaceRefresh(ts=TS, id="brief")))
        await asyncio.sleep(0.2)  # the refresh command is running
        task = asyncio.create_task(srv.viewer.act(1, "look", {}))
        act = await frames_until(conn, "viewer.act")
        await conn.send(dump(ViewerResult(ts=TS, id=act.id, ok=True, text="seen")))
        out = await asyncio.wait_for(task, 1)  # not after the 2 s refresh
        assert out["content"][0]["text"] == "seen"
        await asyncio.wait_for(frames_until(conn, "spaces.list"), 4)  # the refresh's answer still comes

        await conn.send(dump(SpaceRefresh(ts=TS, id="nope")))
        err = await frames_until(conn, "error")
        assert err.code == "space.not_found" and err.id == "nope"
    finally:
        await conn.close()
        await srv.shutdown()


async def test_failed_refresh_answers_its_error_with_the_id(
    state_dir: StateDir, factory: EngineFactory, spaces_dir: Path
) -> None:
    config = make_config(setting_sources=["project"], spaces=SpacesConfig(folder=str(spaces_dir), refresh="exit 3"))
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    put(spaces_dir, "brief.md")
    conn = await hello(srv)
    try:
        await frames_until(conn, "spaces.list")
        await conn.send(dump(SpaceRefresh(ts=TS, id="brief")))
        err = await asyncio.wait_for(frames_until(conn, "error"), 4)
        assert err.code == "space.refresh_failed" and err.id == "brief"
    finally:
        await conn.close()
        await srv.shutdown()


# --- v0.14: no [spaces] folder means <state dir>/spaces ---------------------------


@pytest.fixture
async def default_server(state_dir: StateDir, factory: EngineFactory) -> AsyncIterator[GatewayServer]:
    config: Config = make_config(setting_sources=["project"])
    assert config.spaces.folder is None
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    put(state_dir.path / "spaces", "brief.md", "---\ntitle: Brief\n---\n")  # created at construction; scanned at serve
    await srv.serve(0)
    try:
        yield srv
    finally:
        await srv.shutdown()


async def test_unset_folder_uses_state_dir_spaces(default_server: GatewayServer, state_dir: StateDir) -> None:
    folder = state_dir.path / "spaces"
    assert folder.is_dir()
    assert default_server.spaces_watcher is not None and default_server.spaces_watcher.folder == folder.resolve()
    conn = await hello(default_server)
    try:
        hello_frame = await frames_until(conn, "hello")
        assert "spaces.v1" in hello_frame.capabilities
        listing = await frames_until(conn, "spaces.list")
        assert [s.id for s in listing.spaces] == ["brief"]
    finally:
        await conn.close()


async def test_default_folder_works_across_restarts(state_dir: StateDir, factory: EngineFactory) -> None:
    folder = state_dir.path / "spaces"
    for run in range(2):
        config: Config = make_config(setting_sources=["project"])
        registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
        srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
        if run == 0:
            put(folder, "kept.md", "---\ntitle: Kept\n---\n")
        await srv.serve(0)
        try:
            assert srv.config.spaces.folder == str(folder.resolve())
            assert [s.id for s in srv.spaces_watcher.spaces] == ["kept"]  # type: ignore[union-attr]
        finally:
            await srv.shutdown()


# --- v0.21: only a page with its own folder (field note 18) ---------------------------


def test_require_folder_lists_only_pages_with_a_folder_of_their_name(spaces_dir: Path) -> None:
    put(spaces_dir, "README.md", "# How spaces are laid out\n")
    put(spaces_dir, "brief.html", "<!-- title: Brief -->\n<p>x</p>\n")
    (spaces_dir / "brief").mkdir()
    put(spaces_dir, "meeting-prep.md", "---\ntitle: Meeting prep\n---\n")
    (spaces_dir / "meeting-prep").mkdir()
    put(spaces_dir, "notes.md")
    put(spaces_dir, "notes")  # a file of the name is not a folder
    assert ids(scan(spaces_dir)) == ["brief", "meeting-prep", "notes", "README"], "off by default"
    assert ids(scan(spaces_dir, require_folder=True)) == ["brief", "meeting-prep"]


def test_require_folder_also_holds_for_actions_and_the_viewer(spaces_dir: Path) -> None:
    readme = put(spaces_dir, "README.md", "# How spaces are laid out\n")
    with pytest.raises(SpaceError) as e:
        rename(spaces_dir, "README", "Readme", require_folder=True)
    assert e.value.code == "space.not_found"
    assert readme.read_text(encoding="utf-8") == "# How spaces are laid out\n", "left as it was, for the agent"
    assert space_id_for(spaces_dir, readme, require_folder=True) is None
    assert space_id_for(spaces_dir, readme) == "README"
    (spaces_dir / "README").mkdir()
    assert space_id_for(spaces_dir, readme, require_folder=True) == "README"


async def test_require_folder_watcher_and_config(spaces_dir: Path) -> None:
    assert SpacesConfig().require_folder is False
    assert SpacesConfig(folder=str(spaces_dir), require_folder=True).require_folder is True
    put(spaces_dir, "README.md")
    put(spaces_dir, "brief.md")
    seen: list[list[str]] = []

    async def changed(spaces: list[Space]) -> None:
        seen.append(ids(spaces))

    watcher = SpacesWatcher(spaces_dir, changed, require_folder=True)
    assert watcher.spaces == []
    (spaces_dir / "brief").mkdir()
    await watcher.poll()
    assert seen == [["brief"]]


async def test_require_folder_reaches_the_apps_list(state_dir: StateDir, factory: EngineFactory, spaces_dir: Path) -> None:
    put(spaces_dir, "README.md")
    put(spaces_dir, "brief.md", "---\ntitle: Brief\n---\n")
    (spaces_dir / "brief").mkdir()
    config: Config = make_config(
        setting_sources=["project"], spaces=SpacesConfig(folder=str(spaces_dir), require_folder=True)
    )
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    try:
        conn = await hello(srv)
        try:
            listed = await frames_until(conn, "spaces.list")
            assert [s.id for s in listed.spaces] == ["brief"]
        finally:
            await conn.close()
    finally:
        await srv.shutdown()


# --- v0.22 S1: space actions ------------------------------------------------------


async def test_act_runs_with_the_three_values_in_the_environment(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    out = tmp_path / "out.txt"
    await act("brief", "mark-done", "task:1_a.b", f'printf "%s|%s|%s" "$PORTICO_SPACE" "$PORTICO_ACTION" "$PORTICO_ITEM" > {out}')
    assert out.read_text() == "brief|mark-done|task:1_a.b"
    await act("brief", "go", None, f'printf "[%s]" "$PORTICO_ITEM" > {out}')
    assert out.read_text() == "[]"


async def test_act_refuses_names_that_are_not_plain(tmp_path: Path) -> None:
    marker = tmp_path / "hacked"
    for action, item in (("go;touch " + str(marker), None), ("go", "$(touch " + str(marker) + ")"), ("a b", None), ("", None)):
        with pytest.raises(SpaceError) as e:
            await act("brief", action, item, "true")
        assert e.value.code == "protocol.invalid"
    assert not marker.exists()


async def test_act_failure_carries_the_last_line_and_timeout_stops_it() -> None:
    with pytest.raises(SpaceError) as e:
        await act("brief", "go", None, "echo first; echo no luck >&2; exit 2")
    assert "no luck" in str(e.value)
    with pytest.raises(SpaceError, match="did not finish"):
        await act("brief", "go", None, "sleep 5", timeout=0.2)


@pytest.fixture
def act_server_factory(state_dir: StateDir, factory: EngineFactory, spaces_dir: Path):
    async def make(**spaces: Any) -> GatewayServer:
        config = make_config(setting_sources=["project"], spaces=SpacesConfig(folder=str(spaces_dir), **spaces))
        registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
        srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
        await srv.serve(0)
        return srv

    return make


def test_spaces_config_takes_act_and_advertises_it_only_with_one() -> None:
    from portico_gateway.config import hello_for

    cfg = Config(spaces={"act": "true"})
    assert cfg.spaces.act == "true"
    assert Config(spaces={"act": "  "}).spaces.act is None
    assert "spaces.act" not in hello_for(Config(), "e", "0.22.0").capabilities


def test_hello_advertises_spaces_act_with_the_command(spaces_dir: Path) -> None:
    from portico_gateway.config import hello_for

    cfg = Config(spaces={"folder": str(spaces_dir), "act": "true"})
    assert "spaces.act" in hello_for(cfg, "e", "0.22.0").capabilities
    assert "spaces.act" not in hello_for(Config(spaces={"folder": str(spaces_dir)}), "e", "0.22.0").capabilities


async def test_space_act_runs_the_command_and_answers_with_the_list(
    act_server_factory, spaces_dir: Path, tmp_path: Path
) -> None:
    out = tmp_path / "act.txt"
    put(spaces_dir, "brief.md")
    srv = await act_server_factory(act=f'printf "%s %s %s" "$PORTICO_SPACE" "$PORTICO_ACTION" "$PORTICO_ITEM" > {out}')
    conn = await hello(srv, ["spaces.v1", "spaces.act"])
    try:
        await frames_until(conn, "spaces.list")
        await conn.send(dump(SpaceAct(ts=TS, id="brief", action="done", item="t-1")))
        await asyncio.wait_for(frames_until(conn, "spaces.list"), 4)
        assert out.read_text() == "brief done t-1"
    finally:
        await conn.close()
        await srv.shutdown()


async def test_space_act_failure_no_act_not_found_and_bad_names(act_server_factory, spaces_dir: Path) -> None:
    put(spaces_dir, "brief.md")
    srv = await act_server_factory(act="echo it broke; exit 3")
    conn = await hello(srv, ["spaces.v1", "spaces.act"])
    try:
        await frames_until(conn, "spaces.list")
        await conn.send(dump(SpaceAct(ts=TS, id="brief", action="go")))
        err = await asyncio.wait_for(frames_until(conn, "error"), 4)
        assert err.code == "space.act_failed" and err.id == "brief" and "it broke" in err.message
        await conn.send(dump(SpaceAct(ts=TS, id="nope", action="go")))
        assert (await frames_until(conn, "error")).code == "space.not_found"
        for bad in ({"action": "a b"}, {"action": ""}, {"action": "x" * 129}, {"action": "go", "item": "$(id)"}, {"action": "go", "item": "a/b"}):
            await conn.send(dump(SpaceAct(ts=TS, id="brief", **bad)))
            assert (await frames_until(conn, "error")).code == "protocol.invalid", bad
    finally:
        await conn.close()
        await srv.shutdown()


async def test_space_act_without_a_command_answers_no_act(server: GatewayServer, spaces_dir: Path) -> None:
    put(spaces_dir, "brief.md")
    conn = await hello(server)
    try:
        await frames_until(conn, "spaces.list")
        await conn.send(dump(SpaceAct(ts=TS, id="brief", action="go")))
        err = await frames_until(conn, "error")
        assert err.code == "space.no_act" and err.id == "brief"
    finally:
        await conn.close()


# --- v0.22 S2: notices a space can word -------------------------------------------


def test_scan_reads_notice_and_notice_target(spaces_dir: Path) -> None:
    put(spaces_dir, "a.md", "---\ntitle: A\nnotice: Prep for your 10:00 is ready\nnotice_target: meeting-1000\n---\n")
    put(spaces_dir, "b.html", "<!-- notice: Hello there # not a comment? -->\n<p>x</p>\n")
    put(spaces_dir, "c.md", "---\nnotice: \"\"\nnotice_target: '#top'\n---\n")
    put(spaces_dir, "d.md", "plain\n")
    got = {s.id: (s.notice, s.notice_target) for s in scan(spaces_dir)}
    assert got["a"] == ("Prep for your 10:00 is ready", "meeting-1000")
    assert got["b"] == ("Hello there", None)
    assert got["c"] == ("", "top"), "an empty notice is kept (it means: no notification); a leading # is dropped"
    assert got["d"] == (None, None)


async def test_spaces_list_carries_notice_fields_only_when_set(server: GatewayServer, spaces_dir: Path) -> None:
    put(spaces_dir, "a.md", "---\nnotice: Ready\nnotice_target: x1\n---\n")
    put(spaces_dir, "b.md", "plain\n")
    put(spaces_dir, "c.md", "---\nnotice: \"\"\n---\n")
    await server.spaces_watcher.poll()
    conn = await hello(server)
    try:
        listing = await frames_until(conn, "spaces.list")
        raw = {s.id: s.model_dump(exclude_none=True) for s in listing.spaces}
        assert raw["a"]["notice"] == "Ready" and raw["a"]["notice_target"] == "x1"
        assert "notice" not in raw["b"] and "notice_target" not in raw["b"]
        assert raw["c"]["notice"] == ""
    finally:
        await conn.close()


# --- v0.22 S4: spaces that cannot be removed or renamed ---------------------------


def test_scan_reads_removable(spaces_dir: Path) -> None:
    put(spaces_dir, "a.md", "---\nremovable: false\n---\n")
    put(spaces_dir, "b.md", "---\nremovable: No\n---\n")
    put(spaces_dir, "c.html", "<!-- removable: FALSE -->\n")
    put(spaces_dir, "d.md", "---\nremovable: true\n---\n")
    put(spaces_dir, "e.md", "plain\n")
    assert {s.id: s.removable for s in scan(spaces_dir)} == {"a": False, "b": False, "c": False, "d": True, "e": True}


def test_remove_and_rename_functions_refuse_a_fixed_space(spaces_dir: Path, fake_home: Path) -> None:
    path = put(spaces_dir, "fixed.md", "---\nremovable: false\n---\nbody\n")
    before = path.read_text()
    with pytest.raises(SpaceError) as e:
        rename(spaces_dir, "fixed", "New")
    assert e.value.code == "space.fixed" and path.read_text() == before
    with pytest.raises(SpaceError) as e2:
        asyncio.run(remove(spaces_dir, "fixed", None))
    assert e2.value.code == "space.fixed" and path.exists() and not (fake_home / ".Trash" / "fixed.md").exists()


async def test_server_refuses_remove_and_rename_of_a_fixed_space_and_sends_removable_only_when_false(
    act_server_factory, spaces_dir: Path, fake_home: Path, tmp_path: Path
) -> None:
    ran = tmp_path / "ran"
    path = put(spaces_dir, "fixed.md", "---\nremovable: false\n---\nbody\n")
    put(spaces_dir, "free.md", "plain\n")
    srv = await act_server_factory(remove=f"touch {ran}")
    conn = await hello(srv)
    try:
        listing = await frames_until(conn, "spaces.list")
        wire = {s.id: s.model_dump(exclude_none=True) for s in listing.spaces}
        assert wire["fixed"]["removable"] is False and "removable" not in wire["free"]
        await conn.send(dump(SpaceRemove(ts=TS, id="fixed")))
        err = await frames_until(conn, "error")
        assert err.code == "space.fixed" and err.id == "fixed"
        await conn.send(dump(SpaceRename(ts=TS, id="fixed", title="Other")))
        assert (await frames_until(conn, "error")).code == "space.fixed"
        assert path.exists() and "title: Other" not in path.read_text()
        assert not ran.exists() and not (fake_home / ".Trash").exists()
    finally:
        await conn.close()
        await srv.shutdown()
