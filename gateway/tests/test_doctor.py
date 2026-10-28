"""Task 13: ``doctor`` — every check is one line, every failure says what and why.

Model-free. The checks read the state directory, the config file, the
environment and the process table; nothing here starts a gateway.
"""

from __future__ import annotations

import os
import socket
import stat
import sys
from pathlib import Path

import pytest

from portico_gateway.config import EMPTY_SETTING_SOURCES_MESSAGE
from portico_gateway.doctor import CREDENTIAL_PREFIXES, CREDENTIAL_VARS, Check, doctor, format_check, has_credential
from portico_gateway.state import StateDir

# --- fixtures -----------------------------------------------------------------


@pytest.fixture
def no_credential(monkeypatch: pytest.MonkeyPatch) -> None:
    """Strip every credential variable the gateway recognises."""
    for name in list(os.environ):
        if name in CREDENTIAL_VARS or any(name.startswith(p) for p in CREDENTIAL_PREFIXES):
            monkeypatch.delenv(name, raising=False)


@pytest.fixture
def with_credential(no_credential: None, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(CREDENTIAL_VARS[0], "not-a-real-value")


def dead_pid() -> int:
    """A pid nothing is running under right now."""
    pid = 99_000
    while pid > 1000:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return pid
        except PermissionError:
            pass
        pid -= 1
    raise RuntimeError("no free pid found")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def by_name(checks: list[Check]) -> dict[str, Check]:
    return {c.name: c for c in checks}


# --- tests --------------------------------------------------------------------


def test_doctor_reports_each_failure_in_one_line(state_dir: StateDir, no_credential: None, tmp_path: Path) -> None:
    state_dir.config_path.write_text("setting_sources = []\n", encoding="utf-8")
    state_dir.write_ledger(host="127.0.0.1", port=free_port(), pid=dead_pid(), epoch="e1")
    token_path = state_dir.token_path
    token_path.write_text("tok\n", encoding="ascii")
    token_path.chmod(0o644)
    env_path = state_dir.path / "env"
    env_path.write_text("KEY=value\n", encoding="utf-8")
    env_path.chmod(0o644)

    checks = doctor(state_dir, state_dir.config_path)
    got = by_name(checks)

    assert not got["credential"].ok
    assert "provider credential" in got["credential"].line
    assert not got["setting_sources"].ok
    assert got["setting_sources"].line.endswith(EMPTY_SETTING_SOURCES_MESSAGE)
    assert not got["config"].ok
    assert not got["ledger"].ok
    assert "stale ledger, will be rewritten" in got["ledger"].line
    assert not got["token"].ok
    assert "0644" in got["token"].line and "0600" in got["token"].line
    assert not got["env"].ok
    assert "0644" in got["env"].line and "0600" in got["env"].line

    for check in checks:
        assert "\n" not in check.line, check
        rendered = format_check(check)
        assert rendered.count("\n") == 0
        assert check.name in rendered
        assert rendered.startswith("ok  " if check.ok else "FAIL")


def test_doctor_is_green_on_a_clean_state_dir(state_dir: StateDir, with_credential: None) -> None:
    checks = doctor(state_dir, state_dir.config_path)
    got = by_name(checks)
    assert got["python"].ok, got["python"].line
    assert got["sdk"].ok and "0.2." in got["sdk"].line
    assert got["credential"].ok
    assert got["config"].ok and "defaults" in got["config"].line
    assert got["setting_sources"].ok and "project" in got["setting_sources"].line
    assert got["token"].ok  # absent is fine: written at launch
    assert got["env"].ok  # absent is fine: the credential comes from the shell
    assert got["ledger"].ok  # absent is fine: no gateway running
    # ``swift`` depends on the machine; only its line shape is asserted.
    assert got["swift"].line
    assert all(c.name for c in checks) and len({c.name for c in checks}) == len(checks)


def test_doctor_live_ledger_is_ok_when_pid_alive_and_port_listening(state_dir: StateDir, with_credential: None) -> None:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        state_dir.write_ledger(host="127.0.0.1", port=port, pid=os.getpid(), epoch="e1")
        got = by_name(doctor(state_dir, state_dir.config_path))
    assert got["ledger"].ok, got["ledger"].line
    assert str(port) in got["ledger"].line and str(os.getpid()) in got["ledger"].line


def test_doctor_ledger_port_not_listening_is_stale(state_dir: StateDir, with_credential: None) -> None:
    state_dir.write_ledger(host="127.0.0.1", port=free_port(), pid=os.getpid(), epoch="e1")
    got = by_name(doctor(state_dir, state_dir.config_path))
    assert not got["ledger"].ok
    assert "stale ledger, will be rewritten" in got["ledger"].line


def test_doctor_token_0600_is_ok(state_dir: StateDir, with_credential: None) -> None:
    state_dir.write_token()
    assert stat.S_IMODE(state_dir.token_path.stat().st_mode) == 0o600
    got = by_name(doctor(state_dir, state_dir.config_path))
    assert got["token"].ok, got["token"].line


def test_doctor_config_error_is_one_line(state_dir: StateDir, with_credential: None) -> None:
    state_dir.config_path.write_text("not_a_key = 1\n", encoding="utf-8")
    got = by_name(doctor(state_dir, state_dir.config_path))
    assert not got["config"].ok
    assert "not_a_key" in got["config"].line
    assert "\n" not in got["config"].line
    assert got["setting_sources"].ok  # the key is absent, so the default applies


def test_has_credential_recognises_a_login_token(no_credential: None, monkeypatch: pytest.MonkeyPatch) -> None:
    # The engine accepts a login token as well as an API credential; a person
    # on one must not read "FAIL credential" (and the live smoke must not skip).
    assert not has_credential(os.environ)
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "not-a-real-value")
    assert has_credential(os.environ)
    assert "CLAUDE_CODE_OAUTH_TOKEN" in CREDENTIAL_VARS


def test_has_credential_recognises_provider_switch_prefix(no_credential: None, monkeypatch: pytest.MonkeyPatch) -> None:
    assert not has_credential(os.environ)
    monkeypatch.setenv(CREDENTIAL_PREFIXES[0] + "SOMEPROVIDER", "1")
    assert has_credential(os.environ)


def test_doctor_python_check_names_the_running_version(state_dir: StateDir, with_credential: None) -> None:
    got = by_name(doctor(state_dir, state_dir.config_path))
    assert f"{sys.version_info.major}.{sys.version_info.minor}" in got["python"].line


def test_doctor_cli_exits_nonzero_on_failure(state_dir: StateDir, no_credential: None, capsys: pytest.CaptureFixture[str]) -> None:
    from portico_gateway.__main__ import main

    rc = main(["doctor", "--state", str(state_dir.path)])
    out = capsys.readouterr().out
    assert rc == 1
    lines = [line for line in out.splitlines() if line.strip()]
    assert any(line.startswith("FAIL") and "credential" in line for line in lines)
    *checks, summary = lines
    assert all(line.startswith(("ok  ", "FAIL")) for line in checks)
    assert "checks passed" in summary
