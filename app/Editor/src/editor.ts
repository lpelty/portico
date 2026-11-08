// The viewer's editor (v0.20 §2.3–2.4): CodeMirror 6, one view, set up for
// Markdown as the page or for plain text and code. Swift drives it through
// the `portico` global; it answers through the bridge.

import {
  Annotation,
  ChangeSet,
  Compartment,
  EditorSelection,
  EditorState,
  type Extension,
  Text,
  Transaction,
  type TransactionSpec,
} from "@codemirror/state";
import { EditorView, highlightSpecialChars, keymap, lineNumbers } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { HighlightStyle, type Language, LanguageSupport, StreamLanguage, syntaxHighlighting } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { json } from "@codemirror/lang-json";
import { yaml, yamlFrontmatter } from "@codemirror/lang-yaml";
import { python } from "@codemirror/lang-python";
import { javascript } from "@codemirror/lang-javascript";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { toml } from "@codemirror/legacy-modes/mode/toml";
import { swift } from "@codemirror/legacy-modes/mode/swift";
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { livePreview, type LinkOpener } from "./livePreview.ts";
import { Bridge, type Post } from "./bridge.ts";
import { anchorLines, commentsExtension, draftField, scanComments, selectionRefusal, setDraft } from "./comments.ts";

export type Mode = "markdown" | "code";

export interface LoadOptions {
  text: string;
  mode?: Mode;
  language?: string | null;
  wrap?: boolean;
  scale?: number;
  theme?: Record<string, string | null>;
}

// The file's own line break, kept exactly: CodeMirror otherwise splits on
// any of \r\n, \r and \n and joins with \n, which would rewrite the file.
export function lineSeparatorOf(text: string): string {
  if (text.includes("\r\n")) return "\r\n";
  if (text.includes("\r") && !text.includes("\n")) return "\r";
  return "\n";
}

const streams = {
  toml: () => StreamLanguage.define(toml),
  swift: () => StreamLanguage.define(swift),
  shell: () => StreamLanguage.define(shell),
};

// Syntax colours for the common languages; anything else is plain text.
export function languageFor(name: string | null | undefined): LanguageSupport | Language | null {
  switch ((name ?? "").trim().toLowerCase()) {
    case "markdown":
    case "md":
      return markdown({ base: markdownLanguage });
    case "json":
    case "jsonc":
      return json();
    case "yaml":
    case "yml":
      return yaml();
    case "toml":
      return streams.toml();
    case "python":
    case "py":
      return python();
    case "javascript":
    case "js":
    case "mjs":
    case "cjs":
      return javascript();
    case "jsx":
      return javascript({ jsx: true });
    case "typescript":
    case "ts":
      return javascript({ typescript: true });
    case "tsx":
      return javascript({ typescript: true, jsx: true });
    case "swift":
      return streams.swift();
    case "shell":
    case "sh":
    case "bash":
    case "zsh":
    case "console":
      return streams.shell();
    case "html":
    case "htm":
      return html();
    case "css":
      return css();
    default:
      return null;
  }
}

// Marks the transaction replaceAll makes when it keeps undo: a change from
// disk, not the person's, so it is neither sent back nor counted as an edit.
export const fromDisk = Annotation.define<boolean>();

const anyBreak = /\r\n?|\n/;

// The line separator is pinned to the file's own (lineSeparatorOf), so
// CodeMirror splits typed, pasted and dropped text only on that one break; a
// pasted LF block in a CRLF file would keep raw \n inside its lines. For the
// person's input, inserted text is re-split on any break and joined with the
// file's. A change from disk (replaceAll) keeps its bytes as they are.
export const normalizeInsertedBreaks = EditorState.transactionFilter.of((tr) => {
  if (!tr.docChanged || tr.annotation(fromDisk) || !tr.annotation(Transaction.userEvent)) return tr;
  let raw = false;
  tr.changes.iterChanges((_fa, _ta, _fb, _tb, inserted) => {
    if (!raw) raw = hasRawBreak(inserted);
  });
  if (!raw) return tr;
  const state = tr.startState;
  const specs: { from: number; to: number; insert: Text }[] = [];
  tr.changes.iterChanges((fromA, toA, _fb, _tb, inserted) => {
    const text = inserted.sliceString(0, inserted.length, state.lineBreak);
    specs.push({ from: fromA, to: toA, insert: state.toText(text.split(anyBreak).join(state.lineBreak)) });
  });
  const changes = ChangeSet.of(specs, state.doc.length, state.lineBreak);
  const spec: TransactionSpec = {
    changes,
    selection: state.selection.map(changes, 1),
    effects: tr.effects,
    scrollIntoView: tr.scrollIntoView,
    annotations: [Transaction.userEvent.of(tr.annotation(Transaction.userEvent)!)],
  };
  return spec;
});

function hasRawBreak(text: Text): boolean {
  for (let i = 1; i <= text.lines; i++) if (anyBreak.test(text.line(i).text)) return true;
  return false;
}

export interface ReplaceOptions {
  // Put the cursor on the same line number (default true).
  keepCursorLine?: boolean;
  // Make the replacement one undoable change instead of a fresh document.
  keepUndo?: boolean;
  // Replace even though the person has edits not yet sent.
  force?: boolean;
}

function fenceLanguage(info: string): Language | null {
  const found = languageFor(info.split(/\s/)[0]);
  if (!found) return null;
  return found instanceof LanguageSupport ? found.language : found;
}

// Colours come from CSS variables (editor.html sets light and dark
// defaults; Swift may override them with setTheme). Headings, emphasis and
// links are left to the live preview, so Markdown never gets two looks.
const highlight = HighlightStyle.define([
  { tag: [t.keyword, t.controlKeyword, t.moduleKeyword, t.operatorKeyword], color: "var(--syn-keyword)" },
  { tag: [t.string, t.special(t.string), t.regexp], color: "var(--syn-string)" },
  { tag: [t.number, t.bool, t.null, t.atom], color: "var(--syn-number)" },
  { tag: [t.comment, t.lineComment, t.blockComment], color: "var(--syn-comment)", fontStyle: "italic" },
  { tag: [t.function(t.variableName), t.function(t.propertyName)], color: "var(--syn-function)" },
  { tag: [t.typeName, t.className, t.namespace], color: "var(--syn-type)" },
  { tag: [t.propertyName, t.attributeName], color: "var(--syn-property)" },
  { tag: [t.tagName, t.angleBracket], color: "var(--syn-tag)" },
  { tag: [t.meta, t.processingInstruction, t.definitionKeyword], color: "var(--syn-meta)" },
  { tag: t.invalid, color: "var(--syn-invalid)" },
]);

export interface PorticoEditor {
  load(options: LoadOptions): void;
  setTheme(vars: Record<string, string | null>): void;
  setReadOnly(readOnly: boolean): void;
  setWrap(wrap: boolean): void;
  replaceAll(text: string, options?: ReplaceOptions | boolean): boolean;
  visibleText(): string;
  scrollTopLine(): number;
  scrollToLine(line: number): void;
  // v0.23: a comment action from Swift, as one change on the buffer; refused
  // (false) when the document isn't the length Swift computed it for. It is
  // a normal edit: sent back and saved like typing.
  // Offsets, lengths and text are in the editor's own LF space (a CRLF file's
  // line breaks count as one); the save path writes the file's line endings.
  applyChange(from: number, to: number, insert: string, expectedLength: number): boolean;
  // v0.23: the text in that LF space, for comment actions.
  commentText(): string;
  // v0.23: the draft's range, mapped through edits since it was marked.
  draftRange(): { from: number; to: number } | null;
  // v0.23: the selection, with why it can't be anchored (or null).
  selectionRange(): { from: number; to: number; refusal: "ignored" | "crosses" | "cell" | "atom" | null };
  // v0.23: what the comments margin (viewer-comments.js) needs from the editor.
  commentHooks: CommentHooks;
  readonly view: EditorView;
}

export interface CommentHooks {
  contentElement(): HTMLElement;
  marginParent(): HTMLElement;
  anchorTop(id: string): number | null;
  draftTop(): number | null;
  onLayout(layout: { column: number; card: number } | null): void;
  markDraft(): number;
  clearDraft(): void;
}

export function createEditor(parent: HTMLElement, post?: Post, openLink?: LinkOpener): PorticoEditor {
  const bridge = new Bridge(post);
  const readOnlyCompartment = new Compartment();
  // Settings' Wrap code, changed in place so the undo history survives.
  const wrapCompartment = new Compartment();
  let readOnly = false;
  let current: Required<Omit<LoadOptions, "text" | "theme">> = { mode: "markdown", language: null, wrap: false, scale: 1 };

  const view = new EditorView({ parent });
  const root = parent.ownerDocument.documentElement;

  const readOnlyExtension = (on: boolean): Extension => [EditorState.readOnly.of(on), EditorView.editable.of(!on)];

  function extensions(text: string): Extension[] {
    const listeners = EditorView.updateListener.of((update) => {
      const byPerson = update.transactions.some((tr) => tr.docChanged && !tr.annotation(fromDisk));
      if (byPerson) bridge.edited(() => update.view.state.sliceDoc());
      if (update.focusChanged && !update.view.hasFocus) bridge.blurred(() => update.view.state.sliceDoc());
    });
    const shared: Extension[] = [
      EditorState.lineSeparator.of(lineSeparatorOf(text)),
      history(),
      keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
      highlightSpecialChars(),
      syntaxHighlighting(highlight),
      readOnlyCompartment.of(readOnlyExtension(readOnly)),
      normalizeInsertedBreaks,
      listeners,
    ];
    if (current.mode === "markdown") {
      return [
        ...shared,
        yamlFrontmatter({ content: markdown({ base: markdownLanguage, codeLanguages: fenceLanguage, extensions: [anchorLines()] }) }),
        livePreview(openLink),
        commentsExtension(),
        EditorView.lineWrapping,
        EditorView.editorAttributes.of({ class: "portico-markdown" }),
      ];
    }
    const language = languageFor(current.language);
    return [
      ...shared,
      lineNumbers(),
      ...(language ? [language] : []),
      wrapCompartment.of(current.wrap ? EditorView.lineWrapping : []),
      EditorView.editorAttributes.of({ class: "portico-code" }),
    ];
  }

  // A new state, not a transaction: loading is never an edit, so nothing is
  // sent back and the undo history starts empty.
  function setText(text: string, cursor = 0) {
    const state = EditorState.create({ doc: text, extensions: extensions(text) });
    const anchor = Math.min(cursor, state.doc.length);
    view.setState(state.update({ selection: EditorSelection.cursor(anchor) }).state);
    bridge.loaded();
  }

  function topInScroller(pos: number): number {
    const scroller = view.scrollDOM;
    const offset = view.documentTop - scroller.getBoundingClientRect().top + scroller.scrollTop;
    return view.lineBlockAt(pos).top + offset;
  }

  function setScale(scale: number) {
    root.style.setProperty("--portico-scale", String(scale > 0 ? scale : 1));
  }

  const api: PorticoEditor = {
    view,
    load(options) {
      current = {
        mode: options.mode === "code" ? "code" : "markdown",
        language: options.language ?? null,
        wrap: options.wrap === true,
        scale: options.scale ?? 1,
      };
      if (options.theme) api.setTheme(options.theme);
      setScale(current.scale);
      setText(options.text ?? "");
    },
    setTheme(vars) {
      for (const [key, value] of Object.entries(vars ?? {})) {
        const name = key.startsWith("--") ? key : `--${key}`;
        if (value === null || value === undefined) root.style.removeProperty(name);
        else root.style.setProperty(name, String(value));
      }
    },
    setWrap(on) {
      current.wrap = on === true;
      if (current.mode !== "code") return; // Markdown as the page always wraps.
      view.dispatch({ effects: wrapCompartment.reconfigure(current.wrap ? EditorView.lineWrapping : []) });
    },
    setReadOnly(on) {
      readOnly = on === true;
      view.dispatch({ effects: readOnlyCompartment.reconfigure(readOnlyExtension(readOnly)) });
    },
    // The file changed on disk: show the new text, the cursor on the same
    // line number when asked, the same top line. Refused (false) while the
    // person has edits Swift has not been sent, unless forced. With keepUndo
    // the replacement is one change the person can undo; it is not sent back.
    replaceAll(text, options = {}) {
      const opts: ReplaceOptions = typeof options === "boolean" ? { keepCursorLine: options } : options ?? {};
      if (bridge.pending && !opts.force) return false;
      const keepCursorLine = opts.keepCursorLine !== false;
      const top = api.scrollTopLine();
      const lineNumber = view.state.doc.lineAt(view.state.selection.main.head).number;
      if (opts.keepUndo) {
        const insert = view.state.toText(text);
        const line = keepCursorLine ? insert.line(Math.min(lineNumber, insert.lines)).from : 0;
        view.dispatch({
          changes: { from: 0, to: view.state.doc.length, insert },
          selection: EditorSelection.cursor(line),
          annotations: fromDisk.of(true),
        });
      } else {
        let cursor = 0;
        if (keepCursorLine) {
          const fresh = EditorState.create({ doc: text, extensions: [EditorState.lineSeparator.of(lineSeparatorOf(text))] });
          cursor = fresh.doc.line(Math.min(lineNumber, fresh.doc.lines)).from;
        }
        setText(text, cursor);
      }
      bridge.loaded();
      api.scrollToLine(top);
      return true;
    },
    visibleText() {
      return view.state.sliceDoc();
    },
    // The 1-based line at the top of the view.
    scrollTopLine() {
      const top = view.scrollDOM.getBoundingClientRect().top;
      const block = view.lineBlockAtHeight(Math.max(0, top - view.documentTop));
      return view.state.doc.lineAt(block.from).number;
    },
    scrollToLine(line) {
      const n = Math.max(1, Math.min(Math.floor(line) || 1, view.state.doc.lines));
      view.dispatch({ effects: EditorView.scrollIntoView(view.state.doc.line(n).from, { y: "start" }) });
    },
    applyChange(from, to, insert, expectedLength) {
      const length = view.state.doc.length;
      if (length !== expectedLength || from < 0 || to < from || to > length) return false;
      view.dispatch({
        changes: { from, to, insert: Text.of(insert.split(/\r\n?|\n/)) },
        annotations: Transaction.userEvent.of("input.comment"),
      });
      return true;
    },
    commentText() {
      return view.state.doc.toString();
    },
    draftRange() {
      return view.state.field(draftField, false) ?? null;
    },
    commentHooks: {
      contentElement: () => view.contentDOM,
      marginParent: () => view.scrollDOM,
      // Tops in the scroller's own coordinates (the margin scrolls inside it).
      anchorTop(id) {
        if (current.mode !== "markdown") return null;
        const drawn = view.dom.querySelector(`.cm-md-table mark[data-c="${id}"]`);
        if (drawn) {
          const scroller = view.scrollDOM;
          return drawn.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop;
        }
        const a = scanComments(view.state.doc.toString()).anchors.find((x) => x.id === id);
        return a ? topInScroller(a.openTo) : null;
      },
      draftTop() {
        const d = view.state.field(draftField, false);
        return d ? topInScroller(d.from) : null;
      },
      onLayout(layout) {
        const c = view.contentDOM.style;
        if (layout) {
          c.marginLeft = "12px";
          c.marginRight = "0";
          c.maxWidth = `${layout.column + 64}px`;
        } else {
          c.marginLeft = c.marginRight = c.maxWidth = "";
        }
        view.requestMeasure();
      },
      markDraft() {
        const { from, to } = view.state.selection.main;
        view.dispatch({ effects: setDraft.of(to > from ? { from, to } : null) });
        return to > from ? 1 : 0;
      },
      clearDraft() {
        view.dispatch({ effects: setDraft.of(null) });
      },
    },
    selectionRange() {
      const { from, to } = view.state.selection.main;
      return { from, to, refusal: to > from ? selectionRefusal(view.state, from, to) : null };
    },
  };
  return api;
}

// v0.23: the viewer's own context menu, with the selection's offsets and why
// it can't be anchored; Swift draws the menu (comments handler). A right-click
// in a table drawn as a widget can't be mapped to the source, so it asks the
// person to click into the table (which shows its source).
export function commentMenuMessage(editor: PorticoEditor, target: Node | null, x: number, y: number): Record<string, unknown> {
  const el = target && (target.nodeType === 1 ? (target as Element) : target.parentElement);
  const sel = editor.selectionRange();
  const message: Record<string, unknown> = { type: "commentMenu", x, y, from: sel.from, to: sel.to };
  if (el && el.closest(".cm-md-table")) {
    message.refusal = "widget";
    message.to = Math.max(sel.to, sel.from + 1);
  } else if (sel.refusal) {
    message.refusal = sel.refusal;
  }
  return message;
}

// In the page: build into #editor, publish the global, say ready.
const doc = (globalThis as any).document as Document | undefined;
const mount = doc?.getElementById("editor");
if (mount && !(globalThis as any).portico) {
  const editor = createEditor(mount);
  (globalThis as any).portico = editor;
  // v0.23: the viewer's own context menu, with the selection's offsets and
  // why it can't be anchored; Swift draws the menu (comments handler).
  editor.view.contentDOM.addEventListener("contextmenu", (e: MouseEvent) => {
    e.preventDefault();
    const handler = (globalThis as any).webkit?.messageHandlers?.comments;
    if (handler) handler.postMessage(commentMenuMessage(editor, e.target as Node, e.clientX, e.clientY));
  });
  new Bridge().ready();
}
