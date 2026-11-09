// Comments in Edit mode (v0.23): the scanner agrees with the shared
// fixtures, comment markup is hidden and atomic, anchors survive typing, and
// a comment action from Swift is a normal edit. Run: node --test test/
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { pretendToBeVisual: true });
const g = globalThis as any;
for (const key of Object.getOwnPropertyNames(dom.window)) {
  if (key in g && !["window", "document", "navigator"].includes(key)) continue;
  try {
    Object.defineProperty(g, key, { value: (dom.window as any)[key], configurable: true, writable: true });
  } catch {}
}
g.window = dom.window;
const zeroRect = () => ({ left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0 });
dom.window.Range.prototype.getClientRects = () => [] as any;
dom.window.Range.prototype.getBoundingClientRect = zeroRect as any;
dom.window.HTMLElement.prototype.scrollIntoView = () => {};

const { EditorState, EditorSelection } = await import("@codemirror/state");
const { ensureSyntaxTree } = await import("@codemirror/language");
const { markdown, markdownLanguage } = await import("@codemirror/lang-markdown");
const { yamlFrontmatter } = await import("@codemirror/lang-yaml");
const { scanComments, commentsExtension, commentDecorations, selectionRefusal, trimSelection, widenToAutolink } = await import("../src/comments.ts");
const { createEditor } = await import("../src/editor.ts");
type Message = import("../src/bridge.ts").Message;

const FIXTURES = new URL("../../../protocol/examples/comments/", import.meta.url);
const cases = JSON.parse(readFileSync(new URL("cases.json", FIXTURES), "utf8")).cases;
const read = (name: string) => readFileSync(new URL(name, FIXTURES), "utf8");
const strip = (s: string) => s.replace(/<!--\/?c:[a-z0-9]{5,8}-->/g, "");

function mount() {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const messages: Message[] = [];
  const editor = createEditor(host, (m) => messages.push(m), () => {});
  return { editor, messages };
}

function state(doc: string) {
  const s = EditorState.create({
    doc,
    extensions: [yamlFrontmatter({ content: markdown({ base: markdownLanguage }) }), commentsExtension()],
  });
  ensureSyntaxTree(s, s.doc.length, 5000);
  return s;
}

test("scan agrees with fixtures", () => {
  for (const c of cases.filter((c: any) => c.parse)) {
    const text = read(c.file);
    const scan = scanComments(text);
    assert.deepEqual(scan.blocks.map((b) => b.id), c.parse.threads.map((t: any) => t.id), c.name);
    assert.deepEqual(scan.blocks.map((b) => b.status), c.parse.threads.map((t: any) => t.status), c.name);
    const seenIds = new Set<string>();
    for (const t of c.parse.threads) {
      if (seenIds.has(t.id)) continue; // a pasted copy of a block: an orphan thread; its id's anchors are the first's
      seenIds.add(t.id);
      const a = scan.anchors.find((a) => a.id === t.id);
      if (t.anchored_text === null) assert.equal(a, undefined, `${c.name} ${t.id}`);
      else assert.equal(strip(text.slice(a!.openTo, a!.closeFrom)), t.anchored_text, `${c.name} ${t.id}`);
    }
    const orphans = scan.anchors.filter((a) => !scan.blocks.some((b) => b.id === a.id)).map((a) => a.id);
    assert.deepEqual(orphans, c.parse.orphan_anchors, c.name);
  }
});

test("markers and blocks are hidden and atomic", () => {
  const text = read("plugin-basic.md");
  const s = state(text);
  const hidden: Array<[number, number]> = [];
  const marked: Array<[number, number]> = [];
  commentDecorations(s).between(0, s.doc.length, (from, to, deco) => {
    if (deco.spec.class) marked.push([from, to]);
    else hidden.push([from, to]);
  });
  const open = text.indexOf("<!--c:k3x9a-->");
  const close = text.indexOf("<!--/c:k3x9a-->");
  assert.ok(hidden.some(([f, t]) => f === open && t === open + "<!--c:k3x9a-->".length));
  assert.ok(hidden.some(([f, t]) => f === close && t === close + "<!--/c:k3x9a-->".length));
  const block = text.indexOf("<!--co:");
  assert.ok(hidden.some(([f, t]) => f === block && t === text.indexOf("-->\n", block + 10) + 3), "the thread block, whole lines");
  assert.deepEqual(marked, [[open + "<!--c:k3x9a-->".length, close]]);

  const { editor } = mount();
  editor.load({ text, mode: "markdown" });
  const view = editor.view;
  const after = open + "<!--c:k3x9a-->".length;
  view.dispatch({ selection: EditorSelection.cursor(open) });
  // One step right from before the marker lands after it (and after "p"), never inside it.
  view.dispatch({ selection: EditorSelection.cursor(open + 3) });
  const moved = view.moveByChar(EditorSelection.cursor(open), true);
  assert.ok(moved.head <= open || moved.head >= after, `cursor inside hidden markup: ${moved.head}`);
});

test("typing inside a span keeps anchors", () => {
  const { editor } = mount();
  const text = read("para.add.after.md");
  editor.load({ text, mode: "markdown" });
  const view = editor.view;
  const at = text.indexOf("writes") + 3;
  view.dispatch({ changes: { from: at, insert: "XY" }, userEvent: "input.type" });
  const out = editor.visibleText();
  assert.ok(out.includes("<!--c:nw001-->wriXYtes files<!--/c:nw001-->"), out.slice(0, 120));
});

test("deleting all anchored text removes both markers", () => {
  const { editor } = mount();
  const text = read("para.add.after.md");
  editor.load({ text, mode: "markdown" });
  const view = editor.view;
  const from = text.indexOf("writes files");
  view.dispatch({ changes: { from, to: from + "writes files".length }, userEvent: "delete.selection" });
  const out = editor.visibleText();
  assert.ok(!out.includes("<!--c:nw001-->") && !out.includes("<!--/c:nw001-->"), out.slice(0, 120));
  assert.ok(out.includes("<!--co:nw001"), "the thread stays, as an orphan");
});

test("deleting across one marker keeps the pair", () => {
  const { editor } = mount();
  const text = read("para.add.after.md");
  editor.load({ text, mode: "markdown" });
  const view = editor.view;
  // "gateway <!--c:nw001-->writes" -> delete from "way " through "wri"
  const from = text.indexOf("way ");
  const to = text.indexOf("writes") + 3;
  view.dispatch({ changes: { from, to }, userEvent: "delete.selection" });
  const out = editor.visibleText();
  assert.ok(out.includes("The gate<!--c:nw001-->tes files<!--/c:nw001-->"), out.slice(0, 120));
});

test("applyChange is a normal edit", async () => {
  const { editor, messages } = mount();
  const text = read("para.md");
  editor.load({ text, mode: "markdown" });
  const at = text.indexOf("Second");
  assert.equal(editor.applyChange(at, at, "<!--c:zz001-->", text.length), true);
  assert.ok(editor.visibleText().includes("<!--c:zz001-->Second"));
  assert.deepEqual(messages.filter((m) => m.type !== "ready").map((m) => m.type), ["dirty"]);
  await new Promise((r) => setTimeout(r, 900));
  assert.deepEqual(messages.filter((m) => m.type !== "ready").map((m) => m.type), ["dirty", "changed"]);
});

test("applyChange refuses a stale length", () => {
  const { editor } = mount();
  editor.load({ text: "abc\n", mode: "markdown" });
  assert.equal(editor.applyChange(0, 0, "x", 99), false);
  assert.equal(editor.visibleText(), "abc\n");
});

test("selection in code or table refused", () => {
  const text = "Para one.\n\n```\ncode here\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nUse `make` now.\n\nPara two\ncontinues.\n\nPara three.\n";
  const s = state(text);
  const code = text.indexOf("code here");
  assert.equal(selectionRefusal(s, code, code + 4), "ignored");
  const cell = text.indexOf("| 1");
  assert.equal(selectionRefusal(s, cell + 2, cell + 3), null, "within one cell (spec §13)");
  const inline = text.indexOf("make");
  assert.equal(selectionRefusal(s, inline, inline + 4), "ignored");
  assert.equal(selectionRefusal(s, text.indexOf("continues"), text.indexOf("three")), "crosses");
  assert.equal(selectionRefusal(s, text.indexOf("two"), text.indexOf("continues") + 4), null);
});

test("a selection inside a link or an entity is refused (v0.25 #3)", () => {
  const text = "Visit <https://alpha.example/x> or https://beta.example/y and Tom &amp; Jerry.\n";
  const s = state(text);
  const at = (w: string) => text.indexOf(w);
  assert.equal(selectionRefusal(s, at("alpha"), at("alpha") + 5), "atom", "inside an autolink");
  assert.equal(selectionRefusal(s, at("beta"), at("beta") + 4), "atom", "inside a bare URL");
  assert.equal(selectionRefusal(s, at("Tom"), at("&amp;") + 1), "atom", "ends inside an entity");
  assert.equal(selectionRefusal(s, at("https://beta"), at("https://beta") + "https://beta.example/y".length), null, "the whole bare URL");
  assert.equal(selectionRefusal(s, at("Jerry"), at("Jerry") + 5), null);
});

// v0.26 (review L4): the shared find-* fixtures, through Edit mode's selection check, so
// the editor's atoms agree with the gateway's and the app's.
test("find fixtures agree on links and entities", () => {
  let checked = 0;
  for (const c of cases.filter((c: any) => c.find)) {
    const text: string = c.text ?? read(c.file);
    const s = state(text);
    if (c.expect_prefix !== undefined) {
      const target: string = c.expect_text ?? c.find.quote;
      const from = c.expect_prefix.length;
      if (text.slice(from, from + target.length) !== target) continue; // quoted as rendered: no one source span
      assert.notEqual(selectionRefusal(s, from, from + target.length), "atom", c.name);
      checked++;
    } else if (c.expect_refusal === "inside a link or entity") {
      const from = text.indexOf(c.find.quote);
      assert.equal(selectionRefusal(s, from, from + c.find.quote.length), "atom", c.name);
      checked++;
    }
  }
  assert.ok(checked >= 20, `checked ${checked}`);
});

// v0.26 review M1: an autolink's address, selected, anchors around the whole <…>, so the
// written markers sit outside the brackets and the link still renders.
test("an autolink's address anchors outside its brackets", async () => {
  const { createRequire } = await import("node:module");
  const { marked } = createRequire(import.meta.url)("../../Sources/Portico/Resources/marked.min.js");
  const linkCases = cases.filter((c: any) => c.expect_link);
  assert.equal(linkCases.length, 3);
  for (const c of linkCases) {
    const text = read(c.file);
    const from = text.indexOf(c.args.quote);
    assert.equal(selectionRefusal(state(text), from, from + c.args.quote.length), null, c.name);
    const [a, b] = widenToAutolink(text, from, from + c.args.quote.length);
    assert.equal(text.slice(a, b), c.expect_link, c.name);
    const written = read(c.expect);
    assert.ok(written.includes(`<!--c:${c.args.id}-->${c.expect_link}<!--/c:${c.args.id}-->`), c.name);
    const html: string = marked.parse(written);
    const href = c.expect_link.slice(1, -1);
    assert.ok(html.includes(`<!--c:${c.args.id}--><a href="${href.includes("@") && !href.includes(":") ? "mailto:" + href : href}">`), `${c.name}: ${html}`);
  }
  const other = "See https://b.com/y and words.\n";
  assert.deepEqual(widenToAutolink(other, 4, 19), [4, 19], "a bare URL is not widened");
});

test("emoji offsets", () => {
  const text = read("emoji.md");
  const a = scanComments(text).anchors[0];
  assert.equal(text.slice(a.openTo, a.closeFrom), "first draft");
  assert.equal(a.openFrom, text.indexOf("<!--c:em001-->"));
});

// --- fix round (review items 1, 3, 5, 6) ------------------------------------------

const { EditorView, runScopeHandlers } = await import("@codemirror/view");
const press = (view: any, key: string) => runScopeHandlers(view, new dom.window.KeyboardEvent("keydown", { key }) as any, "editor");
const cmds = await import("@codemirror/commands");
const { syntaxTree } = await import("@codemirror/language");
const { anchorAwareMarkdown } = await import("../src/comments.ts");

const PROTECTED = 'Some <!--c:aaaaa-->text<!--/c:aaaaa--> here.\n<!--co:aaaaa by:Sam at:T status:open quote:"text"\nSam (T): important\n-->\nNext para.\n';

function viewAt(doc: string, pos: number) {
  const { editor } = mount();
  editor.load({ text: doc, mode: "markdown" });
  editor.view.dispatch({ selection: EditorSelection.cursor(pos) });
  return editor;
}

test("backspace at the start of the line after a thread block deletes the visible character before the block", () => {
  const editor = viewAt(PROTECTED, PROTECTED.indexOf("Next"));
  assert.equal(press(editor.view, "Backspace"), true);
  assert.equal(editor.visibleText(), PROTECTED.replace("here.\n", "here\n"));
});

test("delete at the end of the anchored block's last line deletes after the block", () => {
  const editor = viewAt(PROTECTED, PROTECTED.indexOf("\n<!--co"));
  assert.equal(press(editor.view, "Delete"), true);
  assert.equal(editor.visibleText(), PROTECTED.replace("Next para.", "ext para."));
});

test("backspace right after an anchor deletes the visible character before the anchor", () => {
  const editor = viewAt(PROTECTED, PROTECTED.indexOf("text<"));
  assert.equal(press(editor.view, "Backspace"), true);
  assert.equal(editor.visibleText(), PROTECTED.replace("Some <!--c", "Some<!--c"));
});

test("a person's edit never cuts into a thread block, and never joins <!--co: onto a text line", () => {
  const { editor } = mount();
  editor.load({ text: PROTECTED, mode: "markdown" });
  const view = editor.view;
  const inBlock = PROTECTED.indexOf("important");
  view.dispatch({ changes: { from: inBlock - 3, to: inBlock + 4 }, userEvent: "delete.selection" });
  assert.equal(editor.visibleText(), PROTECTED, "cutting into the block is refused");
  view.dispatch({ changes: { from: PROTECTED.indexOf("here") , to: PROTECTED.indexOf("para.") }, userEvent: "delete.selection" });
  const out = editor.visibleText();
  assert.ok(out.includes("\n<!--co:aaaaa"), out);
  assert.ok(out.includes("Sam (T): important\n-->\n"), out);
  assert.ok(!/[^\n]<!--co:/.test(out), out);
});

test("the plain delete commands never remove a thread block either", () => {
  for (const [pos, cmd] of [[PROTECTED.indexOf("Next"), cmds.deleteCharBackward], [PROTECTED.indexOf("\n<!--co"), cmds.deleteCharForward]] as const) {
    const editor = viewAt(PROTECTED, pos);
    (cmd as any)(editor.view);
    assert.ok(editor.visibleText().includes("Sam (T): important\n-->\n"), editor.visibleText());
    assert.ok(!/[^\n]<!--co:/.test(editor.visibleText()), JSON.stringify(editor.visibleText()));
  }
});

test("comment actions may change a thread block", () => {
  const { editor } = mount();
  editor.load({ text: PROTECTED, mode: "markdown" });
  const at = PROTECTED.indexOf("-->\nNext");
  assert.equal(editor.applyChange(at, at, "Agent (T): ok\n", editor.view.state.doc.length), true);
  assert.ok(editor.visibleText().includes("Agent (T): ok\n-->"));
});

test("an anchor at column 0 is a paragraph, not an HTML block", () => {
  const text = read("anchor-col0.md");
  const s = EditorState.create({ doc: text, extensions: [anchorAwareMarkdown()] });
  ensureSyntaxTree(s, s.doc.length, 5000);
  const names: string[] = [];
  for (let n: any = syntaxTree(s).resolveInner(text.indexOf("Hello") + 1, 1); n; n = n.parent) names.push(n.name);
  assert.ok(names.includes("Paragraph"), names.join(" "));
  assert.ok(!names.includes("HTMLBlock") && !names.includes("CommentBlock"), names.join(" "));
  let strong = false;
  syntaxTree(s).iterate({ enter: (n) => { if (n.name === "StrongEmphasis") strong = true; } });
  assert.ok(strong, "the rest of the line is Markdown");
});

test("CRLF: comment offsets and texts are in the editor's LF space", () => {
  const { editor } = mount();
  const text = "Line one\r\nTwo words here\r\n\r\nThird\r\n";
  editor.load({ text, mode: "markdown" });
  const lf = editor.commentText();
  assert.equal(lf, text.replace(/\r\n/g, "\n"));
  const at = lf.indexOf("words");
  const blockAt = lf.indexOf("\n\nThird") + 1;
  const insert = "<!--co:zzzzz by:S at:T status:open quote:\"words\"\nS (T): hi\n-->\n";
  assert.equal(editor.applyChange(blockAt, blockAt, insert, lf.length), true);
  assert.equal(editor.applyChange(at, at, "<!--c:zzzzz-->", editor.commentText().length), true);
  const saved = editor.visibleText();
  assert.ok(!/[^\r]\n/.test(saved), JSON.stringify(saved));
  assert.ok(saved.includes("S (T): hi\r\n-->\r\n"), JSON.stringify(saved));
  assert.ok(saved.includes("<!--c:zzzzz-->words"));
});

test("a draft's range follows edits made before it", () => {
  const { editor } = mount();
  const text = "Alpha beta gamma.\n";
  editor.load({ text, mode: "markdown" });
  const view = editor.view;
  view.dispatch({ selection: EditorSelection.range(6, 10) });
  editor.commentHooks.markDraft();
  view.dispatch({ changes: { from: 0, insert: "New " }, userEvent: "input.type" });
  assert.deepEqual(editor.draftRange(), { from: 10, to: 14 });
  assert.equal(editor.commentText().slice(10, 14), "beta");
});

// --- re-review item 1: a person's input is never dropped next to a thread block ------

const DOC2 = 'Intro.\n\nSome <!--c:aaaaa-->text<!--/c:aaaaa--> here.\n<!--co:aaaaa by:Sam at:T status:open quote:"text"\nSam (T): important\n-->\nNext para.\n';
const BLOCK2 = '<!--co:aaaaa by:Sam at:T status:open quote:"text"\nSam (T): important\n-->\n';

function typed(sel: any, insert: string, userEvent: string) {
  const { editor } = mount();
  editor.load({ text: DOC2, mode: "markdown" });
  const view = editor.view;
  view.dispatch({ selection: sel });
  view.dispatch({ ...view.state.replaceSelection(insert), userEvent });
  return { editor, view };
}

function blockIntact(out: string) {
  assert.ok(out.includes("\n" + BLOCK2) || out.startsWith(BLOCK2), JSON.stringify(out));
  assert.ok(!/[^\n]<!--co:/.test(out), JSON.stringify(out));
}

for (const [label, sel, insert, ev] of [
  ["triple-click a commented paragraph (with its line break) and type", EditorSelection.single(DOC2.indexOf("Some"), DOC2.indexOf("<!--co")), "N", "input.type"],
  ["type at the thread block's start", EditorSelection.cursor(DOC2.indexOf("<!--co")), "x", "input.type"],
  ["IME composition at the thread block's start", EditorSelection.cursor(DOC2.indexOf("<!--co")), "あ", "input.type.compose"],
  ["paste over the paragraph and its line break", EditorSelection.single(DOC2.indexOf("Some"), DOC2.indexOf("<!--co")), "Pasted line", "input.paste"],
  ["select everything and type", EditorSelection.single(0, DOC2.length), "Z", "input.type"],
] as const) {
  test(`${label}: the text lands, the block stays on its own lines, undo and redo work`, () => {
    const { editor, view } = typed(sel, insert, ev);
    const out = editor.visibleText();
    assert.ok(out.includes(insert), `input dropped: ${JSON.stringify(out)}`);
    blockIntact(out);
    cmds.undo(view);
    assert.equal(editor.visibleText(), DOC2, "undo restores");
    cmds.redo(view);
    assert.equal(editor.visibleText(), out, "redo repeats");
  });
}

test("CRLF: typing at a thread block's start keeps CRLF line breaks", () => {
  const { editor } = mount();
  const crlf = DOC2.replace(/\n/g, "\r\n");
  editor.load({ text: crlf, mode: "markdown" });
  const view = editor.view;
  view.dispatch({ selection: EditorSelection.single(view.state.doc.toString().indexOf("Some"), view.state.doc.toString().indexOf("<!--co")) });
  view.dispatch({ ...view.state.replaceSelection("N"), userEvent: "input.type" });
  const out = editor.visibleText();
  assert.ok(out.includes("N\r\n<!--co:aaaaa"), JSON.stringify(out));
  assert.ok(!/[^\r]\n/.test(out), JSON.stringify(out));
});

// --- re-re-review item 1: real typing, one transaction per character ----------------

const blk3 = (id: string) => `<!--co:${id} by:S at:T status:open quote:"t"\nS (T): r\n-->\n`;
const DOC3 = "Some <!--c:aaaaa-->text<!--/c:aaaaa--> here.\n" + blk3("aaaaa") + blk3("bbbbb") + "Next para.\n";

function typeChars(sel: any, chars: string, userEvent = "input.type") {
  const { editor } = mount();
  editor.load({ text: DOC3, mode: "markdown" });
  const view = editor.view;
  view.dispatch({ selection: sel });
  for (const ch of chars) view.dispatch({ ...view.state.replaceSelection(ch), userEvent });
  return { editor, view };
}

const B3 = blk3("aaaaa") + blk3("bbbbb");
for (const [label, sel, chars, want] of [
  ["over a paragraph and two threads, typing ZY", () => EditorSelection.single(DOC3.indexOf("here"), DOC3.indexOf("Next") + 4), "ZY",
    "Some <!--c:aaaaa-->text<!--/c:aaaaa--> ZY\n" + B3 + " para.\n"],
  ["triple-click retype AB", () => EditorSelection.single(0, DOC3.indexOf("<!--co")), "AB", "AB\n" + B3 + "Next para.\n"],
  ["select all, type AB", () => EditorSelection.single(0, DOC3.length), "AB", "AB\n" + B3],
  ["typing QR inside a hidden thread", () => EditorSelection.cursor(DOC3.indexOf("<!--co") + 10), "QR",
    "Some <!--c:aaaaa-->text<!--/c:aaaaa--> here.\n" + blk3("aaaaa") + "QR\n" + blk3("bbbbb") + "Next para.\n"],
] as const) {
  test(`${label}: every character lands in order, the cursor follows, undo and redo`, () => {
    const { editor, view } = typeChars(sel(), chars);
    assert.equal(editor.visibleText(), want);
    const head = view.state.selection.main;
    assert.ok(head.empty, "a cursor, not a selection");
    assert.equal(editor.visibleText().slice(head.head - chars.length, head.head), chars, "the cursor is after the typed text");
    for (let i = 0; i < chars.length; i++) cmds.undo(view);
    assert.equal(editor.visibleText(), DOC3);
    for (let i = 0; i < chars.length; i++) cmds.redo(view);
    assert.equal(editor.visibleText(), want);
  });
}

test("IME composing several characters at a thread's start lands them in order", () => {
  const { editor } = typeChars(EditorSelection.cursor(DOC3.indexOf("<!--co")), "日本語", "input.type.compose");
  assert.ok(editor.visibleText().includes("here.\n日本語\n<!--co:aaaaa"), JSON.stringify(editor.visibleText()));
});

test("a deletion from inside one thread to inside the next moves the cursor instead of vanishing", () => {
  const { editor } = mount();
  editor.load({ text: DOC3, mode: "markdown" });
  const view = editor.view;
  const a = DOC3.indexOf("S (T): r"), b = DOC3.lastIndexOf("S (T): r");
  view.dispatch({ selection: EditorSelection.single(a, b) });
  view.dispatch({ changes: { from: a, to: b }, userEvent: "delete.selection" });
  assert.equal(editor.visibleText(), DOC3);
  assert.ok(view.state.selection.main.empty);
  assert.equal(view.state.selection.main.head, DOC3.indexOf("<!--co:bbbbb"));
});


// --- table cells (spec §13) ------------------------------------------------------------

const { commentMenuMessage } = await import("../src/editor.ts");

test("a selection in one table cell can be commented; across cells, a pipe or the delimiter row can't", () => {
  const text = read("table.md");
  const s = state(text);
  const at = (needle: string) => text.indexOf(needle);
  assert.equal(selectionRefusal(s, at("alpha"), at("alpha") + 5), null);
  assert.equal(selectionRefusal(s, at("a \\| b"), at("a \\| b") + 6), null, "an escaped pipe is text");
  assert.equal(selectionRefusal(s, at("alpha"), at("a \\| b") + 1), "cell");
  assert.equal(selectionRefusal(s, at(":-----"), at(":-----") + 3), "cell");
  assert.equal(selectionRefusal(s, at("code"), at("code") + 4), "ignored");
});

test("the table widget shows comment highlights, never the markup", () => {
  const { editor } = mount();
  const text = read("table-cells.md") + "\nAfter.\n";
  editor.load({ text, mode: "markdown" });
  editor.view.dispatch({ selection: EditorSelection.cursor(text.length) });
  const widget = editor.view.dom.querySelector(".cm-md-table");
  assert.ok(widget, "the table draws as a widget");
  assert.ok(!widget!.textContent!.includes("<!--"), widget!.textContent!);
  const marks = [...widget!.querySelectorAll("mark.pc-anchor.pc-open")].map((m) => [m.getAttribute("data-c"), m.textContent]);
  assert.deepEqual(marks, [["tp001", "alpha"], ["tp002", "y"]]);
});

test("right-clicking in the table widget says to click into the table", () => {
  const { editor } = mount();
  const text = read("table-cells.md") + "\nAfter.\n";
  editor.load({ text, mode: "markdown" });
  editor.view.dispatch({ selection: EditorSelection.cursor(text.length) });
  const cell = editor.view.dom.querySelector(".cm-md-table td")!;
  const msg = commentMenuMessage(editor, cell, 5, 6);
  assert.equal(msg.refusal, "widget");
  const plain = commentMenuMessage(editor, editor.view.contentDOM, 1, 2);
  assert.equal(plain.refusal, undefined);
});

test("GFM: a pipe splits a table row before inline code, so `c|d` is plain text in two cells", () => {
  const text = "| a | b |\n|---|---|\n| `c|d` |\n";
  const s = state(text);
  const c = text.indexOf("c|");
  assert.equal(selectionRefusal(s, c, c + 1), null);
  assert.equal(selectionRefusal(s, c + 2, c + 3), null);
});

// v0.26.2 follow-up (Larry, 11-09 demos): a whole line selected (a triple
// click, a drag past its end) takes the line break and reads as crossing
// into the next block; its edges come in to the text.
test("a whole line selected with its line break can be commented", () => {
  const text = "Intro.\n\nthe permission prompt stays\n\nNext one.\n";
  const s = state(text);
  const start = text.indexOf("the permission");
  const end = text.indexOf("Next");
  const [from, to] = trimSelection(text, start, end);
  assert.equal(text.slice(from, to), "the permission prompt stays");
  assert.equal(selectionRefusal(s, from, to), null);
});

test("a list item selected to the next item's start can be commented", () => {
  const text = "- one item\n- two item\n";
  const s = state(text);
  const [from, to] = trimSelection(text, text.indexOf("one"), text.indexOf("- two"));
  assert.equal(text.slice(from, to), "one item");
  assert.equal(selectionRefusal(s, from, to), null);
});

test("trimming leaves a selection of only spaces alone", () => {
  assert.deepEqual(trimSelection("a   b", 1, 4), [1, 4]);
});
