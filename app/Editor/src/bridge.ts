// The messages the editor sends Swift, through
// `window.webkit.messageHandlers.portico` (v0.20 §5):
//   {type: "ready"}                        once, when the editor exists;
//   {type: "dirty"}                        at once, on the first edit after a
//                                          load or a send (closes the 800 ms
//                                          window in which Swift would think
//                                          nothing is pending);
//   {type: "changed", text, dirty: true}   800 ms after typing stops;
//   {type: "saveNow", text}                on blur, when there is an edit not
//                                          yet sent.
// v0.23: comment messages go to the `comments` handler, not this one:
//   {type: "commentMenu", x, y, from, to, refusal?}  a right-click in the
//                                          editor (offsets are UTF-16);
//   the comments margin's own messages (activate, anchorClicked, reply,
//   resolve, reopen, post, cancelDraft) come from viewer-comments.js.
// A comment action from Swift arrives as portico.applyChange and is an edit
// like typing: it is sent back with dirty/changed and saved.
// Text always carries the file's own line endings. Sending `changed` or
// `saveNow` hands the text to Swift to save: from then on the edit is
// Swift's, and the next edit starts a new round with a new `dirty`.

export type Message =
  | { type: "ready" }
  | { type: "dirty" }
  | { type: "changed"; text: string; dirty: true }
  | { type: "saveNow"; text: string };

export type Post = (message: Message) => void;

export const CHANGE_DELAY_MS = 800;

export function webkitPost(): Post {
  return (message) => {
    const handler = (globalThis as any).webkit?.messageHandlers?.portico;
    if (handler) handler.postMessage(message);
  };
}

export class Bridge {
  private post: Post;
  private timer: ReturnType<typeof setTimeout> | null = null;
  // An edit by the person that Swift has not been sent yet. Cleared by a
  // load (a load or a reload from disk never comes back as a save) and by
  // sending the text.
  private unsent = false;

  constructor(post: Post = webkitPost()) {
    this.post = post;
  }

  ready() {
    this.post({ type: "ready" });
  }

  // A fresh document from Swift: whatever was pending belonged to the old one.
  loaded() {
    this.cancel();
    this.unsent = false;
  }

  edited(text: () => string) {
    if (!this.unsent) this.post({ type: "dirty" });
    this.unsent = true;
    this.cancel();
    this.timer = setTimeout(() => {
      this.timer = null;
      this.unsent = false;
      this.post({ type: "changed", text: text(), dirty: true });
    }, CHANGE_DELAY_MS);
  }

  blurred(text: () => string) {
    if (!this.unsent) return;
    this.cancel();
    this.unsent = false;
    this.post({ type: "saveNow", text: text() });
  }

  // True while the person has typed something Swift has not been sent.
  get pending(): boolean {
    return this.unsent;
  }

  private cancel() {
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
  }
}
