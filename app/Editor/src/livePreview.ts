// Portico's live preview for Markdown (v0.20 §2.3): the source stays exactly
// as it is; decorations draw it as the page and hide the marks on lines the
// cursor is not on. Nothing here ever dispatches a change except a click on a
// checkbox, which flips the one character between its brackets.

import { EditorState, Range, StateField, type Extension, type TransactionSpec } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, WidgetType } from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";
import type { SyntaxNodeRef } from "@lezer/common";

// The lines that show their marks: every line a selection range touches.
export function activeLines(state: EditorState): Set<number> {
  const lines = new Set<number>();
  for (const range of state.selection.ranges) {
    const first = state.doc.lineAt(range.from).number;
    const last = state.doc.lineAt(range.to).number;
    for (let n = first; n <= last; n++) lines.add(n);
  }
  return lines;
}

const hide = Decoration.replace({});

function lineClass(cls: string) {
  return Decoration.line({ class: cls });
}

class CheckboxWidget extends WidgetType {
  readonly checked: boolean;
  constructor(checked: boolean) {
    super();
    this.checked = checked;
  }
  eq(other: CheckboxWidget) {
    return other.checked === this.checked;
  }
  toDOM() {
    const box = document.createElement("input");
    box.type = "checkbox";
    box.checked = this.checked;
    box.className = "cm-md-checkbox";
    box.setAttribute("aria-label", this.checked ? "Done" : "Not done");
    return box;
  }
  ignoreEvent() {
    return false;
  }
}

class BulletWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const dot = document.createElement("span");
    dot.className = "cm-md-bullet";
    dot.textContent = "•";
    return dot;
  }
}

class RuleWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const rule = document.createElement("span");
    rule.className = "cm-md-rule";
    return rule;
  }
}

class ImageWidget extends WidgetType {
  readonly src: string;
  readonly alt: string;
  constructor(src: string, alt: string) {
    super();
    this.src = src;
    this.alt = alt;
  }
  eq(other: ImageWidget) {
    return other.src === this.src && other.alt === this.alt;
  }
  toDOM() {
    const wrap = document.createElement("div");
    wrap.className = "cm-md-image";
    const img = document.createElement("img");
    img.src = this.src;
    img.alt = this.alt;
    wrap.appendChild(img);
    return wrap;
  }
  ignoreEvent() {
    return true;
  }
}

class TableWidget extends WidgetType {
  readonly rows: string[][];
  readonly source: string;
  constructor(rows: string[][], source: string) {
    super();
    this.rows = rows;
    this.source = source;
  }
  eq(other: TableWidget) {
    return other.source === this.source;
  }
  toDOM() {
    const wrap = document.createElement("div");
    wrap.className = "cm-md-table";
    const table = document.createElement("table");
    this.rows.forEach((cells, index) => {
      const tr = document.createElement("tr");
      for (const cell of cells) {
        const td = document.createElement(index === 0 ? "th" : "td");
        td.textContent = cell;
        tr.appendChild(td);
      }
      (index === 0 ? table.createTHead() : table.tBodies[0] ?? table.createTBody()).appendChild(tr);
    });
    wrap.appendChild(table);
    return wrap;
  }
  // A click goes to the editor, which puts the cursor in the table and so
  // shows its source.
  ignoreEvent() {
    return false;
  }
}

// The cells of a GFM table, by row, the delimiter row left out.
export function tableRows(state: EditorState, node: SyntaxNodeRef): string[][] {
  const rows: string[][] = [];
  const table = node.node;
  for (let row = table.firstChild; row; row = row.nextSibling) {
    if (row.name !== "TableHeader" && row.name !== "TableRow") continue;
    const cells: string[] = [];
    for (let cell = row.firstChild; cell; cell = cell.nextSibling) {
      if (cell.name === "TableCell") cells.push(state.sliceDoc(cell.from, cell.to).trim());
    }
    rows.push(cells);
  }
  return rows;
}

function selectionTouches(state: EditorState, from: number, to: number): boolean {
  return state.selection.ranges.some((r) => r.to >= from && r.from <= to);
}

// Every decoration for the document, given where the cursor is. Pure: reads
// the state, changes nothing.
export function buildDecorations(state: EditorState): DecorationSet {
  const active = activeLines(state);
  const isActive = (pos: number) => active.has(state.doc.lineAt(pos).number);
  const out: Range<Decoration>[] = [];
  const lineClasses = (from: number, to: number, cls: string) => {
    const first = state.doc.lineAt(from).number;
    const last = state.doc.lineAt(Math.max(from, to)).number;
    for (let n = first; n <= last; n++) out.push(lineClass(cls).range(state.doc.line(n).from));
  };
  // Marks hidden on a line without the cursor; a mark followed by a space
  // (a heading's `#`, a quote's `>`) takes the space with it.
  const hideMark = (from: number, to: number, withSpace = false) => {
    if (isActive(from)) return;
    let end = to;
    if (withSpace && state.sliceDoc(end, end + 1) === " ") end++;
    if (end > from) out.push(hide.range(from, end));
  };

  syntaxTree(state).iterate({
    enter(node) {
      const name = node.name;
      if (name === "Frontmatter") {
        lineClasses(node.from, Math.max(node.from, node.to - 1), "cm-md-frontmatter");
        return false;
      }
      const heading = /^(ATX|Setext)Heading(\d)$/.exec(name);
      if (heading) {
        lineClasses(node.from, node.to, `cm-md-h cm-md-h${heading[2]}`);
        return;
      }
      switch (name) {
        case "HeaderMark": {
          const parent = node.node.parent?.name ?? "";
          if (parent.startsWith("ATX")) hideMark(node.from, node.to, true);
          else if (!isActive(node.from)) out.push(lineClass("cm-md-setext-mark").range(state.doc.lineAt(node.from).from));
          return;
        }
        case "Emphasis":
          out.push(Decoration.mark({ class: "cm-md-em" }).range(node.from, node.to));
          return;
        case "StrongEmphasis":
          out.push(Decoration.mark({ class: "cm-md-strong" }).range(node.from, node.to));
          return;
        case "Strikethrough":
          out.push(Decoration.mark({ class: "cm-md-strike" }).range(node.from, node.to));
          return;
        case "EmphasisMark":
        case "StrikethroughMark":
          hideMark(node.from, node.to);
          return;
        case "InlineCode":
          out.push(Decoration.mark({ class: "cm-md-code" }).range(node.from, node.to));
          return;
        case "CodeMark": {
          if (node.node.parent?.name === "InlineCode") hideMark(node.from, node.to);
          return;
        }
        case "FencedCode":
        case "CodeBlock": {
          lineClasses(node.from, node.to, "cm-md-codeblock");
          if (name === "FencedCode" && !selectionTouches(state, node.from, node.to)) {
            const first = state.doc.lineAt(node.from);
            const last = state.doc.lineAt(node.to);
            out.push(lineClass("cm-md-fence").range(first.from));
            if (last.number !== first.number && /^\s*(`{3,}|~{3,})\s*$/.test(last.text)) {
              out.push(lineClass("cm-md-fence").range(last.from));
            }
          }
          return;
        }
        case "Blockquote":
          lineClasses(node.from, node.to, "cm-md-quote");
          return;
        case "QuoteMark":
          hideMark(node.from, node.to, true);
          return;
        case "HorizontalRule":
          if (!isActive(node.from)) {
            out.push(lineClass("cm-md-hr").range(state.doc.lineAt(node.from).from));
            out.push(Decoration.replace({ widget: new RuleWidget() }).range(node.from, node.to));
          }
          return;
        case "ListMark": {
          if (isActive(node.from)) {
            out.push(Decoration.mark({ class: "cm-md-listmark" }).range(node.from, node.to));
            return;
          }
          const mark = state.sliceDoc(node.from, node.to);
          const item = node.node.parent;
          const isTask = item?.getChild("Task") != null;
          if (isTask) {
            // The checkbox stands for the item; the bullet and its space go.
            const end = state.sliceDoc(node.to, node.to + 1) === " " ? node.to + 1 : node.to;
            out.push(hide.range(node.from, end));
          } else if (/^[-*+]$/.test(mark)) {
            out.push(Decoration.replace({ widget: new BulletWidget() }).range(node.from, node.to));
          } else {
            out.push(Decoration.mark({ class: "cm-md-listmark" }).range(node.from, node.to));
          }
          return;
        }
        case "TaskMarker": {
          const text = state.sliceDoc(node.from, node.to);
          const checked = /^\[[xX]\]$/.test(text);
          if (checked) {
            const task = node.node.parent;
            if (task) out.push(Decoration.mark({ class: "cm-md-done" }).range(node.to, task.to));
          }
          if (!isActive(node.from)) {
            out.push(Decoration.replace({ widget: new CheckboxWidget(checked) }).range(node.from, node.to));
          }
          return;
        }
        case "Link":
        case "Image": {
          const marks = node.node.getChildren("LinkMark");
          const url = node.node.getChild("URL");
          const href = url ? state.sliceDoc(url.from, url.to) : "";
          if (name === "Image") {
            if (href) {
              const open = marks[0];
              const close = marks[1];
              const alt = open && close ? state.sliceDoc(open.to, close.from) : "";
              const line = state.doc.lineAt(node.to);
              out.push(Decoration.widget({ widget: new ImageWidget(href, alt), block: true, side: 1 }).range(line.to));
            }
            return false;
          }
          // [text](url "title"): the text drawn as a link; the rest hidden.
          if (marks.length >= 2) {
            const textFrom = marks[0].to;
            const textTo = marks[1].from;
            if (textTo > textFrom) {
              out.push(
                Decoration.mark({ class: "cm-md-link", attributes: { "data-href": href } }).range(textFrom, textTo),
              );
            }
            if (!isActive(node.from)) {
              out.push(hide.range(node.from, marks[0].to));
              out.push(hide.range(marks[1].from, node.to));
            }
          }
          return false;
        }
        case "Autolink":
        case "URL": {
          // A URL reached here is a bare one (GFM autolink); a link's or an
          // image's own URL is never visited (those cases return false).
          const urlNode = name === "Autolink" ? node.node.getChild("URL") : node.node;
          if (!urlNode) return;
          const href = state.sliceDoc(urlNode.from, urlNode.to);
          out.push(Decoration.mark({ class: "cm-md-link", attributes: { "data-href": href } }).range(urlNode.from, urlNode.to));
          if (name === "Autolink" && !isActive(node.from)) {
            out.push(hide.range(node.from, urlNode.from));
            out.push(hide.range(urlNode.to, node.to));
          }
          return false;
        }
        case "Table": {
          // Source while the cursor is in it; the table elsewhere.
          const first = state.doc.lineAt(node.from);
          const last = state.doc.lineAt(node.to);
          if (selectionTouches(state, first.from, last.to)) {
            lineClasses(first.from, last.to, "cm-md-tablesource");
          } else {
            const source = state.sliceDoc(first.from, last.to);
            out.push(
              Decoration.replace({ widget: new TableWidget(tableRows(state, node), source), block: true }).range(
                first.from,
                last.to,
              ),
            );
          }
          return false;
        }
      }
    },
  });
  return Decoration.set(out, true);
}

// The one change live preview makes, and only for a click: the character
// between a task's brackets, ` ` to `x` or back. Null when `pos` is not the
// start of a task marker.
export function toggleCheckboxAt(state: EditorState, pos: number): TransactionSpec | null {
  const text = state.sliceDoc(pos, pos + 3);
  if (!/^\[[ xX]\]$/.test(text)) return null;
  const insert = text[1] === " " ? "x" : " ";
  return { changes: { from: pos + 1, to: pos + 2, insert }, userEvent: "input.toggle" };
}

const previewField = StateField.define<DecorationSet>({
  create: (state) => buildDecorations(state),
  update(decorations, tr) {
    const treeGrew = syntaxTree(tr.state) !== syntaxTree(tr.startState);
    if (tr.docChanged || treeGrew) return buildDecorations(tr.state);
    if (tr.selection) {
      const before = activeLines(tr.startState);
      const after = activeLines(tr.state);
      const same = before.size === after.size && [...before].every((n) => after.has(n));
      // Tables and fences depend on the exact selection, not just its lines.
      return same && !touchesBlock(tr.startState) && !touchesBlock(tr.state) ? decorations : buildDecorations(tr.state);
    }
    return decorations;
  },
  provide: (field) => EditorView.decorations.from(field),
});

function touchesBlock(state: EditorState): boolean {
  let hit = false;
  const tree = syntaxTree(state);
  for (const range of state.selection.ranges) {
    tree.iterate({
      from: range.from,
      to: range.to,
      enter(node) {
        if (node.name === "Table" || node.name === "FencedCode") hit = true;
        return !hit;
      },
    });
  }
  return hit;
}

// Opening a link is the host's business; by default a new window, which the
// web view's UI delegate receives.
export type LinkOpener = (href: string) => void;

export function livePreview(openLink: LinkOpener = (href) => window.open(href, "_blank")): Extension {
  return [
    previewField,
    EditorView.domEventHandlers({
      mousedown(event, view) {
        const target = event.target as HTMLElement | null;
        if (!target) return false;
        if (target instanceof HTMLInputElement && target.classList.contains("cm-md-checkbox")) {
          event.preventDefault();
          if (view.state.readOnly || !view.state.facet(EditorView.editable)) return true;
          const spec = toggleCheckboxAt(view.state, view.posAtDOM(target));
          if (spec) view.dispatch(spec);
          return true;
        }
        if (event.metaKey) {
          const link = target.closest?.(".cm-md-link") as HTMLElement | null;
          const href = link?.getAttribute("data-href");
          if (href) {
            event.preventDefault();
            openLink(href);
            return true;
          }
        }
        return false;
      },
    }),
    EditorView.contentAttributes.of({ class: "cm-md-page" }),
  ];
}
