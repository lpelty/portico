"""v0.19 (spec §8.3-8.4): images reach the agent as images; ``user.text`` carries the attachments apart.

``image_block`` and ``split_attachments`` are pure. ``SDKEngine.send`` is
checked against a stand-in client recording what ``query`` got; the gateway's
send path runs against the scripted ``FakeEngine`` from ``conftest``, so
nothing here touches a model.
"""

from __future__ import annotations

import asyncio
import base64
import os
import struct
import zlib
from pathlib import Path
from typing import Any

from portico_gateway.config import hello_for
from portico_gateway.engine import SDKEngine, history_events
from portico_gateway import images as images_module
from portico_gateway.images import (
    MAX_ENCODED_TOTAL,
    MAX_IMAGE_BYTES,
    MAX_IMAGES,
    image_block,
    image_blocks,
    not_image_notice,
    split_attachments,
)
from portico_gateway.messages import (
    MESSAGES_ATTACHMENTS_CAPABILITY,
    ChatHistory,
    ChatNotice,
    ChatOpen,
    ChatQueue,
    ChatQueued,
    ChatState,
    Error,
    HelloClient,
    HelloServer,
    MessageSend,
    TurnFinished,
    TurnStarted,
    TurnStop,
    UserText,
    dump,
)
from portico_gateway.server import GatewayServer
from tests.conftest import Pause, fake_result, make_config
from tests.test_server import attach, ws_url
from tests.test_turns import (  # noqa: F401 (fixtures)
    EngineFactory,
    factory,
    folder,
    new_chat,
    recv,
    recv_until,
    server,
    tool_result,
    tool_use,
)
from websockets.asyncio.client import ClientConnection, connect

TS = "2026-11-04T12:00:00Z"
NEW_APP = [MESSAGES_ATTACHMENTS_CAPABILITY]
NEW_APP_QUEUEING = [MESSAGES_ATTACHMENTS_CAPABILITY, "queue.v1"]


async def attach_as(server: GatewayServer, capabilities: list[str]) -> ClientConnection:
    """An app that declared ``capabilities``: hello, chat.list, services.status."""
    conn = await connect(ws_url(server, server.token))
    await conn.send(dump(HelloClient(ts=TS, app_version="0.19.0", capabilities=capabilities)))
    assert isinstance(await recv(conn), HelloServer)
    await recv(conn)  # chat.list
    await recv(conn)  # services.status
    return conn


class Gate:
    """Stands in for ``GatewayServer._image_blocks``: waits on ``go`` (``reached`` says it got there), then reads."""

    def __init__(self, real: Any, before: Any = None) -> None:
        self.real = real
        self.before = before
        self.go = asyncio.Event()
        self.reached = asyncio.Event()

    async def __call__(self, paths: list[str]) -> Any:
        if not paths:
            return [], []
        self.reached.set()
        await self.go.wait()
        if self.before is not None:
            self.before()
        return await self.real(paths)

# The smallest JPEG start a sniffer needs: SOI, then an APP0 marker.
JPEG_HEAD = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
HEIC_HEAD = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic"


def png(width: int = 2, height: int = 2, rgb: tuple[int, int, int] = (255, 0, 0)) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    raw = (b"\x00" + bytes(rgb) * width) * height
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def big_png() -> bytes:
    """A PNG over the limit (about 4 MB): a real header, then padding the sniffer never reads past."""
    return png() + b"\x00" * (4_000_000 - len(png()))


# --- image_block ----------------------------------------------------------------


def test_a_png_is_an_image_block(tmp_path: Path) -> None:
    data = png()
    path = tmp_path / "red.png"
    path.write_bytes(data)
    assert image_block(path) == {
        "type": "image",
        "source": {"type": "base64", "media_type": "image/png", "data": base64.b64encode(data).decode("ascii")},
    }


def test_the_media_type_comes_from_the_bytes_not_the_name(tmp_path: Path) -> None:
    path = tmp_path / "really-a-photo.png"
    path.write_bytes(JPEG_HEAD)
    block = image_block(path)
    assert block is not None and block["source"]["media_type"] == "image/jpeg"
    gif = tmp_path / "anim.bin"
    gif.write_bytes(b"GIF89a" + b"\x00" * 10)
    webp = tmp_path / "pic"
    webp.write_bytes(b"RIFF\x10\x00\x00\x00WEBPVP8 " + b"\x00" * 8)
    assert [image_block(p)["source"]["media_type"] for p in (gif, webp)] == ["image/gif", "image/webp"]  # type: ignore[index]


def test_heic_and_an_oversized_png_are_not_image_blocks(tmp_path: Path) -> None:
    heic = tmp_path / "photo.heic"
    heic.write_bytes(HEIC_HEAD)
    large = tmp_path / "huge.png"
    large.write_bytes(big_png())
    assert large.stat().st_size > MAX_IMAGE_BYTES
    assert image_block(heic) is None
    assert image_block(large) is None
    assert image_block(tmp_path / "gone.png") is None


def test_image_blocks_names_only_the_images_it_could_not_send(tmp_path: Path) -> None:
    small, large, heic, note = tmp_path / "a.png", tmp_path / "b.png", tmp_path / "c.heic", tmp_path / "d.md"
    small.write_bytes(png())
    large.write_bytes(big_png())
    heic.write_bytes(HEIC_HEAD)
    note.write_text("notes")
    blocks, notices = image_blocks([str(small), str(large), str(heic), str(note)])
    assert [b["source"]["media_type"] for b in blocks] == ["image/png"]
    assert notices == ["b.png is too large to show the agent as an image; it can still open the file."]


def test_the_raw_cap_is_three_megabytes() -> None:
    assert MAX_IMAGE_BYTES == 3_000_000 and MAX_IMAGES == 4 and MAX_ENCODED_TOTAL == 12_000_000


def test_an_unreadable_or_vanished_image_says_so(tmp_path: Path) -> None:
    gone = tmp_path / "gone.png"
    locked = tmp_path / "locked.jpg"
    locked.write_bytes(JPEG_HEAD)
    os.chmod(locked, 0)
    try:
        blocks, notices = image_blocks([str(gone), str(locked), str(tmp_path / "gone.heic")])
    finally:
        os.chmod(locked, 0o600)
    assert blocks == []
    assert notices == [
        "gone.png can't be read as an image; it can still open the file.",
        "locked.jpg can't be read as an image; it can still open the file.",
    ]


def test_a_message_carries_at_most_four_images(tmp_path: Path) -> None:
    paths = []
    for n in range(MAX_IMAGES + 1):
        path = tmp_path / f"{n}.png"
        path.write_bytes(png())
        paths.append(str(path))
    blocks, notices = image_blocks(paths)
    assert len(blocks) == MAX_IMAGES
    assert notices == [not_image_notice("4.png", images_module.PAST_MESSAGE_CAP)]
    assert notices == ["4.png is past what one message can show the agent as images; it can still open the file."]


def test_a_message_carries_at_most_twelve_megabytes_encoded(tmp_path: Path) -> None:
    # Three images just under the raw cap encode to ~11.6 MB; a fourth would pass 12 MB.
    paths = []
    for n in range(4):
        path = tmp_path / f"big{n}.png"
        path.write_bytes(png() + b"\x00" * (2_900_000 - len(png())))
        paths.append(str(path))
    blocks, notices = image_blocks(paths)
    assert len(blocks) == 3
    assert sum(len(b["source"]["data"]) for b in blocks) <= MAX_ENCODED_TOTAL
    assert notices == [not_image_notice("big3.png", images_module.PAST_MESSAGE_CAP)]


# --- split_attachments ------------------------------------------------------------


def test_split_attachments_takes_the_trailing_block() -> None:
    assert split_attachments("Compare these\n\nAttached files:\n- /a.png\n- /b c.png") == ("Compare these", ["/a.png", "/b c.png"])
    assert split_attachments("plain") == ("plain", [])
    # A transcript's text is stripped: attachments only, the header first.
    assert split_attachments("Attached files:\n- /a.png") == ("", ["/a.png"])


def test_split_attachments_ignores_the_words_mid_text() -> None:
    mid = "I wrote\n\nAttached files:\n- /a.png\nin my notes, see?"
    assert split_attachments(mid) == (mid, [])
    both = "Quote: \n\nAttached files:\n- /old.png\nend\n\nAttached files:\n- /new.png"
    assert split_attachments(both) == ("Quote: \n\nAttached files:\n- /old.png\nend", ["/new.png"])


def test_split_attachments_needs_every_trailing_line_an_absolute_path() -> None:
    for text in (
        "Hi\n\nAttached files:\n- /a.png\n- relative.png",
        "Hi\n\nAttached files:\n- /a.png\nnot a path",
        "Hi\n\nAttached files:\n",
    ):
        assert split_attachments(text) == (text, []), text


# --- SDKEngine.send ---------------------------------------------------------------


class RecordingClient:
    """Stands in for ``ClaudeSDKClient``: keeps what each ``query`` got, an iterable drained to its messages."""

    def __init__(self) -> None:
        self.prompts: list[str | list[dict[str, Any]]] = []

    async def query(self, prompt: Any, session_id: str = "default") -> None:
        if isinstance(prompt, str):
            self.prompts.append(prompt)
        else:
            self.prompts.append([m async for m in prompt])


async def test_send_with_images_queries_one_message_of_blocks(tmp_path: Path) -> None:
    path = tmp_path / "red.png"
    path.write_bytes(png())
    block = image_block(path)
    assert block is not None
    client = RecordingClient()
    engine = SDKEngine(chat=1)
    engine._client = client  # type: ignore[assignment]

    text = f"Compare these\n\nAttached files:\n- {path}"
    await engine.send(text, [block])
    await engine.inject("And this", [block])
    await engine.send("no images")

    assert client.prompts[0] == [
        {
            "type": "user",
            "message": {"role": "user", "content": [{"type": "text", "text": text}, block]},
            "parent_tool_use_id": None,
            "session_id": "default",
        }
    ]
    assert client.prompts[1][0]["message"]["content"] == [{"type": "text", "text": "And this"}, block]  # type: ignore[index]
    assert client.prompts[2] == "no images"
    assert engine.turn == 2  # inject does not move the turn


# --- the gateway's send path ------------------------------------------------------


async def test_an_image_goes_to_the_engine_and_user_text_carries_it(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    image = folder / "before.png"
    image.write_bytes(png())
    conn = await attach_as(server, NEW_APP)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="Compare these", attachments=[str(image)])))
        frames = await recv_until(conn, TurnFinished)
        engine = factory.last
        assert engine.calls[-1] == ("send", f"Compare these\n\nAttached files:\n- {image}")
        assert engine.sent_images[-1] == [image_block(image)]
        user = next(f for f in frames if isinstance(f, UserText))
        assert user.text == "Compare these" and user.attachments == [str(image)]
        assert not any(isinstance(f, ChatNotice) for f in frames)
    finally:
        await conn.close()


async def test_an_oversized_image_goes_as_a_path_with_a_notice(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    image = folder / "huge.png"
    image.write_bytes(big_png())
    conn = await attach_as(server, NEW_APP)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="Look", attachments=[str(image)])))
        frames = await recv_until(conn, TurnFinished)
        engine = factory.last
        assert engine.calls[-1] == ("send", f"Look\n\nAttached files:\n- {image}")
        assert engine.sent_images[-1] == []
        notices = [f for f in frames if isinstance(f, ChatNotice)]
        assert [(n.kind, n.text) for n in notices] == [
            ("attachment.not_image", "huge.png is too large to show the agent as an image; it can still open the file.")
        ]
        # The notice follows the person's message in the turn.
        kinds = [type(f) for f in frames]
        assert kinds[:4] == [TurnStarted, UserText, ChatState, ChatNotice]
    finally:
        await conn.close()


async def test_old_and_new_apps_see_their_own_user_text(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    image = folder / "before.png"
    image.write_bytes(png())
    full = f"Compare these\n\nAttached files:\n- {image}"
    new = await attach_as(server, NEW_APP)
    number = await new_chat(new, folder)
    await new.send(dump(MessageSend(ts=TS, chat=number, text="Compare these", attachments=[str(image)])))
    live = next(f for f in await recv_until(new, TurnFinished) if isinstance(f, UserText))
    assert (live.text, live.attachments) == ("Compare these", [str(image)])
    await new.close()

    # The ring keeps the typed text; an app without the capability gets today's text from it.
    ring = [m for m in server.registry.get(number).ring if isinstance(m, UserText)]
    assert [(m.text, m.attachments) for m in ring] == [("Compare these", [str(image)])]
    old = await attach(server)
    try:
        await old.send(dump(ChatOpen(ts=TS, chat=number)))
        history = await recv(old)
        assert isinstance(history, ChatHistory)
        [replayed] = [m for m in history.events if isinstance(m, UserText)]
        assert (replayed.text, replayed.attachments) == (full, [])
        # Live too: the old app's next turn with an attachment.
        await old.send(dump(MessageSend(ts=TS, chat=number, text="Again", attachments=[str(image)])))
        frames = await recv_until(old, TurnFinished)
        said = next(f for f in frames if isinstance(f, UserText) and f.turn == 2)
        assert (said.text, said.attachments) == (f"Again\n\nAttached files:\n- {image}", [])
    finally:
        await old.close()

    again = await attach_as(server, NEW_APP)
    try:
        await again.send(dump(ChatOpen(ts=TS, chat=number)))
        history = await recv(again)
        assert isinstance(history, ChatHistory)
        assert [(m.text, m.attachments) for m in history.events if isinstance(m, UserText)] == [
            ("Compare these", [str(image)]),
            ("Again", [str(image)]),
        ]
    finally:
        await again.close()


async def test_a_known_command_with_an_image_goes_as_a_string(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    image = folder / "shot.png"
    image.write_bytes(png())
    conn = await attach_as(server, NEW_APP)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        engine.commands = {"review"}
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="/review this", attachments=[str(image)])))
        frames = await recv_until(conn, TurnFinished)
        assert engine.calls[-1] == ("send", f"/review this\n\nAttached files:\n- {image}")
        assert engine.sent_images[-1] == []
        assert not any(isinstance(f, ChatNotice) for f in frames)
    finally:
        await conn.close()


async def test_the_echo_goes_before_the_images_are_read_and_a_second_send_is_refused(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    image = folder / "before.png"
    image.write_bytes(png())
    gate = Gate(server._image_blocks)
    server._image_blocks = gate  # type: ignore[method-assign]
    conn = await attach_as(server, NEW_APP)
    try:
        number = await new_chat(conn, folder)
        engine = factory.last
        await conn.send(dump(MessageSend(ts=TS, chat=number, id="req-a", text="one", attachments=[str(image)])))
        await conn.send(dump(MessageSend(ts=TS, chat=number, id="req-b", text="two", attachments=[str(image)])))
        await asyncio.wait_for(gate.reached.wait(), 5)
        frames = await recv_until(conn, Error)
        # The echo went while the images were still being read; the second send was busy.
        assert [type(f) for f in frames] == [TurnStarted, UserText, ChatState, Error]
        assert frames[-1].code == "chat.busy" and frames[-1].id == "req-b"  # type: ignore[union-attr]
        assert [c for c in engine.calls if c[0] == "send"] == []
        gate.go.set()
        await recv_until(conn, TurnFinished)
        assert [c[1] for c in engine.calls if c[0] == "send"] == [f"one\n\nAttached files:\n- {image}"]
        assert engine.sent_images[-1] == [image_block(image)]
    finally:
        await conn.close()


async def test_an_image_that_vanishes_before_it_is_read_goes_as_a_path(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    image = folder / "brief.png"
    image.write_bytes(png())
    gate = Gate(server._image_blocks, before=image.unlink)
    gate.go.set()
    server._image_blocks = gate  # type: ignore[method-assign]
    conn = await attach_as(server, NEW_APP)
    try:
        number = await new_chat(conn, folder)
        await conn.send(dump(MessageSend(ts=TS, chat=number, text="Look", attachments=[str(image)])))
        frames = await recv_until(conn, TurnFinished)
        assert factory.last.sent_images[-1] == []
        assert [n.text for n in frames if isinstance(n, ChatNotice)] == [
            "brief.png can't be read as an image; it can still open the file."
        ]
    finally:
        await conn.close()


# --- the queue ----------------------------------------------------------------------


async def _queued_during_a_pause(server: GatewayServer, factory: EngineFactory, folder: Path, image: Path):
    conn = await attach_as(server, NEW_APP_QUEUEING)
    number = await new_chat(conn, folder)
    engine = factory.last
    pause = Pause()
    engine.script(tool_use("toolu_1", "Bash", {"command": "ls"}), pause, tool_result("toolu_1", "a.md"), fake_result())
    await conn.send(dump(MessageSend(ts=TS, chat=number, id="req-1", text="first")))
    await recv_until(conn, ChatState)
    await asyncio.wait_for(pause.reached.wait(), 5)
    await conn.send(dump(MessageSend(ts=TS, chat=number, id="req-2", text="And this", attachments=[str(image)])))
    await recv_until(conn, ChatQueued)
    assert isinstance(await recv(conn), ChatQueue)
    return conn, number, engine, pause


async def test_a_queued_image_is_injected_as_an_image(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    image = folder / "after.png"
    image.write_bytes(png())
    conn, number, engine, pause = await _queued_during_a_pause(server, factory, folder, image)
    try:
        pause.go.set()
        frames = await recv_until(conn, TurnFinished)
        assert ("inject", f"And this\n\nAttached files:\n- {image}") in engine.calls
        assert engine.sent_images[-1] == [image_block(image)]
        said = [f for f in frames if isinstance(f, UserText)]
        assert [(m.text, m.attachments, m.turn) for m in said] == [("And this", [str(image)], 1)]
    finally:
        await conn.close()


async def test_a_stop_while_a_queued_image_is_read_returns_it_and_writes_nothing(
    server: GatewayServer, factory: EngineFactory, folder: Path
) -> None:
    image = folder / "after.png"
    image.write_bytes(png())
    conn, number, engine, pause = await _queued_during_a_pause(server, factory, folder, image)
    gate = Gate(server._image_blocks)
    server._image_blocks = gate  # type: ignore[method-assign]
    try:
        pause.go.set()
        await asyncio.wait_for(gate.reached.wait(), 5)
        await conn.send(dump(TurnStop(ts=TS, chat=number)))
        returned = (await recv_until(conn, ChatQueue))[-1]
        assert isinstance(returned, ChatQueue) and [i.id for i in returned.returned] == ["req-2"]
        gate.go.set()
        frames = await recv_until(conn, TurnFinished)
        assert not any(c[0] == "inject" for c in engine.calls)
        assert not any(isinstance(f, UserText) for f in frames)
    finally:
        await conn.close()


# --- replay -----------------------------------------------------------------------


def test_replay_gives_the_typed_text_and_the_attachments() -> None:
    image = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="}}
    session = [
        {
            "type": "user",
            "session_id": "s",
            "message": {
                "role": "user",
                "content": [{"type": "text", "text": "Compare these\n\nAttached files:\n- /a.png"}, image],
            },
        },
        {"type": "assistant", "session_id": "s", "message": {"role": "assistant", "content": [{"type": "text", "text": "Red."}]}},
        {"type": "user", "session_id": "s", "message": {"role": "user", "content": "Thanks"}},
    ]
    users = [e for e in history_events(session, chat=2) if isinstance(e, UserText)]
    assert users == [
        UserText(ts=users[0].ts, chat=2, turn=1, text="Compare these", attachments=["/a.png"]),
        UserText(ts=users[1].ts, chat=2, turn=2, text="Thanks"),
    ]


# --- hello ------------------------------------------------------------------------


def test_hello_lists_messages_attachments() -> None:
    hello = hello_for(make_config(), "7f1c4a2e-3b5d-4c6e-9a8b-0d1e2f3a4b5c", "0.19.0")
    assert MESSAGES_ATTACHMENTS_CAPABILITY == "messages.attachments.v1"
    assert MESSAGES_ATTACHMENTS_CAPABILITY in hello.capabilities
