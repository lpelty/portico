# Comment format v1

Comments are stored inline in a Markdown (`.md`) file as HTML comments, so they travel with the file, render as nothing in any Markdown viewer, and are plain text an agent can read. Version 1 is the same as the Obsidian **Document Comments** plugin's format at its v0.1.5. If that plugin changes, this format doesn't follow; a reader of v1 always shows comments written in v1.

The shared fixtures in [`examples/comments/`](examples/comments/) (`cases.json` and the files it names) are the executable definition. The gateway (Python), the app (Swift) and the editor (TypeScript) are each tested against them.

## Anchors

```
The gateway <!--c:k3x9a-->writes files<!--/c:k3x9a--> atomically.
```

- `<!--c:ID-->` and `<!--/c:ID-->` go around the commented text, in the same paragraph or list item.
- `ID` is 5 characters from `[a-z0-9]`, unique in the file (against every `c:`, `/c:` and `co:` ID, even inside code). If 1,000 random draws all collide, use 8 characters. Readers accept 5 to 8.
- Anchors may nest: text already commented on can be commented on again.
- A person's selection is snapped to whole words at both ends (a word character is a Unicode letter, digit or `_`, plus `'` or `’` between two of them), except in scripts written without spaces between words (Chinese, Japanese, Thai, Lao, Khmer, Myanmar), where it is anchored as selected.
- An anchor never splits a grapheme cluster (a letter and its combining marks, an emoji with its skin tone or joined family, a flag). An agent's quote is anchored where it matches, its ends widened only to whole grapheme clusters.

## The thread block

```
<!--co:k3x9a by:"Sam Rivera" at:2026-11-07T18:38:26.176Z status:open quote:"writes files"
Sam Rivera (2026-11-07T18:38:26.176Z): Which files?
Agent (2026-11-07T18:40:00.000Z): The ones in this folder.
+👍 Sam Rivera
-->
```

- **Where it goes.** On its own lines, after the top-level block that contains the anchor: after the whole paragraph, list or blockquote (not between two list items, which would split the list), and after any thread blocks already there. Never inside a fenced or indented code block. Readers accept a block anywhere outside code.
  - The block ends as CommonMark ends a paragraph: at a blank line, or before a line that starts a fence, an ATX heading (`# …`), a thematic break, a blockquote (when not inside one), an HTML block (a line starting with an anchor marker is text, not HTML), a thread block, or a list item that may interrupt a paragraph. A setext underline (`===`, `---`) belongs to the paragraph above it.
  - Lazy continuation lines (`> a` then `lazy`) belong to the quote; a list continues past blank lines while the next line is indented or another item.
  - For `# Heading` followed directly by `Body`, an anchor in `Body` belongs to the body paragraph, and its block goes after it.
- **The header** is `<!--co:ID` followed by `key:value` fields:
  - `by` — the first comment's author; `at` — when it was made, UTC, ISO 8601 with milliseconds and `Z`; `status` — `open` or `resolved`; `quote` — the anchored text when the comment was made, as a reader saw it (no markers; a line break and the next line's indent or `>` prefix become one space).
  - Any value may be written in double quotes; readers accept quotes on every field (`status:"resolved"` is resolved). Writers quote a value that contains a space, a tab, `"`, `\` or `-->`; `quote` is always quoted.
  - Inside quotes, a newline is written as a space, then `\` as `\\`, `"` as `\"`, and `-->` as `--\>`. Reading, `\\`, `\"` and `\>` stand for `\`, `"` and `>`; any other backslash is itself.
  - When a key appears twice, the first one counts, for reading and for changing the status. A header with no `status` is open.
  - Writers use the order `by`, `at`, `status`, `quote`. Unknown fields are kept.
  - A header that ends with `-->` is a thread with no replies.
- **Thread lines**, up to the closing `-->`:
  - A line matching `^(.*?)(?:\s\(([^)]*)\))?:\s?(.*)$` whose name (group 1, trimmed) is non-empty is a new reply: `Author (time): text`. Any parenthetical is accepted as the time (`2026-10-17` occurs in real files).
  - A line starting with `+` is a reaction (`+EMOJI Name, Name`). v1 readers keep reactions; showing them is optional.
  - Any other non-blank line continues the previous reply's text, after a line break.
- **Authors are real names.** Writers never write `me`; a `by:me` already in a file is shown as written.
- **A colon in a name** (v0.25): on a reply line, writers write each `:` in the author as `∶` (U+2236 RATIO), so `Dr: Who` replies as `Dr∶ Who (time): text` and reads back whole; the header's `by:` keeps the name as given (quoted). Readers compare authors (whose comment is the person's own, the edit guard) after the same mapping on both sides. The `∶` is not turned back into `:` for display (v0.26, review N6, closed by design): reversing it would make a real `∶` and a `:` the same name in stored files.

## Text that would break the format

- In a `quote` (and any quoted value), see the header rules above.
- In a reply, one backslash is added between `--` and `>` wherever `--`, any number of backslashes and `>` occur, and one is removed when reading: `-->` is written `--\>`, and a literal `--\>` is written `--\\>`. So reading what was written always gives the text back.
- A continuation line starting with `\` is never a reply: the `\` is dropped and the rest is text. Writers put a leading `\` on any continuation line that would otherwise read as a reply (it contains a colon after a name, as in `Note: …` or a URL), that starts with `+` or `\`, or that is blank (a lone `\`).

## Editing and deleting

- Editing a comment replaces that comment's text (its reply line and continuation lines) and nothing else. Its author and its time stay as written: the format has no "edited" mark.
- Deleting a reply removes its lines. Deleting a thread's first comment deletes the thread: its block and both of its anchors.
- Reactions already in a block are kept by every edit.

## Table cells

- Text within one cell of a GFM table can be commented: the anchors go inside that cell's text, and the thread block goes after the whole table.
- A cell boundary (an unescaped `|`) and the delimiter row (`|---|:--:|`) are never inside a match, so a quote or selection can't span cells. An escaped pipe (`\|`) is text in its cell; an anchor never goes between its backslash and its pipe.
- Inline code in a cell is code: it can't be anchored.

## Ignored regions

Markup inside front matter, fenced code blocks (```` ``` ```` and `~~~`), indented code blocks and inline code spans is not a comment.

## Orphans

- A thread block whose anchors are missing is a thread with no anchor; it is shown with "Text no longer found".
- Anchors with no thread block are ignored, and are removed the next time the file is written by a comment action.

## Round trip

Every write is a splice of the touched anchors and block. Reading a file and writing it back with no change to its comments leaves its bytes unchanged. Line endings follow the file's (CRLF when its first line break is CRLF), and a file without a final newline keeps none.

## Finding text to anchor

A quote (from the agent's `comment_add`, or the person's selection) is matched against the file as a reader sees it, and only against text a reader sees:

- existing comment markers are invisible;
- link destinations and titles, the brackets around link text, whole images (alt text and address), HTML tags and comments, the angle brackets of autolinks, link reference definitions and thread blocks are not searched, and no match runs across them;
- text in code (inline, fenced or indented) and front matter can't be anchored;
- the `occurrence` of a match counts visible matches only;
- `>` prefixes on wrapped lines, and indentation, count as whitespace;
- whitespace runs compare equal;
- the match must lie in one paragraph (no blank line inside it), outside ignored regions and thread blocks;
- (v0.25) a match may not start or end inside an atom: an autolink with its angle brackets (`<https://…>`, `<name@host>`), a bare URL (`https://` or `http://` or `www.`, up to whitespace, `<` or `]`; v0.26: trailing `.,:;!?)]'"` left out, as GFM does) or an HTML entity (`&name;`, `&#123;`, `&#x1F;`). Whitespace here is exactly space, tab, line feed, carriage return, form feed and vertical tab, in every reader. Markers there would break the link or the entity. Such a match is refused ("inside a link or entity"), never widened, and it still counts as an occurrence. A match that covers a whole atom (a whole bare URL) is fine, and so is one that covers an autolink's address (v0.26: its brackets aren't shown, so they can't be quoted). Then the markers are written around the whole `<…>`, outside its brackets, so the link still renders; the header's `quote` stays the address.
