"""Comment format v1: comments stored inline in a Markdown file (v0.23).

The format is written down in ``protocol/COMMENTS.md``. Text is anchored with
``<!--c:ID-->`` … ``<!--/c:ID-->`` and its thread is an HTML comment block
``<!--co:ID by:… at:… status:… quote:"…"`` … ``-->`` after the top-level
block that holds the anchor.

Every edit here is a splice: the bytes outside the touched anchors and block
are never regenerated, so reading a file and writing it back with no change
to its comments leaves it byte-identical. Offsets are ``str`` indices; the
app and the editor use UTF-16 offsets of their own, and fixtures carry text,
never offsets.

The app (``CommentFormat.swift``) and the editor (``comments.ts``) implement
the same rules; ``protocol/examples/comments/`` is their shared test.
"""

from __future__ import annotations

import random
import re
import unicodedata
from dataclasses import dataclass
from typing import Literal

ID_RE = r"[a-z0-9]{5,8}"
ID_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789"

_MARKER_RE = re.compile(r"<!--(/?)c:(" + ID_RE + r")-->")
_ANY_ID_RE = re.compile(r"<!--/?co?:([a-z0-9]+)")
_BLOCK_START_RE = re.compile(r"[ \t]*<!--co:(" + ID_RE + r")(?=[ \t\r\n\f\v]|-->|$)")
_REPLY_RE = re.compile(r"^(.*?)(?:\s\(([^)]*)\))?:\s?(.*)$")
_WORD_RE = re.compile(r"\w")
_WS = " \t\n\r\f\v"

# Block starts (CommonMark, as far as comments need it).
_FENCE_RE = re.compile(r"^[ \t>]*(`{3,}|~{3,})")
_TOP_FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
_HEADING_RE = re.compile(r"^ {0,3}#{1,6}(?:[ \t]|$)")
_HR_RE = re.compile(r"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$")
_SETEXT_RE = re.compile(r"^ {0,3}(?:=+|-+)[ \t]*$")
_QUOTE_RE = re.compile(r"^ {0,3}>")
_HTML_RE = re.compile(r"^ {0,3}<(?:[A-Za-z/?]|!)")
_ANCHOR_LINE_RE = re.compile(r"^ {0,3}<!--/?c:" + ID_RE + r"-->")
_BULLET_RE = re.compile(r"^ {0,3}[-*+][ \t]+\S")
_ORDERED_RE = re.compile(r"^ {0,3}\d{1,9}[.)](?:[ \t]|$)")
_ORDERED_ONE_RE = re.compile(r"^ {0,3}1[.)][ \t]+\S")
_LIST_RE = re.compile(r"^ {0,3}(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$)")
_REFDEF_RE = re.compile(r"^ {0,3}\[[^\]]+\]:[ \t]*\S")
_ROW_PREFIX_RE = re.compile(r"^[ \t>]*")
_DELIMITER_RE = re.compile(r"^\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$")


@dataclass(frozen=True)
class Reply:
    author: str
    at: str | None
    text: str


@dataclass(frozen=True)
class Thread:
    id: str
    by: str
    at: str
    status: Literal["open", "resolved"]
    quote: str
    replies: tuple[Reply, ...]
    reactions: tuple[str, ...]
    block: tuple[int, int]
    anchor: tuple[int, int] | None
    # Where the header's fields sit, for splices: (key, value start, value end).
    fields: tuple[tuple[str, int, int], ...] = ()
    close: int = 0  # offset of the closing "-->"
    # Each reply's source: (line start, where its text starts, end of its last line without the line break).
    reply_spans: tuple[tuple[int, int, int], ...] = ()


@dataclass(frozen=True)
class Parsed:
    threads: tuple[Thread, ...]
    orphan_anchors: tuple[str, ...]


# --- lines --------------------------------------------------------------------


def _lines(text: str) -> list[tuple[int, int, int]]:
    """(start, end without its line ending, end with it) for every line."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        j = text.find("\n", i)
        if j < 0:
            out.append((i, n, n))
            break
        end = j - 1 if j > i and text[j - 1] == "\r" else j
        out.append((i, end, j + 1))
        i = j + 1
    return out


def line_ending(text: str) -> str:
    j = text.find("\n")
    return "\r\n" if j > 0 and text[j - 1] == "\r" else "\n"


def _blank(s: str) -> bool:
    return s.strip(" \t\r\f\v") == ""


_INDENTED_RE = re.compile(r"(?: {4}| {0,3}\t)")


def _indented(s: str) -> bool:
    return bool(_INDENTED_RE.match(s))


def _inside(spans, pos: int) -> bool:
    return any(a <= pos < b for a, b in spans)


# --- structure ------------------------------------------------------------------


def _front_matter(text: str, lines) -> tuple[int, int] | None:
    if not lines or text[lines[0][0] : lines[0][1]].rstrip(" \t") != "---":
        return None
    for start, end, full in lines[1:]:
        if text[start:end].rstrip(" \t") in ("---", "..."):
            return (0, full)
    return None


def _fences(text: str, lines, skip_until: int) -> list[tuple[int, int]]:
    """``` and ~~~ fences anywhere (also in lists and quotes)."""
    out = []
    open_at = None
    fence = ""
    for start, end, full in lines:
        if full <= skip_until:
            continue
        line = text[start:end]
        m = _FENCE_RE.match(line)
        if open_at is None:
            if m:
                open_at = start
                fence = m.group(1)
        elif m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and _blank(line[m.end() :]):
            out.append((open_at, full))
            open_at = None
    if open_at is not None:
        out.append((open_at, len(text)))
    return out


def _block_spans(text: str, lines, coarse) -> list[tuple[int, int, int, str]]:
    """Thread blocks outside front matter and fences: (start, end incl. line break, close offset, id)."""
    out = []
    k = 0
    while k < len(lines):
        start, end, full = lines[k]
        m = _BLOCK_START_RE.match(text, start, end)
        if m and not _inside(coarse, start):
            close = text.find("-->", m.end())
            if close < 0:
                k += 1
                continue
            j = k
            while lines[j][2] <= close:
                j += 1
            out.append((start, lines[j][2], close, m.group(1)))
            k = j + 1
            continue
        k += 1
    return out


def _interrupts(t: str, in_quote: bool = False) -> bool:
    """Whether line ``t`` starts a block that ends a paragraph (CommonMark interruption)."""
    if _BLOCK_START_RE.match(t):
        return True
    if _TOP_FENCE_RE.match(t) or _HEADING_RE.match(t) or _HR_RE.match(t):
        return True
    if not in_quote and _QUOTE_RE.match(t):
        return True
    if _HTML_RE.match(t) and not _ANCHOR_LINE_RE.match(t):
        return True
    return bool(_BULLET_RE.match(t) or _ORDERED_ONE_RE.match(t))


def _segments(text: str, lines, blocks) -> list[tuple[str, int, int]]:
    """Top-level blocks as (kind, first line, last line): para, list, quote, heading, hr,
    fence, icode, html, thread, fm."""
    segs: list[tuple[str, int, int]] = []
    n = len(lines)
    by_start = {b[0]: b for b in blocks}

    def t(k: int) -> str:
        return text[lines[k][0] : lines[k][1]]

    i = 0
    fm = _front_matter(text, lines)
    if fm:
        j = 0
        while lines[j][2] < fm[1]:
            j += 1
        segs.append(("fm", 0, j))
        i = j + 1
    while i < n:
        s = t(i)
        if _blank(s):
            i += 1
            continue
        if lines[i][0] in by_start:
            end = by_start[lines[i][0]][1]
            j = i
            while lines[j][2] < end:
                j += 1
            segs.append(("thread", i, j))
            i = j + 1
            continue
        m = _TOP_FENCE_RE.match(s)
        if m:
            fence = m.group(1)
            j = i + 1
            while j < n:
                mm = _TOP_FENCE_RE.match(t(j))
                if mm and mm.group(1)[0] == fence[0] and len(mm.group(1)) >= len(fence) and _blank(t(j)[mm.end() :]):
                    break
                j += 1
            j = min(j, n - 1)
            segs.append(("fence", i, j))
            i = j + 1
            continue
        if _indented(s):
            j = i
            while j + 1 < n and (_indented(t(j + 1)) or _blank(t(j + 1))):
                j += 1
            while _blank(t(j)):
                j -= 1
            segs.append(("icode", i, j))
            i = j + 1
            continue
        if _HEADING_RE.match(s):
            segs.append(("heading", i, i))
            i += 1
            continue
        if _HR_RE.match(s):
            segs.append(("hr", i, i))
            i += 1
            continue
        if _HTML_RE.match(s) and not _ANCHOR_LINE_RE.match(s):
            j = i
            if s.lstrip(" ").startswith("<!--"):
                while j < n and "-->" not in t(j):
                    j += 1
                j = min(j, n - 1)
            else:
                while j + 1 < n and not _blank(t(j + 1)):
                    j += 1
            segs.append(("html", i, j))
            i = j + 1
            continue
        if _QUOTE_RE.match(s):
            j = i
            while j + 1 < n and not _blank(t(j + 1)) and (_QUOTE_RE.match(t(j + 1)) or not _interrupts(t(j + 1), True)):
                j += 1
            segs.append(("quote", i, j))
            i = j + 1
            continue
        if _LIST_RE.match(s):
            j = i
            while True:
                if j + 1 < n and not _blank(t(j + 1)):
                    nxt = t(j + 1)
                    if nxt[:1] in (" ", "\t") or _LIST_RE.match(nxt) or not _interrupts(nxt):
                        if _BLOCK_START_RE.match(nxt):
                            break
                        j += 1
                        continue
                    break
                k = j + 1
                while k < n and _blank(t(k)):
                    k += 1
                if k > j + 1 and k < n and not _BLOCK_START_RE.match(t(k)) and (t(k)[:1] in (" ", "\t") or _LIST_RE.match(t(k))):
                    j = k
                    continue
                break
            segs.append(("list", i, j))
            i = j + 1
            continue
        j = i
        while j + 1 < n:
            nxt = t(j + 1)
            if _blank(nxt):
                break
            if _SETEXT_RE.match(nxt):
                j += 1
                break
            if _interrupts(nxt):
                break
            j += 1
        segs.append(("para", i, j))
        i = j + 1
    return segs


def _row_cells(line: str) -> list[tuple[int, int]]:
    """A table row's cells as (start, end) offsets in ``line``, between boundary pipes."""
    lead = len(_ROW_PREFIX_RE.match(line).group(0))
    end = len(line.rstrip(" \t"))
    bounds = [q for q in _unescaped_pipes(line) if q >= lead]
    cells = list(zip([lead] + [q + 1 for q in bounds], bounds + [end]))
    if bounds and bounds[0] == lead:
        cells = cells[1:]
    if bounds and bounds[-1] == end - 1:
        cells = cells[:-1]
    return cells


def _unescaped_pipes(line: str) -> list[int]:
    """Offsets of the ``|`` in ``line`` that are cell boundaries (not ``\\|``)."""
    out = []
    i = 0
    while i < len(line):
        if line[i] == "\\":
            i += 2
            continue
        if line[i] == "|":
            out.append(i)
        i += 1
    return out


def _tables(text: str, lines, hidden) -> list[tuple[int, int, int]]:
    """GFM tables as (header line, delimiter line, last row line), outside code and thread blocks."""
    out = []
    n = len(lines)

    def body(k: int) -> str:
        s, e, _ = lines[k]
        return text[s:e][len(_ROW_PREFIX_RE.match(text[s:e]).group(0)) :]

    k = 0
    while k + 1 < n:
        if _inside(hidden, lines[k][0]) or _inside(hidden, lines[k + 1][0]):
            k += 1
            continue
        head, delim = body(k), body(k + 1)
        if _unescaped_pipes(head) and "|" in delim and "-" in delim and _DELIMITER_RE.match(delim):
            j = k + 1
            while j + 1 < n and not _blank(body(j + 1)) and not _inside(hidden, lines[j + 1][0]) and not _interrupts(body(j + 1)):
                j += 1
            out.append((k, k + 1, j))
            k = j + 1
            continue
        k += 1
    return out


def _code_spans(text: str, segments) -> list[tuple[int, int]]:
    out = []
    for a, b in segments:
        i = a
        while i < b:
            j = text.find("`", i, b)
            if j < 0:
                break
            n = j
            while n < b and text[n] == "`":
                n += 1
            run = n - j
            k = n
            found = None
            while k < b:
                k = text.find("`", k, b)
                if k < 0:
                    break
                e = k
                while e < b and text[e] == "`":
                    e += 1
                if e - k == run:
                    found = e
                    break
                k = e
            if found is not None and not re.search(r"\n[ \t>]*\r?\n", text[j:found]):
                out.append((j, found))
                i = found
            else:
                i = n
    return out


@dataclass
class _Regions:
    lines: list
    ignored: list  # front matter, fences, indented code, inline code
    blocks: list  # thread blocks
    segs: list  # top-level blocks
    tables: list  # (header line, delimiter line, last row line)


def _regions(text: str) -> _Regions:
    lines = _lines(text)
    fm = _front_matter(text, lines)
    coarse = ([fm] if fm else []) + _fences(text, lines, fm[1] if fm else 0)
    blocks = _block_spans(text, lines, coarse)
    segs = _segments(text, lines, blocks)
    icode = [(lines[a][0], lines[b][2]) for kind, a, b in segs if kind == "icode"]
    coarse = sorted(coarse + icode)
    walls = sorted(coarse + [(s, e) for s, e, _, _ in blocks])
    tables = _tables(text, lines, walls)
    # GFM splits a table row on its unescaped pipes before inline code is
    # recognised: a code span never runs across a cell boundary.
    cuts = []
    for head, delim, last in tables:
        for k in range(head, last + 1):
            s0, e0, _ = lines[k]
            cuts += [(s0 + q, s0 + q + 1) for q in _unescaped_pipes(text[s0:e0])]
    segments = []
    pos = 0
    for a, b in sorted(walls + cuts):
        if a > pos:
            segments.append((pos, a))
        pos = max(pos, b)
    if pos < len(text):
        segments.append((pos, len(text)))
    ignored = sorted(coarse + _code_spans(text, segments))
    return _Regions(lines, ignored, blocks, segs, tables)


# --- escaping -------------------------------------------------------------------


def escape_quoted(s: str) -> str:
    """A header value inside double quotes: newlines as spaces, then \\ → \\\\, " → \\", --> → --\\>."""
    s = s.replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("-->", "--\\>")


def unescape_quoted(s: str) -> str:
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s) and s[i + 1] in '\\">':
            out.append(s[i + 1])
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


_BODY_ARROW = re.compile(r"--(\\*)>")
_BODY_ARROW_BACK = re.compile(r"--(\\+)>")


def escape_body(s: str) -> str:
    """A reply's text: one more backslash between ``--`` and ``>``, so it never closes the block."""
    return _BODY_ARROW.sub(lambda m: "--" + m.group(1) + "\\>", s)


def unescape_body(s: str) -> str:
    return _BODY_ARROW_BACK.sub(lambda m: "--" + m.group(1)[1:] + ">", s)


# --- header and thread lines ----------------------------------------------------

_KEY_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_-]*):")


def _header_fields(text: str, a: int, b: int) -> list[tuple[str, int, int, str]]:
    """Tokens ``key:value`` / ``key:"…"`` in text[a:b]: (key, value start, value end, value)."""
    out = []
    i = a
    while i < b:
        while i < b and text[i] in " \t":
            i += 1
        if i >= b:
            break
        m = _KEY_RE.match(text, i, b)
        if not m:
            while i < b and text[i] not in " \t":
                i += 1
            continue
        key = m.group(1)
        i = m.end()
        if i < b and text[i] == '"':
            j = i + 1
            while j < b and text[j] != '"':
                j += 2 if text[j] == "\\" and j + 1 < b else 1
            vs, ve = i + 1, min(j, b)
            out.append((key, vs, ve, unescape_quoted(text[vs:ve])))
            i = j + 1
        else:
            j = i
            while j < b and text[j] not in " \t":
                j += 1
            out.append((key, i, j, unescape_quoted(text[i:j])))
            i = j
    return out


def _thread_lines(raw: list[tuple[str, int]]) -> tuple[list[Reply], list[str], list[tuple[int, int, int]]]:
    """Replies, reactions and each reply's source span, from (line, start offset) pairs."""
    replies: list[list] = []
    reactions: list[str] = []
    spans: list[list[int]] = []
    for line, at in raw:
        if line.startswith("\\"):
            if replies:
                replies[-1][2] += "\n" + unescape_body(line[1:])
                spans[-1][2] = at + len(line)
            continue
        if _blank(line):
            continue
        if line.startswith("+"):
            reactions.append(line)
            continue
        m = _REPLY_RE.match(line)
        if m and m.group(1).strip():
            replies.append([m.group(1).strip(), m.group(2), unescape_body(m.group(3))])
            spans.append([at, at + m.start(3), at + len(line)])
        elif replies:
            replies[-1][2] += "\n" + unescape_body(line)
            spans[-1][2] = at + len(line)
    return [Reply(a, t, x) for a, t, x in replies], reactions, [tuple(x) for x in spans]


# --- parse --------------------------------------------------------------------


def _markers(text: str, reg: _Regions):
    """Live markers: (start, end, id, closing) outside ignored regions and thread blocks."""
    walls = reg.ignored + [(s, e) for s, e, _, _ in reg.blocks]
    return [(m.start(), m.end(), m.group(2), bool(m.group(1))) for m in _MARKER_RE.finditer(text) if not _inside(walls, m.start())]


def parse(text: str) -> Parsed:
    reg = _regions(text)
    markers = _markers(text, reg)
    threads = []
    seen = set()
    for start, end, close, tid in reg.blocks:
        first_of_id = tid not in seen  # a later block with the same id (a pasted copy) is an orphan thread
        seen.add(tid)
        header_end = text.find("\n", start)
        header_end = end if header_end < 0 or header_end >= close else header_end
        hb = min(close, header_end)
        if hb > start and text[hb - 1] == "\r":
            hb -= 1
        head_from = text.index("<!--co:", start) + len("<!--co:") + len(tid)
        fields = _header_fields(text, head_from, hb)
        values: dict[str, str] = {}
        for k, _, _, v in fields:
            values.setdefault(k, v)  # the first of a duplicated key wins
        raw: list[tuple[str, int]] = []
        if close > hb:
            at = hb
            parts = text[hb:close].split("\n")
            for k, part in enumerate(parts):
                if k:
                    line = part.rstrip("\r")
                    if k == len(parts) - 1:
                        line = line.rstrip(" \t")  # text before a `-->` on the same line
                    raw.append((line, at))
                at += len(part) + 1
        replies, reactions, spans = _thread_lines(raw)
        anchor = None
        o = next((m for m in markers if m[2] == tid and not m[3]), None) if first_of_id else None
        if o:
            c = next((m for m in markers if m[2] == tid and m[3] and m[0] >= o[1]), None)
            if c:
                anchor = (o[1], c[0])
        threads.append(
            Thread(
                id=tid,
                by=values.get("by", ""),
                at=values.get("at", ""),
                status="resolved" if values.get("status", "open") == "resolved" else "open",
                quote=values.get("quote", ""),
                replies=tuple(replies),
                reactions=tuple(reactions),
                block=(start, end),
                anchor=anchor,
                fields=tuple((k, s, e) for k, s, e, _ in fields),
                close=close,
                reply_spans=tuple(spans),
            )
        )
    orphans = []
    for m in [m for m in markers if not m[3]] + [m for m in markers if m[3]]:
        if m[2] not in seen and m[2] not in orphans:
            orphans.append(m[2])
    return Parsed(tuple(threads), tuple(orphans))


def strip_markers(s: str) -> str:
    return _MARKER_RE.sub("", s)


def quote_text(s: str) -> str:
    """The anchored source as a reader sees it, for a header's ``quote``: no
    markers, and a line break with the next line's indent or ``>`` prefix as one space."""
    return re.sub(r"\r?\n[ \t]*(?:>[ \t]?)*", " ", strip_markers(s))


def anchored_text(text: str, thread: Thread) -> str | None:
    """The anchored text with any comment markers inside it removed; None for an orphan thread."""
    if thread.anchor is None:
        return None
    return strip_markers(text[thread.anchor[0] : thread.anchor[1]])


# --- words, blocks, quotes ------------------------------------------------------


def _is_word(text: str, i: int) -> bool:
    if i < 0 or i >= len(text):
        return False
    c = text[i]
    if _WORD_RE.match(c):
        return True
    if c in "'’":
        return i > 0 and i + 1 < len(text) and bool(_WORD_RE.match(text[i - 1])) and bool(_WORD_RE.match(text[i + 1]))
    return False


def snap_to_words(text: str, start: int, end: int) -> tuple[int, int]:
    """Widen each end outward to a word boundary; never narrows, never crosses a marker."""
    while start > 0 and _is_word(text, start - 1) and _is_word(text, start):
        start -= 1
    while end < len(text) and _is_word(text, end) and _is_word(text, end - 1):
        end += 1
    return start, end


def _extend(c: str) -> bool:
    o = ord(c)
    return (
        unicodedata.category(c) in ("Mn", "Me", "Mc")
        or o == 0x200D
        or 0xFE00 <= o <= 0xFE0F
        or 0xE0100 <= o <= 0xE01EF
        or 0x1F3FB <= o <= 0x1F3FF
        or 0xE0020 <= o <= 0xE007F
    )


def _regional(c: str) -> bool:
    return 0x1F1E6 <= ord(c) <= 0x1F1FF


def _grapheme_boundary(text: str, i: int) -> bool:
    """Whether a grapheme cluster may end before ``text[i]`` (the rules that matter for
    comments: CR LF, combining marks and other extenders, emoji ZWJ sequences, flags)."""
    if i <= 0 or i >= len(text):
        return True
    a, b = text[i - 1], text[i]
    if a == "\r" and b == "\n":
        return False
    if _extend(b) or a == "\u200d":
        return False
    if _regional(a) and _regional(b):
        k = i - 1
        while k >= 0 and _regional(text[k]):
            k -= 1
        return (i - 1 - k) % 2 == 0
    return True


def snap_to_graphemes(text: str, start: int, end: int) -> tuple[int, int]:
    """Widen each end to a grapheme cluster boundary, so a match never splits one,
    and never split an escaped pipe (``\\|``)."""
    while not _grapheme_boundary(text, start):
        start -= 1
    while not _grapheme_boundary(text, end):
        end += 1
    if start > 0 and text[start - 1] == "\\" and start < len(text) and text[start] == "|":
        start -= 1
    if end > 0 and text[end - 1] == "\\" and end < len(text) and text[end] == "|":
        end += 1
    return start, end


def block_end(text: str, offset: int) -> int:
    """Where a new thread block goes for an anchor at ``offset``: after the top-level
    block that holds it (CommonMark's paragraph interruption), after any thread blocks there."""
    reg = _regions(text)
    lines = reg.lines
    if not lines:
        return len(text)
    k = next((i for i, l in enumerate(lines) if offset < l[2]), len(lines) - 1)
    seg = next((s for s in reg.segs if s[1] <= k <= s[2]), None)
    last = seg[2] if seg else k
    pos = lines[last][2]
    while True:
        nxt = next((b for b in reg.blocks if b[0] == pos), None)
        if not nxt:
            break
        pos = nxt[1]
    return pos


# Where text isn't visible: (start, end) spans, by kind.
_VISIBLE, _CODE, _WALL = 0, 1, 2


def _inline_walls(text: str, a: int, b: int, out: list[tuple[int, int]]) -> None:
    """Link destinations and brackets, whole images, HTML tags and comments, autolink brackets."""
    i = a
    while i < b:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "<":
            m = re.compile(r"<(?:[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*|[^\s<>@]+@[^\s<>@]+)>").match(text, i, b)
            if m:
                out.append((i, i + 1))
                out.append((m.end() - 1, m.end()))
                i = m.end()
                continue
            if _MARKER_RE.match(text, i, b):
                i = _MARKER_RE.match(text, i, b).end()
                continue
            if text.startswith("<!--", i):
                e = text.find("-->", i + 4, b)
                e = b if e < 0 else e + 3
                out.append((i, e))
                i = e
                continue
            m = re.compile(r"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>").match(text, i, b)
            if m:
                out.append((i, m.end()))
                i = m.end()
                continue
        if c == "!" and text.startswith("![", i):
            close = _bracket_end(text, i + 1, b)
            if close is not None:
                e = _link_tail(text, close + 1, b)
                out.append((i, e if e is not None else close + 1))
                i = e if e is not None else close + 1
                continue
        if c == "[":
            close = _bracket_end(text, i, b)
            if close is not None:
                e = _link_tail(text, close + 1, b)
                if e is not None:
                    out.append((i, i + 1))
                    out.append((close, e))
                    _inline_walls(text, i + 1, close, out)
                    i = e
                    continue
        i += 1


def _bracket_end(text: str, i: int, b: int) -> int | None:
    """The ``]`` matching the ``[`` at ``i``, within one paragraph."""
    depth = 0
    j = i
    while j < b:
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return j
        elif c == "\n" and re.match(r"[ \t>]*\r?\n", text[j + 1 : j + 40]):
            return None
        j += 1
    return None


def _link_tail(text: str, i: int, b: int) -> int | None:
    """The end of ``(dest "title")`` or ``[ref]`` right after a link's text, else None."""
    if i < b and text[i] == "(":
        depth = 0
        j = i
        while j < b:
            c = text[j]
            if c == "\\":
                j += 2
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    return j + 1
            elif c == "\n" and re.match(r"[ \t]*\r?\n", text[j + 1 : j + 40]):
                return None
            j += 1
        return None
    if i < b and text[i] == "[":
        j = text.find("]", i + 1, b)
        if j >= 0 and "\n" not in text[i:j]:
            return j + 1
    return None


def _visible(text: str):
    """The text as a reader sees it, for searching: (chars, source offset per char, code flag per
    char, paragraph-break flag per char).

    Markers are zero-width; quote prefixes at line starts count as whitespace; whitespace runs
    collapse to one space; code (front matter, fences, indented and inline code) is searchable but
    flagged; thread blocks, link destinations and brackets, images, HTML tags and comments,
    autolink brackets and link reference definitions are walls ("\\0") nothing matches across.
    """
    reg = _regions(text)
    lines = reg.lines
    walls: list[tuple[int, int]] = [(s, e) for s, e, _, _ in reg.blocks]
    # Text outside code and thread blocks, line by line, for the inline walls and definitions.
    hidden = sorted(reg.ignored + walls)
    for s, e, full in lines:
        if not _inside(hidden, s) and _REFDEF_RE.match(text[s:e]):
            walls.append((s, e))
    segments = []
    pos = 0
    for a, b in sorted(hidden + walls):
        if a > pos:
            segments.append((pos, a))
        pos = max(pos, b)
    if pos < len(text):
        segments.append((pos, len(text)))
    for a, b in segments:
        _inline_walls(text, a, b, walls)
    # Tables: a cell boundary (an unescaped pipe) and the delimiter row are walls,
    # so a match stays in one cell; an escaped pipe's backslash is zero-width.
    zero = []
    dropped: list[tuple[int, int]] = []  # cells beyond the header's columns: the renderer drops them
    for head, delim, last in reg.tables:
        walls.append((lines[delim][0], lines[delim][1]))
        columns = len(_row_cells(text[lines[head][0] : lines[head][1]]))
        for k in range(head, last + 1):
            if k == delim:
                continue
            s, e, _ = lines[k]
            for pipe in _unescaped_pipes(text[s:e]):
                walls.append((s + pipe, s + pipe + 1))
            extra = _row_cells(text[s:e])[columns:]
            if extra:
                dropped.append((s + extra[0][0], s + extra[-1][1]))
    for m in re.finditer(r"\\\|", text):
        if not _inside(reg.ignored, m.start()):
            zero.append((m.start(), m.start() + 1))
    walls.sort()
    markers = sorted([(m.start(), m.end()) for m in _MARKER_RE.finditer(text)] + zero)
    # Line breaks that end a top-level block: the space they become is a paragraph break.
    seg_ends = {lines[s[2]][1] for s in reg.segs}
    chars: list[str] = []
    src: list[int] = []
    code: list[bool] = []
    breaks: list[bool] = []
    prefix_ends = {}
    for s, e, _ in lines:
        m = re.compile(r"[ \t]*(?:>[ \t]?)+").match(text, s, e)
        if m:
            prefix_ends[s] = m.end()
    wall_at = {}
    for a, b in walls:
        if a not in wall_at or wall_at[a] < b:
            wall_at[a] = b
    ig = reg.ignored

    def space(i: int, brk: bool) -> None:
        if chars and chars[-1] == " ":
            if brk:
                breaks[-1] = True
            return
        chars.append(" ")
        src.append(i)
        code.append(_inside(ig, i))
        breaks.append(brk)

    i = 0
    n = len(text)
    mi = 0
    while i < n:
        if i in wall_at:
            chars.append("\0")
            src.append(i)
            code.append(False)
            breaks.append(False)
            i = max(wall_at[i], i + 1)
            continue
        if i in prefix_ends:
            space(i, False)
            i = prefix_ends[i]
            continue
        while mi < len(markers) and markers[mi][1] <= i:
            mi += 1
        if mi < len(markers) and markers[mi][0] == i:
            i = markers[mi][1]
            continue
        c = text[i]
        if c in _WS:
            brk = False
            if c == "\n" or (c == "\r" and text.startswith("\r\n", i)):
                end = i
                brk = end in seg_ends
                if c == "\n":
                    k = i + 1
                    e = text.find("\n", k)
                    e = n if e < 0 else e
                    if text[k:e].strip(" \t\r>") == "" and e < n:
                        brk = True
            space(i, brk)
            i += 1
            continue
        chars.append(c)
        src.append(i)
        code.append(_inside(ig, i))
        breaks.append(False)
        i += 1
    return "".join(chars), src, code, breaks, dropped


# v0.25 (#3, ruling 22): spans a comment's markers must never split. An autolink with its
# brackets, a bare URL (up to whitespace or "<"), an HTML entity.
# v0.26 (review L4, N5): one whitespace class in all three scanners (this, the app's
# CommentFormat.swift, the editor's comments.ts): space, tab, LF, CR, FF and VT.
_AUTOLINK_RE = re.compile(r"<[A-Za-z][A-Za-z0-9+.\-]{1,31}:[^ \t\n\r\f\x0b<>]*>")
_EMAIL_AUTOLINK_RE = re.compile(r"<[^ \t\n\r\f\x0b<>@]+@[^ \t\n\r\f\x0b<>@]+>")
# A bare URL stops at whitespace, ``<`` or ``]``, and leaves trailing punctuation out (as GFM does).
_BARE_URL_RE = re.compile(r"(?:https?://|www\.)[^ \t\n\r\f\x0b<\]]*")
_URL_TRAILING = ".,:;!?)]'\""
_ENTITY_RE = re.compile(r"&(?:[A-Za-z][A-Za-z0-9]*|#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6});")
INSIDE_ATOM = "inside a link or entity"


def _atoms(text: str) -> list[tuple[int, int, int, int]]:
    """Autolinks (brackets included), bare URLs and HTML entities, as source spans: ``(start, end,
    inner start, inner end)``. An autolink's inner span is its address, without the brackets."""
    out: list[tuple[int, int, int, int]] = []
    for pattern in (_AUTOLINK_RE, _EMAIL_AUTOLINK_RE):
        out += [(m.start(), m.end(), m.start() + 1, m.end() - 1) for m in pattern.finditer(text)]
    autolinks = list(out)
    for m in _BARE_URL_RE.finditer(text):
        if any(a <= m.start() < b for a, b, _, _ in autolinks):
            continue  # the address inside an autolink is the autolink's
        end = m.end()
        while end > m.start() and text[end - 1] in _URL_TRAILING:
            end -= 1
        if end > m.start():
            out.append((m.start(), end, m.start(), end))
    out += [(m.start(), m.end(), m.start(), m.end()) for m in _ENTITY_RE.finditer(text)]
    return sorted(out)


def _splits_atom(atoms: list[tuple[int, int, int, int]], span: tuple[int, int]) -> bool:
    """Whether ``span`` starts or ends strictly inside an atom. Covering a whole one is fine, and so
    is covering an autolink's address (the brackets aren't shown, so they can't be quoted)."""
    start, end = span
    return any(
        (a < start < b or a < end < b) and not (start <= ia and ib <= end)
        for a, b, ia, ib in atoms
    )


def _normalise(q: str) -> str:
    # A quote may be written as the source shows a cell (`x \| y`) or as it renders (`x | y`).
    return re.sub(r"[ \t\n\r\f\v]+", " ", q.replace("\\|", "|")).strip(" ")


def _matches(text: str, quote: str, within: tuple[int, int] | None = None):
    """Matches of ``quote`` in the visible text: (good spans, each with whether it splits a link or
    entity, any in code, any across paragraphs, any not shown)."""
    q = _normalise(quote)
    good: list[tuple[tuple[int, int], bool]] = []
    in_code = crosses = not_shown = False
    if not q:
        return good, in_code, crosses, not_shown
    vis, src, code, breaks, dropped = _visible(text)
    atoms = _atoms(text)
    i = vis.find(q)
    while i >= 0:
        j = i + len(q)
        span = (src[i], src[j - 1] + 1)
        if within and not (within[0] <= span[0] and span[1] <= within[1]):
            pass
        elif any(a <= span[0] < b for a, b in dropped):
            not_shown = True
        elif any(code[i:j]):
            in_code = True
        elif any(breaks[i:j]):
            crosses = True
        else:
            good.append((span, _splits_atom(atoms, span)))
        i = vis.find(q, j)
    return good, in_code, crosses, not_shown


def find_quote(text: str, quote: str, occurrence: int = 1) -> tuple[int, int] | str:
    """The ``occurrence``-th (1-based) visible match of ``quote``, its ends snapped to grapheme
    clusters (never split, never widened to words), or a refusal reason."""
    good, in_code, crosses, not_shown = _matches(text, quote)
    if 1 <= occurrence <= len(good):
        (a, b), splits = good[occurrence - 1]
        if splits:
            # Refused, not widened (ruling 22): widening would change the quote the fingerprint holds.
            return INSIDE_ATOM
        return snap_to_graphemes(text, a, b)
    if good:
        return f"occurs {len(good)} times"
    if not_shown:
        return "not shown in the table"
    if in_code:
        return "inside code or front matter"
    if crosses:
        return "crosses paragraphs"
    return "not found"


def new_id(text: str, rng: random.Random) -> str:
    taken = set(_ANY_ID_RE.findall(text))
    for _ in range(1000):
        c = "".join(rng.choice(ID_CHARS) for _ in range(5))
        if c not in taken:
            return c
    while True:
        c = "".join(rng.choice(ID_CHARS) for _ in range(8))
        if c not in taken:
            return c


# --- edits --------------------------------------------------------------------


def _splice(text: str, edits: list[tuple[int, int, str, int]]) -> str:
    """Apply (start, end, insert, order) edits made against ``text``."""
    out = []
    cur = 0
    for a, b, ins, _ in sorted(edits, key=lambda e: (e[0], e[3])):
        if a > cur:
            out.append(text[cur:a])
        out.append(ins)
        cur = max(cur, b)
    out.append(text[cur:])
    return "".join(out)


def _orphan_edits(text: str) -> list[tuple[int, int, str, int]]:
    reg = _regions(text)
    ids = {b[3] for b in reg.blocks}
    return [(s, e, "", 1) for s, e, tid, _ in _markers(text, reg) if tid not in ids]


def _field(value: str, always: bool = False) -> str:
    if always or any(c in value for c in ' \t"\\') or "-->" in value:
        return '"' + escape_quoted(value) + '"'
    return value


def reply_author(name: str) -> str:
    """#11 (ruling 23): a name as a reply line writes it: each ``:`` as ``\u2236`` (RATIO), so the line reads back.

    Compare authors through it too (``is_person``, the edit guard), so a person always finds their own comments.
    """
    return name.replace(":", "\u2236")


def _reply_lines(author: str, at: str, body: str, prefix: str | None = None) -> list[str]:
    parts = body.strip().replace("\r\n", "\n").replace("\r", "\n").split("\n")
    out = [(prefix if prefix is not None else f"{reply_author(author)} ({at}): ") + escape_body(parts[0])]
    for line in parts[1:]:
        line = escape_body(line)
        m = _REPLY_RE.match(line)
        # A leading backslash keeps a line that would read as a reply, a reaction,
        # an escaped line or a blank line as this reply's text (read back without it).
        if _blank(line) or line.startswith(("\\", "+")) or (m and m.group(1).strip()):
            line = "\\" + line
        out.append(line)
    return out


def _thread(text: str, thread_id: str) -> Thread:
    for t in parse(text).threads:
        if t.id == thread_id:
            return t
    raise KeyError(thread_id)


def add_thread(text: str, start: int, end: int, *, id: str, author: str, at: str, body: str) -> str:
    eol = line_ending(text)
    lines = [
        f"<!--co:{id} by:{_field(author)} at:{_field(at)} status:open quote:{_field(quote_text(text[start:end]), True)}",
        *_reply_lines(author, at, body),
        "-->",
    ]
    block = eol.join(lines)
    p = block_end(text, start)
    insert = (eol + block) if p == len(text) and not text.endswith("\n") else (block + eol)
    edits = _orphan_edits(text)
    edits += [(p, p, insert, 2), (end, end, f"<!--/c:{id}-->", 0), (start, start, f"<!--c:{id}-->", 3)]
    return _splice(text, edits)


def add_reply(text: str, thread_id: str, *, author: str, at: str, body: str) -> str:
    t = _thread(text, thread_id)
    eol = line_ending(text)
    lines = _reply_lines(author, at, body)
    ls = text.rfind("\n", 0, t.close) + 1
    if text[ls : t.close].strip() == "":
        edit = (ls, ls, eol.join(lines) + eol, 0)
    else:
        edit = (t.close, t.close, eol + eol.join(lines) + eol, 0)
    return _splice(text, _orphan_edits(text) + [edit])


def set_status(text: str, thread_id: str, status: Literal["open", "resolved"]) -> str:
    t = _thread(text, thread_id)
    f = next((f for f in t.fields if f[0] == "status"), None)
    if f:
        # The first status field is the one read; it is left as written when it already says so.
        current = unescape_quoted(text[f[1] : f[2]])
        edit = (f[1], f[2], text[f[1] : f[2]] if current == status else status, 0)
    elif status == "open":
        return _splice(text, _orphan_edits(text))  # no status field reads as open already
    else:
        at = next((f for f in t.fields if f[0] == "at"), None)
        # After the ID where ``<!--co:`` begins (#9: an indented block starts before it).
        opener = text.find("<!--co:", t.block[0])
        pos = at[2] + (1 if at and at[2] < len(text) and text[at[2]] == '"' else 0) if at else opener + len(f"<!--co:{t.id}")
        edit = (pos, pos, f" status:{status}", 0)
    return _splice(text, _orphan_edits(text) + [edit])


class CommentChanged(Exception):
    """The comment an action was aimed at isn't in the text as it was seen (someone changed it)."""


Fingerprint = tuple  # (author, at, text) of a comment as it was shown


def _locate(text: str, thread_id: str, index: int, fingerprint: Fingerprint | None) -> tuple[Thread, int]:
    """The thread and comment an action means: by id and the comment's fingerprint when given
    (exactly one match, and the thread's first comment exactly when ``index`` is 0), else by index."""
    threads = [t for t in parse(text).threads if t.id == thread_id]
    if not threads:
        raise KeyError(thread_id)
    if fingerprint is None:
        t = threads[0]
        if not 0 <= index < max(1, len(t.replies)):
            raise KeyError(f"{thread_id}#{index}")
        return t, index
    found = [
        (t, i)
        for t in threads
        for i, r in enumerate(t.replies)
        if (r.author, r.at, r.text) == tuple(fingerprint) and (i == 0) == (index == 0)
    ]
    if len(found) != 1:
        raise CommentChanged(thread_id)
    return found[0]


def _closer_on_line(text: str, end: int, close: int) -> bool:
    return "\n" not in text[end:close]


def edit_comment(text: str, thread_id: str, index: int, *, body: str, fingerprint: Fingerprint | None = None) -> str:
    """Replace the text of comment ``index`` (0 is the thread's first) and nothing else: its author
    and time stay as written, the other comments, reactions and the header are untouched; a closing
    ``-->`` on its line moves to a line of its own."""
    if not body.strip():
        raise ValueError("a comment needs text")
    t, i = _locate(text, thread_id, index, fingerprint)
    if not t.reply_spans:
        raise KeyError(f"{thread_id}#{index}")
    start, text_at, end = t.reply_spans[i]
    eol = line_ending(text)
    lines = eol.join(_reply_lines("", "", body, prefix=text[start:text_at]))
    if _closer_on_line(text, end, t.close):
        edit = (start, t.close, lines + eol, 0)
    else:
        edit = (start, end, lines, 0)
    return _splice(text, _orphan_edits(text) + [edit])


def delete_comment(text: str, thread_id: str, index: int, fingerprint: Fingerprint | None = None) -> str:
    """Delete reply ``index``, or with ``index`` 0 the whole thread: the block the comment is in and,
    when that block owns them, its anchors. A closing ``-->`` is never removed with a reply."""
    reg = _regions(text)
    t, i = _locate(text, thread_id, index, fingerprint)
    edits = _orphan_edits(text)
    if i == 0:
        start, end = t.block
        if end == len(text) and not text.endswith("\n") and start > 0:
            start -= 2 if text[start - 2 : start] == "\r\n" else 1  # the file keeps having no final line break
        edits.append((start, end, "", 2))
        if t.anchor is not None:
            edits += [(a, b, "", 1) for a, b, tid, _ in _markers(text, reg) if tid == thread_id]
        return _splice(text, edits)
    start, _, end = t.reply_spans[i]
    if _closer_on_line(text, end, t.close):
        edits.append((start, t.close, "", 0))
    else:
        nl = text.find("\n", end)
        edits.append((start, len(text) if nl < 0 else nl + 1, "", 0))
    return _splice(text, edits)
