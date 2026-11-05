"""Task 12: ``files.list`` — roots from config plus the chat's folder, listing rules, escape refusal.

The app asks ``files.list {root, path}``; the gateway answers ``files.list``
with the entries of that directory: directories first, names ordered
case-insensitively within each group, hidden entries skipped. A ``path``
that leaves the root (``..``, an absolute path, a symlink pointing out) is
refused with ``error code=files.outside_root``.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection, connect

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import Config
from portico_gateway.messages import (
    Error,
    FilesList,
    FilesListRequest,
    FilesRoots,
    FilesRootsSet,
    HelloClient,
    HelloServer,
    ProtocolError,
    Root,
    dump,
    parse_server,
)
from portico_gateway.server import GatewayServer, list_directory
from portico_gateway.state import StateDir
from tests.conftest import make_config
from tests.test_server import attach, ws_url
from tests.test_turns import EngineFactory, new_chat, recv

TS = "2026-10-27T12:00:00Z"


# --- fixtures -----------------------------------------------------------------


@pytest.fixture
def projects(tmp_path: Path) -> Path:
    """A config root with a mixed listing: dirs, files, a hidden file, mixed case."""
    root = tmp_path / "projects"
    root.mkdir()
    (root / "zeta").mkdir()
    (root / "Alpha").mkdir()
    (root / "notes.md").write_text("hello\n")
    (root / "README").write_text("x" * 10)
    (root / "beta.txt").write_text("")
    (root / ".hidden").write_text("secret")
    (root / ".git").mkdir()
    (root / "Alpha" / "inner.py").write_text("print()\n")
    return root


@pytest.fixture
async def server(state_dir: StateDir, projects: Path) -> AsyncIterator[GatewayServer]:
    config: Config = make_config(roots=[Root(name="projects", path=str(projects))])
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=EngineFactory(), version=__version__)
    await srv.serve(0)
    try:
        yield srv
    finally:
        await srv.shutdown()


async def ask(conn: ClientConnection, root: str, path: str = "", *, chat: int | None = None, id: str = "req-f") -> FilesList | Error:
    await conn.send(dump(FilesListRequest(ts=TS, chat=chat, id=id, root=root, path=path)))
    reply = await recv(conn)
    assert isinstance(reply, (FilesList, Error)), reply
    return reply


# --- the plan's three ---------------------------------------------------------


async def test_lists_root_level_dirs_first(server: GatewayServer, projects: Path) -> None:
    conn = await attach(server)
    try:
        reply = await ask(conn, "projects", "", id="req-1")
        assert isinstance(reply, FilesList), reply
        assert reply.id == "req-1"
        assert reply.root == "projects"
        assert reply.path == ""
        # Directories first, then files; each group case-insensitive; hidden skipped.
        assert [e.name for e in reply.entries] == ["Alpha", "zeta", "beta.txt", "notes.md", "README"]
        assert [e.dir for e in reply.entries] == [True, True, False, False, False]
        by_name = {e.name: e for e in reply.entries}
        assert by_name["README"].size == 10
        assert by_name["beta.txt"].size == 0
        assert by_name["Alpha"].size is None

        # A subdirectory, by relative path.
        inner = await ask(conn, "projects", "Alpha", id="req-2")
        assert isinstance(inner, FilesList), inner
        assert inner.path == "Alpha"
        assert [(e.name, e.dir) for e in inner.entries] == [("inner.py", False)]
    finally:
        await conn.close()


async def test_path_escape_refused(server: GatewayServer, projects: Path, tmp_path: Path) -> None:
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "leak.txt").write_text("nope")
    os.symlink(outside, projects / "link-out")

    conn = await attach(server)
    try:
        for path in ("..", "Alpha/../..", "../outside", str(outside), "link-out"):
            reply = await ask(conn, "projects", path, id=f"esc:{path}")
            assert isinstance(reply, Error), (path, reply)
            assert reply.code == "files.outside_root", path
            assert reply.id == f"esc:{path}"
        # Reaching the root through ".." from a subdirectory is still inside it.
        ok = await ask(conn, "projects", "Alpha/..", id="req-ok")
        assert isinstance(ok, FilesList), ok
        assert ok.path == ""
        # The symlink itself is listed as a directory entry; only descending into it is refused.
        top = await ask(conn, "projects", "", id="req-top")
        assert isinstance(top, FilesList)
        assert ("link-out", True) in [(e.name, e.dir) for e in top.entries]
    finally:
        await conn.close()


async def test_chat_folder_is_a_root(server: GatewayServer, tmp_path: Path) -> None:
    folder = tmp_path / "demo"
    folder.mkdir()
    (folder / "src").mkdir()
    (folder / "src" / "main.py").write_text("x" * 1204)
    (folder / "app.toml").write_text("")

    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        reply = await ask(conn, "chat", "", chat=number, id="req-c")
        assert isinstance(reply, FilesList), reply
        assert reply.chat == number
        assert reply.root == "chat"
        assert [(e.name, e.dir) for e in reply.entries] == [("src", True), ("app.toml", False)]

        inner = await ask(conn, "chat", "src", chat=number, id="req-c2")
        assert isinstance(inner, FilesList), inner
        assert [(e.name, e.size) for e in inner.entries] == [("main.py", 1204)]

        # The chat root needs a chat; an unknown chat is chat.unknown as everywhere else.
        no_chat = await ask(conn, "chat", "", chat=None, id="req-c3")
        assert isinstance(no_chat, Error) and no_chat.code == "files.unknown_root"
        bad_chat = await ask(conn, "chat", "", chat=number + 50, id="req-c4")
        assert isinstance(bad_chat, Error) and bad_chat.code == "chat.unknown"
    finally:
        await conn.close()


# --- edges --------------------------------------------------------------------


async def test_unknown_root_and_missing_path(server: GatewayServer) -> None:
    conn = await attach(server)
    try:
        reply = await ask(conn, "nope", "", id="req-u")
        assert isinstance(reply, Error) and reply.code == "files.unknown_root"
        missing = await ask(conn, "projects", "does-not-exist", id="req-m")
        assert isinstance(missing, Error) and missing.code == "files.not_found"
        a_file = await ask(conn, "projects", "notes.md", id="req-nf")
        assert isinstance(a_file, Error) and a_file.code == "files.not_found"
    finally:
        await conn.close()


def test_list_directory_is_pure(projects: Path) -> None:
    rel, entries = list_directory(projects, "./Alpha/")
    assert rel == "Alpha"
    assert [e.name for e in entries] == ["inner.py"]
    with pytest.raises(ProtocolError) as e:
        list_directory(projects, "../")
    assert e.value.code == "files.outside_root"


async def test_root_written_with_a_tilde_lists(state_dir: StateDir, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    vault = tmp_path / "vault"
    vault.mkdir()
    (vault / "notes.md").write_text("n")
    config: Config = make_config(roots=[Root(name="vault", path="~/vault")])
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=EngineFactory(), version=__version__)
    await srv.serve(0)
    conn = await attach(srv)
    try:
        reply = await ask(conn, "vault", "", id="req-v")
        assert isinstance(reply, FilesList), reply
        assert [(e.name, e.dir) for e in reply.entries] == [("notes.md", False)]
    finally:
        await conn.close()
        await srv.shutdown()


# --- v0.19: folders a person adds (files.extra.v1, spec §4.2) -------------------


async def set_roots(conn: ClientConnection, paths: list[str], *, id: str = "req-r") -> FilesRoots | Error:
    await conn.send(dump(FilesRootsSet(ts=TS, id=id, paths=paths)))
    reply = await recv(conn)
    assert isinstance(reply, (FilesRoots, Error)), reply
    return reply


async def test_hello_carries_files_extra(server: GatewayServer) -> None:
    conn = await connect(ws_url(server, server.token))
    try:
        await conn.send(dump(HelloClient(ts=TS, app_version="0.19.0")))
        hello = parse_server(await conn.recv())
        assert isinstance(hello, HelloServer)
        assert "files.extra.v1" in hello.capabilities
    finally:
        await conn.close()


async def test_set_lists_deployment_roots_then_extras_with_missing_marked(
    server: GatewayServer, projects: Path, tmp_path: Path
) -> None:
    papers = tmp_path / "papers"
    papers.mkdir()
    (papers / "a.txt").write_text("a")
    gone = tmp_path / "gone"
    conn = await attach(server)
    try:
        reply = await set_roots(conn, [str(papers), str(gone)])
        assert isinstance(reply, FilesRoots), reply
        assert reply.id == "req-r"
        assert [(r.name, r.extra, r.missing) for r in reply.roots] == [
            ("projects", False, False),
            ("papers", True, False),
            ("gone", True, True),
        ]
        listed = await ask(conn, "papers", "", id="req-p")
        assert isinstance(listed, FilesList), listed
        assert [e.name for e in listed.entries] == ["a.txt"]
        missing = await ask(conn, "gone", "", id="req-g")
        assert isinstance(missing, Error), missing
        assert missing.code == "files.not_found"
    finally:
        await conn.close()


async def test_relative_path_is_invalid_root(server: GatewayServer) -> None:
    conn = await attach(server)
    try:
        reply = await set_roots(conn, ["notes/here"])
        assert isinstance(reply, Error), reply
        assert reply.code == "files.invalid_root"
    finally:
        await conn.close()


async def test_resending_replaces_and_clashing_names_get_a_number(server: GatewayServer, projects: Path, tmp_path: Path) -> None:
    one = tmp_path / "a" / "work"
    two = tmp_path / "b" / "work"
    other = tmp_path / "other"
    for d in (one, two, other):
        d.mkdir(parents=True)
    conn = await attach(server)
    try:
        first = await set_roots(conn, [str(one), str(two), str(projects)])
        assert isinstance(first, FilesRoots), first
        assert [r.name for r in first.roots] == ["projects", "work", "work 2", "projects 2"]
        second = await set_roots(conn, [str(other)])
        assert isinstance(second, FilesRoots), second
        assert [r.name for r in second.roots] == ["projects", "other"]
        stale = await ask(conn, "work", "", id="req-s")
        assert isinstance(stale, Error) and stale.code == "files.unknown_root"
    finally:
        await conn.close()


async def test_extra_roots_belong_to_the_connection(server: GatewayServer, tmp_path: Path) -> None:
    papers = tmp_path / "papers"
    papers.mkdir()
    first = await attach(server)
    await set_roots(first, [str(papers)])
    await first.close()
    second = await attach(server)
    try:
        reply = await ask(second, "papers", "", id="req-n")
        assert isinstance(reply, Error) and reply.code == "files.unknown_root"
    finally:
        await second.close()
