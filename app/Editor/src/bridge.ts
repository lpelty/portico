// The messages the editor sends Swift, through
// `window.webkit.messageHandlers.portico` (v0.20 §5):
//   {type: "ready"}                        once, when the editor exists;
//   {type: "changed", text, dirty: true}   800 ms after typing stops;
//   {type: "saveNow", text}                on blur, when there was an edit.
// Text always carries the file's own line endings.

export type Message =
  | { type: "ready" }
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
  // Set by the person's edits; cleared by a load, so a load or a reload from
  // disk never comes back as a save.
  private editedSinceLoad = false;

  constructor(post: Post = webkitPost()) {
    this.post = post;
  }

  ready() {
    this.post({ type: "ready" });
  }

  // A fresh document from Swift: whatever was pending belonged to the old one.
  loaded() {
    this.cancel();
    this.editedSinceLoad = false;
  }

  edited(text: () => string) {
    this.editedSinceLoad = true;
    this.cancel();
    this.timer = setTimeout(() => {
      this.timer = null;
      this.post({ type: "changed", text: text(), dirty: true });
    }, CHANGE_DELAY_MS);
  }

  blurred(text: () => string) {
    if (!this.editedSinceLoad) return;
    this.cancel();
    this.post({ type: "saveNow", text: text() });
  }

  get pending(): boolean {
    return this.timer !== null;
  }

  private cancel() {
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
  }
}
