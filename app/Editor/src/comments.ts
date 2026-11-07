// Comments in Edit mode (v0.23): comment format v1 (protocol/COMMENTS.md)
// markup hidden the way the read view hides it. Anchors <!--c:ID--> and
// <!--/c:ID--> are replaced with nothing, thread blocks <!--co:ID ...-->
// are hidden whole lines, and text anchored by an open thread is
// highlighted. The markup is atomic, so the cursor never lands inside it;
// editing inside an anchored span keeps the anchors, and deleting all of the
// anchored text removes them (the thread becomes an orphan).
//
// Offsets are JavaScript string offsets: UTF-16, as Swift's.

import { EditorState, type Extension, RangeSet, StateEffect, StateField, Transaction, type TransactionSpec } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView } from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";

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
    const m = /^[ \t]*<!--co:([a-z0-9]{5,8})(?=\s|-->)/.exec(text.slice(l.start, l.end));
    if (!m || inside(coarse, l.start)) continue;
    const close = text.indexOf("-->", l.start + m[0].length);
    if (close < 0) continue;
    let j = k;
    while (ls[j].full <= close) j++;
    const header = text.slice(l.start, Math.min(close, l.end));
    const status = /(?:^|\s)status:(\S+)/.exec(header);
    blocks.push({ id: m[1], from: l.start, to: ls[j].full, status: status && status[1] === "resolved" ? "resolved" : "open" });
    k = j;
  }
  const walls = [...coarse, ...blocks.map((b) => [b.from, b.to] as [number, number])].sort((x, y) => x[0] - y[0]);
  const segments: Array<[number, number]> = [];
  let pos = 0;
  for (const [a, b] of walls) {
    if (a > pos) segments.push([pos, a]);
    pos = Math.max(pos, b);
  }
  if (pos < text.length) segments.push([pos, text.length]);
  const ignored = [...coarse, ...codeSpans(text, segments)].sort((x, y) => x[0] - y[0]);
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

export function commentsExtension(): Extension {
  return [decorations, keepAnchors, draftField];
}

// Why a selection can't be anchored: "ignored" (code, a table, front
// matter), "crosses" (more than one paragraph or list item), or null.
export function selectionRefusal(state: EditorState, from: number, to: number): "ignored" | "crosses" | null {
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
  const code = /^(FencedCode|CodeBlock|InlineCode|Table|TableRow|TableCell|Frontmatter|FrontMatter)$/;
  if (a.some((n) => code.test(n.name)) || b.some((n) => code.test(n.name))) return "ignored";
  const holder = (list: typeof a) => list.find((n) => n.name === "Paragraph" || n.name === "ListItem");
  const ha = holder(a);
  const hb = holder(b);
  if (!ha || !hb || ha.from !== hb.from || ha.name !== hb.name) return "crosses";
  if (/\n[ \t>]*\r?\n/.test(text.slice(from, to))) return "crosses";
  return null;
}
