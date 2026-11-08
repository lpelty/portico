"""v0.24 §2: ``config.local.toml`` beside ``config.toml``, the person's own overrides.

Tables merge key by key; any other value (arrays included) replaces the
deployment's. The merged result is validated as ``config.toml`` is, and an
error from the local file names it.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from portico_gateway.config import (
    LOCAL_CONFIG_NAME,
    ConfigError,
    load_config,
    local_config_path,
    merge_tables,
    read_config_layers,
)
from portico_gateway.doctor import check_config


def _write(folder: Path, base: str | None, local: str | None) -> Path:
    path = folder / "config.toml"
    if base is not None:
        path.write_text(base, encoding="utf-8")
    if local is not None:
        (folder / LOCAL_CONFIG_NAME).write_text(local, encoding="utf-8")
    return path


def test_local_path_is_the_sibling(tmp_path: Path) -> None:
    assert local_config_path(tmp_path / "config.toml") == tmp_path / "config.local.toml"


def test_local_overrides_a_key(tmp_path: Path) -> None:
    path = _write(tmp_path, 'titles = "generated"\n', 'titles = "first_line"\n')
    assert load_config(path).titles == "first_line"


def test_tables_merge_key_by_key(tmp_path: Path) -> None:
    path = _write(tmp_path, '[brand]\nname = "Acme"\nagent_name = "Ace"\n', '[brand]\naccent = "#112233"\n')
    brand = load_config(path).brand
    assert (brand.name, brand.agent_name, brand.accent) == ("Acme", "Ace", "#112233")


def test_arrays_replace(tmp_path: Path) -> None:
    base = (
        '[[services]]\nid = "a"\nname = "A"\ncheck = "true"\n'
        '[[services]]\nid = "b"\nname = "B"\ncheck = "true"\n'
    )
    local = '[[services]]\nid = "c"\nname = "C"\ncheck = "true"\n'
    path = _write(tmp_path, base, local)
    assert [s.id for s in load_config(path).services] == ["c"]


def test_merge_tables_is_recursive_and_does_not_mutate() -> None:
    base = {"a": {"b": {"c": 1, "d": 2}}, "l": [1, 2]}
    local = {"a": {"b": {"d": 3}}, "l": [9]}
    assert merge_tables(base, local) == {"a": {"b": {"c": 1, "d": 3}}, "l": [9]}
    assert base == {"a": {"b": {"c": 1, "d": 2}}, "l": [1, 2]}


def test_local_alone_without_config_toml(tmp_path: Path) -> None:
    path = _write(tmp_path, None, 'titles = "first_line"\n')
    assert load_config(path).titles == "first_line"


def test_local_error_names_the_file(tmp_path: Path) -> None:
    path = _write(tmp_path, "", 'system_prompt_append = "/nope/missing.md"\n')
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert str(e.value).startswith("config.local.toml: system_prompt_append: ")
    assert "is not a file" in str(e.value)


def test_local_type_error_names_the_file(tmp_path: Path) -> None:
    path = _write(tmp_path, "", "history_buffer = 0\n")
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert str(e.value).startswith("config.local.toml: ")
    assert "history_buffer" in str(e.value)


def test_local_not_toml_is_named(tmp_path: Path) -> None:
    path = _write(tmp_path, "", "titles = \n")
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert "config.local.toml" in str(e.value) and "not valid TOML" in str(e.value)


def test_base_error_text_unchanged(tmp_path: Path) -> None:
    path = _write(tmp_path, 'system_prompt_append = "/nope/missing.md"\n', None)
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert str(e.value) == "system_prompt_append: /nope/missing.md is not a file"


def test_source_of(tmp_path: Path) -> None:
    path = _write(tmp_path, '[brand]\nname = "Acme"\n', '[brand]\naccent = "#112233"\n')
    layers = read_config_layers(path)
    assert layers.source_of("brand.name") == "config.toml"
    assert layers.source_of("brand.accent") == "config.local.toml"
    assert layers.source_of("titles") == "default"


def test_source_names_a_config_flag_file_by_its_name(tmp_path: Path) -> None:
    path = tmp_path / "deploy.toml"
    path.write_text('titles = "first_line"\n', encoding="utf-8")
    assert read_config_layers(path).source_of("titles") == "deploy.toml"


def test_doctor_reports_bad_local_file(tmp_path: Path) -> None:
    path = _write(tmp_path, "", "titles = \n")
    check = check_config(path)
    assert not check.ok and "config.local.toml" in check.line


def test_doctor_says_the_local_file_loads(tmp_path: Path) -> None:
    path = _write(tmp_path, "", 'titles = "first_line"\n')
    check = check_config(path)
    assert check.ok and "config.local.toml" in check.line
