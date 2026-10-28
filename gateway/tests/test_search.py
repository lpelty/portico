"""v0.2: ``files.search`` — Spotlight under a root, or a plug-in's ``search``.

The default runs ``mdfind -onlyin <root> <query>``; these tests inject the
runner, so nothing here depends on Spotlight's index. (A test against the
real ``mdfind`` was tried and dropped: Spotlight does not index the test
temp directories, so it could not pass reliably.)
"""

from __future__ import annotations

import sys
from collections.abc import AsyncIterator
from pathlib import Path

import pytest

from portico_gateway.messages import Error, FilesResults, FilesSearch, Hit, ProtocolError, Root, dump
from portico_gateway.plugins import load_plugins
from portico_gateway.search import SEARCH_LIMIT, SEARCH_TIMEOUT_SECONDS, run_command, search_files
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from tests.test_server import attach
from tests.test_sessions import start_server
from tests.test_turns import EngineFactory, new_chat, recv

TS = "2026-10-28T12:00:00Z"


class Runner:
    """Records the argv and answers with canned ``mdfind`` output."""

    def __init__(self, lines: list[str] | None = None, error: Exception | None = None) -> None:
        self.lines = lines or []
        self.error = error
        self.calls: list[tuple[list[str], float]] = []

    async def __call__(self, argv: list[str], timeout: float) -> str:
        self.calls.append((argv, timeout))
        if self.error is not None:
            raise self.error
        return "".join(line + "\n" for line in self.lines)


@pytest.fixture
def projects(tmp_path: Path) -> Path:
    root = tmp_path / "projects"
    (root / "demo").mkdir(parents=True)
    return root


# --- the default search -------------------------------------------------------


async def test_runs_mdfind_only_in_the_root(projects: Path) -> None:
    runner = Runner()
    await search_files(projects, "synthesis", runner)
    argv, timeout = runner.calls[0]
    assert argv == ["mdfind", "-onlyin", str(projects.resolve()), "synthesis"]
    assert timeout == SEARCH_TIMEOUT_SECONDS == 5.0


async def test_hits_are_relative_names_first_and_outside_dropped(projects: Path, tmp_path: Path) -> None:
    base = projects.resolve()
    runner = Runner(
        [
            f"{base}/demo/notes.md",  # text match only
            f"{base}/demo/Q3-Synthesis.md",  # name match
            f"{tmp_path.resolve()}/elsewhere/synthesis.md",  # outside the root
            f"{base}/.git/synthesis",  # hidden
            f"{base}/demo/../../escape-synthesis.md",  # leaves the root once resolved
            "",
            f"{base}",  # the root itself
        ]
    )
    hits = await search_files(projects, "synthesis", runner)
    assert hits == [Hit(path="demo/Q3-Synthesis.md"), Hit(path="demo/notes.md")]
    assert all(h.snippet is None for h in hits)


async def test_results_are_capped(projects: Path) -> None:
    base = projects.resolve()
    runner = Runner([f"{base}/f{i}.md" for i in range(SEARCH_LIMIT + 25)])
    hits = await search_files(projects, "x", runner)
    assert len(hits) == SEARCH_LIMIT == 50


async def test_a_blank_query_runs_nothing(projects: Path) -> None:
    runner = Runner()
    assert await search_files(projects, "   ", runner) == []
    assert runner.calls == []


async def test_run_command_times_out_and_kills(tmp_path: Path) -> None:
    with pytest.raises(ProtocolError) as e:
        await run_command([sys.executable, "-c", "import time; time.sleep(30)"], 0.3)
    assert e.value.code == "files.search_failed" and "timed out" in e.value.message


async def test_run_command_reports_a_missing_program() -> None:
    with pytest.raises(ProtocolError) as e:
        await run_command(["portico-no-such-program"], 1.0)
    assert e.value.code == "files.search_failed"


async def test_run_command_reports_a_failing_program() -> None:
    with pytest.raises(ProtocolError) as e:
        await run_command([sys.executable, "-c", "import sys; sys.exit(3)"], 5.0)
    assert e.value.code == "files.search_failed" and "3" in e.value.message


# --- over the wire ----------------------------------------------------------------


@pytest.fixture
async def server(state_dir: StateDir, projects: Path) -> AsyncIterator[GatewayServer]:
    srv = await start_server(state_dir, EngineFactory(), roots=[Root(name="projects", path=str(projects))])
    try:
        yield srv
    finally:
        await srv.shutdown()


async def test_files_search_answers_with_results(server: GatewayServer, projects: Path) -> None:
    server.search_runner = Runner([f"{projects.resolve()}/demo/Q3-synthesis.md"])
    conn = await attach(server)
    try:
        await conn.send(dump(FilesSearch(ts=TS, id="req-s", root="projects", query="synthesis")))
        reply = await recv(conn)
        assert isinstance(reply, FilesResults), reply
        assert (reply.id, reply.root, reply.query) == ("req-s", "projects", "synthesis")
        assert reply.hits == [Hit(path="demo/Q3-synthesis.md")]
        assert reply.seq is None
    finally:
        await conn.close()


async def test_files_search_on_the_chat_root(server: GatewayServer, tmp_path: Path) -> None:
    folder = tmp_path / "chatfolder"
    folder.mkdir()
    runner = Runner([f"{folder.resolve()}/a.md"])
    server.search_runner = runner
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(FilesSearch(ts=TS, chat=number, id="req-s", root="chat", query="a")))
        reply = await recv(conn)
        assert isinstance(reply, FilesResults) and reply.hits == [Hit(path="a.md")]
        assert runner.calls[0][0][2] == str(folder.resolve())
    finally:
        await conn.close()


async def test_files_search_unknown_root_is_the_files_list_error(server: GatewayServer) -> None:
    conn = await attach(server)
    try:
        await conn.send(dump(FilesSearch(ts=TS, id="req-s", root="nowhere", query="x")))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "files.unknown_root" and err.id == "req-s"
    finally:
        await conn.close()


async def test_files_search_failure_is_an_error_frame(server: GatewayServer) -> None:
    server.search_runner = Runner(error=ProtocolError("files.search_failed", "Spotlight timed out"))
    conn = await attach(server)
    try:
        await conn.send(dump(FilesSearch(ts=TS, id="req-s", root="projects", query="x")))
        err = await recv(conn)
        assert isinstance(err, Error) and err.code == "files.search_failed"
    finally:
        await conn.close()


async def test_a_plugin_search_replaces_spotlight_and_is_kept_inside_the_root(
    state_dir: StateDir, projects: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(sys, "path", list(sys.path))
    monkeypatch.setattr(sys, "modules", dict(sys.modules))
    plugdir = tmp_path / "plugs"
    plugdir.mkdir()
    (plugdir / "pp_search.py").write_text(
        "PORTICO_PLUGIN_API = 1\n"
        "def search(root, query):\n"
        "    return [{'path': 'demo/hit.md', 'snippet': 'found ' + query}, {'path': '../out.md'}, {'path': '/etc/passwd'}]\n"
    )
    plugins = load_plugins(["pp_search"], [str(plugdir)])
    srv = await start_server(state_dir, EngineFactory(), plugins=plugins, roots=[Root(name="projects", path=str(projects))])
    runner = Runner()
    srv.search_runner = runner
    conn = await attach(srv)
    try:
        await conn.send(dump(FilesSearch(ts=TS, id="req-s", root="projects", query="q")))
        reply = await recv(conn)
        assert isinstance(reply, FilesResults)
        assert reply.hits == [Hit(path="demo/hit.md", snippet="found q")]
        assert runner.calls == [], "Spotlight is not asked when a plug-in searches"
    finally:
        await conn.close()
        await srv.shutdown()
