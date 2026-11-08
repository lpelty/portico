"""The Pen check (v0.26, PORT-25): hex colours in Pen's UI frames are listed."""

import json
import sys
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parent))

from pen_tokens import hex_in_ui_frames, load_rules, main  # noqa: E402

REPO = Path(__file__).resolve().parents[1]


def test_hex_in_a_ui_frame_is_listed():
    pen = {"variables": {}, "children": [{"type": "frame", "id": "a", "name": "ZG1", "children": [
        {"type": "rectangle", "id": "r", "name": "Row", "fill": "#FFFFFF"}]}]}
    assert hex_in_ui_frames(pen) == ["ZG1 › Row (r): fill = #FFFFFF"]


def test_content_frames_and_variables_are_allowed():
    pen = {"variables": {}, "children": [{"type": "frame", "id": "a", "name": "ZB3", "children": [
        {"type": "frame", "id": "c", "name": "Content · Pricing page", "children": [
            {"type": "text", "id": "t", "name": "T", "fill": "#123456"}]},
        {"type": "rectangle", "id": "r", "name": "Row", "fill": "$window", "stroke": {"fill": "transparent"}}]}]}
    assert hex_in_ui_frames(pen) == []


def test_nested_values_are_found_with_their_path():
    pen = {"children": [{"type": "frame", "id": "a", "name": "ZF1b", "effect": {"color": "#00000066"},
                         "children": [{"id": "m", "name": "Mark", "fill": {"colors": [{"color": "#3b6fd8"}]}}]}]}
    assert hex_in_ui_frames(pen) == [
        "ZF1b › ZF1b (a): effect.color = #00000066",
        "ZF1b › Mark (m): fill.colors[0].color = #3b6fd8",
    ]


def test_history_rows_and_no_fill_are_exempt():
    # The controller's rules (design/token-check.json): only current rows are checked,
    # AS0 (the palette board) is not, and #00000000 is Pen's "no fill".
    pen = {"children": [
        {"type": "frame", "id": "h", "name": "A1 · Classic three-column", "fill": "#FFFFFF"},
        {"type": "frame", "id": "p", "name": "AS0 · Solid palette, was → now", "fill": "#FFFFFF"},
        {"type": "frame", "id": "z", "name": "ZG1 · Labs", "fill": "#00000000"},
    ]}
    assert hex_in_ui_frames(pen) == []


def test_rules_come_from_the_config_file():
    rules = load_rules()
    assert rules["content_frame_prefix"] == "Content · "
    assert "ZG" in rules["checked_frame_prefixes"] and "AS1" in rules["checked_frame_prefixes"]
    custom = {"content_frame_prefix": "Content · ", "checked_frame_prefixes": [], "allowed_values": []}
    pen = {"children": [{"type": "frame", "id": "h", "name": "A1", "fill": "#00000000"}]}
    assert hex_in_ui_frames(pen, custom) == ["A1 › A1 (h): fill = #00000000"]


def test_main_prints_and_fails_on_any(tmp_path, capsys):
    path = tmp_path / "x.pen"
    path.write_text(json.dumps({"children": [{"id": "a", "name": "ZG1", "fill": "#FFFFFF"}]}))
    assert main([str(path)]) == 1
    assert "ZG1 › ZG1 (a): fill = #FFFFFF" in capsys.readouterr().out
    path.write_text(json.dumps({"children": [{"id": "a", "name": "ZG1", "fill": "$window"}]}))
    assert main([str(path)]) == 0


def test_the_design_file_has_no_hex_in_ui_frames():
    pen = json.loads((REPO / "design" / "portico.pen").read_text(encoding="utf-8"))
    assert hex_in_ui_frames(pen) == []
