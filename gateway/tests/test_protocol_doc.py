"""PROTOCOL.md says what v0.24 changed on the wire (v0.24 §11.4, sweep #15 and #16).

App authors read the protocol reference, not the gateway's source, so the
two v0.24 facts must be in the sections that describe them.
"""

from __future__ import annotations

import re
from pathlib import Path

PROTOCOL = Path(__file__).resolve().parents[2] / "protocol" / "PROTOCOL.md"


def _section(heading: str) -> str:
    """The text under the ``###`` heading that starts with ``heading``, up to the next heading."""
    text = PROTOCOL.read_text(encoding="utf-8")
    match = re.search(rf"^### {re.escape(heading)}.*?$(.*?)(?=^#{{1,4}} )", text, re.M | re.S)
    assert match, f"no section {heading!r} in PROTOCOL.md"
    return " ".join(match.group(1).split())


def test_config_stale_names_both_config_files() -> None:
    section = _section("`config.stale`")
    assert "config.toml" in section and "config.local.toml" in section, section


def test_the_cli_watch_names_both_config_files() -> None:
    text = " ".join(PROTOCOL.read_text(encoding="utf-8").split())
    watch = text[text.index("The running gateway also checks for updates itself") :][:900]
    assert "config.local.toml" in watch, watch


def test_hello_config_stale_names_both_config_files() -> None:
    section = _section("`hello` — `HelloServer`")
    stale = section[section.index("`config_stale: bool`") :][:400]
    assert "config.local.toml" in stale, stale


def test_hello_documents_voice() -> None:
    section = _section("`hello` — `HelloServer`")
    assert "`voice?: {read_aloud: bool}`" in section, "hello's v0.24 voice field"
    assert "[voice] read_aloud" in section


def test_config_toml_appearing_is_named_too() -> None:
    # Review N2: ``_stale_file`` also fires when config.toml appears after being absent at start.
    assert "or it appeared" in _section("`config.stale`")
    hello = _section("`hello` — `HelloServer`")
    assert "or appeared" in hello[hello.index("`config_stale: bool`") :][:400]
    text = " ".join(PROTOCOL.read_text(encoding="utf-8").split())
    assert "or appeared" in text[text.index("The running gateway also checks for updates itself") :][:900]
