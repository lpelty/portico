"""The app and the gateway agree on which extensions are plain text.

The gateway marks these files `text`; the app maps the same extensions to
`text` itself (for files opened from the Files pane, and for an older
gateway that called them `other`). The two lists are kept by hand, so this
reads both and compares them.
"""

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SWIFT = REPO / "app/Sources/Portico/Model/AppModel.swift"
PYTHON = REPO / "gateway/portico_gateway/artifacts.py"


def _swift_extensions() -> set[str]:
    source = SWIFT.read_text(encoding="utf-8")
    match = re.search(r"static let textExtensions: Set<String> = \[(.*?)\]", source, re.S)
    assert match, "Media.textExtensions not found in AppModel.swift"
    return set(re.findall(r'"([^"]+)"', match.group(1)))


def _python_extensions() -> set[str]:
    source = PYTHON.read_text(encoding="utf-8")
    match = re.search(r"TEXT_EXTENSIONS: tuple\[str, \.\.\.\] = \((.*?)\)", source, re.S)
    assert match, "TEXT_EXTENSIONS not found in artifacts.py"
    return {ext.lstrip(".") for ext in re.findall(r'"([^"]+)"', match.group(1))}


def test_app_and_gateway_text_extensions_match():
    swift, python = _swift_extensions(), _python_extensions()
    assert swift, "no extensions read from the app"
    assert swift == python, f"only in the app: {sorted(swift - python)}; only in the gateway: {sorted(python - swift)}"
    assert {"csv", "tsv"} <= swift
