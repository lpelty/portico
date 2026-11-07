"""v0.23: the comment tools — comments_list, comment_reply, comment_add.

Handlers are called directly with a fake owner; no model.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import pytest

from portico_gateway import artifacts, comment_tools
from portico_gateway import comments as cm
from portico_gateway.comment_tools import COMMENT_TOOL_NAMES, build_comment_tools, write_comment_edit
from portico_gateway.engine import SHOW_TOOL_NAME, build_options
from portico_gateway.viewer import VIEWER_TOOL_NAMES
from tests.test_viewer_tools import WithBridge, make_bridge

FIXTURES = Path(__file__).resolve().parents[2] / "protocol" / "examples" / "comments"
NOW = "2026-11-07T18:38:26.176Z"


class Owner:
    def __init__(self, folder: Path) -> None:
        self.folder = folder

    @property
    def comment_folders(self) -> list[Path]:
        return [self.folder.resolve()]

    @property
    def agent_name(self) -> str:
        return "Rowan"


@pytest.fixture
def folder(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(comment_tools, "_now", lambda: NOW)
    d = tmp_path / "work"
    d.mkdir()
    return d


def tools(folder: Path) -> dict[str, Any]:
    return {t.name: t for t in build_comment_tools(Owner(folder))}


def put(folder: Path, name: str, fixture: str | None = None, text: str | None = None) -> Path:
    p = folder / name
    p.write_bytes((FIXTURES / fixture).read_bytes() if fixture else text.encode("utf-8"))
    return p


def text_of(out: dict[str, Any]) -> str:
    return out["content"][0]["text"]


async def test_list_omits_resolved_by_default(folder: Path) -> None:
    put(folder, "a.md", "list-after.md")
    out = await tools(folder)["comments_list"].handler({"path": "a.md"})
    data = json.loads(text_of(out))
    assert [t["id"] for t in data["threads"]] == ["ab12c", "gh56i"]
    out = await tools(folder)["comments_list"].handler({"path": "a.md", "include_resolved": True})
    data = json.loads(text_of(out))
    assert [t["id"] for t in data["threads"]] == ["ab12c", "de34f", "gh56i"]
    assert data["threads"][0]["replies"][1] == {"author": "Agent", "at": "2026-10-18", "text": "Yes, every fixture."}


async def test_list_reports_not_found_for_orphans(folder: Path) -> None:
    put(folder, "a.md", "list-after.md")
    data = json.loads(text_of(await tools(folder)["comments_list"].handler({"path": "a.md"})))
    assert data["threads"][0]["anchored_text"] == "round trip"
    assert data["threads"][1]["anchored_text"] == "not found"


async def test_reply_writes_agent_name_and_now(folder: Path) -> None:
    p = put(folder, "a.md", "plugin-basic.md")
    out = await tools(folder)["comment_reply"].handler({"path": "a.md", "id": "k3x9a", "text": "Yes."})
    assert text_of(out) == "Replied in thread k3x9a."
    t = cm.parse(p.read_text()).threads[0]
    assert t.replies[-1] == cm.Reply("Rowan", NOW, "Yes.")


async def test_add_anchors_nth_occurrence(folder: Path) -> None:
    p = put(folder, "a.md", text="one word, one more\n")
    out = await tools(folder)["comment_add"].handler({"path": "a.md", "quote": "one", "text": "Second.", "occurrence": 2})
    t = cm.parse(p.read_text()).threads[0]
    assert text_of(out) == f'Added comment {t.id} on "one".'
    assert t.anchor is not None and t.anchor[0] == len("one word, ") + len(f"<!--c:{t.id}-->")
    assert t.by == "Rowan" and t.replies[0] == cm.Reply("Rowan", NOW, "Second.")


ERRORS = [
    ("comments_list", {"path": "../outside.md"}, "../outside.md is outside this session's folders."),
    ("comments_list", {"path": "a.txt"}, "Comments are only in Markdown (.md) files."),
    ("comments_list", {"path": "missing.md"}, "There is no file at missing.md."),
    ("comment_reply", {"path": "a.md", "id": "zzzzz", "text": "x"}, "No comment thread zzzzz in a.md."),
    ("comment_reply", {"path": "a.md", "id": "k3x9a", "text": "  "}, "Write the comment's text."),
    ("comment_add", {"path": "a.md", "quote": "not there", "text": "x"}, '"not there" isn\'t in a.md as text in one paragraph, outside code.'),
    ("comment_add", {"path": "a.md", "quote": "Closing", "text": "x", "occurrence": 3}, '"Closing" occurs 1 times in a.md; there is no occurrence 3.'),
]


@pytest.mark.parametrize("tool,args,message", ERRORS, ids=[e[2][:30] for e in ERRORS])
async def test_errors_change_nothing(folder: Path, tool: str, args: dict, message: str) -> None:
    p = put(folder, "a.md", "plugin-basic.md")
    put(folder, "a.txt", text="plain")
    (folder.parent / "outside.md").write_text("x")
    before = (p.read_bytes(), p.stat().st_mtime_ns)
    out = await tools(folder)[tool].handler(args)
    assert out.get("is_error") is True
    assert text_of(out) == message
    assert (p.read_bytes(), p.stat().st_mtime_ns) == before


async def test_changed_while_writing_error_changes_nothing(folder: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    p = put(folder, "a.md", "plugin-basic.md")

    def always_changed(path: Path, edit):
        raise comment_tools.ChangedWhileWriting()

    monkeypatch.setattr(comment_tools, "write_comment_edit", always_changed)
    out = await tools(folder)["comment_reply"].handler({"path": "a.md", "id": "k3x9a", "text": "x"})
    assert out.get("is_error") is True
    assert text_of(out) == "a.md changed while the comment was being written; nothing was changed. Try again."


def test_write_is_atomic_and_keeps_crlf_and_bom(tmp_path: Path) -> None:
    p = tmp_path / "w.md"
    raw = (FIXTURES / "crlf-no-final-newline.md").read_bytes()
    p.write_bytes(b"\xef\xbb\xbf" + raw)
    write_comment_edit(p, lambda t: cm.add_reply(t, "cr001", author="Rowan", at=NOW, body="Still CRLF."))
    out = p.read_bytes()
    assert out.startswith(b"\xef\xbb\xbf")
    assert b"Rowan (" + NOW.encode() + b"): Still CRLF.\r\n-->" in out
    assert b"\n" not in out.replace(b"\r\n", b"")
    assert not [f for f in tmp_path.iterdir() if f.name.endswith(".saving")]


def test_concurrent_change_retries_once_then_errors(tmp_path: Path) -> None:
    p = tmp_path / "w.md"
    p.write_text("A paragraph.\n")
    calls = []

    def edit_changing_once(t: str) -> str:
        calls.append(t)
        if len(calls) == 1:
            p.write_text("A paragraph, changed meanwhile.\n")
        return t + "x\n"

    write_comment_edit(p, edit_changing_once)
    assert len(calls) == 2 and p.read_text() == "A paragraph, changed meanwhile.\nx\n"

    def edit_changing_always(t: str) -> str:
        p.write_text(p.read_text() + "more\n")
        return t

    with pytest.raises(comment_tools.ChangedWhileWriting):
        write_comment_edit(p, edit_changing_always)


def test_comment_tools_are_file_tools() -> None:
    assert artifacts.from_tool("mcp__portico__comment_reply", {"path": "a.md"}) == Path("a.md")
    assert artifacts.from_tool("mcp__portico__comment_add", {"path": "a.md"}) == Path("a.md")


def test_tools_present_whenever_viewer_tools_are(tmp_path: Path) -> None:
    bridge, _ = make_bridge()
    options = build_options(tmp_path, None, ["project"], WithBridge(bridge))
    assert options.allowed_tools == [SHOW_TOOL_NAME, *VIEWER_TOOL_NAMES, *COMMENT_TOOL_NAMES]
    assert len(options.allowed_tools) == 11
    assert COMMENT_TOOL_NAMES == (
        "mcp__portico__comments_list",
        "mcp__portico__comment_reply",
        "mcp__portico__comment_add",
    )


def test_descriptions_never_name_the_product() -> None:
    for t in build_comment_tools(Owner(Path("."))):
        assert "portico" not in t.description.lower()
    reply = {t.name: t for t in build_comment_tools(Owner(Path(".")))}["comment_reply"]
    assert "resolving is the person's" in reply.description.lower()


NOT_UTF8 = "This file isn't UTF-8 text; comments can't be added."


@pytest.mark.parametrize("tool,args", [
    ("comments_list", {"path": "latin.md"}),
    ("comment_reply", {"path": "latin.md", "id": "k3x9a", "text": "x"}),
    ("comment_add", {"path": "latin.md", "quote": "word", "text": "x"}),
])
async def test_non_utf8_file_is_a_plain_error(folder: Path, tool: str, args: dict) -> None:
    p = folder / "latin.md"
    p.write_bytes("caf\xe9 word\n".encode("latin-1"))
    before = p.read_bytes()
    out = await tools(folder)[tool].handler(args)
    assert out.get("is_error") is True
    assert text_of(out) == NOT_UTF8
    assert p.read_bytes() == before


async def test_add_refuses_indented_code_and_counts_visible_matches(folder: Path) -> None:
    put(folder, "a.md", text="    word in code\n\n[word](word) word\n")
    out = await tools(folder)["comment_add"].handler({"path": "a.md", "quote": "word", "text": "x", "occurrence": 3})
    assert text_of(out) == '"word" occurs 2 times in a.md; there is no occurrence 3.'
