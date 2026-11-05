// The viewer's editor (v0.20 §2.3–2.4): CodeMirror 6, one view, set up for
// Markdown as the page or for plain text and code. Swift drives it through
// the `portico` global; it answers through the bridge.

import { Compartment, EditorSelection, EditorState, type Extension } from "@codemirror/state";
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
  replaceAll(text: string, keepCursorLine?: boolean): void;
  visibleText(): string;
  scrollTopLine(): number;
  scrollToLine(line: number): void;
  readonly view: EditorView;
}

export function createEditor(parent: HTMLElement, post?: Post, openLink?: LinkOpener): PorticoEditor {
  const bridge = new Bridge(post);
  const readOnlyCompartment = new Compartment();
  let readOnly = false;
  let current: Required<Omit<LoadOptions, "text" | "theme">> = { mode: "markdown", language: null, wrap: false, scale: 1 };

  const view = new EditorView({ parent });
  const root = parent.ownerDocument.documentElement;

  const readOnlyExtension = (on: boolean): Extension => [EditorState.readOnly.of(on), EditorView.editable.of(!on)];

  function extensions(text: string): Extension[] {
    const listeners = EditorView.updateListener.of((update) => {
      if (update.docChanged) bridge.edited(() => update.view.state.sliceDoc());
      if (update.focusChanged && !update.view.hasFocus) bridge.blurred(() => update.view.state.sliceDoc());
    });
    const shared: Extension[] = [
      EditorState.lineSeparator.of(lineSeparatorOf(text)),
      history(),
      keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
      highlightSpecialChars(),
      syntaxHighlighting(highlight),
      readOnlyCompartment.of(readOnlyExtension(readOnly)),
      listeners,
    ];
    if (current.mode === "markdown") {
      return [
        ...shared,
        yamlFrontmatter({ content: markdown({ base: markdownLanguage, codeLanguages: fenceLanguage }) }),
        livePreview(openLink),
        EditorView.lineWrapping,
        EditorView.editorAttributes.of({ class: "portico-markdown" }),
      ];
    }
    const language = languageFor(current.language);
    return [
      ...shared,
      lineNumbers(),
      ...(language ? [language] : []),
      ...(current.wrap ? [EditorView.lineWrapping] : []),
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
    setReadOnly(on) {
      readOnly = on === true;
      view.dispatch({ effects: readOnlyCompartment.reconfigure(readOnlyExtension(readOnly)) });
    },
    // The file changed on disk and nothing was pending: show the new text,
    // the cursor on the same line number when asked, the same top line.
    replaceAll(text, keepCursorLine = true) {
      const top = api.scrollTopLine();
      let cursor = 0;
      if (keepCursorLine) {
        const lineNumber = view.state.doc.lineAt(view.state.selection.main.head).number;
        const fresh = EditorState.create({ doc: text, extensions: [EditorState.lineSeparator.of(lineSeparatorOf(text))] });
        cursor = fresh.doc.line(Math.min(lineNumber, fresh.doc.lines)).from;
      }
      setText(text, cursor);
      api.scrollToLine(top);
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
  };
  return api;
}

// In the page: build into #editor, publish the global, say ready.
const doc = (globalThis as any).document as Document | undefined;
const mount = doc?.getElementById("editor");
if (mount && !(globalThis as any).portico) {
  const editor = createEditor(mount);
  (globalThis as any).portico = editor;
  new Bridge().ready();
}
