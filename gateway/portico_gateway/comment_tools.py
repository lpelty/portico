"""v0.23: the agent's comment tools — read, reply to, and add comments in Markdown files.

Three tools on the same in-process MCP server as the viewer tools, available
whenever they are: ``comments_list``, ``comment_reply`` and ``comment_add``.
They read and write comment format v1 (``protocol/COMMENTS.md``) through
``comments.py``, so they work with or without the app attached. Agents can't
resolve threads: resolving is the person's.

Paths must be inside the chat's folders (as for showing a file); a relative
path resolves against the chat's folder. Writes are atomic (a temporary file,
then a rename), keep the file's line endings and byte-order mark, and touch
only the thread's anchors and block. Any error changes nothing.
"""

from __future__ import annotations

import json
import os
import random
import secrets
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from claude_agent_sdk import SdkMcpTool, tool

from . import comments as cm

SERVER = "portico"
COMMENT_TOOLS = ("comments_list", "comment_reply", "comment_add")
COMMENT_TOOL_NAMES = tuple(f"mcp__{SERVER}__{name}" for name in COMMENT_TOOLS)

_BOM = "﻿"
_rng = random.SystemRandom()


NOT_UTF8 = "This file isn't UTF-8 text; comments can't be added."


class ChangedWhileWriting(Exception):
    """The file changed on disk twice while a comment edit was being written."""


def _now() -> str:
    now = datetime.now(UTC)
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"


def _error(text: str) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}], "is_error": True}


def _text(text: str) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}]}


def _stamp(path: Path) -> tuple[int, int]:
    st = path.stat()
    return (st.st_mtime_ns, st.st_size)


def _read(path: Path) -> tuple[str, bool]:
    with path.open("r", encoding="utf-8", newline="") as f:
        text = f.read()
    if text.startswith(_BOM):
        return text[1:], True
    return text, False


def write_comment_edit(path: Path, edit: Callable[[str], str]) -> None:
    """Apply ``edit`` to the file's text and write it atomically.

    Reads the text (a byte-order mark is stripped and put back), applies the
    edit, writes ``.<name>.<8hex>.saving`` beside the file and renames it over
    the file. If the file changed between the read and the rename, it reads
    and applies once more; a second change raises ``ChangedWhileWriting`` and
    nothing is written.
    """
    for _attempt in range(2):
        before = _stamp(path)
        text, bom = _read(path)
        out = edit(text)
        tmp = path.with_name(f".{path.name}.{secrets.token_hex(4)}.saving")
        try:
            with tmp.open("w", encoding="utf-8", newline="") as f:
                f.write((_BOM if bom else "") + out)
            try:
                os.chmod(tmp, path.stat().st_mode & 0o7777)
            except OSError:
                pass
            if _stamp(path) != before:
                continue
            os.replace(tmp, path)
            return
        finally:
            if tmp.exists():
                tmp.unlink()
    raise ChangedWhileWriting()


def build_comment_tools(owner: Any) -> list[SdkMcpTool[Any]]:
    """The three comment tools. ``owner`` gives ``comment_folders`` (the chat's
    folder first) and ``agent_name`` (the name in the app's hello), read at call time."""

    def schema(properties: dict[str, Any], required: list[str]) -> dict[str, Any]:
        return {"type": "object", "properties": properties, "required": required}

    def resolve(raw: Any) -> Path | dict[str, Any]:
        raw = str(raw or "")
        folders = list(getattr(owner, "comment_folders", []) or [])
        candidate = Path(raw).expanduser()
        if not candidate.is_absolute():
            if not folders:
                return _error(f"{raw} is outside this session's folders.")
            candidate = folders[0] / candidate
        try:
            candidate = candidate.resolve()
        except OSError:
            return _error(f"There is no file at {raw}.")
        if not any(candidate.is_relative_to(f) for f in folders):
            return _error(f"{raw} is outside this session's folders.")
        if candidate.suffix.lower() != ".md":
            return _error("Comments are only in Markdown (.md) files.")
        if not candidate.is_file():
            return _error(f"There is no file at {raw}.")
        return candidate

    def agent() -> str:
        return str(getattr(owner, "agent_name", "") or "Agent")

    @tool(
        "comments_list",
        "List the comment threads in a Markdown file. Comments are stored in the file itself as HTML comments: "
        "<!--c:ID--> and <!--/c:ID--> around the commented text, and a <!--co:ID ...--> block holding the thread. "
        "Each thread gives its id, status, the quote it was made on, the text it is anchored to now (or \"not found\"), "
        "and its replies with author and time. Resolved threads are left out unless include_resolved is true.",
        schema({"path": {"type": "string"}, "include_resolved": {"type": "boolean"}}, ["path"]),
    )
    async def comments_list(args: dict[str, Any]) -> dict[str, Any]:
        path = resolve(args.get("path"))
        if isinstance(path, dict):
            return path
        try:
            text, _ = _read(path)
        except UnicodeDecodeError:
            return _error(NOT_UTF8)
        include = args.get("include_resolved") is True
        threads = []
        for t in cm.parse(text).threads:
            if t.status == "resolved" and not include:
                continue
            anchored = cm.anchored_text(text, t)
            threads.append(
                {
                    "id": t.id,
                    "status": t.status,
                    "quote": t.quote,
                    "anchored_text": anchored if anchored is not None else "not found",
                    "replies": [{"author": r.author, "at": r.at, "text": r.text} for r in t.replies],
                }
            )
        return _text(json.dumps({"path": str(args.get("path")), "threads": threads}, ensure_ascii=False))

    @tool(
        "comment_reply",
        "Reply in a comment thread in a Markdown file, by id (from comments_list). The reply is written into the "
        "file's thread block under your name with the time now. You can't resolve a thread: resolving is the person's.",
        schema({"path": {"type": "string"}, "id": {"type": "string"}, "text": {"type": "string"}}, ["path", "id", "text"]),
    )
    async def comment_reply(args: dict[str, Any]) -> dict[str, Any]:
        raw = str(args.get("path") or "")
        path = resolve(raw)
        if isinstance(path, dict):
            return path
        tid = str(args.get("id") or "")
        body = str(args.get("text") or "")
        try:
            text, _ = _read(path)
        except UnicodeDecodeError:
            return _error(NOT_UTF8)
        if not any(t.id == tid for t in cm.parse(text).threads):
            return _error(f"No comment thread {tid} in {raw}.")
        if not body.strip():
            return _error("Write the comment's text.")
        name, at = agent(), _now()
        try:
            write_comment_edit(path, lambda t: cm.add_reply(t, tid, author=name, at=at, body=body))
        except KeyError:
            return _error(f"No comment thread {tid} in {raw}.")
        except ChangedWhileWriting:
            return _error(f"{raw} changed while the comment was being written; nothing was changed. Try again.")
        return _text(f"Replied in thread {tid}.")

    @tool(
        "comment_add",
        "Add a comment to a Markdown file, anchored on text in it: quote is the exact text to comment on, within one "
        "paragraph and outside code; occurrence picks which match (1 is the first). The anchors and a new thread block "
        "are written into the file under your name. You can't resolve threads: resolving is the person's.",
        schema(
            {
                "path": {"type": "string"},
                "quote": {"type": "string"},
                "text": {"type": "string"},
                "occurrence": {"type": "integer", "minimum": 1},
            },
            ["path", "quote", "text"],
        ),
    )
    async def comment_add(args: dict[str, Any]) -> dict[str, Any]:
        raw = str(args.get("path") or "")
        path = resolve(raw)
        if isinstance(path, dict):
            return path
        quote = str(args.get("quote") or "")
        body = str(args.get("text") or "")
        try:
            occurrence = max(1, int(args.get("occurrence") or 1))
        except (TypeError, ValueError):
            occurrence = 1
        if not body.strip():
            return _error("Write the comment's text.")

        def refusal(found: tuple[int, int] | str) -> dict[str, Any] | None:
            if not isinstance(found, str):
                return None
            if found == "not shown in the table":
                return _error("That text isn't shown in the table.")
            if found == cm.INSIDE_ATOM:
                return _error(f'"{quote}" is inside a link or an HTML entity in {raw}; quote text outside it, or the whole link.')
            if found.startswith("occurs "):
                n = found.split()[1]
                return _error(f'"{quote}" occurs {n} times in {raw}; there is no occurrence {occurrence}.')
            return _error(f'"{quote}" isn\'t in {raw} as text in one paragraph, outside code.')

        try:
            text, _ = _read(path)
        except UnicodeDecodeError:
            return _error(NOT_UTF8)
        refused = refusal(cm.find_quote(text, quote, occurrence))
        if refused:
            return refused
        name, at = agent(), _now()
        made: dict[str, str] = {}

        def edit(t: str) -> str:
            found = cm.find_quote(t, quote, occurrence)
            if isinstance(found, str):
                raise LookupError(found)
            made["id"] = cm.new_id(t, _rng)
            return cm.add_thread(t, found[0], found[1], id=made["id"], author=name, at=at, body=body)

        try:
            write_comment_edit(path, edit)
        except LookupError as e:
            return refusal(str(e)) or _error(str(e))
        except ChangedWhileWriting:
            return _error(f"{raw} changed while the comment was being written; nothing was changed. Try again.")
        return _text(f'Added comment {made["id"]} on "{quote}".')

    return [comments_list, comment_reply, comment_add]
