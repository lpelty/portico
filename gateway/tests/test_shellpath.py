"""The person's PATH and the attended flag (v0.11, items 57 and 56).

Started from the app, the gateway has launchd's bare PATH; it asks the login
shell for the person's and puts it first. Every engine for a person's chat
carries ``PORTICO_ATTENDED=1``.
"""

from __future__ import annotations

import os
import stat
from pathlib import Path

from portico_gateway.config import Config
from portico_gateway.doctor import check_path
from portico_gateway.engine import ATTENDED_ENV, build_options
from portico_gateway.shellpath import apply_login_shell_path, login_shell_path, merged
from tests.test_system_prompt import PlainCallbacks

BARE = "/usr/bin:/bin:/usr/sbin:/sbin"


def fake_shell(tmp_path: Path, body: str) -> str:
    """A ``$SHELL`` that runs ``body`` whatever it is asked (``-l -i -c …``)."""
    shell = tmp_path / "fakesh"
    shell.write_text(f"#!/bin/sh\n{body}\n")
    shell.chmod(shell.stat().st_mode | stat.S_IXUSR)
    return str(shell)


def test_merged_puts_the_first_path_first_and_keeps_what_it_lacks():
    assert merged("/opt/homebrew/bin:/usr/bin", BARE) == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"


def test_merged_drops_empties_and_repeats():
    assert merged("/a::/a", ":/b:/a") == "/a:/b"


def test_login_shell_path_reads_between_the_markers_past_a_banner(tmp_path):
    # An interactive shell may print a banner first; only the marked PATH counts.
    shell = fake_shell(tmp_path, 'echo "Welcome!"; printf "__PORTICO_PATH_START__/opt/homebrew/bin:/usr/bin__PORTICO_PATH_END__"')
    assert login_shell_path({"SHELL": shell}) == "/opt/homebrew/bin:/usr/bin"


def test_the_real_login_shell_is_asked_with_the_script(tmp_path):
    # Runs the given -c script with a known PATH, as a real shell would.
    shell = fake_shell(tmp_path, 'PATH=/opt/homebrew/bin:/usr/bin; shift 3; eval "$1"')
    env = {"SHELL": shell, "PATH": BARE}
    assert apply_login_shell_path(env) is True
    assert env["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"


def test_no_shell_keeps_the_inherited_path():
    env = {"PATH": BARE}
    assert apply_login_shell_path(env) is False
    assert env["PATH"] == BARE


def test_a_shell_that_prints_no_path_keeps_the_inherited_path(tmp_path):
    env = {"SHELL": fake_shell(tmp_path, "echo nothing here"), "PATH": BARE}
    assert apply_login_shell_path(env) is False
    assert env["PATH"] == BARE


def test_a_slow_shell_times_out_and_keeps_the_inherited_path(tmp_path):
    env = {"SHELL": fake_shell(tmp_path, "sleep 5"), "PATH": BARE}
    assert apply_login_shell_path(env, timeout=0.3) is False
    assert env["PATH"] == BARE


def test_login_shell_path_is_on_by_default_and_can_be_turned_off():
    assert Config().login_shell_path is True
    assert Config(login_shell_path=False).login_shell_path is False


def test_doctor_reports_the_path_and_the_missing_launchers(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for tool in ("node", "npx"):
        exe = bin_dir / tool
        exe.write_text("#!/bin/sh\n")
        exe.chmod(0o755)
    config = tmp_path / "config.toml"
    config.write_text("")
    check = check_path(config, env={"PATH": BARE}, read=lambda env: str(bin_dir))
    assert check.ok and check.warn  # a warning, never a failure
    assert "from the login shell" in check.line
    assert "not found: uvx" in check.line


def test_doctor_says_when_the_login_shell_could_not_be_read(tmp_path):
    config = tmp_path / "config.toml"
    config.write_text("")
    check = check_path(config, env={"PATH": BARE}, read=lambda env: None)
    assert "could not be read" in check.line


def test_every_engine_for_a_chat_is_attended(tmp_path):
    options = build_options(tmp_path, None, ["project"], PlainCallbacks())
    assert options.env == {ATTENDED_ENV: "1"}
    assert os.environ.get(ATTENDED_ENV) is None  # the gateway's own environment is untouched


def test_an_env_file_path_goes_first_and_survives_the_login_shell(tmp_path):
    # The deployment's explicit PATH wins: first after loading, and first again
    # after the login shell's PATH is put in front.
    from portico_gateway.doctor import apply_env_file

    env_file = tmp_path / "env"
    env_file.write_text("PATH=/deploy/bin\n")
    shell = fake_shell(tmp_path, 'PATH=/opt/homebrew/bin; shift 3; eval "$1"')
    env = {"SHELL": shell, "PATH": BARE}
    apply_env_file(env_file, env)
    assert env["PATH"] == "/deploy/bin:" + BARE
    assert apply_login_shell_path(env)
    apply_env_file(env_file, env)
    assert env["PATH"] == "/deploy/bin:/opt/homebrew/bin:" + BARE
