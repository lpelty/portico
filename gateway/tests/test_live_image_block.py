"""v0.19 Task 0 (spec §8.3): the live probe that an image content block reaches the agent through ``query()``.

Gated like ``tests/test_live_smoke.py``: ``PORTICO_LIVE=1`` and a provider
credential in the environment; skipped otherwise. It starts the gateway's own
``SDKEngine`` in a throwaway folder, with a scratch ``CLAUDE_CONFIG_DIR`` so no
user plugins, hooks or settings mix in, and passes ``ClaudeSDKClient.query`` an
async iterable yielding one user message whose content is a text block and a
base64 PNG block: a 64x64 solid red square, written here with ``zlib`` and
``struct``. The reply must name the colour.

It goes the shipped way: ``images.image_block`` reads the file and
``SDKEngine.send(text, [block])`` builds the message (``images.user_message``:
the SDK's own string-path message, ``content`` a list of blocks) and passes
``query`` an async iterable yielding it.

Run once here: ``PORTICO_LIVE=1 uv run pytest tests/test_live_image_block.py -v``
"""

from __future__ import annotations

import asyncio
import os
import struct
import zlib
from pathlib import Path

import pytest

from portico_gateway.doctor import has_credential
from portico_gateway.engine import SDKEngine
from portico_gateway.images import image_block
from portico_gateway.messages import TextDelta, TurnFinished
from tests.conftest import RecordingCallbacks

pytestmark = pytest.mark.skipif(
    os.environ.get("PORTICO_LIVE") != "1" or not has_credential(os.environ),
    reason="live image probe: set PORTICO_LIVE=1 and a provider credential in the environment",
)

PROMPT = "What single colour fills this image? Answer with the colour's name in one word."
TURN_TIMEOUT = 180.0


def solid_png(width: int, height: int, rgb: tuple[int, int, int]) -> bytes:
    """A truecolour PNG of one colour: signature, IHDR, one zlib IDAT, IEND."""

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    row = b"\x00" + bytes(rgb) * width  # filter byte 0 (None), then the pixels
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8-bit RGB, no interlace
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(row * height))
        + chunk(b"IEND", b"")
    )


def test_solid_png_is_a_png() -> None:
    png = solid_png(64, 64, (255, 0, 0))
    assert png.startswith(b"\x89PNG\r\n\x1a\n") and b"IHDR" in png and png.endswith(b"IEND\xaeB`\x82")


async def test_an_image_block_reaches_the_agent(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    config_dir = tmp_path / "cli-config"
    config_dir.mkdir()
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config_dir))
    folder = tmp_path / "image-probe"
    folder.mkdir()

    engine = SDKEngine(chat=1, init_timeout=60.0)
    callbacks = RecordingCallbacks()
    await engine.start(folder, None, ["project"], callbacks)
    try:
        # The shipped path (fix round 1): ``image_block`` reads the file, ``SDKEngine.send``
        # builds the message (``images.user_message``) and hands ``query`` the iterable.
        image = folder / "red.png"
        image.write_bytes(solid_png(64, 64, (255, 0, 0)))
        block = image_block(image)
        assert block is not None and block["source"]["media_type"] == "image/png"
        await engine.send(PROMPT, [block])

        deadline = asyncio.get_running_loop().time() + TURN_TIMEOUT
        while not any(isinstance(e, TurnFinished) for e in callbacks.events):
            assert asyncio.get_running_loop().time() < deadline, f"no reply within {TURN_TIMEOUT}s: {callbacks.events}"
            await asyncio.sleep(0.2)
        finished = next(e for e in callbacks.events if isinstance(e, TurnFinished))
        reply = "".join(e.text for e in callbacks.events if isinstance(e, TextDelta))
        assert finished.outcome == "done", (finished, reply, callbacks.events)
        assert "red" in reply.lower(), f"the agent did not see the image: {reply!r}"
    finally:
        await engine.close()
