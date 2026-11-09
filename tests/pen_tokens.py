"""List hex colours in the Pen file's UI frames (v0.26, PORT-25).

Every UI colour in `design/portico.pen` is a `$variable`. This walks the
file's frames and lists any value that is a hex colour, except where
`design/token-check.json` allows it:

- inside a frame (at any depth) whose name starts with `content_frame_prefix`
  (depicted content: a web page, a phone, an image);
- in a top-level frame whose name starts with none of `checked_frame_prefixes`
  (earlier rows are history snapshots; the palette board shows hex on purpose);
- a value in `allowed_values` (`#00000000` is how Pen stores "no fill").

Stdlib only. Run: `python3 tests/pen_tokens.py design/portico.pen`.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[1]
RULES = REPO / "design" / "token-check.json"
HEX = re.compile(r"^#[0-9A-Fa-f]{3,8}$")


def load_rules(path: Path = RULES) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _values(value: Any, path: str):
    """Every (key path, string) under a node's property, nested objects and lists included."""
    if isinstance(value, str):
        yield path, value
    elif isinstance(value, dict):
        for key, inner in value.items():
            yield from _values(inner, f"{path}.{key}")
    elif isinstance(value, list):
        for index, inner in enumerate(value):
            yield from _values(inner, f"{path}[{index}]")


def hex_in_ui_frames(pen: dict, rules: dict[str, Any] | None = None) -> list[str]:
    """One line per hex value in a UI frame:
    `"<top-level frame name> › <node name> (<id>): <key path> = <value>"`."""
    rules = load_rules() if rules is None else rules
    content = rules.get("content_frame_prefix", "Content · ")
    checked = tuple(rules.get("checked_frame_prefixes", ()))
    allowed = {v.upper() for v in rules.get("allowed_values", ())}
    out: list[str] = []

    def walk(node: dict, top: str) -> None:
        if str(node.get("name", "")).startswith(content):
            return
        for key, value in node.items():
            if key == "children":
                continue
            for path, text in _values(value, key):
                if HEX.match(text) and text.upper() not in allowed:
                    out.append(f"{top} › {node.get('name', '')} ({node.get('id', '')}): {path} = {text}")
        for child in node.get("children") or []:
            if isinstance(child, dict):
                walk(child, top)

    for frame in pen.get("children") or []:
        if not isinstance(frame, dict):
            continue
        name = str(frame.get("name", ""))
        if checked and not name.startswith(checked):
            continue
        walk(frame, name)
    return out


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    path = Path(argv[0]) if argv else REPO / "design" / "portico.pen"
    lines = hex_in_ui_frames(json.loads(path.read_text(encoding="utf-8")))
    for line in lines:
        print(line)
    return 1 if lines else 0


if __name__ == "__main__":
    sys.exit(main())
