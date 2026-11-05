"""v0.19 (spec §8.3-8.4): images reach the agent as images; ``user.text`` carries the attachments apart.

``image_block`` and ``split_attachments`` are pure. ``SDKEngine.send`` is
checked against a stand-in client recording what ``query`` got; the gateway's
send path runs against the scripted ``FakeEngine`` from ``conftest``, so
nothing here touches a model.
"""

from __future__ import annotations

import base64
import struct
import zlib
from pathlib import Path
from typing import Any

from portico_gateway.config import hello_for
from portico_gateway.engine import SDKEngine, history_events
from portico_gateway.images import MAX_IMAGE_BYTES, image_block, image_blocks, split_attachments
from portico_gateway.messages import (
    MESSAGES_ATTACHMENTS_CAPABILITY,
    ChatNotice,
    ChatState,
    MessageSend,
    TurnFinished,
    TurnStarted,
    UserText,
    dump,
)
from portico_gateway.server import GatewayServer
from tests.conftest import make_config
from tests.test_server import attach
from tests.test_turns import EngineFactory, factory, folder, new_chat, recv_until, server  # noqa: F401 (fixtures)

TS = "2026-11-04T12:00:00Z"

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
    blocks, refused = image_blocks([str(small), str(large), str(heic), str(note)])
    assert [b["source"]["media_type"] for b in blocks] == ["image/png"]
    assert refused == ["b.png"]


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
    conn = await attach(server)
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
    conn = await attach(server)
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
