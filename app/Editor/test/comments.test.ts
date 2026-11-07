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
const { scanComments, commentsExtension, commentDecorations, selectionRefusal } = await import("../src/comments.ts");
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
    for (const t of c.parse.threads) {
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
  assert.equal(selectionRefusal(s, cell + 2, cell + 3), "ignored");
  const inline = text.indexOf("make");
  assert.equal(selectionRefusal(s, inline, inline + 4), "ignored");
  assert.equal(selectionRefusal(s, text.indexOf("continues"), text.indexOf("three")), "crosses");
  assert.equal(selectionRefusal(s, text.indexOf("two"), text.indexOf("continues") + 4), null);
});

test("emoji offsets", () => {
  const text = read("emoji.md");
  const a = scanComments(text).anchors[0];
  assert.equal(text.slice(a.openTo, a.closeFrom), "first draft");
  assert.equal(a.openFrom, text.indexOf("<!--c:em001-->"));
});
