// Comments in Edit mode (v0.23): comment format v1 (protocol/COMMENTS.md)
// markup hidden the way the read view hides it. Anchors <!--c:ID--> and
// <!--/c:ID--> are replaced with nothing, thread blocks <!--co:ID ...-->
// are hidden whole lines, and text anchored by an open thread is
// highlighted. The markup is atomic, so the cursor never lands inside it;
// editing inside an anchored span keeps the anchors, and deleting all of the
// anchored text removes them (the thread becomes an orphan).
//
// Offsets are JavaScript string offsets: UTF-16, as Swift's.

import { ChangeSet, EditorSelection, EditorState, type Extension, RangeSet, StateEffect, StateField, Transaction, type TransactionSpec } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, keymap } from "@codemirror/view";
import { Prec } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import type { Language } from "@codemirror/language";
import type { MarkdownConfig } from "@lezer/markdown";

export interface Anchor {
  id: string;
  openFrom: number;
  openTo: number;
  closeFrom: number;
  closeTo: number;
}

export interface Block {
  id: string;
  from: number;
  to: number; // after the closing line's break
  status: "open" | "resolved";
}

export interface Scan {
  anchors: Anchor[];
  blocks: Block[];
  ignored: Array<[number, number]>;
  markers: Array<[number, number]>;
}

interface Line {
  start: number;
  end: number;
  full: number;
}

function lines(text: string): Line[] {
  const out: Line[] = [];
  let i = 0;
  while (i < text.length) {
    const j = text.indexOf("\n", i);
    if (j < 0) {
      out.push({ start: i, end: text.length, full: text.length });
      break;
    }
    out.push({ start: i, end: j > i && text[j - 1] === "\r" ? j - 1 : j, full: j + 1 });
    i = j + 1;
  }
  return out;
}

const inside = (spans: Array<[number, number]>, pos: number) => spans.some(([a, b]) => a <= pos && pos < b);
const blank = (s: string) => s.trim() === "";

function frontMatter(text: string, ls: Line[]): [number, number] | null {
  if (!ls.length || text.slice(ls[0].start, ls[0].end).replace(/[ \t]+$/, "") !== "---") return null;
  for (const l of ls.slice(1)) {
    const t = text.slice(l.start, l.end).replace(/[ \t]+$/, "");
    if (t === "---" || t === "...") return [0, l.full];
  }
  return null;
}

function fences(text: string, ls: Line[], skipUntil: number): Array<[number, number]> {
  const out: Array<[number, number]> = [];
  let openAt: number | null = null;
  let fence = "";
  for (const l of ls) {
    if (l.full <= skipUntil) continue;
    const line = text.slice(l.start, l.end);
    const m = /^[ \t>]*(`{3,}|~{3,})/.exec(line);
    if (openAt === null) {
      if (m) {
        openAt = l.start;
        fence = m[1];
      }
    } else if (m && m[1][0] === fence[0] && m[1].length >= fence.length && blank(line.slice(m[0].length))) {
      out.push([openAt, l.full]);
      openAt = null;
    }
  }
  if (openAt !== null) out.push([openAt, text.length]);
  return out;
}

// Block starts (CommonMark, as far as comments need it), the same rules as
// comments.py and CommentFormat.swift.
const TOP_FENCE = /^ {0,3}(`{3,}|~{3,})/;
const HEADING = /^ {0,3}#{1,6}(?:[ \t]|$)/;
const HR = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
const SETEXT = /^ {0,3}(?:=+|-+)[ \t]*$/;
const QUOTE = /^ {0,3}>/;
const HTML = /^ {0,3}<(?:[A-Za-z/?]|!)/;
const ANCHOR_LINE = /^ {0,3}<!--\/?c:[a-z0-9]{5,8}-->/;
const BULLET = /^ {0,3}[-*+][ \t]+\S/;
const ORDERED_ONE = /^ {0,3}1[.)][ \t]+\S/;
const LIST = /^ {0,3}(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$)/;
const INDENTED = /^(?: {4}| {0,3}\t)/;
const BLOCK_START = /^[ \t]*<!--co:([a-z0-9]{5,8})(?=[ \t\r\n\f\v]|-->|$)/;

function interrupts(t: string, inQuote = false): boolean {
  if (BLOCK_START.test(t)) return true;
  if (TOP_FENCE.test(t) || HEADING.test(t) || HR.test(t)) return true;
  if (!inQuote && QUOTE.test(t)) return true;
  if (HTML.test(t) && !ANCHOR_LINE.test(t)) return true;
  return BULLET.test(t) || ORDERED_ONE.test(t);
}

export interface Segment {
  kind: string;
  first: number;
  last: number;
}

// Top-level blocks: para, list, quote, heading, hr, fence, icode, html, thread, fm.
export function segments(text: string, ls: Line[], blocks: Block[], fm: [number, number] | null): Segment[] {
  const segs: Segment[] = [];
  const n = ls.length;
  const t = (k: number) => text.slice(ls[k].start, ls[k].end);
  const isBlank = (x: string) => /^[ \t\r\f\v]*$/.test(x);
  const lead = (x: string) => x.startsWith(" ") || x.startsWith("\t");
  const byStart = new Map(blocks.map((b) => [b.from, b]));
  let i = 0;
  if (fm) {
    let j = 0;
    while (ls[j].full < fm[1]) j++;
    segs.push({ kind: "fm", first: 0, last: j });
    i = j + 1;
  }
  while (i < n) {
    const line = t(i);
    if (isBlank(line)) { i++; continue; }
    const b = byStart.get(ls[i].start);
    if (b) {
      let j = i;
      while (ls[j].full < b.to) j++;
      segs.push({ kind: "thread", first: i, last: j });
      i = j + 1;
      continue;
    }
    const m = TOP_FENCE.exec(line);
    if (m) {
      const fence = m[1];
      let j = i + 1;
      for (; j < n; j++) {
        const mm = TOP_FENCE.exec(t(j));
        if (mm && mm[1][0] === fence[0] && mm[1].length >= fence.length && isBlank(t(j).slice(mm[0].length))) break;
      }
      j = Math.min(j, n - 1);
      segs.push({ kind: "fence", first: i, last: j });
      i = j + 1;
      continue;
    }
    if (INDENTED.test(line)) {
      let j = i;
      while (j + 1 < n && (INDENTED.test(t(j + 1)) || isBlank(t(j + 1)))) j++;
      while (isBlank(t(j))) j--;
      segs.push({ kind: "icode", first: i, last: j });
      i = j + 1;
      continue;
    }
    if (HEADING.test(line)) { segs.push({ kind: "heading", first: i, last: i }); i++; continue; }
    if (HR.test(line)) { segs.push({ kind: "hr", first: i, last: i }); i++; continue; }
    if (HTML.test(line) && !ANCHOR_LINE.test(line)) {
      let j = i;
      if (line.replace(/^ +/, "").startsWith("<!--")) {
        while (j < n && !t(j).includes("-->")) j++;
        j = Math.min(j, n - 1);
      } else {
        while (j + 1 < n && !isBlank(t(j + 1))) j++;
      }
      segs.push({ kind: "html", first: i, last: j });
      i = j + 1;
      continue;
    }
    if (QUOTE.test(line)) {
      let j = i;
      while (j + 1 < n && !isBlank(t(j + 1)) && (QUOTE.test(t(j + 1)) || !interrupts(t(j + 1), true))) j++;
      segs.push({ kind: "quote", first: i, last: j });
      i = j + 1;
      continue;
    }
    if (LIST.test(line)) {
      let j = i;
      for (;;) {
        if (j + 1 < n && !isBlank(t(j + 1))) {
          const next = t(j + 1);
          if (lead(next) || LIST.test(next) || !interrupts(next)) {
            if (BLOCK_START.test(next)) break;
            j++;
            continue;
          }
          break;
        }
        let k = j + 1;
        while (k < n && isBlank(t(k))) k++;
        if (k > j + 1 && k < n && !BLOCK_START.test(t(k)) && (lead(t(k)) || LIST.test(t(k)))) {
          j = k;
          continue;
        }
        break;
      }
      segs.push({ kind: "list", first: i, last: j });
      i = j + 1;
      continue;
    }
    let j = i;
    while (j + 1 < n) {
      const next = t(j + 1);
      if (isBlank(next)) break;
      if (SETEXT.test(next)) { j++; break; }
      if (interrupts(next)) break;
      j++;
    }
    segs.push({ kind: "para", first: i, last: j });
    i = j + 1;
  }
  return segs;
}

// A thread header's fields (`key:value` or `key:"…"`); the first of a duplicated key wins.
export function headerFields(header: string): Map<string, string> {
  const out = new Map<string, string>();
  let i = 0;
  const b = header.length;
  const unq = (v: string) => v.replace(/\\([\\">])/g, "$1");
  while (i < b) {
    while (i < b && (header[i] === " " || header[i] === "\t")) i++;
    if (i >= b) break;
    const m = /^([A-Za-z_][A-Za-z0-9_-]*):/.exec(header.slice(i));
    if (!m) {
      while (i < b && header[i] !== " " && header[i] !== "\t") i++;
      continue;
    }
    const key = m[1];
    i += m[0].length;
    let value: string;
    if (header[i] === '"') {
      let j = i + 1;
      while (j < b && header[j] !== '"') j += header[j] === "\\" && j + 1 < b ? 2 : 1;
      value = unq(header.slice(i + 1, Math.min(j, b)));
      i = j + 1;
    } else {
      let j = i;
      while (j < b && header[j] !== " " && header[j] !== "\t") j++;
      value = unq(header.slice(i, j));
      i = j;
    }
    if (!out.has(key)) out.set(key, value);
  }
  return out;
}

function codeSpans(text: string, segments: Array<[number, number]>): Array<[number, number]> {
  const out: Array<[number, number]> = [];
  for (const [a, b] of segments) {
    let i = a;
    while (i < b) {
      const j = text.indexOf("`", i);
      if (j < 0 || j >= b) break;
      let n = j;
      while (n < b && text[n] === "`") n++;
      const run = n - j;
      let k = n;
      let found: number | null = null;
      while (k < b) {
        const kk = text.indexOf("`", k);
        if (kk < 0 || kk >= b) break;
        let e = kk;
        while (e < b && text[e] === "`") e++;
        if (e - kk === run) {
          found = e;
          break;
        }
        k = e;
      }
      if (found !== null && !/\n[ \t>]*\r?\n/.test(text.slice(j, found))) {
        out.push([j, found]);
        i = found;
      } else {
        i = n;
      }
    }
  }
  return out;
}

export function scanComments(text: string): Scan {
  const ls = lines(text);
  const fm = frontMatter(text, ls);
  const coarse: Array<[number, number]> = [...(fm ? [fm] : []), ...fences(text, ls, fm ? fm[1] : 0)];
  const blocks: Block[] = [];
  for (let k = 0; k < ls.length; k++) {
    const l = ls[k];
    const m = BLOCK_START.exec(text.slice(l.start, l.end));
    if (!m || inside(coarse, l.start)) continue;
    const close = text.indexOf("-->", l.start + m[0].length);
    if (close < 0) continue;
    let j = k;
    while (ls[j].full <= close) j++;
    const header = text.slice(l.start + m[0].length, Math.min(close, l.end)).replace(/\r$/, "");
    const status = headerFields(header).get("status");
    blocks.push({ id: m[1], from: l.start, to: ls[j].full, status: status === "resolved" ? "resolved" : "open" });
    k = j;
  }
  const segs = segments(text, ls, blocks, fm);
  for (const sg of segs) if (sg.kind === "icode") coarse.push([ls[sg.first].start, ls[sg.last].full]);
  coarse.sort((x, y) => x[0] - y[0]);
  const walls = [...coarse, ...blocks.map((b) => [b.from, b.to] as [number, number])].sort((x, y) => x[0] - y[0]);
  const textSegs: Array<[number, number]> = [];
  let pos = 0;
  for (const [a, b] of walls) {
    if (a > pos) textSegs.push([pos, a]);
    pos = Math.max(pos, b);
  }
  if (pos < text.length) textSegs.push([pos, text.length]);
  const ignored = [...coarse, ...codeSpans(text, textSegs)].sort((x, y) => x[0] - y[0]);
  const live = [...ignored, ...blocks.map((b) => [b.from, b.to] as [number, number])];
  const opens = new Map<string, [number, number]>();
  const closes = new Map<string, Array<[number, number]>>();
  const order: string[] = [];
  const markers: Array<[number, number]> = [];
  const re = /<!--(\/?)c:([a-z0-9]{5,8})-->/g;
  let mm: RegExpExecArray | null;
  while ((mm = re.exec(text))) {
    if (inside(live, mm.index)) continue;
    markers.push([mm.index, mm.index + mm[0].length]);
    const id = mm[2];
    if (!order.includes(id)) order.push(id);
    if (mm[1]) {
      if (!closes.has(id)) closes.set(id, []);
      closes.get(id)!.push([mm.index, mm.index + mm[0].length]);
    } else if (!opens.has(id)) {
      opens.set(id, [mm.index, mm.index + mm[0].length]);
    }
  }
  const anchors: Anchor[] = [];
  for (const id of order) {
    const o = opens.get(id);
    const c = o && (closes.get(id) ?? []).find(([s]) => s >= o[1]);
    if (o && c) anchors.push({ id, openFrom: o[0], openTo: o[1], closeFrom: c[0], closeTo: c[1] });
  }
  // Anchors with no thread are listed too; the caller tells them apart by the blocks.
  return { anchors, blocks, ignored, markers };
}

const hide = Decoration.replace({});
const hideBlock = Decoration.replace({ block: true });

// The decorations for a state: markers and blocks hidden, open anchors marked.
export function commentDecorations(state: EditorState): DecorationSet {
  const text = state.doc.toString();
  const scan = scanComments(text);
  const ranges = [];
  for (const [a, b] of scan.markers) ranges.push(hide.range(a, b));
  for (const b of scan.blocks) {
    let end = b.to;
    if (end > b.from && text[end - 1] === "\n") end--;
    if (end > b.from && text[end - 1] === "\r") end--;
    ranges.push(hideBlock.range(b.from, end));
  }
  const open = new Set(scan.blocks.filter((b) => b.status === "open").map((b) => b.id));
  for (const a of scan.anchors) {
    if (!open.has(a.id) || a.closeFrom <= a.openTo) continue;
    ranges.push(
      Decoration.mark({ class: "cm-comment-anchor pc-anchor pc-open", tagName: "mark", attributes: { "data-c": a.id } }).range(
        a.openTo,
        a.closeFrom,
      ),
    );
  }
  return Decoration.set(ranges, true);
}

function hiddenRanges(state: EditorState): RangeSet<Decoration> {
  const text = state.doc.toString();
  const scan = scanComments(text);
  const ranges = [];
  for (const [a, b] of scan.markers) ranges.push(hide.range(a, b));
  for (const b of scan.blocks) ranges.push(hide.range(b.from, b.to));
  return Decoration.set(ranges, true);
}

const decorations = StateField.define<{ deco: DecorationSet; atomic: RangeSet<Decoration> }>({
  create: (state) => ({ deco: commentDecorations(state), atomic: hiddenRanges(state) }),
  update: (value, tr) => (tr.docChanged ? { deco: commentDecorations(tr.state), atomic: hiddenRanges(tr.state) } : value),
  provide: (f) => [
    EditorView.decorations.from(f, (v) => v.deco),
    EditorView.atomicRanges.of((view) => view.state.field(f).atomic),
  ],
});

// Anchors survive editing: a deletion that removes one marker of a pair
// while anchored text remains puts that marker back at the deletion's edge;
// a change that leaves nothing between a pair removes both.
export const keepAnchors = EditorState.transactionFilter.of((tr: Transaction) => {
  if (!tr.docChanged || tr.isUserEvent("input.comment") || !tr.annotation(Transaction.userEvent)) return tr;
  const before = scanComments(tr.startState.doc.toString());
  if (!before.anchors.length) return tr;
  const after = tr.newDoc.toString();
  const now = scanComments(after);
  const fixes: Array<{ from: number; to?: number; insert?: string }> = [];
  for (const a of before.anchors) {
    const n = now.anchors.find((x) => x.id === a.id);
    const openLeft = now.markers.some(([s, e]) => after.slice(s, e) === `<!--c:${a.id}-->`);
    const closeLeft = now.markers.some(([s, e]) => after.slice(s, e) === `<!--/c:${a.id}-->`);
    if (n) {
      if (n.closeFrom === n.openTo) {
        fixes.push({ from: n.openFrom, to: n.openTo }, { from: n.closeFrom, to: n.closeTo });
      }
      continue;
    }
    if (openLeft === closeLeft) continue; // both gone (or neither): nothing to keep
    if (!openLeft) {
      const at = tr.changes.mapPos(a.openFrom, 1);
      const close = after.indexOf(`<!--/c:${a.id}-->`);
      if (close > at) fixes.push({ from: at, insert: `<!--c:${a.id}-->` });
      else if (close >= 0) fixes.push({ from: close, to: close + `<!--/c:${a.id}-->`.length });
    } else {
      const at = tr.changes.mapPos(a.closeTo, -1);
      const open = after.indexOf(`<!--c:${a.id}-->`);
      const openEnd = open + `<!--c:${a.id}-->`.length;
      if (open >= 0 && at > openEnd) fixes.push({ from: at, insert: `<!--/c:${a.id}-->` });
      else if (open >= 0) fixes.push({ from: open, to: openEnd });
    }
  }
  if (!fixes.length) return tr;
  fixes.sort((x, y) => x.from - y.from);
  const spec: TransactionSpec = { changes: fixes, sequential: true };
  return [tr, spec];
});

// The draft's range (the person chose Comment): drawn in the active
// highlight while the draft card is open. Mapped through edits.
export const setDraft = StateEffect.define<{ from: number; to: number } | null>();

const draftMark = Decoration.mark({ class: "pc-draft", tagName: "mark" });

export const draftField = StateField.define<{ from: number; to: number } | null>({
  create: () => null,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setDraft)) return e.value;
    if (value && tr.docChanged) return { from: tr.changes.mapPos(value.from, 1), to: tr.changes.mapPos(value.to, -1) };
    return value;
  },
  provide: (f) =>
    EditorView.decorations.from(f, (v) => (v && v.to > v.from ? Decoration.set([draftMark.range(v.from, v.to)]) : Decoration.none)),
});

// Thread blocks are the comments' own: a person's edit never removes or
// changes part of one (comment actions, "input.comment", may), and never
// leaves `<!--co:` after text on its line. The person's input is never
// dropped: a deletion skips the blocks inside it, text typed inside a block
// lands after it, and a line break is put before a block that would follow
// text.
export const protectBlocks = EditorState.transactionFilter.of((tr: Transaction) => {
  if (!tr.docChanged || tr.isUserEvent("input.comment") || !tr.annotation(Transaction.userEvent)) return tr;
  const start = tr.startState;
  const text = start.doc.toString();
  const blocks = scanComments(text).blocks;
  if (!blocks.length) return tr;
  const specs: Array<{ from: number; to: number; insert: string }> = [];
  // Where each change's text goes (start-doc position) and whether it has text,
  // so the cursor can be put after the person's text in the rebuilt change.
  const landings: Array<{ fromA: number; at: number; length: number }> = [];
  let changed = false;
  tr.changes.iterChanges((fromA, toA, _fb, _tb, inserted) => {
    const ins = inserted.sliceString(0, inserted.length, start.lineBreak);
    let at = fromA;
    const inside = blocks.find((b) => b.from < fromA && fromA < b.to);
    if (inside) { at = inside.to; changed = true; }
    // The deletion, less every block it touches.
    const pieces: Array<[number, number]> = [];
    let cur = at;
    const end = Math.max(toA, at);
    for (const b of blocks) {
      if (b.to <= cur || b.from >= end) continue;
      changed = true;
      if (b.from > cur) pieces.push([cur, b.from]);
      cur = Math.max(cur, b.to);
    }
    if (end > cur) pieces.push([cur, end]);
    if (!pieces.length) pieces.push([at, at]);
    landings.push({ fromA, at: pieces[0][0], length: inserted.length });
    pieces.forEach(([f, t], i) => specs.push({ from: f, to: t, insert: i === 0 ? ins : "" }));
  });
  let first = changed ? ChangeSet.of(specs, text.length, start.lineBreak) : tr.changes;
  // Every block still starts a line: a line break goes before one that would
  // follow text, in the same change (after any text typed at the same place).
  const after = first.apply(start.doc).toString();
  const fixes: Array<{ from: number; to: number; insert: string }> = [];
  for (const b of blocks) {
    const at = first.mapPos(b.from, 1);
    if (at > 0 && after.startsWith("<!--co:", at) && after[at - 1] !== "\n") fixes.push({ from: b.from, to: b.from, insert: start.lineBreak });
  }
  if (!changed && !fixes.length) return tr;
  if (fixes.length) {
    // `specs` already holds every change (rebuilt or as typed).
    changed = true;
    first = ChangeSet.of([...specs, ...fixes], text.length, start.lineBreak);
  }
  const userEvent = tr.annotation(Transaction.userEvent);
  // The cursor goes after the text the person typed (or where the deletion
  // was), in the rebuilt change: never the old selection mapped, which would
  // leave the typed text selected for the next keystroke to replace.
  let selection = tr.selection;
  if (changed) {
    const main = start.selection.main;
    const land = landings.find((l) => l.fromA === main.from) ?? landings[landings.length - 1];
    if (land) {
      const head = first.mapPos(land.at, -1) + land.length;
      selection = EditorSelection.cursor(head);
    }
  }
  const out: TransactionSpec[] = [
    { changes: first, selection, userEvent, scrollIntoView: tr.scrollIntoView },
  ];
  return out;
});

// Hidden markup the cursor steps over: markers and thread blocks.
function hiddenAt(text: string) {
  const scan = scanComments(text);
  return {
    blocks: scan.blocks,
    ranges: [...scan.markers.map(([from, to]) => ({ from, to, block: false })), ...scan.blocks.map((b) => ({ from: b.from, to: b.to, block: true }))],
  };
}

function charBefore(text: string, p: number): number {
  return p >= 2 && /[\uDC00-\uDFFF]/.test(text[p - 1]) && /[\uD800-\uDBFF]/.test(text[p - 2]) ? 2 : 1;
}

// Backspace right after hidden markup deletes the visible character before
// it: after a thread block, the character before the block (not the line
// break, which would put `<!--co:` on a text line); after an anchor marker,
// the character before the marker.
export function deleteBackwardSkippingComments(view: EditorView): boolean {
  const sel = view.state.selection.main;
  if (!sel.empty) return false;
  const text = view.state.doc.toString();
  const { ranges } = hiddenAt(text);
  let p = sel.head;
  for (;;) {
    const r = ranges.find((x) => x.to === p && x.from < p);
    if (!r) break;
    p = r.from;
    if (r.block && p > 0 && text[p - 1] === "\n") p -= 1;
  }
  if (p === sel.head) return false;
  if (p <= 0) return true;
  const from = p - charBefore(text, p);
  view.dispatch({ changes: { from, to: p }, selection: { anchor: from }, userEvent: "delete.backward", scrollIntoView: true });
  return true;
}

// Delete at the end of a line followed by a thread block deletes the first
// visible character after the block; before an anchor marker, after it.
export function deleteForwardSkippingComments(view: EditorView): boolean {
  const sel = view.state.selection.main;
  if (!sel.empty) return false;
  const text = view.state.doc.toString();
  const { ranges, blocks } = hiddenAt(text);
  let p = sel.head;
  for (;;) {
    const r = ranges.find((x) => x.from === p && x.to > p);
    if (r) { p = r.to; continue; }
    const b = text[p] === "\n" ? blocks.find((x) => x.from === p + 1) : undefined;
    if (b) { p = b.to; continue; }
    break;
  }
  if (p === sel.head) return false;
  if (p >= text.length) return true;
  const len = /[\uD800-\uDBFF]/.test(text[p]) && p + 1 < text.length ? 2 : 1;
  view.dispatch({ changes: { from: p, to: p + len }, userEvent: "delete.forward", scrollIntoView: true });
  return true;
}

const commentKeys = Prec.high(
  keymap.of([
    { key: "Backspace", run: deleteBackwardSkippingComments },
    { key: "Delete", run: deleteForwardSkippingComments },
  ]),
);

export function commentsExtension(): Extension {
  return [decorations, keepAnchors, protectBlocks, draftField, commentKeys];
}

// A table cell's source drawn with its comments: markers hidden, text anchored
// by an open thread in a highlight (the table widget, when the cursor is
// outside the table).
export function cellWithComments(doc: Document, source: string, open: Set<string>): DocumentFragment {
  const frag = doc.createDocumentFragment();
  const stack: Node[] = [frag];
  const re = /<!--(\/?)c:([a-z0-9]{5,8})-->/g;
  let last = 0;
  let m: RegExpExecArray | null;
  const top = () => stack[stack.length - 1];
  const textOf = (s: string) => s.replace(/\\\|/g, "|");
  while ((m = re.exec(source))) {
    if (m.index > last) top().appendChild(doc.createTextNode(textOf(source.slice(last, m.index))));
    if (!m[1]) {
      const mark = doc.createElement("mark");
      mark.className = "pc-anchor cm-comment-anchor" + (open.has(m[2]) ? " pc-open" : "");
      mark.setAttribute("data-c", m[2]);
      top().appendChild(mark);
      stack.push(mark);
    } else if (stack.length > 1 && (top() as Element).getAttribute?.("data-c") === m[2]) {
      stack.pop();
    }
    last = m.index + m[0].length;
  }
  if (last < source.length) top().appendChild(doc.createTextNode(textOf(source.slice(last))));
  return frag;
}

// A line that starts with an anchor marker is text, not an HTML block
// (comment format v1 writes anchors at a line's start when the selection
// starts there); the rest of the line is parsed as Markdown.
const ANCHOR_AT = /^<!--\/?c:[a-z0-9]{5,8}-->/;
export function anchorLines(): MarkdownConfig {
  const base: any = markdownLanguage.parser;
  const html = base.blockParsers[base.blockNames.indexOf("HTMLBlock")];
  return {
    parseBlock: [
      {
        name: "HTMLBlock",
        parse(cx, line) {
          if (ANCHOR_AT.test(line.text.slice(line.pos))) return false;
          return html ? html(cx, line) : false;
        },
      },
    ],
  };
}

export function anchorAwareMarkdown(codeLanguages?: (info: string) => Language | null) {
  return markdown({ base: markdownLanguage, codeLanguages: codeLanguages ?? undefined, extensions: [anchorLines()] });
}

// Why a selection can't be anchored: "ignored" (code, a table, front
// matter), "crosses" (more than one paragraph or list item), or null.
export function selectionRefusal(state: EditorState, from: number, to: number): "ignored" | "crosses" | "cell" | null {
  if (to <= from) return "crosses";
  const text = state.doc.toString();
  const scan = scanComments(text);
  if (scan.ignored.some(([a, b]) => from < b && to > a)) return "ignored";
  if (scan.blocks.some((b) => from < b.to && to > b.from)) return "crosses";
  const tree = syntaxTree(state);
  const ancestors = (pos: number, side: -1 | 1) => {
    const names: Array<{ name: string; from: number }> = [];
    for (let n: any = tree.resolveInner(pos, side); n; n = n.parent) names.push({ name: n.name, from: n.from });
    return names;
  };
  const a = ancestors(from, 1);
  const b = ancestors(to, -1);
  const code = /^(FencedCode|CodeBlock|InlineCode|Frontmatter|FrontMatter)$/;
  if (a.some((n) => code.test(n.name)) || b.some((n) => code.test(n.name))) return "ignored";
  // A table: only within one cell (spec §13); an escaped pipe is text in its cell.
  const inTable = (list: typeof a) => list.some((n) => n.name === "Table");
  if (inTable(a) || inTable(b)) {
    const ca = a.find((n) => n.name === "TableCell");
    const cb = b.find((n) => n.name === "TableCell");
    if (!ca || !cb || ca.from !== cb.from) return "cell";
    return null;
  }
  const holder = (list: typeof a) => list.find((n) => n.name === "Paragraph" || n.name === "ListItem");
  const ha = holder(a);
  const hb = holder(b);
  if (!ha || !hb || ha.from !== hb.from || ha.name !== hb.name) return "crosses";
  if (/\n[ \t>]*\r?\n/.test(text.slice(from, to))) return "crosses";
  return null;
}
