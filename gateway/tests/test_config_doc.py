"""v0.24 §5–6: the key docs, ``config show``, ``CONFIGURATION.md`` and ``config.example.toml``."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import portico_gateway.config_doc as cd
from portico_gateway.__main__ import main
from portico_gateway.config import LOCAL_CONFIG_NAME, load_config, read_config_layers


def _files(tmp_path: Path, base: str, local: str | None = None) -> Path:
    path = tmp_path / "config.toml"
    path.write_text(base, encoding="utf-8")
    if local is not None:
        (tmp_path / LOCAL_CONFIG_NAME).write_text(local, encoding="utf-8")
    return path


def _rows(path: Path) -> list[cd.ShowRow]:
    return cd.show_rows(read_config_layers(path), load_config(path))


def test_every_model_key_is_documented_and_no_extra() -> None:
    assert set(cd.model_keys()) == set(cd.KEY_DOCS)


def test_every_section_is_ordered() -> None:
    assert {cd.section_of(k) for k in cd.model_keys()} <= set(cd.SECTION_ORDER)


def test_show_lists_value_and_source(tmp_path: Path) -> None:
    path = _files(tmp_path, '[brand]\nname = "Acme"\nagent_name = "Ace"\n', '[brand]\naccent = "#112233"\n')
    text = cd.format_show(_rows(path))
    assert 'brand.name = "Acme"  [config.toml]  (gateway restart)' in text
    assert 'brand.accent = "#112233"  [config.local.toml]' in text
    assert 'titles = "generated"  [default]' in text
    assert text.index("[general]") < text.index("[brand]") < text.index("[voice]")


def test_changed_only(tmp_path: Path) -> None:
    path = _files(tmp_path, "", "[voice]\nread_aloud = true\n")
    text = cd.format_show(_rows(path), changed=True)
    assert text.splitlines() == ["[voice]", "voice.read_aloud = true  [config.local.toml]  (gateway restart (the app follows when it reconnects))"]
    empty = tmp_path / "empty"
    empty.mkdir()
    assert cd.format_show(_rows(_files(empty, "")), changed=True) == "every key is at its default"


def test_json_matches(tmp_path: Path) -> None:
    path = _files(tmp_path, 'titles = "first_line"\n')
    rows = cd.rows_json(_rows(path))
    titles = next(r for r in rows if r["key"] == "titles")
    assert titles == {
        "key": "titles", "section": "general", "value": "first_line", "default": "generated",
        "source": "config.toml", "applies": "gateway restart", "note": "",
    }
    assert [r["key"] for r in cd.rows_json(_rows(path), changed=True)] == ["titles"]


def test_sensitive_shows_set(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(cd.KEY_DOCS, "update.run", cd.KeyDoc("x", "run = 'x'", sensitive=True))
    path = _files(tmp_path, '[update]\nrun = "deploy --token abc123"\n')
    rows = _rows(path)
    text = cd.format_show(rows)
    assert "abc123" not in text and "update.run = (set)" in text
    assert "update.check = (not set)" in text
    assert "abc123" not in json.dumps(cd.rows_json(rows))


def test_system_prompt_note_names_file_and_version(tmp_path: Path) -> None:
    prompt = tmp_path / "mine.md"
    prompt.write_text("<!-- captured from Claude Code 9.9.1 · model m · 2026-11-07 -->\nInvented.", encoding="utf-8")
    path = _files(tmp_path, "", f'system_prompt = "custom"\nsystem_prompt_file = "{prompt}"\n')
    row = next(r for r in _rows(path) if r.key == "system_prompt")
    assert row.note == f"file {prompt} (captured from Claude Code 9.9.1)"
    assert "next new or renewed session" in row.applies and "until it compacts" in row.applies
    plain = tmp_path / "plain"
    plain.mkdir()
    other = _files(plain, f'system_prompt_file = "{prompt}"\n')
    file_row = next(r for r in _rows(other) if r.key == "system_prompt_file")
    assert file_row.note == 'ignored unless system_prompt = "custom"'


def test_cli_config_show_needs_no_gateway(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    _files(tmp_path, 'titles = "first_line"\n')
    assert main(["config", "show", "--state", str(tmp_path)]) == 0
    assert 'titles = "first_line"  [config.toml]' in capsys.readouterr().out
    assert main(["config", "show", "--changed", "--json", "--state", str(tmp_path)]) == 0
    assert [r["key"] for r in json.loads(capsys.readouterr().out)] == ["titles"]


def test_cli_config_show_reports_a_bad_file(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    _files(tmp_path, "", "titles = \n")
    assert main(["config", "show", "--state", str(tmp_path)]) == 1
    assert "config.local.toml" in capsys.readouterr().err


# --- §6: the generated reference and template -------------------------------------

from portico_gateway import REPO_ROOT  # noqa: E402


def test_configuration_md_is_current() -> None:
    assert (REPO_ROOT / "CONFIGURATION.md").read_text(encoding="utf-8") == cd.render_markdown(), (
        "CONFIGURATION.md is out of date: run bin/portico-gateway export-config-doc"
    )


def test_example_toml_is_current() -> None:
    assert (REPO_ROOT / "config.example.toml").read_text(encoding="utf-8") == cd.render_example(), (
        "config.example.toml is out of date: run bin/portico-gateway export-config-doc"
    )


def test_every_key_is_in_the_reference_with_its_parts() -> None:
    text = cd.render_markdown()
    for key, doc in cd.KEY_DOCS.items():
        assert f"`{key}`" in text, key
        assert doc.applies in text
    for word in ("Type", "Default", "Example", "Applies", "Belongs in"):
        assert word in text


def test_example_toml_uncommented_loads_at_the_defaults(tmp_path: Path) -> None:
    """Every key line is commented out at its default; uncommenting the scalar ones still loads as defaults."""
    import tomllib

    lines = []
    for line in cd.render_example().splitlines():
        if line.startswith("# [[") or line.startswith("#   "):
            continue  # a list-of-tables sample stays a comment
        if line.startswith("# ") and ("=" in line or line.startswith("# [")) and not line.startswith("# #"):
            line = line[2:]
        if line.startswith("#"):
            continue
        lines.append(line)
    data = tomllib.loads("\n".join(lines))
    path = tmp_path / "config.toml"
    path.write_text("\n".join(lines), encoding="utf-8")
    assert load_config(path) == load_config(tmp_path / "absent.toml")
    assert data["system_prompt"] == "claude_code"


def test_intro_says_local_first() -> None:
    intro = cd.render_markdown().split("## General", 1)[0]
    assert "config.local.toml" in intro and "config show" in intro
    assert "never edit `config.toml` for a personal preference" in intro.lower() or "Never edit `config.toml` for a personal preference" in intro
    assert ".gitignore" in intro


def test_export_config_doc_writes_both(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["export-config-doc", "--out", str(tmp_path)]) == 0
    assert (tmp_path / "CONFIGURATION.md").read_text(encoding="utf-8") == cd.render_markdown()
    assert (tmp_path / "config.example.toml").read_text(encoding="utf-8") == cd.render_example()
