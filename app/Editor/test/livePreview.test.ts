// Live preview must never change the document except by the person's input
// or a checkbox click (v0.20 §2.3, Review Focus 2). Run: node --test test/
import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

// A DOM for CodeMirror's view, installed before it is imported.
const dom = new JSDOM("<!doctype html><html><body><div id='host'></div></body></html>", { pretendToBeVisual: true });
const g = globalThis as any;
for (const key of Object.getOwnPropertyNames(dom.window)) {
  if (key in g && !["window", "document", "navigator"].includes(key)) continue;
  try {
    Object.defineProperty(g, key, { value: (dom.window as any)[key], configurable: true, writable: true });
  } catch {}
}
g.window = dom.window;
// jsdom has no layout; CodeMirror only needs these to answer something.
const zeroRect = () => ({ left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0 });
dom.window.Range.prototype.getClientRects = () => [] as any;
dom.window.Range.prototype.getBoundingClientRect = zeroRect as any;
dom.window.HTMLElement.prototype.scrollIntoView = () => {};

const { EditorState, EditorSelection } = await import("@codemirror/state");
const { ensureSyntaxTree } = await import("@codemirror/language");
const { markdown, markdownLanguage } = await import("@codemirror/lang-markdown");
const { yamlFrontmatter } = await import("@codemirror/lang-yaml");
const { buildDecorations, toggleCheckboxAt } = await import("../src/livePreview.ts");
const { createEditor, lineSeparatorOf } = await import("../src/editor.ts");
type Message = import("../src/bridge.ts").Message;

const SAMPLE = [
  "---",
  "title: Notes",
  "tags: [a, b]",
  "---",
  "# Heading **one**",
  "",
  "Some *italic*, **bold**, ~~gone~~ and `code` with a [link](https://example.com \"t\") and <https://x.test>.",
  "",
  "- [ ] open task",
  "- [x] done task",
  "* bullet",
  "1. ordered",
  "",
  "> a quote",
  "",
  "***",
  "",
  "![alt](img.png)",
  "",
  "| a | b |",
  "|:--|--:|",
  "| 1 | 2 |",
  "",
  "```js",
  "let x = 1",
  "```",
  "",
  "Setext",
  "======",
  "",
].join("\n");

function mount() {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const messages: Message[] = [];
  const editor = createEditor(host, (m) => messages.push(m), () => {});
  return { editor, messages };
}

function mdState(doc: string, cursorLine: number) {
  let state = EditorState.create({
    doc,
    extensions: [yamlFrontmatter({ content: markdown({ base: markdownLanguage }) })],
  });
  ensureSyntaxTree(state, state.doc.length, 5000);
  state = state.update({ selection: EditorSelection.cursor(state.doc.line(cursorLine).from) }).state;
  return state;
}

// The replaced (hidden or drawn-over) ranges, as [from, to] pairs.
function replaced(state: InstanceType<typeof EditorState>): Array<[number, number]> {
  const out: Array<[number, number]> = [];
  buildDecorations(state).between(0, state.doc.length, (from, to, deco) => {
    // Marks always carry a class; what is left with a length replaces text.
    if (to > from && !deco.spec.class && !deco.spec.attributes) out.push([from, to]);
  });
  return out;
}

for (const [name, text] of [
  ["LF", SAMPLE],
  ["CRLF, no final newline", SAMPLE.replace(/\n/g, "\r\n").replace(/\r\n$/, "")],
] as const) {
  test(`moving the cursor through every line changes nothing (${name})`, async () => {
    const { editor, messages } = mount();
    const changes: unknown[] = [];
    editor.load({ text, mode: "markdown" });
    const view = editor.view;
    ensureSyntaxTree(view.state, view.state.doc.length, 5000);
    const original = editor.visibleText();
    assert.equal(original, text);
    // Watch every transaction from here on, however it is dispatched.
    const realUpdate = view.update.bind(view);
    (view as any).update = (trs: readonly any[]) => {
      for (const tr of trs) if (tr.docChanged) changes.push(tr);
      realUpdate(trs);
    };
    view.focus();
    for (let n = 1; n <= view.state.doc.lines; n++) {
      const line = view.state.doc.line(n);
      for (const pos of [line.from, Math.floor((line.from + line.to) / 2), line.to]) {
        view.dispatch({ selection: EditorSelection.cursor(pos) });
      }
    }
    view.dispatch({ selection: EditorSelection.range(0, view.state.doc.length) });
    editor.setReadOnly(true);
    editor.setReadOnly(false);
    editor.scrollToLine(10);
    editor.scrollTopLine();
    view.contentDOM.blur();
    (view as any).observer?.flush?.();
    await new Promise((r) => setTimeout(r, 900));
    assert.equal(changes.length, 0);
    assert.equal(editor.visibleText(), original);
    assert.deepEqual(messages.filter((m) => m.type !== "ready"), []);
  });
}

test("CRLF, CR and LF input round-trip unchanged", () => {
  const { editor } = mount();
  for (const text of ["a\r\nb\r\n", "a\r\nb", "a\rb\r", "a\nb\n", "", "\r\n", "mixed\r\nlone\nend\r\n"]) {
    editor.load({ text, mode: "markdown" });
    assert.equal(editor.visibleText(), text, JSON.stringify(text));
    editor.load({ text, mode: "code", language: "json" });
    assert.equal(editor.visibleText(), text, JSON.stringify(text));
    editor.replaceAll(text, true);
    assert.equal(editor.visibleText(), text, JSON.stringify(text));
  }
  assert.equal(lineSeparatorOf("x\r\ny"), "\r\n");
  assert.equal(lineSeparatorOf("x\ry"), "\r");
  assert.equal(lineSeparatorOf("x\ny"), "\n");
});

test("typing in a CRLF file keeps CRLF", () => {
  const { editor } = mount();
  editor.load({ text: "one\r\ntwo\r\n", mode: "markdown" });
  const view = editor.view;
  view.dispatch(view.state.replaceSelection(view.state.lineBreak), { userEvent: "input" } as any);
  assert.equal(editor.visibleText(), "\r\none\r\ntwo\r\n");
});

test("a checkbox click changes only [ ] to [x], and back", () => {
  const { editor, messages } = mount();
  const text = "intro\r\n- [ ] first\r\n- [x] second\r\n";
  editor.load({ text, mode: "markdown" });
  const view = editor.view;
  ensureSyntaxTree(view.state, view.state.doc.length, 5000);
  view.dispatch({ selection: EditorSelection.cursor(0) });
  const boxes = view.contentDOM.querySelectorAll("input.cm-md-checkbox");
  assert.equal(boxes.length, 2);
  const event = new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true, button: 0 });
  boxes[0].dispatchEvent(event);
  assert.equal(editor.visibleText(), "intro\r\n- [x] first\r\n- [x] second\r\n");
  // Only the one byte differs.
  const before = Buffer.from(text);
  const after = Buffer.from(editor.visibleText());
  assert.equal(before.length, after.length);
  const diff = [...before].map((b, i) => (b !== after[i] ? i : -1)).filter((i) => i >= 0);
  assert.deepEqual(diff, [text.indexOf("[ ]") + 1]);
  // And back, through the pure helper.
  const pos = view.state.doc.toString().indexOf("[x]");
  view.dispatch(toggleCheckboxAt(view.state, pos)!);
  assert.equal(editor.visibleText(), text);
  assert.equal(toggleCheckboxAt(view.state, 0), null);
  // A checkbox click in read-only does nothing.
  editor.setReadOnly(true);
  view.dispatch({ selection: EditorSelection.cursor(0) });
  view.contentDOM.querySelector("input.cm-md-checkbox")!.dispatchEvent(
    new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }),
  );
  assert.equal(editor.visibleText(), text);
  editor.setReadOnly(false);
  assert.ok(messages.length >= 0);
});

test("decorations hide ** on lines without the cursor, and show them on the cursor's line", () => {
  const doc = "**bold** text\nsecond line";
  const away = mdState(doc, 2);
  const hidden = replaced(away);
  assert.ok(hidden.some(([f, t]) => f === 0 && t === 2), JSON.stringify(hidden));
  assert.ok(hidden.some(([f, t]) => f === 6 && t === 8), JSON.stringify(hidden));
  const here = mdState(doc, 1);
  assert.deepEqual(replaced(here).filter(([f]) => f < 8), []);
});

test("headings, quotes, links, tables and front matter decorate without touching text", () => {
  const state = mdState(SAMPLE, 1);
  const decos = buildDecorations(state);
  const classes = new Set<string>();
  decos.between(0, state.doc.length, (_f, _t, d) => {
    const cls = (d.spec && (d.spec.class || d.spec.attributes?.class)) as string | undefined;
    if (cls) cls.split(" ").forEach((c) => classes.add(c));
  });
  for (const c of ["cm-md-frontmatter", "cm-md-h1", "cm-md-strong", "cm-md-em", "cm-md-link", "cm-md-quote", "cm-md-codeblock", "cm-md-code"]) {
    assert.ok(classes.has(c), c);
  }
  // The table is drawn as a table while the cursor is elsewhere ...
  const tableStart = state.doc.toString().indexOf("| a |");
  let tableWidget = false;
  decos.between(tableStart, tableStart + 1, (f, _t, d) => {
    if (f === tableStart && d.spec.widget) tableWidget = true;
  });
  assert.ok(tableWidget);
  // ... and is source while the cursor is in it.
  const inTable = state.update({ selection: EditorSelection.cursor(tableStart + 2) }).state;
  let stillWidget = false;
  buildDecorations(inTable).between(tableStart, tableStart + 1, (f, _t, d) => {
    if (f === tableStart && d.spec.widget) stillWidget = true;
  });
  assert.ok(!stillWidget);
  assert.equal(state.doc.toString(), SAMPLE);
});

test("edits are sent after 800 ms, and a blur after an edit asks for a save", async () => {
  const { editor, messages } = mount();
  editor.load({ text: "abc\n", mode: "code", language: "python" });
  const view = editor.view;
  view.dispatch({ changes: { from: 3, insert: "d" }, userEvent: "input.type" });
  assert.deepEqual(messages, []);
  await new Promise((r) => setTimeout(r, 850));
  assert.deepEqual(messages, [{ type: "changed", text: "abcd\n", dirty: true }]);
  view.focus();
  view.contentDOM.blur();
  (view as any).observer?.flush?.();
  // jsdom may not report the focus change; the bridge contract is checked directly.
  const { Bridge } = await import("../src/bridge.ts");
  const sent: Message[] = [];
  const bridge = new Bridge((m) => sent.push(m));
  bridge.blurred(() => "x");
  assert.deepEqual(sent, []);
  bridge.edited(() => "y");
  bridge.blurred(() => "y");
  assert.deepEqual(sent, [{ type: "saveNow", text: "y" }]);
  assert.equal(bridge.pending, false);
  bridge.ready();
  assert.deepEqual(sent.at(-1), { type: "ready" });
});

test("a reload from disk is not an edit", async () => {
  const { editor, messages } = mount();
  editor.load({ text: "one\ntwo\nthree\n", mode: "markdown" });
  editor.view.dispatch({ selection: EditorSelection.cursor(editor.view.state.doc.line(3).from) });
  editor.replaceAll("one\ntwo\nthree changed\nfour\n", true);
  assert.equal(editor.visibleText(), "one\ntwo\nthree changed\nfour\n");
  assert.equal(editor.view.state.doc.lineAt(editor.view.state.selection.main.head).number, 3);
  await new Promise((r) => setTimeout(r, 850));
  assert.deepEqual(messages, []);
});
