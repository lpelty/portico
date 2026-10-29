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


# --- update -------------------------------------------------------------------------


def test_update_check_exit_codes(tmp_path: Path, capfd: pytest.CaptureFixture[str]) -> None:
    home = tmp_path / "home"
    write_config(home, "")
    assert main(["update", "--check", "--state", str(home)]) == 2
    assert "no update check configured" in capfd.readouterr().err

    write_config(home, '[update]\ncheck = "echo checking >&2; echo; echo 0.3.1"\n')
    assert main(["update", "--check", "--state", str(home)]) == 0
    assert capfd.readouterr().out == "0.3.1\n"

    write_config(home, '[update]\ncheck = "exit 1"\n')
    assert main(["update", "--check", "--state", str(home)]) == 1
    assert capfd.readouterr().out == ""

    write_config(home, '[update]\ncheck = "true"\n')  # exit 0 but no version: none
    assert main(["update", "--check", "--state", str(home)]) == 1


async def test_update_stops_the_gateway_then_streams_the_run_and_exits_with_its_code(
    tmp_path: Path, capfd: pytest.CaptureFixture[str]
) -> None:
    home = tmp_path / "home"
    write_config(home, "")
    assert await asyncio.to_thread(main, ["update", "--state", str(home)]) == 2
    assert "no update command configured" in capfd.readouterr().err

    write_config(home, '[update]\nrun = "echo updating; echo to stderr >&2; exit 7"\n')
    proc = await _spawn_gateway(home)
    try:
        code = await asyncio.to_thread(main, ["update", "--state", str(home)])
        assert code == 7
        out = capfd.readouterr().out
        assert f"stopped the gateway (pid {proc.pid})" in out
        assert "updating" in out and "to stderr" in out
        await asyncio.wait_for(proc.wait(), 30)
        assert proc.returncode == 0
    finally:
        if proc.returncode is None:
            proc.kill()
            await proc.wait()

    # No gateway running: the update just runs.
    write_config(home, '[update]\nrun = "echo done"\n')
    assert await asyncio.to_thread(main, ["update", "--state", str(home)]) == 0
    assert "done" in capfd.readouterr().out
