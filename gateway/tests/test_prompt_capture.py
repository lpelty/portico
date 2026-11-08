"""v0.24 §3: ``capture-prompt`` copies Claude Code's prompt as the start of a custom one.

A fake ``query`` stands in for the engine: it writes request bodies where
``OTEL_LOG_RAW_API_BODIES`` points, as Claude Code does. No model is called,
and the text is invented.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

import pytest

from portico_gateway import REPO_ROOT
from portico_gateway.engine import HEADER_RE, MARKER_PREFIX, custom_prompt_text
from portico_gateway.prompt_capture import CaptureError, capture_prompt, mark_machine_lines, system_text

SHORT = "Name this conversation."
LONG_LINES = ["You are a careful helper for a made-up shop.", "Keep answers short.", "Be kind to customers."]
seen: dict[str, Any] = {}


def fake_query(write: bool = True):  # noqa: ANN201
    async def query(*, prompt: str, options: Any):  # noqa: ANN202
        seen["prompt"] = prompt
        seen["options"] = options
        logdir = Path(options.env["OTEL_LOG_RAW_API_BODIES"].removeprefix("file:"))
        seen["logdir"] = logdir
        if write:
            logdir.mkdir(parents=True, exist_ok=True)
            (logdir / "a.request.json").write_text(json.dumps({"model": "small", "system": SHORT}))
            long_system = [{"type": "text", "text": "\n".join(LONG_LINES)}, {"type": "text", "text": f"Working folder: {options.cwd}"}]
            (logdir / "b.request.json").write_text(json.dumps({"model": "big", "system": long_system, "messages": []}))
            (logdir / "b.response.json").write_text(json.dumps({"content": []}))
        yield {"type": "result"}

    return query


def _capture(tmp_path: Path, out: Path | None = None, write: bool = True) -> Path:
    return asyncio.run(
        capture_prompt(tmp_path / "state", [], out, query=fake_query(write), version=lambda: "9.9.1", today="2026-11-07")
    )


def test_writes_the_longest_system_with_header(tmp_path: Path) -> None:
    out = _capture(tmp_path, tmp_path / "copy.md")
    lines = out.read_text(encoding="utf-8").splitlines()
    header = HEADER_RE.match(lines[0])
    assert header and header.group("version") == "9.9.1" and header.group("model") == "big" and header.group("date") == "2026-11-07"
    body = custom_prompt_text(out.read_text(encoding="utf-8"))
    assert body.startswith("\n".join(LONG_LINES))
    assert SHORT not in body


def test_machine_lines_are_marked(tmp_path: Path) -> None:
    out = _capture(tmp_path, tmp_path / "copy.md")
    lines = out.read_text(encoding="utf-8").splitlines()
    i = next(n for n, line in enumerate(lines) if line.startswith("Working folder:"))
    assert lines[i - 1].startswith(MARKER_PREFIX)
    assert not any(lines[n - 1].startswith(MARKER_PREFIX) for n, line in enumerate(lines) if line in LONG_LINES)


def test_mark_machine_lines() -> None:
    text = mark_machine_lines("plain\nmemory at /home/me/x\nend", ["/home/me"])
    assert text.splitlines()[1].startswith(MARKER_PREFIX) and text.splitlines()[2] == "memory at /home/me/x"


def test_system_text_shapes() -> None:
    assert system_text({"system": "Just text."}) == "Just text."
    assert system_text({"system": [{"type": "text", "text": "A"}, {"type": "text", "text": "B"}]}) == "A\n\nB"
    assert system_text({"not_recorded": "withheld"}) is None


def test_runs_one_minimal_request_in_a_scratch_folder(tmp_path: Path) -> None:
    _capture(tmp_path, tmp_path / "copy.md")
    options = seen["options"]
    assert options.max_turns == 1 and options.setting_sources == []
    assert options.system_prompt == {"type": "preset", "preset": "claude_code"}
    assert not Path(options.cwd).exists(), "the scratch folder is removed"
    assert not seen["logdir"].exists(), "the temporary logs are deleted"


def test_default_out_under_state_prompts(tmp_path: Path) -> None:
    out = _capture(tmp_path)
    assert out == tmp_path / "state" / "prompts" / "claude-code-9.9.1.md" and out.is_file()


def test_refuses_inside_checkout(tmp_path: Path) -> None:
    with pytest.raises(CaptureError) as e:
        _capture(tmp_path, REPO_ROOT / "captured.md")
    assert "never writes inside the checkout" in str(e.value)
    assert not (REPO_ROOT / "captured.md").exists()


def test_refuses_existing_out(tmp_path: Path) -> None:
    out = tmp_path / "copy.md"
    out.write_text("my edits", encoding="utf-8")
    with pytest.raises(CaptureError) as e:
        _capture(tmp_path, out)
    assert "exists" in str(e.value)
    assert out.read_text(encoding="utf-8") == "my edits"


def test_nothing_logged_changes_nothing(tmp_path: Path) -> None:
    out = tmp_path / "copy.md"
    with pytest.raises(CaptureError) as e:
        _capture(tmp_path, out, write=False)
    assert "Capture isn't possible" in str(e.value) and "Nothing was written" in str(e.value)
    assert not out.exists()
    assert not seen["logdir"].exists()


def test_cli_reports_failure_exit_1(tmp_path: Path, capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch) -> None:
    import portico_gateway.prompt_capture as pc
    from portico_gateway.__main__ import main

    monkeypatch.setattr(pc, "DEFAULT_QUERY", fake_query(write=False))
    monkeypatch.setattr(pc, "DEFAULT_VERSION", lambda: "9.9.1")
    assert main(["capture-prompt", "--state", str(tmp_path / "state"), "--out", str(tmp_path / "x.md")]) == 1
    assert "Capture isn't possible" in capsys.readouterr().err


def test_cli_writes_and_prints_the_path(tmp_path: Path, capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch) -> None:
    import portico_gateway.prompt_capture as pc
    from portico_gateway.__main__ import main

    monkeypatch.setattr(pc, "DEFAULT_QUERY", fake_query())
    monkeypatch.setattr(pc, "DEFAULT_VERSION", lambda: "9.9.1")
    out = tmp_path / "x.md"
    assert main(["capture-prompt", "--state", str(tmp_path / "state"), "--out", str(out)]) == 0
    printed = capsys.readouterr().out
    assert str(out) in printed and out.is_file()


def test_billing_header_blocks_are_dropped() -> None:
    body = {"system": [{"type": "text", "text": "x-anthropic-billing-header: cc_version=9; cch=00;"}, {"type": "text", "text": "Real invented text."}]}
    assert system_text(body) == "Real invented text."
    assert system_text({"system": "x-anthropic-billing-header: a\nKept line."}) == "Kept line."
    assert system_text({"system": [{"type": "text", "text": "  x-anthropic-billing-header: only"}]}) is None


def test_unknown_version_writes_no_version(tmp_path: Path) -> None:
    from portico_gateway.engine import prompt_header_version

    out = asyncio.run(
        capture_prompt(tmp_path / "state", [], tmp_path / "c.md", query=fake_query(), version=lambda: None, today="2026-11-07")
    )
    first = out.read_text(encoding="utf-8").splitlines()[0]
    assert "unknown" in first and "vunknown" not in first and not HEADER_RE.match(first)
    assert prompt_header_version(out) is None
