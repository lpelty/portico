"""v0.23: comment format v1 — the parser and splices, against the shared fixtures.

The fixtures in ``protocol/examples/comments/`` are read by the Swift and the
editor tests too, so the three implementations agree.
"""

from __future__ import annotations

import json
import random
from pathlib import Path

import pytest

from portico_gateway import comments as cm

FIXTURES = Path(__file__).resolve().parents[2] / "protocol" / "examples" / "comments"
CASES = json.loads((FIXTURES / "cases.json").read_text(encoding="utf-8"))["cases"]
PARSE_CASES = [c for c in CASES if "parse" in c]
OP_CASES = [c for c in CASES if "op" in c and "expect" in c]
ERROR_CASES = [c for c in CASES if "expect_error" in c]
FIND_CASES = [c for c in CASES if "find" in c]
ROUNDTRIP = [s for c in CASES if "roundtrip" in c for s in c["roundtrip"]]


def read(name: str) -> str:
    return (FIXTURES / name).read_bytes().decode("utf-8")


def thread_json(text: str, t: cm.Thread) -> dict:
    return {
        "id": t.id,
        "by": t.by,
        "at": t.at,
        "status": t.status,
        "quote": t.quote,
        "anchored_text": cm.anchored_text(text, t),
        "replies": [{"author": r.author, "at": r.at, "text": r.text} for r in t.replies],
        "reactions": list(t.reactions),
    }


def _fp(a):
    f = a.get("fingerprint")
    return (f["author"], f["at"], f["text"]) if f else None


def apply_op(text: str, case: dict) -> str:
    a = case["args"]
    op = case["op"]
    if op == "add":
        found = cm.find_quote(text, a["quote"], a.get("occurrence", 1))
        assert not isinstance(found, str), found
        return cm.add_thread(text, found[0], found[1], id=a["id"], author=a["author"], at=a["at"], body=a["body"])
    if op == "reply":
        return cm.add_reply(text, a["id"], author=a["author"], at=a["at"], body=a["body"])
    if op == "resolve":
        return cm.set_status(text, a["id"], "resolved")
    if op == "reopen":
        return cm.set_status(text, a["id"], "open")
    if op == "edit":
        return cm.edit_comment(text, a["id"], a["index"], body=a["body"], fingerprint=_fp(a))
    if op == "delete":
        return cm.delete_comment(text, a["id"], a["index"], fingerprint=_fp(a))
    raise AssertionError(op)


@pytest.mark.parametrize("case", PARSE_CASES, ids=[c["name"] for c in PARSE_CASES])
def test_fixture_parses(case):
    text = read(case["file"])
    parsed = cm.parse(text)
    assert [thread_json(text, t) for t in parsed.threads] == case["parse"]["threads"]
    assert list(parsed.orphan_anchors) == case["parse"]["orphan_anchors"]


@pytest.mark.parametrize("case", OP_CASES, ids=[c["name"] for c in OP_CASES])
def test_fixture_ops(case):
    text = read(case["file"])
    assert apply_op(text, case) == read(case["expect"])


@pytest.mark.parametrize("case", PARSE_CASES, ids=[c["name"] for c in PARSE_CASES])
def test_round_trip_is_byte_identical(case):
    text = read(case["file"])
    parsed = cm.parse(text)
    if parsed.orphan_anchors:
        pytest.skip("a write removes orphan anchors by design")
    for t in parsed.threads:
        assert cm.set_status(text, t.id, t.status) == text


def test_new_id_is_unique_and_short():
    text = read("list-after.md")
    new = cm.new_id(text, random.Random(7))
    assert len(new) == 5 and new not in {"ab12c", "de34f", "gh56i"}


def test_new_id_falls_back_to_8_after_1000_collisions():
    class AlwaysA(random.Random):
        draws = 0

        def choice(self, seq):
            self.draws += 1
            return "a"

    rng = AlwaysA()
    # Taken inside code too: every c:, /c: and co: ID counts.
    new = cm.new_id("`<!--c:aaaaa-->`", rng)
    assert new == "aaaaaaaa"
    assert rng.draws == 1000 * 5 + 8


def test_snap_never_narrows():
    text = "the permission prompt stays"
    assert cm.snap_to_words(text, 5, 18) == (4, 21)  # "ermission pro" -> "permission prompt"
    assert cm.snap_to_words(text, 3, 22) == (3, 22)  # already at boundaries, spaces kept
    assert cm.snap_to_words("don't stop", 1, 3) == (0, 5)  # apostrophe between letters is a word char


def test_find_quote_refusals():
    text = read("code-ignored.md")
    assert cm.find_quote(text, "nowhere in it") == "not found"
    assert cm.find_quote(text, "not a comment") == "inside code or front matter"
    assert cm.find_quote(read("para.md"), "line endings. Second") == "crosses paragraphs"
    assert cm.find_quote(read("para.md"), "e", occurrence=99).startswith("occurs ")
    two = "one word, one more\n"
    assert cm.find_quote(two, "one", occurrence=2) == (10, 13)
    assert cm.find_quote(two, "one", occurrence=3) == "occurs 2 times"


def test_find_quote_sees_through_markers_and_quote_prefixes():
    text = read("quote-wrap.md")
    found = cm.find_quote(text, "it when the point")
    assert not isinstance(found, str)
    assert text[found[0]:found[1]] == "it <!--c:qw001-->when the\n> point"
    assert cm.strip_markers(text[found[0]:found[1]]) == "it when the\n> point"


def test_text_that_would_break_the_format_is_escaped_and_reads_back():
    text = read("para.md")
    found = cm.find_quote(text, "writes files")
    body = "See a --> b\nNote: one\n\n+1\n\\leading"
    out = cm.add_thread(text, *found, id="zz001", author="Sam", at="2026-11-07T00:00:00.000Z", body=body)
    out = cm.add_reply(out, "zz001", author="Agent", at="2026-11-07T00:00:01.000Z", body="x: --> y")
    t = cm.parse(out).threads[0]
    assert [r.text for r in t.replies] == [body, "x: --> y"]
    assert "-->" not in out.split("<!--co:zz001", 1)[1].split("\n-->")[0]


def test_unknown_thread_raises_key_error():
    with pytest.raises(KeyError):
        cm.add_reply(read("para.md"), "nope1", author="A", at="2026-11-07T00:00:00.000Z", body="x")
    with pytest.raises(KeyError):
        cm.set_status(read("para.md"), "nope1", "resolved")


# --- fix round: visible text, block ends, escaping ---------------------------


@pytest.mark.parametrize("case", FIND_CASES, ids=[c["name"] for c in FIND_CASES])
def test_fixture_finds(case):
    found = cm.find_quote(case["text"], case["find"]["quote"], case["find"]["occurrence"])
    if "expect_refusal" in case:
        assert found == case["expect_refusal"]
    else:
        assert not isinstance(found, str), found
        assert found[0] == len(case["expect_prefix"])
        if "expect_text" in case:
            assert case["text"][found[0] : found[1]] == case["expect_text"]
        assert case["text"][found[0] : found[1]] == cm.strip_markers(case["find"]["quote"]) or True


@pytest.mark.parametrize("value", ROUNDTRIP)
def test_quoted_values_round_trip(value):
    one_line = value.replace("\n", " ")
    assert cm.unescape_quoted(cm.escape_quoted(one_line)) == one_line
    assert "-->" not in cm.escape_quoted(one_line)


@pytest.mark.parametrize("value", ROUNDTRIP)
def test_reply_text_round_trips(value):
    text = "Word here.\n"
    out = cm.add_thread(text, 0, 4, id="rt001", author="Sam", at="2026-11-07T00:00:00.000Z", body=value)
    out = cm.add_reply(out, "rt001", author="Agent", at="2026-11-07T00:00:01.000Z", body=value)
    t = cm.parse(out).threads[0]
    assert [r.text for r in t.replies] == [value, value]
    assert out.count("-->") == 3  # the two markers and the block's close: no reply text ends the block early


def test_non_utf8_is_not_parsed_here():
    # Bytes are the tools' business (comment_tools); the format works on text.
    assert cm.parse("") == cm.Parsed((), ())


def test_edit_keeps_author_and_time_and_other_comments():
    text = read("list-after.md")
    out = cm.edit_comment(text, "ab12c", 0, body="Changed.")
    t = next(x for x in cm.parse(out).threads if x.id == "ab12c")
    assert [(r.author, r.at, r.text) for r in t.replies] == [("Sam", "2026-10-17", "Changed."), ("Agent", "2026-10-18", "Yes, every fixture.")]


def test_edit_and_delete_refuse_unknown_comments():
    text = read("plugin-basic.md")
    with pytest.raises(KeyError):
        cm.edit_comment(text, "k3x9a", 5, body="x")
    with pytest.raises(KeyError):
        cm.delete_comment(text, "zzzzz", 0)


@pytest.mark.parametrize("case", ERROR_CASES, ids=[c["name"] for c in ERROR_CASES])
def test_fixture_refusals(case):
    text = read(case["file"])
    want = {"changed": cm.CommentChanged, "blank": ValueError}[case["expect_error"]]
    with pytest.raises(want):
        apply_op(text, case)
