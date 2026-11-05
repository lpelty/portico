"""v0.19 (spec §8.3): image attachments reach the agent as image content blocks.

An attachment that is a png, jpeg, gif or webp of at most ``MAX_IMAGE_BYTES``
goes to the engine as a base64 ``image`` block after the message's text block;
its path stays in the text's "Attached files:" block as well, so the agent
knows where the file lives. The format is read from the file's first bytes,
never its name. One message carries at most ``MAX_IMAGES`` images and
``MAX_ENCODED_TOTAL`` base64 bytes of them. An image too large, past those
caps, or one that cannot be read, goes as a path only, and the person is told
(``image_blocks``' notices). Other files are paths only, as before.
"""

from __future__ import annotations

import re
import base64
import os
from collections.abc import Iterable
from pathlib import Path
from typing import Any

# Raw bytes per image (fix round 1, ruling A): base64 of 3 MB is about 4.0 MB,
# under the API's 5 MB limit on the encoded text with margin.
MAX_IMAGE_BYTES = 3_000_000

# Per message (ruling B): images past either cap go as paths only.
MAX_IMAGES = 4
MAX_ENCODED_TOTAL = 12_000_000

# The exact form attachments take in the text the engine receives
# (PROTOCOL.md, ``message.send``): "\n\n" + this + "\n", then "- /path" lines.
ATTACHMENT_HEADER = "Attached files:"

# The ``chat.notice`` kind for an image that goes as a path only.
NOT_IMAGE_NOTICE_KIND = "attachment.not_image"

# Why an image goes as a path only; each has its notice (``not_image_notice``).
TOO_LARGE = "too_large"
UNREADABLE = "unreadable"
PAST_MESSAGE_CAP = "past_message_cap"
UNSUPPORTED = "unsupported_format"

# Names that read as an image the agent could have been shown; one that
# cannot be read or sniffed is still the person's image, and they hear why.
_IMAGE_SUFFIXES = frozenset({".png", ".jpg", ".jpeg", ".gif", ".webp"})

# Image types the app shows as thumbnails but the engine cannot be sent
# (read from the name when the bytes are not one of the four sendable
# formats): the person is told the agent has only the path.
_UNSENDABLE_SUFFIXES = frozenset({".heic", ".heif", ".tiff", ".tif", ".bmp"})


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


def read_image(path: Path) -> tuple[dict[str, Any] | None, str | None]:
    """``path``'s ``image`` block, or ``None`` and why: ``TOO_LARGE``, ``UNREADABLE``, ``UNSUPPORTED``, or ``None`` for not an image.

    A file that can't be opened or read (gone since it was checked, no
    permission) is ``UNREADABLE`` when its name says image, else not one.
    """
    try:
        with path.open("rb") as f:
            head = f.read(12)
            kind = media_type(head)
            if kind is None:
                return None, (UNSUPPORTED if path.suffix.lower() in _UNSENDABLE_SUFFIXES else None)
            if os.fstat(f.fileno()).st_size > MAX_IMAGE_BYTES:
                return None, TOO_LARGE
            data = head + f.read(MAX_IMAGE_BYTES + 1 - len(head))
    except OSError:
        suffix = path.suffix.lower()
        return None, (UNREADABLE if suffix in _IMAGE_SUFFIXES else UNSUPPORTED if suffix in _UNSENDABLE_SUFFIXES else None)
    if len(data) > MAX_IMAGE_BYTES:
        return None, TOO_LARGE  # grew since the stat
    return {"type": "image", "source": {"type": "base64", "media_type": kind, "data": base64.b64encode(data).decode("ascii")}}, None


def image_block(path: Path) -> dict[str, Any] | None:
    """The ``image`` content block for ``path``; ``None`` when it is not a supported image, is too large, or can't be read."""
    return read_image(path)[0]


def image_blocks(paths: Iterable[str]) -> tuple[list[dict[str, Any]], list[str]]:
    """The image blocks for one message's ``paths``, in order, and a notice for each image that goes as a path only.

    A HEIC, TIFF or BMP is an image the agent cannot be shown: a path and a
    notice. A file that is not an image (a PDF, text) goes as a path, as any file does. Past ``MAX_IMAGES`` images or
    ``MAX_ENCODED_TOTAL`` encoded bytes, a further image goes as a path only.
    """
    blocks: list[dict[str, Any]] = []
    notices: list[str] = []
    total = 0
    for raw in paths:
        path = Path(raw)
        block, why = read_image(path)
        if block is not None:
            size = len(block["source"]["data"])
            if len(blocks) >= MAX_IMAGES or total + size > MAX_ENCODED_TOTAL:
                block, why = None, PAST_MESSAGE_CAP
            else:
                blocks.append(block)
                total += size
        if block is None and why is not None:
            notices.append(not_image_notice(path.name, why))
    return blocks, notices


def not_image_notice(name: str, why: str = TOO_LARGE) -> str:
    """What the person sees for an image the agent is not shown."""
    if why == UNREADABLE:
        return f"{name} can't be read as an image; it can still open the file."
    if why == UNSUPPORTED:
        return f"{name} can't be shown to the agent as an image; it can still open the file."
    if why == PAST_MESSAGE_CAP:
        return f"{name} is past what one message can show the agent as images; it can still open the file."
    return f"{name} is too large to show the agent as an image; it can still open the file."


_EDITED_NOTE = re.compile(r"\(Edited in the viewer since your last message: [^()\x00-\x1f]*\)\n\n")


def split_edited_note(text: str) -> str:
    """``text`` without a LEADING edits note (v0.20 §2.7) exactly as the gateway writes it.

    The note is for the agent only; replay of the stored transcript must show what was typed.
    """
    m = _EDITED_NOTE.match(text)
    return text[m.end():] if m else text


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
