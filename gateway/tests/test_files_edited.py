"""v0.20 (spec §2.7, ``files.edited.v1``): the agent hears of the person's viewer edits with their next message.

``files.edited {chat, path}`` is remembered per chat (ordered, unique). The
next ``message.send`` (or an injected queued message) reaches the engine as
the note, the typed text, then the attachment block; ``user.text`` stays what
was typed. A slash command goes without it and leaves the edits for the next message.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from websockets.asyncio.client import ClientConnection, connect

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.messages import (
    ChatQueue,
    FilesEdited,
    HelloClient,
    HelloServer,
    MessageSend,
    TurnFinished,
    UserText,
    dump,
)
from portico_gateway.server import GatewayServer, edited_note
from portico_gateway.state import StateDir
from tests.conftest import Pause, fake_result, make_config
from tests.test_server import ws_url
from tests.test_turns import EngineFactory, TS, new_chat, recv, recv_until, text_delta, tool_result, tool_use


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
async def server(state_dir: StateDir, factory: EngineFactory) -> AsyncIterator[GatewayServer]:
    cfg = make_config(setting_sources=["project"])
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=cfg.history_buffer)
    srv = GatewayServer(config=cfg, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
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


async def attach_app(server: GatewayServer) -> tuple[ClientConnection, HelloServer]:
    conn = await connect(ws_url(server, server.token))
    await conn.send(dump(HelloClient(ts=TS, app_version="0.20.0", capabilities=["queue.v1", "files.edited.v1"])))
    hello = await recv(conn)
    assert isinstance(hello, HelloServer)
    await recv(conn)  # chat.list
    await recv(conn)  # services.status
    return conn, hello


async def edited(conn: ClientConnection, number: int, path: Path | str) -> None:
    await conn.send(dump(FilesEdited(ts=TS, chat=number, path=str(path))))


async def one_turn(conn: ClientConnection, factory: EngineFactory, number: int, text: str, **kw: object) -> UserText:
    factory.last.script(text_delta("ok"), fake_result())
    await conn.send(dump(MessageSend(ts=TS, chat=number, text=text, **kw)))  # type: ignore[arg-type]
    frames = await recv_until(conn, TurnFinished)
    await recv(conn)  # chat.state idle
    return next(m for m in frames if isinstance(m, UserText))


def sent(factory: EngineFactory) -> list[str]:
    return [c[1] for c in factory.last.calls if c[0] == "send"]  # type: ignore[misc]


async def test_hello_lists_the_capability(server: GatewayServer) -> None:
    conn, hello = await attach_app(server)
    try:
        assert "files.edited.v1" in hello.capabilities
    finally:
        await conn.close()


def test_the_note_names_paths_relative_to_the_folder_or_absolute(tmp_path: Path) -> None:
    folder = tmp_path / "demo"
    other = tmp_path / "elsewhere" / "x.md"
    assert edited_note([], folder) == ""
    note = edited_note([str(folder / "notes" / "a.md"), str(other)], folder)
    assert note == f"(Edited in the viewer since your last message: notes/a.md, {other})\n\n"


async def test_two_saves_of_one_file_and_one_of_another_give_one_note_in_order(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn, _ = await attach_app(server)
    try:
        number = await new_chat(conn, folder)
        await edited(conn, number, folder / "a.md")
        await edited(conn, number, folder / "b.md")
        await edited(conn, number, folder / "a.md")
        said = await one_turn(conn, factory, number, "Look at them")
        assert sent(factory) == ["(Edited in the viewer since your last message: a.md, b.md)\n\nLook at them"]
        # The bubble is what was typed.
        assert said.text == "Look at them"
        assert not any("Edited in the viewer" in str(m) for m in server.registry.get(number).ring if isinstance(m, UserText))
    finally:
        await conn.close()


async def test_the_note_goes_once_then_the_edits_are_cleared(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn, _ = await attach_app(server)
    try:
        number = await new_chat(conn, folder)
        await edited(conn, number, folder / "a.md")
        await one_turn(conn, factory, number, "first")
        await one_turn(conn, factory, number, "second")
        assert sent(factory)[1] == "second"
    finally:
        await conn.close()


async def test_the_note_comes_before_the_text_and_the_attachment_block(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    attached = folder / "n.txt"
    attached.write_text("x")
    conn, _ = await attach_app(server)
    try:
        number = await new_chat(conn, folder)
        await edited(conn, number, folder / "a.md")
        await one_turn(conn, factory, number, "see", attachments=[str(attached)])
        assert sent(factory) == [
            f"(Edited in the viewer since your last message: a.md)\n\nsee\n\nAttached files:\n- {attached}"
        ]
    finally:
        await conn.close()


async def test_a_slash_command_goes_without_the_note_and_leaves_the_edits(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn, _ = await attach_app(server)
    try:
        number = await new_chat(conn, folder)
        await edited(conn, number, folder / "a.md")
        await one_turn(conn, factory, number, "/standup now")
        assert sent(factory) == ["/standup now"]
        await one_turn(conn, factory, number, "then")
        assert sent(factory)[1] == "(Edited in the viewer since your last message: a.md)\n\nthen"
    finally:
        await conn.close()


async def test_an_injected_queued_message_gets_the_note(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    conn, _ = await attach_app(server)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        pause = Pause()
        engine.script(tool_use("toolu_1", "Bash", {"command": "ls"}), pause, tool_result("toolu_1", "a.md"), fake_result())
        await conn.send(dump(MessageSend(ts=TS, chat=number, id="req-1", text="first")))
        await recv_until(conn, UserText)
        await asyncio.wait_for(pause.reached.wait(), 5)
        await edited(conn, number, folder / "a.md")
        await conn.send(dump(MessageSend(ts=TS, chat=number, id="req-2", text="also")))  # queued
        await recv_until(conn, ChatQueue)
        pause.go.set()
        frames = await recv_until(conn, TurnFinished)
        assert ("inject", "(Edited in the viewer since your last message: a.md)\n\nalso") in engine.calls
        assert [m.text for m in frames if isinstance(m, UserText)] == ["also"]
        await recv(conn)  # idle
        await one_turn(conn, factory, number, "after")
        assert sent(factory)[-1] == "after"
    finally:
        await conn.close()
