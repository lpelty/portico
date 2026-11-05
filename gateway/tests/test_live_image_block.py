"""v0.19 Task 0 (spec §8.3): the live probe that an image content block reaches the agent through ``query()``.

Gated like ``tests/test_live_smoke.py``: ``PORTICO_LIVE=1`` and a provider
credential in the environment; skipped otherwise. It starts the gateway's own
``SDKEngine`` in a throwaway folder, with a scratch ``CLAUDE_CONFIG_DIR`` so no
user plugins, hooks or settings mix in, and passes ``ClaudeSDKClient.query`` an
async iterable yielding one user message whose content is a text block and a
base64 PNG block: a 64x64 solid red square, written here with ``zlib`` and
``struct``. The reply must name the colour.

The message dict is the one Task 7 sends verbatim: the SDK's own string-path
message (``type``, ``message`` with ``role`` and ``content``,
``parent_tool_use_id``, ``session_id``), with ``content`` a list of blocks.

Run once here: ``PORTICO_LIVE=1 uv run pytest tests/test_live_image_block.py -v``
"""

from __future__ import annotations

import asyncio
import base64
import os
import struct
import zlib
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest

from portico_gateway.doctor import has_credential
from portico_gateway.engine import SDKEngine
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


def user_message(text: str, png: bytes) -> dict[str, Any]:
    """The message ``ClaudeSDKClient.query`` writes for a string, with ``content`` as blocks instead."""
    return {
        "type": "user",
        "message": {
            "role": "user",
            "content": [
                {"type": "text", "text": text},
                {
                    "type": "image",
                    "source": {"type": "base64", "media_type": "image/png", "data": base64.b64encode(png).decode("ascii")},
                },
            ],
        },
        "parent_tool_use_id": None,
        "session_id": "default",
    }


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
        message = user_message(PROMPT, solid_png(64, 64, (255, 0, 0)))

        async def one() -> AsyncIterator[dict[str, Any]]:
            yield message

        assert engine._client is not None
        engine.turn += 1
        await engine._client.query(one())

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
