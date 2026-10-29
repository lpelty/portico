"""Task 13: ``doctor`` — every check is one line, every failure says what and why.

Model-free. The checks read the state directory, the config file, the
environment and the process table; nothing here starts a gateway.
"""

from __future__ import annotations

import os
import socket
import stat
import subprocess
import sys
from pathlib import Path

import pytest

from portico_gateway import REPO_ROOT
from portico_gateway.config import EMPTY_SETTING_SOURCES_MESSAGE
from portico_gateway.doctor import (
    CREDENTIAL_PREFIXES,
    CREDENTIAL_VARS,
    Check,
    check_checkout,
    doctor,
    format_check,
    has_credential,
)
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
        assert rendered.startswith(("warn" if check.warn else "ok  ") if check.ok else "FAIL")


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
    assert all(line.startswith(("ok  ", "warn", "FAIL")) for line in checks)
    assert "checks passed" in summary


def test_doctor_reports_an_env_file_line_that_is_not_key_value_by_number_only(
    state_dir: StateDir, with_credential: None
) -> None:
    env_path = state_dir.path / "env"
    env_path.write_text(
        "# the deployment's credential\n"
        "GOOD=1\n"
        "export ALSO_GOOD='quoted value'\n"
        'DOUBLE="quoted too" # trailing comment\n'
        "BAD LINE WITH SPACES=x y\n"
        "\n"
        "UNQUOTED=x y\n"
        "SECRET_VALUE=abc\n",
        encoding="utf-8",
    )
    env_path.chmod(0o600)
    got = by_name(doctor(state_dir, state_dir.config_path))
    assert not got["env"].ok
    assert "line 5" in got["env"].line and "1 more" in got["env"].line
    # Never the content: a bad line may hold a credential.
    for word in ("BAD", "SPACES", "UNQUOTED", "SECRET", "abc"):
        assert word not in got["env"].line
    assert "\n" not in got["env"].line

    env_path.write_text("GOOD=1\nexport ALSO_GOOD='v'\n", encoding="utf-8")
    assert by_name(doctor(state_dir, state_dir.config_path))["env"].ok


def test_bin_doctor_survives_a_malformed_env_file(tmp_path: Path) -> None:
    # bin/doctor goes through bin/portico-gateway, which loads the env file:
    # a bad line there must not kill the doctor before its first check.
    cli = REPO_ROOT / "gateway" / ".venv" / "bin" / "portico-gateway"
    if not os.access(cli, os.X_OK):
        pytest.skip("bin/install has not been run; the installed CLI is missing")
    home = tmp_path / "home"
    home.mkdir()
    env_path = home / "env"
    env_path.write_text("GOOD=1\nBAD LINE WITH SPACES=x y\n", encoding="utf-8")
    env_path.chmod(0o600)
    proc = subprocess.run(
        [str(REPO_ROOT / "bin" / "doctor")],
        env={**os.environ, "PORTICO_HOME": str(home)},
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert proc.returncode == 1, proc.stderr
    lines = proc.stdout.splitlines()
    assert any(line.startswith("FAIL env") and "line 2" in line for line in lines), proc.stdout
    assert "command not found" not in proc.stderr
    assert "BAD" not in proc.stdout + proc.stderr
    assert "GOOD" not in proc.stdout + proc.stderr


def test_launcher_never_runs_a_line_of_the_env_file(tmp_path: Path) -> None:
    # The file is parsed, never sourced: a line that would be a command to a
    # shell (``SNEAKY=1; touch marker``) is a bad line, nothing runs, and the
    # doctor still runs every check and names the line by number.
    cli = REPO_ROOT / "gateway" / ".venv" / "bin" / "portico-gateway"
    if not os.access(cli, os.X_OK):
        pytest.skip("bin/install has not been run; the installed CLI is missing")
    home = tmp_path / "home"
    home.mkdir()
    marker = tmp_path / "marker"
    env_path = home / "env"
    env_path.write_text(f"OK=1\nSNEAKY=1; touch {marker}\n", encoding="utf-8")
    env_path.chmod(0o600)
    proc = subprocess.run(
        [str(REPO_ROOT / "bin" / "doctor")],
        env={**os.environ, "PORTICO_HOME": str(home)},
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert not marker.exists()
    assert proc.returncode == 1, proc.stderr
    assert any(line.startswith("FAIL env") and "line 2" in line for line in proc.stdout.splitlines()), proc.stdout
    assert "not loaded: line(s) 2" in proc.stderr, proc.stderr
    assert "SNEAKY" not in proc.stdout + proc.stderr


def test_env_file_values_reach_the_cli_literally(tmp_path: Path) -> None:
    # A well-formed file is loaded by the CLI for doctor (and run); values are
    # literal, so the doctor's credential check sees the variable and nothing
    # is expanded.
    cli = REPO_ROOT / "gateway" / ".venv" / "bin" / "portico-gateway"
    if not os.access(cli, os.X_OK):
        pytest.skip("bin/install has not been run; the installed CLI is missing")
    home = tmp_path / "home"
    home.mkdir()
    env_path = home / "env"
    env_path.write_text(f"export {CREDENTIAL_PREFIXES[0]}PROBE='$(not run) # literal'\n", encoding="utf-8")
    env_path.chmod(0o600)
    env = {k: v for k, v in os.environ.items() if k not in CREDENTIAL_VARS and not k.startswith(CREDENTIAL_PREFIXES)}
    proc = subprocess.run(
        [str(REPO_ROOT / "bin" / "doctor")],
        env={**env, "PORTICO_HOME": str(home)},
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    lines = proc.stdout.splitlines()
    assert any(line.startswith("ok   credential") for line in lines), proc.stdout
    assert any(line.startswith("ok   env") and "loaded" in line for line in lines), proc.stdout
    assert proc.stderr == "", proc.stderr


def test_check_env_subcommand_prints_bad_line_numbers_only(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    from portico_gateway.__main__ import main

    env_path = tmp_path / "env"
    env_path.write_text("A=1\nB=a b\nC='open\n# fine\nexport D='x y'\n", encoding="utf-8")
    assert main(["check-env", str(env_path)]) == 1
    assert capsys.readouterr().out.strip() == "2 3"
    env_path.write_text("A=1\nexport D='x y'\n", encoding="utf-8")
    assert main(["check-env", str(env_path)]) == 0
    assert main(["check-env", str(tmp_path / "missing")]) == 0


def test_parse_env_file_is_literal_and_shell_free(tmp_path: Path) -> None:
    from portico_gateway.doctor import EnvFileError, apply_env_file, parse_env_file

    env_path = tmp_path / "env"
    env_path.write_bytes(
        b"# comment\n"
        b"A=1#x\n"
        b"B=1 # a comment\n"
        b"C='a # b $HOME'\n"
        b'D="x \\"y\\" \\\\ $HOME"\n'
        b"export E=${NOPE?}\n"
        b"F=\n"
        b"G=last"
    )
    assert parse_env_file(env_path) == {
        "A": "1#x", "B": "1", "C": "a # b $HOME", "D": 'x "y" \\ $HOME', "E": "${NOPE?}", "F": "", "G": "last",
    }
    environ = {"A": "kept"}
    assert apply_env_file(env_path, environ) == ["B", "C", "D", "E", "F", "G"]
    assert environ["A"] == "kept" and environ["E"] == "${NOPE?}"
    # Lines a shell would tokenise differently are bad lines, named by number only.
    for bad in (
        b"KEY=1\r# c ; touch marker\n",
        b"KEY=1\x0c# c ; touch marker\n",
        b"KEY=1\xc2\xa0# c ; touch marker\n",
        b"KEY=1# c ; touch marker\n",
        b"KEY=1 x\n",
        b"KEY='a\n",
        b'KEY="a\n',
        b"KEY=\"a\"b\n",
        b"1KEY=a\n",
        b"KEY\n",
        b"KEY=caf\xe9\n",
    ):
        env_path.write_bytes(b"OK=1\n" + bad)
        with pytest.raises(EnvFileError) as e:
            parse_env_file(env_path)
        assert e.value.lines == [2], bad
        assert b"marker" not in str(e.value).encode()
    # A malformed file loads nothing, not part of it.
    environ = {}
    env_path.write_bytes(b"OK=1\nBAD LINE\n")
    with pytest.raises(EnvFileError):
        apply_env_file(env_path, environ)
    assert environ == {}
    assert apply_env_file(tmp_path / "missing", environ) == []


# --- v0.2: plug-ins and the checkout ---------------------------------------------


def _git(repo: Path, *args: str) -> str:
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
    return subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
        cwd=repo, env=env, check=True, capture_output=True, text=True,
    ).stdout


@pytest.fixture
def checkout(tmp_path: Path) -> Path:
    repo = tmp_path / "checkout"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    (repo / "README.md").write_text("hi\n")
    _git(repo, "add", "README.md")
    _git(repo, "commit", "-q", "-m", "first")
    _git(repo, "tag", "v0.1.0")
    return repo


def test_checkout_on_a_tag_with_no_changes_is_ok(checkout: Path) -> None:
    check = check_checkout(checkout)
    assert check.ok and not check.warn
    assert "v0.1.0" in check.line


def test_checkout_with_local_changes_warns_and_never_fails(checkout: Path) -> None:
    (checkout / "README.md").write_text("changed\n")
    check = check_checkout(checkout)
    assert check.ok and check.warn
    assert "plug-in" in check.line and "upstream" in check.line
    assert format_check(check).startswith("warn")


def test_checkout_off_a_tag_names_the_commit(checkout: Path) -> None:
    (checkout / "b.txt").write_text("b\n")
    _git(checkout, "add", "b.txt")
    _git(checkout, "commit", "-q", "-m", "second")
    check = check_checkout(checkout)
    head = _git(checkout, "rev-parse", "--short", "HEAD").strip()
    assert check.ok and head in check.line


def test_not_a_git_checkout_is_ok(tmp_path: Path) -> None:
    check = check_checkout(tmp_path)
    assert check.ok and not check.warn and "not a git checkout" in check.line


@pytest.fixture
def isolated_imports(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(sys, "path", list(sys.path))
    monkeypatch.setattr(sys, "modules", dict(sys.modules))


def test_doctor_reports_each_configured_plugin(state_dir: StateDir, with_credential: None, tmp_path: Path, isolated_imports: None) -> None:
    plugdir = tmp_path / "plugs"
    plugdir.mkdir()
    (plugdir / "pp_old_api.py").write_text("PORTICO_PLUGIN_API = 0\n")
    example = REPO_ROOT / "examples" / "plugin"
    state_dir.config_path.write_text(
        'log_prompt = "SECRET-DO-NOT-PRINT"\n'
        'plugins = ["portico_example_plugin", "pp_missing", "pp_old_api"]\n'
        f'plugin_paths = ["{example}", "{plugdir}"]\n'
    )
    checks = doctor(state_dir, state_dir.config_path)
    got = by_name(checks)
    assert got["plugin portico_example_plugin"].ok
    assert "on_renew" in got["plugin portico_example_plugin"].line
    assert not got["plugin pp_missing"].ok and "not found" in got["plugin pp_missing"].line
    assert not got["plugin pp_old_api"].ok and "PORTICO_PLUGIN_API" in got["plugin pp_old_api"].line
    assert not any("SECRET-DO-NOT-PRINT" in format_check(c) for c in checks)


def test_doctor_with_no_plugins_says_so(state_dir: StateDir, with_credential: None) -> None:
    got = by_name(doctor(state_dir, state_dir.config_path))
    assert got["plugins"].ok and "none" in got["plugins"].line
    assert "checkout" in got


# --- v0.4: services ---------------------------------------------------------------


def test_doctor_names_the_configured_services(state_dir: StateDir, with_credential: None) -> None:
    got = by_name(doctor(state_dir, state_dir.config_path))
    assert got["services"].ok and "none configured" in got["services"].line
    state_dir.config_path.write_text(
        'services_interval_seconds = 10\n[[services]]\nid = "memory"\nname = "Memory"\ncheck = "exit 1"\n'
    )
    got = by_name(doctor(state_dir, state_dir.config_path))
    assert got["services"].ok and "1 configured (memory)" in got["services"].line and "10 s" in got["services"].line


def test_doctor_reports_a_bad_services_section(state_dir: StateDir, with_credential: None) -> None:
    state_dir.config_path.write_text('[[services]]\nid = "Memory"\nname = "M"\ncheck = "true"\n')
    got = by_name(doctor(state_dir, state_dir.config_path))
    assert not got["config"].ok and not got["services"].ok
    assert "'Memory'" in got["services"].line and "\n" not in got["services"].line
