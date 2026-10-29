"""v0.3: the command line beyond ``run`` — ``config-value``, ``stop``, ``status``, ``update``.

``config-value`` and the ``update`` commands are driven through ``main``
in-process; ``stop`` and ``status`` against a real gateway process on a
throwaway state directory (no model: no chat is ever opened).
"""

from __future__ import annotations

import asyncio
import contextlib
import io
import json
import os
import sys
from pathlib import Path

import pytest

from portico_gateway import REPO_ROOT
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


# --- stop and status against a real gateway ---------------------------------------


async def _spawn_gateway(home: Path) -> asyncio.subprocess.Process:
    env = {**os.environ, "PORTICO_HOME": str(home)}
    proc = await asyncio.create_subprocess_exec(
        sys.executable, "-m", "portico_gateway", "run",
        cwd=str(REPO_ROOT / "gateway"), env=env,
        stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    assert proc.stdout is not None
    ready = await asyncio.wait_for(proc.stdout.readline(), 30)
    assert ready.startswith(b"PORTICO_READY port="), ready
    return proc


async def cli(*argv: str) -> tuple[int, str]:
    """``main(argv)`` in a thread (it blocks), with its stdout."""
    buf = io.StringIO()

    def run() -> int:
        with contextlib.redirect_stdout(buf):
            return main(list(argv))

    code = await asyncio.to_thread(run)
    return code, buf.getvalue()


async def test_status_and_stop_with_and_without_a_gateway(tmp_path: Path) -> None:
    home = tmp_path / "home"
    marker = tmp_path / "stopped.txt"
    config = write_config(home, f'on_stop = "echo stopped > {marker}"\n')

    code, out = await cli("status", "--json", "--state", str(home))
    assert code == 3 and json.loads(out) == {"version": 1, "running": False}
    code, out = await cli("stop", "--state", str(home))
    assert code == 3 and "no gateway running" in out

    proc = await _spawn_gateway(home)
    try:
        code, out = await cli("status", "--json", "--state", str(home))
        status = json.loads(out)
        assert code == 0
        assert status["version"] == 1 and status["running"] is True
        assert status["pid"] == proc.pid and isinstance(status["port"], int)
        assert status["config_stale"] is False and status["started_at"].endswith("Z")
        assert "session" not in status and "folder" not in status  # no session yet: left out, not guessed
        code, out = await cli("status", "--state", str(home))
        assert code == 0 and out.startswith(f"gateway running: pid {proc.pid}")

        # The config changes after the start: status and the doctor say so.
        later = config.stat().st_mtime + 5
        os.utime(config, (later, later))
        code, out = await cli("status", "--json", "--state", str(home))
        assert json.loads(out)["config_stale"] is True
        code, out = await cli("status", "--state", str(home))
        assert "restart the gateway to apply" in out
        from portico_gateway.doctor import check_gateway_config
        from portico_gateway.state import StateDir

        check = check_gateway_config(StateDir(home))
        assert check.ok and check.warn and "restart the gateway to apply" in check.line

        code, out = await cli("stop", "--state", str(home))
        assert code == 0 and f"pid {proc.pid}" in out
        await asyncio.wait_for(proc.wait(), 30)
        assert proc.returncode == 0
        assert marker.read_text().strip() == "stopped", "the gateway's own stop path ran (on_stop)"
    finally:
        if proc.returncode is None:
            proc.kill()
            await proc.wait()

    code, out = await cli("status", "--json", "--state", str(home))
    assert code == 3 and json.loads(out)["running"] is False
    code, _ = await cli("stop", "--state", str(home))
    assert code == 3
