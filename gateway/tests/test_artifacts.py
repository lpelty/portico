"""Task 9: artifacts — media kinds, detection from tool events and text, the per-turn collector,
auto-open at ``turn.finished``, the producer endpoint, persistence in the index.

The detection functions and the collector are tested on their own; the
turn-level behaviour and the producer run against the server with the
scripted ``FakeEngine``. Nothing here touches a model.
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection

from portico_gateway import __version__
from portico_gateway.artifacts import TurnCollector, from_tool, is_viewable, media_for, paths_in, urls_in
from portico_gateway.chats import Chat, ChatRegistry
from portico_gateway.config import Config
from portico_gateway.messages import (
    ArtifactCreated,
    ArtifactOpened,
    ChatState,
    MessageSend,
    ToolFinished,
    ToolStarted,
    TurnFinished,
    TurnStarted,
    dump,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from tests.conftest import fake_result, make_config
from tests.test_server import attach
from tests.test_turns import EngineFactory, new_chat, recv, recv_until, text_delta, tool_result, tool_use

TS = "2026-10-27T12:00:00Z"


# --- fixtures -----------------------------------------------------------------


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
async def server(state_dir: StateDir, factory: EngineFactory) -> AsyncIterator[GatewayServer]:
    config: Config = make_config(setting_sources=["project"])
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    await srv.serve(0)
    try:
        yield srv
    finally:
        await srv.shutdown()


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = tmp_path / "demo"
    path.mkdir()
    return path


def touch(path: Path, text: str = "x") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def write_tool(path: Path, tool_use_id: str):
    return tool_use(tool_use_id, "Write", {"file_path": str(path), "content": "x"})


async def http_post(
    port: int, path: str, body: dict, token: str | None
) -> tuple[int, dict]:
    """One plain HTTP/1.1 POST over a raw socket; returns status and the JSON body."""
    payload = json.dumps(body).encode()
    auth = f"Authorization: Bearer {token}\r\n" if token else ""
    head = (
        f"POST {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n{auth}Content-Type: application/json\r\n"
        f"Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n"
    )
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(head.encode() + payload)
    await writer.drain()
    raw = await asyncio.wait_for(reader.read(), 5)
    writer.close()
    header, _, raw_body = raw.partition(b"\r\n\r\n")
    status = int(header.decode().split("\r\n")[0].split(" ")[1])
    return status, (json.loads(raw_body) if raw_body else {})


async def run_turn(conn: ClientConnection, number: int, engine, *items) -> list:
    """Send a message with ``items`` as the engine's script; frames through ``chat.state idle``."""
    engine.script(*items, fake_result())
    await conn.send(dump(MessageSend(ts=TS, chat=number, text="go")))
    frames = await recv_until(conn, TurnFinished)
    idle = await recv(conn)
    assert isinstance(idle, ChatState) and idle.state == "idle"
    return frames


# --- media and detection ------------------------------------------------------


def test_media_mapping() -> None:
    assert media_for(Path("/a/report.md")) == "markdown"
    assert media_for(Path("/a/notes.MARKDOWN")) == "markdown"
    for ext in ("png", "jpg", "jpeg", "gif", "webp", "svg"):
        assert media_for(Path(f"/a/pic.{ext}")) == "image", ext
    assert media_for(Path("/a/index.html")) == "html"
    assert media_for(Path("/a/index.htm")) == "html"
    assert media_for(Path("/a/paper.pdf")) == "pdf"
    assert media_for(Path("/a/log.txt")) == "text"
    for name in ("main.py", "Package.swift", "config.toml", "Makefile", "data.csv", "archive.tar.gz"):
        assert media_for(Path(f"/a/{name}")) == "other", name

    assert [m for m in ("markdown", "image", "html", "pdf", "url") if not is_viewable(m)] == []
    assert not is_viewable("text")
    assert not is_viewable("other")


def test_from_tool_reads_the_file_writing_tools_only() -> None:
    assert from_tool("Write", {"file_path": "/a/b.md", "content": ""}) == Path("/a/b.md")
    assert from_tool("Edit", {"file_path": "/a/b.md", "old_string": "x", "new_string": "y"}) == Path("/a/b.md")
    assert from_tool("MultiEdit", {"file_path": "/a/b.md", "edits": []}) == Path("/a/b.md")
    assert from_tool("NotebookEdit", {"notebook_path": "/a/n.ipynb", "new_source": ""}) == Path("/a/n.ipynb")
    assert from_tool("Read", {"file_path": "/a/b.md"}) is None
    assert from_tool("Bash", {"command": "echo hi > /a/b.md"}) is None
    assert from_tool("Write", {"content": "no path"}) is None
    assert from_tool("Write", {"file_path": ""}) is None


def test_urls_in_finds_local_addresses_only() -> None:
    text = (
        "Dev server at http://localhost:5173/ and the API on http://127.0.0.1:8000/docs.\n"
        "Docs: https://example.com/guide and http://localhost (no port), again http://localhost:5173/."
    )
    assert urls_in(text) == ["http://localhost:5173/", "http://127.0.0.1:8000/docs", "http://localhost"]
    assert urls_in("nothing here") == []
    assert urls_in("(see http://localhost:3000/app)") == ["http://localhost:3000/app"]


def test_paths_in_names_viewable_files_that_exist(tmp_path: Path) -> None:
    folder = tmp_path / "proj"
    report = touch(folder / "out" / "report.md")
    chart = touch(folder / "chart.png")
    touch(folder / "main.py")
    elsewhere = touch(tmp_path / "scratch" / "notes.md")
    text = (
        f"Wrote the report to out/report.md and `chart.png`; the code is in main.py.\n"
        f"Scratch notes: {elsewhere}. Missing: out/nope.md and /nowhere/x.pdf. See (out/report.md)."
    )
    assert paths_in(text, folder) == [report, chart, elsewhere]
    assert paths_in("plain prose, no paths", folder) == []


def test_paths_in_finds_markdown_link_targets(tmp_path: Path) -> None:
    # A report written through the shell and named as a markdown link is
    # the common case for a Bash-produced artifact.
    folder = tmp_path / "proj"
    report = touch(folder / "reports" / "summary.md")
    assert paths_in("See [the report](reports/summary.md) for details.", folder) == [report]
    assert paths_in(f"See [the report]({report}) for details.", folder) == [report]
    assert paths_in('[the report](reports/summary.md "Summary") and [again](reports/summary.md)', folder) == [report]
    # A link to a URL is a URL, and a missing target is nothing.
    assert paths_in("Open [the app](http://localhost:3000/app).", folder) == []
    assert paths_in("See [the report](reports/nope.md).", folder) == []


# --- the collector ------------------------------------------------------------


def make_chat(folder: Path, number: int = 1) -> Chat:
    return Chat(number, folder, history_buffer=100)


def test_write_tool_path_is_collected(tmp_path: Path) -> None:
    folder = tmp_path / "proj"
    folder.mkdir()
    report = touch(folder / "report.md")
    collector = TurnCollector(make_chat(folder))
    collector.note_tool("Write", {"file_path": str(report), "content": "# R"})
    collector.note_tool("Read", {"file_path": str(folder / "other.md")})
    artifacts = collector.finish(folder)
    assert len(artifacts) == 1
    art = artifacts[0]
    assert art.kind == "file" and art.location == str(report)
    assert art.media == "markdown" and art.title == "report.md"
    assert art.source == "tool" and art.open is True
    assert art.id


def test_denied_or_failed_write_leaves_no_artifact(tmp_path: Path) -> None:
    folder = tmp_path / "proj"
    folder.mkdir()
    collector = TurnCollector(make_chat(folder))
    collector.note_tool("Write", {"file_path": str(folder / "never-written.md"), "content": ""})
    assert collector.finish(folder) == []


def test_source_files_listed_but_not_opened(tmp_path: Path) -> None:
    folder = tmp_path / "proj"
    folder.mkdir()
    files = [touch(folder / "src" / name) for name in ("App.swift", "Model.swift", "Package.swift")]
    collector = TurnCollector(make_chat(folder))
    for path in files:
        collector.note_tool("Write", {"file_path": str(path), "content": ""})
    artifacts = collector.finish(folder)
    assert [a.title for a in artifacts] == ["App.swift", "Model.swift", "Package.swift"]
    assert all(a.media == "other" and a.open is False and a.kind == "file" for a in artifacts)


def test_newest_viewable_opens_and_dedup_by_location(tmp_path: Path) -> None:
    folder = tmp_path / "proj"
    folder.mkdir()
    a = touch(folder / "a.md")
    b = touch(folder / "b.png")
    code = touch(folder / "main.py")
    collector = TurnCollector(make_chat(folder))
    collector.note_tool("Write", {"file_path": str(a), "content": ""})
    collector.note_tool("Write", {"file_path": str(b), "content": ""})
    collector.note_tool("Write", {"file_path": str(code), "content": ""})  # newest, but not viewable
    collector.note_tool("Edit", {"file_path": str(a), "old_string": "", "new_string": ""})  # a again
    artifacts = collector.finish(folder)
    assert [a_.location for a_ in artifacts] == [str(b), str(code), str(a)]
    assert [a_.open for a_ in artifacts] == [False, False, True]
    assert {a_.source for a_ in artifacts} == {"tool"}


def test_localhost_url_in_text_opens(tmp_path: Path) -> None:
    folder = tmp_path / "proj"
    folder.mkdir()
    collector = TurnCollector(make_chat(folder))
    collector.note_text("The dev server is up at ")
    collector.note_text("http://localhost:5173/ — open it.")
    artifacts = collector.finish(folder)
    assert len(artifacts) == 1
    art = artifacts[0]
    assert art.kind == "url" and art.location == "http://localhost:5173/" and art.media == "url"
    assert art.title == "http://localhost:5173/" and art.source == "text" and art.open is True


def test_named_existing_markdown_path_in_text_is_collected(tmp_path: Path) -> None:
    folder = tmp_path / "proj"
    folder.mkdir()
    report = touch(folder / "reports" / "summary.md")
    collector = TurnCollector(make_chat(folder))
    collector.note_tool("Bash", {"command": "python make_report.py"})
    collector.note_text("Done — the report is at reports/summary.md, and reports/missing.md was skipped.")
    artifacts = collector.finish(folder)
    assert [(a.location, a.media, a.source, a.open) for a in artifacts] == [(str(report), "markdown", "text", True)]


def test_markdown_link_in_text_is_collected_and_opens(tmp_path: Path) -> None:
    folder = tmp_path / "proj"
    folder.mkdir()
    report = touch(folder / "reports" / "summary.md")
    collector = TurnCollector(make_chat(folder))
    collector.note_tool("Bash", {"command": "python make_report.py"})
    collector.note_text("Done — see [the report](reports/summary.md) and the [app](http://localhost:3000/app).")
    artifacts = collector.finish(folder)
    assert [(a.location, a.media, a.source, a.open) for a in artifacts] == [
        (str(report), "markdown", "text", False),
        ("http://localhost:3000/app", "url", "text", True),
    ]


def test_text_mention_of_a_tool_written_file_keeps_tool_source(tmp_path: Path) -> None:
    folder = tmp_path / "proj"
    folder.mkdir()
    report = touch(folder / "summary.md")
    collector = TurnCollector(make_chat(folder))
    collector.note_tool("Write", {"file_path": str(report), "content": ""})
    collector.note_text("I wrote summary.md for you.")
    artifacts = collector.finish(folder)
    assert len(artifacts) == 1
    assert artifacts[0].source == "tool" and artifacts[0].open is True


def test_artifact_outside_folder_is_still_reported(tmp_path: Path) -> None:
    # Review Focus 1: a file written outside the chat's folder opens like any other.
    folder = tmp_path / "proj"
    folder.mkdir()
    outside = touch(tmp_path / "scratch" / "draft.md")
    collector = TurnCollector(make_chat(folder))
    collector.note_tool("Write", {"file_path": str(outside), "content": ""})
    artifacts = collector.finish(folder)
    assert [(a.location, a.media, a.open) for a in artifacts] == [(str(outside), "markdown", True)]
    assert not (folder / "draft.md").exists()  # the chat folder is untouched


def test_empty_turn_yields_nothing(tmp_path: Path) -> None:
    collector = TurnCollector(make_chat(tmp_path))
    collector.note_text("Just a reply, nothing produced.")
    assert collector.finish(tmp_path) == []


# --- through the server -------------------------------------------------------


async def test_newest_viewable_opens_at_finish_only(
    server: GatewayServer, factory: EngineFactory, folder: Path, state_dir: StateDir
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        a = touch(folder / "a.md")
        b = touch(folder / "b.png")
        frames = await run_turn(
            conn,
            number,
            engine,
            text_delta("Writing"),
            write_tool(a, "toolu_1"),
            tool_result("toolu_1", "ok"),
            write_tool(b, "toolu_2"),
            tool_result("toolu_2", "ok"),
            text_delta(" done."),
        )
        kinds = [type(m) for m in frames]
        # Nothing opens mid-turn: both artifacts come after the last tool event, before turn.finished.
        assert kinds.index(ArtifactCreated) > max(i for i, k in enumerate(kinds) if k in (ToolStarted, ToolFinished))
        assert kinds[-1] is TurnFinished
        created = [m for m in frames if isinstance(m, ArtifactCreated)]
        assert [(m.artifact.location, m.artifact.open) for m in created] == [(str(a), False), (str(b), True)]
        assert all(m.chat == number and m.seq is not None for m in created)

        chat = server.registry.get(number)
        assert [m.seq for m in chat.ring] == list(range(1, chat.seq + 1))
        assert [x.location for x in chat.artifacts] == [str(a), str(b)]
    finally:
        await conn.close()


async def test_url_and_named_path_in_streamed_text_are_reported(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        report = touch(folder / "report.md")
        frames = await run_turn(
            conn,
            number,
            engine,
            text_delta("Report at report.md; preview on http://localhost:"),
            text_delta("4000/preview."),
        )
        created = [m.artifact for m in frames if isinstance(m, ArtifactCreated)]
        assert [(a.kind, a.location, a.open) for a in created] == [
            ("file", str(report), False),
            ("url", "http://localhost:4000/preview", True),
        ]
    finally:
        await conn.close()


async def test_producer_endpoint_opens_immediately_and_needs_token(
    server: GatewayServer, factory: EngineFactory, folder: Path, state_dir: StateDir
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        page = touch(folder / "build" / "index.html")

        status, body = await http_post(server.port, "/v1/artifact", {"chat": number, "location": str(page)}, None)
        assert status == 401
        status, body = await http_post(server.port, "/v1/artifact", {"chat": number, "location": str(page)}, "wrong")
        assert status == 401
        status, body = await http_post(server.port, "/v1/artifact", {"chat": 99, "location": str(page)}, server.token)
        assert status == 404
        status, body = await http_post(server.port, "/v1/artifact", {"chat": number}, server.token)
        assert status == 400
        status, body = await http_post(server.port, "/v1/artifact", {"location": str(page)}, server.token)
        assert status == 400
        # Nothing reached the app for any of those.
        with pytest.raises(TimeoutError):
            await recv(conn, timeout=0.2)

        status, body = await http_post(
            server.port, "/v1/artifact", {"chat": number, "location": str(page), "title": "Build preview"}, server.token
        )
        assert status == 201, body
        event = await recv(conn)
        assert isinstance(event, ArtifactCreated)
        assert event.chat == number and event.seq is not None
        art = event.artifact
        assert art.kind == "file" and art.location == str(page) and art.media == "html"
        assert art.title == "Build preview" and art.source == "producer" and art.open is True
        assert body["artifact"]["id"] == art.id

        # A URL, and a relative path resolved against the chat's folder; title defaults to the name/URL.
        status, body = await http_post(
            server.port, "/v1/artifact", {"chat": number, "location": "http://127.0.0.1:8080/"}, server.token
        )
        assert status == 201
        url_event = await recv(conn)
        assert isinstance(url_event, ArtifactCreated)
        assert url_event.artifact.kind == "url" and url_event.artifact.media == "url"
        assert url_event.artifact.title == "http://127.0.0.1:8080/" and url_event.artifact.open is True

        status, body = await http_post(
            server.port, "/v1/artifact", {"chat": number, "location": "build/index.html"}, server.token
        )
        assert status == 201
        rel_event = await recv(conn)
        assert isinstance(rel_event, ArtifactCreated)
        assert rel_event.artifact.location == str(page) and rel_event.artifact.title == "index.html"

        chat = server.registry.get(number)
        assert [a.source for a in chat.artifacts] == ["producer", "producer", "producer"]
        assert [a.id for a in state_dir.load_index().chats[0].artifacts] == [a.id for a in chat.artifacts]
    finally:
        await conn.close()


async def test_producer_works_while_no_app_is_attached(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach(server)
    number = await new_chat(conn, folder)
    await conn.close()
    await asyncio.sleep(0.05)
    assert not server.attached

    page = touch(folder / "out.md")
    status, body = await http_post(server.port, "/v1/artifact", {"chat": number, "location": str(page)}, server.token)
    assert status == 201
    chat = server.registry.get(number)
    assert [a.location for a in chat.artifacts] == [str(page)]
    # It is in the ring, so a reattaching app catches up through chat.open.
    assert any(isinstance(m, ArtifactCreated) for m in chat.ring)


async def test_artifact_opened_is_acknowledged_silently(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(ArtifactOpened(ts=TS, chat=number, artifact_id="art-whatever")))
        with pytest.raises(TimeoutError):
            await recv(conn, timeout=0.2)
    finally:
        await conn.close()


async def test_artifacts_persist_in_index(
    server: GatewayServer, factory: EngineFactory, folder: Path, state_dir: StateDir
) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        report = touch(folder / "report.md")
        await run_turn(conn, number, engine, write_tool(report, "toolu_1"), tool_result("toolu_1", "ok"))
        record = state_dir.load_index().chats[0]
        assert [(a.location, a.media, a.source) for a in record.artifacts] == [(str(report), "markdown", "tool")]

        # A fresh registry from the index carries the artifacts back into the chat.
        registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=10)
        assert [a.location for a in registry.get(number).artifacts] == [str(report)]
    finally:
        await conn.close()
