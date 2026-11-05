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
    editor.replaceAll(text, { keepCursorLine: true });
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

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

test("the first edit pings dirty at once; the text follows 800 ms later", async () => {
  const { editor, messages } = mount();
  editor.load({ text: "abc\n", mode: "code", language: "python" });
  const view = editor.view;
  view.dispatch({ changes: { from: 3, insert: "d" }, userEvent: "input.type" });
  assert.deepEqual(messages, [{ type: "dirty" }]);
  view.dispatch({ changes: { from: 4, insert: "e" }, userEvent: "input.type" });
  assert.deepEqual(messages, [{ type: "dirty" }]);
  await wait(850);
  assert.deepEqual(messages, [{ type: "dirty" }, { type: "changed", text: "abcde\n", dirty: true }]);
  // Once sent, the next edit is a new round with a new ping.
  view.dispatch({ changes: { from: 0, insert: "z" }, userEvent: "input.type" });
  assert.deepEqual(messages.at(-1), { type: "dirty" });
  await wait(850);
  assert.deepEqual(messages.at(-1), { type: "changed", text: "zabcde\n", dirty: true });
});

test("blur asks for a save only for an edit not yet sent", async () => {
  const { Bridge } = await import("../src/bridge.ts");
  const sent: Message[] = [];
  const bridge = new Bridge((m) => sent.push(m));
  bridge.blurred(() => "x");
  assert.deepEqual(sent, []);
  bridge.edited(() => "y");
  bridge.blurred(() => "y");
  assert.deepEqual(sent, [{ type: "dirty" }, { type: "saveNow", text: "y" }]);
  assert.equal(bridge.pending, false);
  // Sent is saved: later blurs send nothing more.
  bridge.blurred(() => "y");
  bridge.blurred(() => "y");
  assert.equal(sent.length, 2);
  // Nor after the debounced send.
  bridge.edited(() => "w");
  await wait(850);
  bridge.blurred(() => "w");
  assert.deepEqual(sent.slice(2), [{ type: "dirty" }, { type: "changed", text: "w", dirty: true }]);
  bridge.ready();
  assert.deepEqual(sent.at(-1), { type: "ready" });
});

test("a reload from disk is not an edit", async () => {
  const { editor, messages } = mount();
  editor.load({ text: "one\ntwo\nthree\n", mode: "markdown" });
  editor.view.dispatch({ selection: EditorSelection.cursor(editor.view.state.doc.line(3).from) });
  assert.equal(editor.replaceAll("one\ntwo\nthree changed\nfour\n", { keepCursorLine: true }), true);
  assert.equal(editor.visibleText(), "one\ntwo\nthree changed\nfour\n");
  assert.equal(editor.view.state.doc.lineAt(editor.view.state.selection.main.head).number, 3);
  assert.equal(editor.replaceAll("x\n", { keepUndo: true }), true);
  assert.equal(editor.visibleText(), "x\n");
  await wait(850);
  assert.deepEqual(messages, []);
});

test("replaceAll refuses while an edit is unsent, unless forced", async () => {
  const { editor, messages } = mount();
  editor.load({ text: "mine\n", mode: "markdown" });
  editor.view.dispatch({ changes: { from: 4, insert: "!" }, userEvent: "input.type" });
  assert.equal(editor.replaceAll("theirs\n"), false);
  assert.equal(editor.replaceAll("theirs\n", { keepUndo: true }), false);
  assert.equal(editor.visibleText(), "mine!\n");
  assert.equal(editor.replaceAll("theirs\n", { force: true }), true);
  assert.equal(editor.visibleText(), "theirs\n");
  await wait(850);
  // The forced replace dropped the pending send.
  assert.deepEqual(messages, [{ type: "dirty" }]);
  // Once sent, replacing is allowed again.
  editor.view.dispatch({ changes: { from: 0, insert: "a" }, userEvent: "input.type" });
  await wait(850);
  assert.equal(editor.replaceAll("b\n"), true);
});

test("replaceAll with keepUndo: the person's text comes back with undo", async () => {
  const { undo } = await import("@codemirror/commands");
  const { editor, messages } = mount();
  editor.load({ text: "base\r\nline\r\n", mode: "markdown" });
  const view = editor.view;
  view.dispatch({ changes: { from: 4, insert: " mine" }, userEvent: "input.type" });
  await wait(850);
  const sentCount = messages.length;
  assert.equal(editor.replaceAll("theirs\r\nline\r\nmore\r\n", { keepUndo: true }), true);
  assert.equal(editor.visibleText(), "theirs\r\nline\r\nmore\r\n");
  assert.equal(messages.length, sentCount);
  await wait(850);
  assert.equal(messages.length, sentCount, "the replace is not sent back");
  assert.ok(undo(view));
  assert.equal(editor.visibleText(), "base mine\r\nline\r\n");
  // The undo is the person's: it is sent.
  assert.deepEqual(messages.at(-1), { type: "dirty" });
});

function paste(view: any, text: string) {
  // As CodeMirror's own paste handler does: toText, then replaceSelection.
  view.dispatch(view.state.replaceSelection(view.state.toText(text)), { userEvent: "input.paste", scrollIntoView: true });
}

test("pasted and dropped text takes the file's line breaks", () => {
  const { editor } = mount();
  editor.load({ text: "a\r\nb\r\n", mode: "markdown" });
  const view = editor.view;
  view.dispatch({ selection: EditorSelection.cursor(1) });
  paste(view, "\none\ntwo\n");
  assert.equal(editor.visibleText(), "a\r\none\r\ntwo\r\n\r\nb\r\n");
  assert.equal(view.state.selection.main.head, view.state.doc.toString().indexOf("two") + 4);
  editor.load({ text: "x\ny\n", mode: "code", language: "json" });
  view.dispatch({ selection: EditorSelection.cursor(1) });
  paste(editor.view, "\r\np\r\nq\rr");
  assert.equal(editor.visibleText(), "x\np\nq\nr\ny\n");
  assert.ok(!editor.visibleText().includes("\r"));
  // A drop goes through the same filter.
  editor.view.dispatch({ changes: { from: 0, insert: editor.view.state.toText("d1\r\nd2") }, userEvent: "input.drop" });
  assert.equal(editor.visibleText(), "d1\nd2x\np\nq\nr\ny\n");
  // A change from disk keeps its bytes (a mixed file stays mixed).
  editor.load({ text: "m\r\n", mode: "markdown" });
  editor.replaceAll("m\r\nlone\nend\r\n", { keepUndo: true });
  assert.equal(editor.visibleText(), "m\r\nlone\nend\r\n");
});

test("a remote image draws as a placeholder, never fetched", async () => {
  const { isRemote } = await import("../src/livePreview.ts");
  assert.ok(isRemote("https://example.com/a.png"));
  assert.ok(isRemote("//cdn.example.com/a.png"));
  assert.ok(!isRemote("img/a.png"));
  assert.ok(!isRemote("data:image/png;base64,AAAA"));
  assert.ok(!isRemote("file:///tmp/a.png"));
  const { editor } = mount();
  editor.load({ text: "top\n\n![far](https://example.com/a.png)\n\n![near](a.png)\n", mode: "markdown" });
  ensureSyntaxTree(editor.view.state, editor.view.state.doc.length, 5000);
  editor.view.dispatch({ selection: EditorSelection.cursor(0) });
  const dom = editor.view.contentDOM;
  const imgs = [...dom.querySelectorAll(".cm-md-image img")].map((i: any) => i.getAttribute("src"));
  assert.deepEqual(imgs, ["a.png"]);
  const notes = [...dom.querySelectorAll(".cm-md-remote-image")].map((n: any) => n.textContent);
  assert.deepEqual(notes, ["Remote image"]);
});

test("setWrap changes wrapping in place: the text and the undo history stay", async () => {
  const { undoDepth } = await import("@codemirror/commands");
  const host = document.createElement("div");
  document.body.appendChild(host);
  const messages: Message[] = [];
  const editor = createEditor(host, (m) => messages.push(m), () => {});
  editor.load({ text: "let a = 1\r\nlet b = 2", mode: "code", language: "js", wrap: false });
  const view = editor.view;
  view.dispatch({ changes: { from: 0, insert: "// x\r\n" }, userEvent: "input.type" });
  const depth = undoDepth(view.state);
  assert.ok(depth > 0);
  assert.ok(!view.dom.querySelector(".cm-lineWrapping"));
  editor.setWrap(true);
  assert.ok(view.contentDOM.classList.contains("cm-lineWrapping"));
  assert.equal(undoDepth(view.state), depth, "undo history survives");
  assert.equal(editor.visibleText(), "// x\r\nlet a = 1\r\nlet b = 2");
  editor.setWrap(false);
  assert.ok(!view.contentDOM.classList.contains("cm-lineWrapping"));
  host.remove();
});
