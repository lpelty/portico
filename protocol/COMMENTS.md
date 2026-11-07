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
- Anchored text is snapped to whole words at both ends. A word character is a Unicode letter, digit or `_`, plus `'` or `’` between two of them.

## The thread block

```
<!--co:k3x9a by:"Sam Rivera" at:2026-11-07T18:38:26.176Z status:open quote:"writes files"
Sam Rivera (2026-11-07T18:38:26.176Z): Which files?
Agent (2026-11-07T18:40:00.000Z): The ones in this folder.
+👍 Sam Rivera
-->
```

- **Where it goes.** On its own lines, after the top-level block that contains the anchor: after the whole paragraph, list or blockquote (not between two list items, which would split the list), and after any thread blocks already there. Readers accept a block anywhere outside code.
- **The header** is `<!--co:ID` followed by `key:value` fields:
  - `by` — the first comment's author; `at` — when it was made, UTC, ISO 8601 with milliseconds and `Z`; `status` — `open` or `resolved`; `quote` — the anchored text when the comment was made, as a reader saw it (no markers; a line break and the next line's indent or `>` prefix become one space).
  - A value is written in double quotes when it contains a space; `quote` is always quoted. Inside quotes, `"` is written `\"`, and a newline as a space.
  - Writers use the order `by`, `at`, `status`, `quote`. Unknown fields are kept.
  - A header that ends with `-->` is a thread with no replies.
- **Thread lines**, up to the closing `-->`:
  - A line matching `^(.*?)(?:\s\(([^)]*)\))?:\s?(.*)$` whose name (group 1, trimmed) is non-empty is a new reply: `Author (time): text`. Any parenthetical is accepted as the time (`2026-10-17` occurs in real files).
  - A line starting with `+` is a reaction (`+EMOJI Name, Name`). v1 readers keep reactions; showing them is optional.
  - Any other non-blank line continues the previous reply's text, after a line break.
- **Authors are real names.** Writers never write `me`; a `by:me` already in a file is shown as written.

## Text that would break the format

- `-->` inside a `quote` or a reply is written `--\>`, and read back as `-->`.
- A continuation line starting with `\` is never a reply: the `\` is dropped and the rest is text. Writers put a leading `\` on any continuation line that would otherwise read as a reply (it contains a colon after a name, as in `Note: …` or a URL), that starts with `+` or `\`, or that is blank (a lone `\`).

## Ignored regions

Markup inside front matter, fenced code blocks (```` ``` ```` and `~~~`) and inline code spans is not a comment.

## Orphans

- A thread block whose anchors are missing is a thread with no anchor; it is shown with "Text no longer found".
- Anchors with no thread block are ignored, and are removed the next time the file is written by a comment action.

## Round trip

Every write is a splice of the touched anchors and block. Reading a file and writing it back with no change to its comments leaves its bytes unchanged. Line endings follow the file's (CRLF when its first line break is CRLF), and a file without a final newline keeps none.

## Finding text to anchor

A quote (from the agent's `comment_add`, or the person's selection) is matched against the file as a reader sees it:

- existing comment markers are invisible;
- `>` prefixes on wrapped lines, and indentation, count as whitespace;
- whitespace runs compare equal;
- the match must lie in one paragraph (no blank line inside it), outside ignored regions and thread blocks.
