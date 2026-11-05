"""v0.19 (spec §8.3): image attachments reach the agent as image content blocks.

An attachment that is a png, jpeg, gif or webp of at most ``MAX_IMAGE_BYTES``
goes to the engine as a base64 ``image`` block after the message's text block;
its path stays in the text's "Attached files:" block as well, so the agent
knows where the file lives. The format is read from the file's first bytes,
never its name. An image too large, or one that cannot be read, goes as a
path only, and the person is told (``not_image_notice``). Other files are
paths only, as before.
"""

from __future__ import annotations

import base64
from collections.abc import Iterable
from pathlib import Path
from typing import Any

# The API's 5 MB limit is on the base64 text; 3.75 MB of raw bytes encodes to it.
MAX_IMAGE_BYTES = 3_750_000

# The exact form attachments take in the text the engine receives
# (PROTOCOL.md, ``message.send``): "\n\n" + this + "\n", then "- /path" lines.
ATTACHMENT_HEADER = "Attached files:"

# The ``chat.notice`` kind for an image that goes as a path only.
NOT_IMAGE_NOTICE_KIND = "attachment.not_image"

# Names that read as an image the agent could have been shown; one that
# cannot be read or sniffed is still the person's image, and they hear why.
_IMAGE_SUFFIXES = frozenset({".png", ".jpg", ".jpeg", ".gif", ".webp"})


def media_type(head: bytes) -> str | None:
    """The image's media type from its first bytes (at least 12); ``None`` when it is not png, jpeg, gif or webp."""
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if head.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if head.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if len(head) >= 12 and head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp"
    return None


def image_block(path: Path) -> dict[str, Any] | None:
    """The ``image`` content block for ``path``; ``None`` when it is not a supported image, is too large, or can't be read."""
    try:
        if path.stat().st_size > MAX_IMAGE_BYTES:
            return None
        with path.open("rb") as f:
            data = f.read(MAX_IMAGE_BYTES + 1)
    except OSError:
        return None
    if len(data) > MAX_IMAGE_BYTES:
        return None  # grew since the stat
    kind = media_type(data[:12])
    if kind is None:
        return None
    return {"type": "image", "source": {"type": "base64", "media_type": kind, "data": base64.b64encode(data).decode("ascii")}}


def _reads_as_image(path: Path) -> bool:
    """Whether ``path`` is a supported image by its bytes, or, when they can't be read, by its name."""
    try:
        with path.open("rb") as f:
            return media_type(f.read(12)) is not None
    except OSError:
        return path.suffix.lower() in _IMAGE_SUFFIXES


def image_blocks(paths: Iterable[str]) -> tuple[list[dict[str, Any]], list[str]]:
    """The image blocks for ``paths``, in order, and the names of the images that go as paths only.

    A file that is not a supported image (HEIC, a PDF, text) is neither: it goes as a path, as any file does.
    """
    blocks: list[dict[str, Any]] = []
    refused: list[str] = []
    for raw in paths:
        path = Path(raw)
        block = image_block(path)
        if block is not None:
            blocks.append(block)
        elif _reads_as_image(path):
            refused.append(path.name)
    return blocks, refused


def not_image_notice(name: str) -> str:
    """What the person sees for an image the agent is not shown."""
    return f"{name} is too large to show the agent as an image; it can still open the file."


def split_attachments(text: str) -> tuple[str, list[str]]:
    """``text`` as typed and its attachments' paths, from the trailing "Attached files:" block.

    Only a block at the very end counts, and only when every line after its
    header is "- " and an absolute path; otherwise ``(text, [])``. The text
    may have been stripped (a transcript's), so a message of attachments
    only, the header first, gives ``("", paths)``.
    """
    marker = "\n\n" + ATTACHMENT_HEADER + "\n"
    at = text.rfind(marker)
    if at >= 0:
        typed, tail = text[:at], text[at + len(marker) :]
    elif text.startswith(ATTACHMENT_HEADER + "\n"):
        typed, tail = "", text[len(ATTACHMENT_HEADER) + 1 :]
    else:
        return text, []
    lines = tail.split("\n")
    if not lines or not all(line.startswith("- /") for line in lines):
        return text, []
    return typed, [line[2:] for line in lines]


def user_message(text: str, images: list[dict[str, Any]], session_id: str = "default") -> dict[str, Any]:
    """The user message ``ClaudeSDKClient.query`` writes for a string prompt, with ``content`` as blocks:
    the text, then each image (the shape Task 0's live probe proved)."""
    return {
        "type": "user",
        "message": {"role": "user", "content": [{"type": "text", "text": text}, *images]},
        "parent_tool_use_id": None,
        "session_id": session_id,
    }
