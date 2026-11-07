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
"""

from __future__ import annotations

import random
import re
from dataclasses import dataclass
from typing import Literal

ID_RE = r"[a-z0-9]{5,8}"
ID_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789"

_OPEN_RE = re.compile(r"<!--c:(" + ID_RE + r")-->")
_CLOSE_RE = re.compile(r"<!--/c:(" + ID_RE + r")-->")
_MARKER_RE = re.compile(r"<!--/?c:" + ID_RE + r"-->")
_ANY_ID_RE = re.compile(r"<!--/?co?:([a-z0-9]+)")
_BLOCK_START_RE = re.compile(r"[ \t]*<!--co:(" + ID_RE + r")(?=[\s]|-->)")
_REPLY_RE = re.compile(r"^(.*?)(?:\s\(([^)]*)\))?:\s?(.*)$")
_FENCE_RE = re.compile(r"^[ \t>]*(`{3,}|~{3,})")
_LIST_RE = re.compile(r"^\s{0,3}([-*+]|\d+[.)])\s")
_HEADING_RE = re.compile(r"^#{1,6}\s")
_QUOTE_PREFIX_RE = re.compile(r"[ \t]*(?:>[ \t]?)+")
_WORD_RE = re.compile(r"\w")


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
    # Where the header's fields sit, for splices: key -> (value start, value end).
    fields: tuple[tuple[str, int, int], ...] = ()
    close: int = 0  # offset of the closing "-->"


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
    return s.strip() == ""


# --- regions ------------------------------------------------------------------


def _front_matter(text: str, lines) -> tuple[int, int] | None:
    if not lines or text[lines[0][0] : lines[0][1]].rstrip(" \t") != "---":
        return None
    for start, end, full in lines[1:]:
        if text[start:end].rstrip(" \t") in ("---", "..."):
            return (0, full)
    return None


def _fences(text: str, lines, skip_until: int) -> list[tuple[int, int]]:
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


def _inside(spans, pos: int) -> bool:
    return any(a <= pos < b for a, b in spans)


def _block_spans(text: str, lines, ignored) -> list[tuple[int, int, int, str]]:
    """Thread blocks outside ignored regions: (start, end incl. line break, close offset, id)."""
    out = []
    k = 0
    while k < len(lines):
        start, end, full = lines[k]
        m = _BLOCK_START_RE.match(text, start, end)
        if m and not _inside(ignored, start):
            close = text.find("-->", m.end())
            if close < 0:
                k += 1
                continue
            # The block ends with the line that holds its "-->".
            j = k
            while lines[j][2] <= close:
                j += 1
            out.append((start, lines[j][2], close, m.group(1)))
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


def _regions(text: str):
    lines = _lines(text)
    fm = _front_matter(text, lines)
    coarse = ([fm] if fm else []) + _fences(text, lines, fm[1] if fm else 0)
    blocks = _block_spans(text, lines, coarse)
    walls = sorted(coarse + [(s, e) for s, e, _, _ in blocks])
    segments = []
    pos = 0
    for a, b in walls:
        if a > pos:
            segments.append((pos, a))
        pos = max(pos, b)
    if pos < len(text):
        segments.append((pos, len(text)))
    ignored = sorted(coarse + _code_spans(text, segments))
    return lines, ignored, blocks


def ignored_regions(text: str) -> list[tuple[int, int]]:
    """Front matter, ``` and ~~~ fences, and inline code spans."""
    return _regions(text)[1]


# --- header and thread lines ----------------------------------------------------


def _unescape(s: str) -> str:
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s) and s[i + 1] == '"':
            out.append('"')
            i += 2
        elif s.startswith("--\\>", i):
            out.append("-->")
            i += 4
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _escape_quote(s: str) -> str:
    s = s.replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
    return s.replace('"', '\\"').replace("-->", "--\\>")


def _header_fields(text: str, a: int, b: int) -> list[tuple[str, int, int, str]]:
    """Tokens ``key:value`` / ``key:"…"`` in text[a:b]: (key, value start, value end, value)."""
    out = []
    i = a
    while i < b:
        while i < b and text[i] in " \t":
            i += 1
        if i >= b:
            break
        m = re.compile(r"([A-Za-z_][\w-]*):").match(text, i, b)
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
            out.append((key, vs, ve, _unescape(text[vs:ve])))
            i = j + 1
        else:
            j = i
            while j < b and text[j] not in " \t":
                j += 1
            out.append((key, i, j, _unescape(text[i:j])))
            i = j
    return out


def _thread_lines(raw: list[str]) -> tuple[list[Reply], list[str]]:
    replies: list[list] = []
    reactions: list[str] = []
    for line in raw:
        if line.startswith("\\"):
            if replies:
                replies[-1][2] += "\n" + _unescape(line[1:])
            continue
        if _blank(line):
            continue
        if line.startswith("+"):
            reactions.append(line)
            continue
        m = _REPLY_RE.match(line)
        if m and m.group(1).strip():
            replies.append([m.group(1).strip(), m.group(2), _unescape(m.group(3))])
        elif replies:
            replies[-1][2] += "\n" + _unescape(line)
    return [Reply(a, t, x) for a, t, x in replies], reactions


# --- parse --------------------------------------------------------------------


def _markers(text: str, ignored, blocks):
    walls = ignored + [(s, e) for s, e, _, _ in blocks]
    opens: dict[str, list[tuple[int, int]]] = {}
    closes: dict[str, list[tuple[int, int]]] = {}
    for rx, into in ((_OPEN_RE, opens), (_CLOSE_RE, closes)):
        for m in rx.finditer(text):
            if not _inside(walls, m.start()):
                into.setdefault(m.group(1), []).append((m.start(), m.end()))
    return opens, closes


def parse(text: str) -> Parsed:
    lines, ignored, blocks = _regions(text)
    opens, closes = _markers(text, ignored, blocks)
    threads = []
    seen = set()
    for start, end, close, tid in blocks:
        seen.add(tid)
        header_end = text.find("\n", start)
        header_end = end if header_end < 0 or header_end >= close else header_end
        hb = min(close, header_end)
        if hb > start and text[hb - 1] == "\r":
            hb -= 1
        head_from = text.index("<!--co:", start) + len("<!--co:") + len(tid)
        fields = _header_fields(text, head_from, hb)
        values = {k: v for k, _, _, v in fields}
        body = text[hb:close]
        raw = [l.rstrip("\r") for l in body.split("\n")[1:]] if close > hb else []
        replies, reactions = _thread_lines(raw)
        anchor = None
        if tid in opens and tid in closes:
            o = opens[tid][0][1]
            c = next((s for s, _ in closes[tid] if s >= o), None)
            if c is not None:
                anchor = (o, c)
        status = values.get("status", "open")
        threads.append(
            Thread(
                id=tid,
                by=values.get("by", ""),
                at=values.get("at", ""),
                status="resolved" if status == "resolved" else "open",
                quote=values.get("quote", ""),
                replies=tuple(replies),
                reactions=tuple(reactions),
                block=(start, end),
                anchor=anchor,
                fields=tuple((k, s, e) for k, s, e, _ in fields),
                close=close,
            )
        )
    orphans = []
    for tid in list(opens) + list(closes):
        if tid not in seen and tid not in orphans:
            orphans.append(tid)
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
        return (
            i > 0 and i + 1 < len(text) and bool(_WORD_RE.match(text[i - 1])) and bool(_WORD_RE.match(text[i + 1]))
        )
    return False


def snap_to_words(text: str, start: int, end: int) -> tuple[int, int]:
    """Widen each end outward to a word boundary; never narrows, never crosses a marker."""
    while start > 0 and _is_word(text, start - 1) and _is_word(text, start):
        start -= 1
    while end < len(text) and _is_word(text, end) and _is_word(text, end - 1):
        end += 1
    return start, end


def block_end(text: str, offset: int) -> int:
    """Where a new thread block goes for an anchor at ``offset`` (rulings: after the top-level block)."""
    lines, ignored, blocks = _regions(text)
    if not lines:
        return len(text)
    fm = _front_matter(text, lines)
    floor = fm[1] if fm else 0
    block_lines = {lines.index(l) for l in lines if any(s <= l[0] < e for s, e, _, _ in blocks)}

    def t(k):
        return text[lines[k][0] : lines[k][1]]

    i = next(k for k, l in enumerate(lines) if offset < l[2] or k == len(lines) - 1)
    j = i
    while j > 0 and not _blank(t(j - 1)) and lines[j - 1][0] >= floor and (j - 1) not in block_lines:
        j -= 1
    first = t(j)
    if _HEADING_RE.match(first):
        k = j
    elif _LIST_RE.match(first):
        k = i
        while True:
            if k + 1 < len(lines) and not _blank(t(k + 1)) and (k + 1) not in block_lines:
                k += 1
                continue
            n = k + 1
            while n < len(lines) and _blank(t(n)):
                n += 1
            if n > k + 1 and n < len(lines) and n not in block_lines and (t(n)[:1] in (" ", "\t") or _LIST_RE.match(t(n))):
                k = n
                continue
            break
    elif first.lstrip().startswith(">"):
        k = i
        while k + 1 < len(lines) and t(k + 1).lstrip().startswith(">"):
            k += 1
    else:
        k = i
        while k + 1 < len(lines) and not _blank(t(k + 1)) and (k + 1) not in block_lines:
            k += 1
    pos = lines[k][2]
    while True:
        nxt = next((b for b in blocks if b[0] == pos), None)
        if not nxt:
            break
        pos = nxt[1]
    return pos


def _visible(text: str):
    """The text as a reader sees it, for searching: (chars, source offset per char, ignored flag per char).

    Markers are zero-width, quote prefixes at line starts count as whitespace,
    whitespace runs collapse to one space, and thread blocks are walls ("\\0").
    """
    lines, ignored, blocks = _regions(text)
    markers = [(m.start(), m.end()) for m in _MARKER_RE.finditer(text)]
    walls = [(s, e) for s, e, _, _ in blocks]
    chars: list[str] = []
    src: list[int] = []
    flag: list[bool] = []
    breaks: list[bool] = []  # this whitespace run held a paragraph break
    prefix_ends = {}
    for s, e, _ in lines:
        m = _QUOTE_PREFIX_RE.match(text, s, e)
        if m and ">" in m.group(0):
            prefix_ends[s] = m.end()
    i = 0
    n = len(text)
    mi = 0
    markers.sort()
    while i < n:
        if i in prefix_ends:
            stop = prefix_ends[i]
            _push_space(chars, src, flag, breaks, i, _inside(ignored, i))
            i = stop
            continue
        while mi < len(markers) and markers[mi][1] <= i:
            mi += 1
        if mi < len(markers) and markers[mi][0] == i:
            i = markers[mi][1]
            continue
        w = next((b for b in walls if b[0] == i), None)
        if w:
            chars.append("\0")
            src.append(i)
            flag.append(False)
            breaks.append(False)
            i = w[1]
            continue
        c = text[i]
        if c.isspace():
            _push_space(chars, src, flag, breaks, i, _inside(ignored, i))
            if c == "\n" and chars and chars[-1] == " ":
                # A line holding only whitespace or ">" ends the paragraph.
                k = i + 1
                e = text.find("\n", k)
                e = n if e < 0 else e
                if text[k:e].strip(" \t\r>") == "" and e < n:
                    breaks[-1] = True
            i += 1
            continue
        chars.append(c)
        src.append(i)
        flag.append(_inside(ignored, i))
        breaks.append(False)
        i += 1
    return "".join(chars), src, flag, breaks


def _push_space(chars, src, flag, breaks, i, ig):
    if chars and chars[-1] == " ":
        return
    chars.append(" ")
    src.append(i)
    flag.append(ig)
    breaks.append(False)


def _normalise(q: str) -> str:
    return re.sub(r"\s+", " ", q).strip()


def find_quote(text: str, quote: str, occurrence: int = 1) -> tuple[int, int] | str:
    """The ``occurrence``-th (1-based) match of ``quote``, snapped to words, or a refusal reason."""
    q = _normalise(quote)
    if not q:
        return "not found"
    vis, src, flag, breaks = _visible(text)
    good: list[tuple[int, int]] = []
    in_code = crosses = False
    i = vis.find(q)
    while i >= 0:
        j = i + len(q)
        if any(flag[i:j]):
            in_code = True
        elif any(breaks[i:j]):
            crosses = True
        else:
            good.append((src[i], src[j - 1] + 1))
        i = vis.find(q, j)
    if occurrence <= len(good):
        a, b = good[occurrence - 1]
        return snap_to_words(text, a, b)
    if good:
        return f"occurs {len(good)} times"
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
    lines, ignored, blocks = _regions(text)
    opens, closes = _markers(text, ignored, blocks)
    ids = {b[3] for b in blocks}
    edits = []
    for table in (opens, closes):
        for tid, spans in table.items():
            if tid not in ids:
                edits += [(s, e, "", 1) for s, e in spans]
    return edits


def _field(value: str, always: bool = False) -> str:
    if always or " " in value or '"' in value:
        return '"' + _escape_quote(value) + '"'
    return value.replace("-->", "--\\>")


def _reply_lines(author: str, at: str, body: str) -> list[str]:
    parts = body.strip().replace("\r\n", "\n").replace("\r", "\n").split("\n")
    first = f"{author} ({at}): " + parts[0].replace("-->", "--\\>")
    out = [first]
    for line in parts[1:]:
        line = line.replace("-->", "--\\>")
        m = _REPLY_RE.match(line)
        if _blank(line) or line.startswith(("\\", "+")) or (m and m.group(1).strip()):
            line = "\\" + line.strip() if _blank(line) else "\\" + line
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
        edit = (f[1], f[2], status, 0)
    else:
        at = next((f for f in t.fields if f[0] == "at"), None)
        pos = at[2] if at else t.block[0] + len(f"<!--co:{t.id}")
        edit = (pos, pos, f" status:{status}", 0)
    return _splice(text, _orphan_edits(text) + [edit])
