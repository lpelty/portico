"""v0.3: the command line beyond ``run`` — ``config-value``, ``stop``, ``status``, ``update``.

``config-value`` and the ``update`` commands are driven through ``main``
in-process; ``stop`` and ``status`` against a real gateway process on a
throwaway state directory (no model: no chat is ever opened).
"""

from __future__ import annotations

from pathlib import Path

import pytest

from portico_gateway.__main__ import main


def write_config(home: Path, text: str) -> Path:
    home.mkdir(parents=True, exist_ok=True)
    path = home / "config.toml"
    path.write_text(text, encoding="utf-8")
    return path


# --- config-value ----------------------------------------------------------------


def test_config_value_prints_the_value_or_nothing(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    home = tmp_path / "home"
    write_config(home, '[brand]\nname = "ethOS"\nagent_name = "Atlas"\napp_icon = "/icons/ethos.png"\n')
    assert main(["config-value", "brand.name", "--state", str(home)]) == 0
    assert capsys.readouterr().out == "ethOS\n"
    assert main(["config-value", "brand.app_icon", "--state", str(home)]) == 0
    assert capsys.readouterr().out == "/icons/ethos.png\n"
    assert main(["config-value", "brand.accent", "--state", str(home)]) == 0
    assert capsys.readouterr().out == ""
    assert main(["config-value", "nothing.here", "--state", str(home)]) == 0
    assert capsys.readouterr().out == ""


def test_config_value_without_a_config_file_prints_defaults(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    home = tmp_path / "home"
    home.mkdir()
    assert main(["config-value", "brand.name", "--state", str(home)]) == 0
    assert capsys.readouterr().out == "Portico\n"
    assert main(["config-value", "permission_mode", "--state", str(home)]) == 0
    assert capsys.readouterr().out == "auto\n"


def test_config_value_with_a_broken_config_says_why_and_exits_1(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    home = tmp_path / "home"
    write_config(home, "presentation = [\n")
    assert main(["config-value", "brand.name", "--state", str(home)]) == 1
    captured = capsys.readouterr()
    assert captured.out == "" and "not valid TOML" in captured.err
