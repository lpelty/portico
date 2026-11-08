"""v0.25 §4 (PORT-3): sign-in kinds, the error detail that names one, and how a sign-in is known current again.

Nothing here runs the real ``claude`` CLI or touches AWS: the SSO token
cache is fixture files under ``tmp_path``, and the CLI is
``tests/fixtures/fake_claude``.
"""

from __future__ import annotations

import json
import os
import shlex
import shutil
import time
from datetime import UTC, datetime
from pathlib import Path

import pytest
from claude_agent_sdk import AssistantMessage, ResultMessage, TextBlock

from portico_gateway import signin
from portico_gateway.config import Config, ConfigError, load_config
from portico_gateway.engine import error_detail
from portico_gateway.signin import (
    SIGNIN_EXPIRED,
    claude_status_current,
    command_current,
    is_current,
    kinds_for,
    match_kind,
    parse_signin_link,
    poll_interval,
    sso_cache_current,
)

FIXTURES = Path(__file__).parent / "fixtures"
FAKE_CLAUDE = FIXTURES / "fake_claude"
START_URL = "https://example-x.awsapps.com/start"


def result(is_error: bool = True, **fields: object) -> ResultMessage:
    return ResultMessage(
        subtype="error_during_execution" if is_error else "success",
        duration_ms=1, duration_api_ms=1, is_error=is_error, num_turns=1, session_id="s", **fields,  # type: ignore[arg-type]
    )


# --- the error detail ---------------------------------------------------------------


def test_error_detail_reads_result_and_assistant_errors() -> None:
    assert "cloud_credential_error" in error_detail(result(errors=["cloud_credential_error"]))
    detail = error_detail(result(result="Could not load AWS credentials", api_error_status=403, terminal_reason="error"))
    assert "Could not load AWS credentials" in detail and "403" in detail and "error" in detail
    assert error_detail(AssistantMessage(content=[], model="m", error="authentication_failed")) == ["authentication_failed"]


def test_error_detail_keeps_an_error_messages_own_words() -> None:
    msg = AssistantMessage(content=[TextBlock(text="Login expired · Please run /login")], model="m", error="authentication_failed")
    assert error_detail(msg) == ["authentication_failed", "Login expired · Please run /login"]


def test_error_detail_ignores_what_is_not_an_error() -> None:
    assert error_detail(result(is_error=False, result="Not logged in? Here is how.")) == []
    assert error_detail(AssistantMessage(content=[TextBlock(text="Not logged in")], model="m")) == []


# --- kinds and matching ---------------------------------------------------------------


@pytest.mark.parametrize(
    ("text", "kind"),
    [
        ("Could not load AWS credentials · The SSO session associated with this profile has expired", "aws-sso"),
        ("cloud_credential_error", "aws-sso"),
        ("SSO session associated with this profile has expired", "aws-sso"),
        ("authentication_failed", "claude"),
        ("Login expired · Please run /login", "claude"),
        ("OAuth token has expired", "claude"),
        ("Not logged in · Please run /login", "claude"),
        ("rate_limit", None),
        ("authentication_failed_elsewhere", None),
    ],
)
def test_match_kind(text: str, kind: str | None) -> None:
    # As the engine's own error message carries it (review M1: the only place the claude kind reads).
    found = match_kind([text], kinds_for(Config()), assistant=[text])
    assert (found.name if found else None) == kind


def test_aws_sso_is_matched_before_claude() -> None:
    found = match_kind(["cloud_credential_error"], kinds_for(Config()), assistant=["authentication_failed"])
    assert found is not None and found.name == "aws-sso"


def test_default_kinds(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(signin, "cli_path", lambda: "/opt/the cli/claude")
    aws, claude = kinds_for(Config())
    assert aws.name == "aws-sso" and aws.check is None and aws.open is None and not aws.wants_code
    assert aws.title == "Sign in again to continue"
    assert aws.body == "Your sign-in to AWS has run out. Sign in in your browser; this conversation carries on by itself when you're done."
    assert claude.name == "claude" and claude.wants_code
    assert claude.check == shlex.quote("/opt/the cli/claude") + " auth status"
    assert claude.open == shlex.quote("/opt/the cli/claude") + " auth login"
    assert claude.body == "Your Claude sign-in has run out. Sign in in your browser; this conversation carries on by itself when you're done."
    assert poll_interval(aws) == 5.0 and poll_interval(claude) == 10.0
    assert SIGNIN_EXPIRED == "signin.expired"


def test_signin_config_overrides_a_kind(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text(
        "[signin.aws-sso]\n"
        'check = "my-check"\n'
        'open = "aws sso login"\n'
        f'sso_start_url = "{START_URL}"\n'
        'title = "Sign in to the cloud"\n'
        'body = "Your cloud sign-in ran out."\n'
        'patterns = ["custom_error"]\n'
    )
    aws, _ = kinds_for(load_config(path))
    assert (aws.check, aws.open, aws.sso_start_url, aws.title, aws.body) == (
        "my-check", "aws sso login", START_URL, "Sign in to the cloud", "Your cloud sign-in ran out."
    )
    assert aws.patterns == ("custom_error",)
    assert poll_interval(aws) == 10.0, "a check command is polled every 10 s"
    path.write_text("[signin.aws-sso]\nwhat = 1\n")
    with pytest.raises(ConfigError):
        load_config(path)
    path.write_text('[signin.claude]\nsso_start_url = "x"\n')
    with pytest.raises(ConfigError):
        load_config(path)


def test_a_bad_pattern_is_a_config_error(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text('[signin.claude]\npatterns = ["(unclosed"]\n')
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert "patterns" in str(e.value)


# --- the SSO token cache ---------------------------------------------------------------


def _cache(tmp_path: Path, *names: str, mtime: float | None = None) -> Path:
    folder = tmp_path / "sso"
    folder.mkdir(exist_ok=True)
    for name in names:
        target = folder / name
        shutil.copy(FIXTURES / "sso_cache" / name, target)
        if mtime is not None:
            os.utime(target, (mtime, mtime))
    return folder


def test_sso_cache_current_needs_a_later_expiry_written_after_the_error(tmp_path: Path) -> None:
    now = datetime(2026, 11, 8, 20, 0, tzinfo=UTC)
    since = time.time() - 60
    assert not sso_cache_current(_cache(tmp_path, "expired.json", "no_token.json"), since, None, now)
    folder = _cache(tmp_path, "fresh.json")
    assert sso_cache_current(folder, since, None, now)
    assert sso_cache_current(folder, since, START_URL, now)
    assert not sso_cache_current(folder, since, "https://other.awsapps.com/start", now)
    assert not sso_cache_current(folder, time.time() + 60, None, now), "written before the error: not a new sign-in"


def test_sso_cache_reads_both_expiry_forms(tmp_path: Path) -> None:
    now = datetime(2026, 11, 8, 20, 0, tzinfo=UTC)
    assert sso_cache_current(_cache(tmp_path, "fresh_utc.json"), time.time() - 60, None, now)


def test_sso_cache_skips_unreadable_files(tmp_path: Path) -> None:
    folder = tmp_path / "sso"
    folder.mkdir()
    (folder / "junk.json").write_text("not json")
    (folder / "list.json").write_text("[1, 2]")
    (folder / "bad-date.json").write_text(json.dumps({"accessToken": "x", "expiresAt": "soon"}))
    now = datetime(2026, 11, 8, 20, 0, tzinfo=UTC)
    assert not sso_cache_current(folder, 0, None, now)
    assert not sso_cache_current(tmp_path / "missing", 0, None, now)


# --- commands -----------------------------------------------------------------------


def test_claude_status() -> None:
    assert claude_status_current(0, '{"authMethod":"claude.ai"}')
    assert claude_status_current(0, "Logged in")
    assert not claude_status_current(1, "")
    assert not claude_status_current(0, '{"authMethod":"api_key"}')
    assert not claude_status_current(0, '{"authMethod":"none"}')


async def test_command_current(tmp_path: Path) -> None:
    assert await command_current("true")
    assert not await command_current("false")


async def test_is_current_uses_the_fake_claude(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr(signin, "cli_path", lambda: str(FAKE_CLAUDE))
    _, claude = kinds_for(Config())
    assert await is_current(claude, 0, tmp_path)
    monkeypatch.setenv("FAKE_CLAUDE_STATUS", '{"authMethod": "none"}')
    monkeypatch.setenv("FAKE_CLAUDE_STATUS_CODE", "1")
    assert not await is_current(claude, 0, tmp_path)


async def test_is_current_reads_the_cache_for_aws(tmp_path: Path) -> None:
    aws, _ = kinds_for(Config())
    assert not await is_current(aws, time.time() - 60, tmp_path / "nothing")
    assert await is_current(aws, time.time() - 60, _cache(tmp_path, "fresh.json"))


# --- the link and code --------------------------------------------------------------


def test_parse_signin_link() -> None:
    assert parse_signin_link(["Open https://device.sso.us-east-1.amazonaws.com/ and enter", "Code: QKXW-RTBN"]) == (
        "https://device.sso.us-east-1.amazonaws.com/",
        "QKXW-RTBN",
    )
    assert parse_signin_link(["nothing here"]) == (None, None)
    assert parse_signin_link(["visit: https://claude.example/oauth/authorize?code=true"]) == (
        "https://claude.example/oauth/authorize?code=true",
        None,
    )


# --- the sign-in command (Task 6) ---------------------------------------------------------


def _script(tmp_path: Path, name: str, body: str) -> str:
    path = tmp_path / name
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)
    return shlex.quote(str(path))


async def _until(predicate, timeout: float = 3.0) -> None:  # type: ignore[no-untyped-def]
    import asyncio

    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("timed out")
        await asyncio.sleep(0.01)


async def test_open_reports_the_link_and_code(tmp_path: Path) -> None:
    from portico_gateway.signin import SigninCommand

    command = _script(
        tmp_path, "aws_login",
        "echo 'Attempting to open the SSO authorization page in your browser.'\n"
        "echo 'If the browser does not open, open the following URL:'\n"
        "echo 'https://device.sso.us-east-1.amazonaws.com/'\n"
        "sleep 0.2\n"
        "echo 'Then enter the code:'\n"
        "echo 'QKXW-RTBN'\n"
        "sleep 5\n",
    )
    seen: list[tuple[str | None, str | None]] = []

    async def on_link(url: str | None, code: str | None) -> None:
        seen.append((url, code))

    cmd = SigninCommand()
    await cmd.start(command, on_link)
    try:
        await _until(lambda: any(code for _, code in seen))
        assert seen[0] == ("https://device.sso.us-east-1.amazonaws.com/", None)
        assert seen[-1] == ("https://device.sso.us-east-1.amazonaws.com/", "QKXW-RTBN")
        assert cmd.running
    finally:
        await cmd.close()


async def test_a_pasted_code_reaches_the_command(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from portico_gateway.signin import SigninCommand

    got = tmp_path / "pasted"
    monkeypatch.setenv("FAKE_CLAUDE_CODE_FILE", str(got))
    monkeypatch.setattr(signin, "cli_path", lambda: str(FAKE_CLAUDE))
    _, claude = kinds_for(Config())
    links: list[tuple[str | None, str | None]] = []

    async def on_link(url: str | None, code: str | None) -> None:
        links.append((url, code))

    cmd = SigninCommand()
    assert not await cmd.write_code("too early")
    assert claude.open is not None
    await cmd.start(claude.open, on_link)
    try:
        await _until(lambda: bool(links))
        assert links[0][0] == "https://claude.example/oauth/authorize?code=true"
        assert await cmd.write_code("abc")
        await _until(lambda: got.exists() and got.read_text() == "abc")
    finally:
        await cmd.close()
    assert not cmd.running


async def test_open_output_is_never_logged(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    import logging

    from portico_gateway.signin import SigninCommand

    caplog.set_level(logging.DEBUG)
    command = _script(
        tmp_path, "chatty",
        "echo 'secret-token-123'\necho 'https://device.example/start' 1>&2\necho 'ABCD-EFGH'\nread line\n",
    )
    links: list[tuple[str | None, str | None]] = []

    async def on_link(url: str | None, code: str | None) -> None:
        links.append((url, code))

    cmd = SigninCommand()
    await cmd.start(command, on_link)
    try:
        await _until(lambda: any(code for _, code in links))
        await cmd.write_code("pasted-ZZZZ-9999")
    finally:
        await cmd.close()
    text = caplog.text
    for secret in ("secret-token-123", "https://device.example/start", "ABCD-EFGH", "pasted-ZZZZ-9999", str(tmp_path)):
        assert secret not in text
    assert "sign-in command started" in text


async def test_close_kills_a_hung_command(tmp_path: Path) -> None:
    from portico_gateway.signin import SigninCommand

    ready = tmp_path / "ready"
    command = _script(tmp_path, "hang", f"trap '' TERM\ntouch {shlex.quote(str(ready))}\nsleep 60\n")

    async def on_link(url: str | None, code: str | None) -> None:
        pass

    cmd = SigninCommand()
    await cmd.start(command, on_link)
    await _until(ready.exists)
    assert cmd.running
    began = time.monotonic()
    await cmd.close()
    took = time.monotonic() - began
    assert 1.5 < took < 3.0, "it ignores a terminate, so it is killed after 2 s"
    assert not cmd.running


# --- review fixes (M1) -------------------------------------------------------------------


def test_review_m1_an_expired_sts_token_is_aws_not_claude() -> None:
    """The reviewer's first proof case: an AWS credential worded as an expired security token."""
    msg = AssistantMessage(
        content=[TextBlock(text="The security token included in the request is expired")], model="m",
        error="authentication_failed",
    )
    detail = error_detail(msg)
    found = match_kind(detail, kinds_for(Config()), assistant=detail)
    assert found is not None and found.name == "aws-sso"
    assert match_kind(["ExpiredToken"], kinds_for(Config())).name == "aws-sso"  # type: ignore[union-attr]


def test_review_m1_claude_patterns_never_read_the_result_text() -> None:
    """The reviewer's second proof case: a failed result that merely says "Not logged in"."""
    detail = error_detail(result(result="The site says: Not logged in, so I stopped."))
    assert match_kind(detail, kinds_for(Config()), assistant=[]) is None
    # The same words from the engine's own error message do name it.
    assert match_kind([], kinds_for(Config()), assistant=["Not logged in · Please run /login"]).name == "claude"  # type: ignore[union-attr]


@pytest.mark.parametrize(
    ("env", "claude"),
    [
        ({}, True),
        ({"CLAUDE_CODE_USE_BEDROCK": "1"}, False),
        ({"CLAUDE_CODE_USE_VERTEX": "1"}, False),
        ({"ANTHROPIC_API_KEY": "x"}, False),
        ({"ANTHROPIC_AUTH_TOKEN": "x"}, False),
        ({"CLAUDE_CODE_USE_BEDROCK": ""}, True),
        ({"CLAUDE_CODE_USE_BEDROCK": "0"}, True),
        ({"CLAUDE_CODE_OAUTH_TOKEN": "x"}, True),
    ],
)
def test_the_claude_kind_only_with_a_claude_login(env: dict[str, str], claude: bool) -> None:
    from portico_gateway.signin import claude_login

    assert claude_login(env) is claude
    names = [k.name for k in kinds_for(Config(), claude=claude_login(env))]
    assert names == (["aws-sso", "claude"] if claude else ["aws-sso"])


# --- v0.26: the v0.25 review's sign-in leftovers (PORT-22) ------------------------------


def test_a_token_written_after_the_turn_started_counts(tmp_path: Path) -> None:
    """L2: ``since`` is the failed turn's start, so a sign-in made while the turn was failing counts."""
    now = datetime(2026, 11, 8, 20, 0, tzinfo=UTC)
    turn_started = time.time() - 30
    folder = _cache(tmp_path, "fresh.json", mtime=time.time() - 10)  # after the turn began, before the wait
    assert sso_cache_current(folder, turn_started, START_URL, now)


@pytest.mark.parametrize("cached", [
    "https://example-x.awsapps.com/start/", "https://example-x.awsapps.com/start/#/",
    "https://EXAMPLE-X.awsapps.com/start", "HTTPS://example-x.awsapps.com/start#",
])
def test_start_urls_match_with_a_slash_or_fragment(tmp_path: Path, cached: str) -> None:
    """L3: a trailing ``/`` or ``#/``, or the host's case, never stops a match."""
    now = datetime(2026, 11, 8, 20, 0, tzinfo=UTC)
    folder = tmp_path / "sso"
    folder.mkdir()
    data = json.loads((FIXTURES / "sso_cache" / "fresh.json").read_text())
    data["startUrl"] = cached
    (folder / "a.json").write_text(json.dumps(data))
    assert sso_cache_current(folder, time.time() - 60, START_URL, now)
    assert sso_cache_current(folder, time.time() - 60, START_URL + "/", now)
    assert not sso_cache_current(folder, time.time() - 60, "https://example-x.awsapps.com/other", now)


def test_normalise_start_url() -> None:
    from portico_gateway.signin import normalise_start_url

    assert normalise_start_url("https://Example-X.awsapps.com/start/#/") == "https://example-x.awsapps.com/start"
    assert normalise_start_url("https://example-x.awsapps.com/start") == "https://example-x.awsapps.com/start"
    assert normalise_start_url("https://example-x.awsapps.com/Start") == "https://example-x.awsapps.com/Start", "the path keeps its case"


async def test_a_timed_out_check_kills_its_children(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """L10: the check runs in a session of its own; on timeout its whole group goes."""
    monkeypatch.setattr(signin, "CHECK_TIMEOUT", 0.3)
    pids = tmp_path / "pids"
    check = f"sh -c 'sleep 60 & echo $! > {shlex.quote(str(pids))}; wait'"
    began = time.monotonic()
    code, _ = await signin._run_check(check)
    assert code == -1
    assert time.monotonic() - began < 5, "the check's children don't hold it open"
    child = int(pids.read_text().strip())

    def alive(pid: int) -> bool:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    await _until(lambda: not alive(child), timeout=3.0)


async def test_the_exit_report_task_is_kept(tmp_path: Path) -> None:
    """N3: the task that reports the command's exit is kept until it completes."""
    from portico_gateway.signin import SigninCommand

    async def on_link(url: str | None, code: str | None) -> None:
        pass

    cmd = SigninCommand()
    await cmd.start(_script(tmp_path, "quick", "exit 0\n"), on_link)
    try:
        assert cmd._exit_task is not None
        await _until(lambda: cmd._exit_task is not None and cmd._exit_task.done())
    finally:
        await cmd.close()


async def test_output_stops_parsing_once_link_and_code_are_found(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """N4: once both the URL and the code are found, later lines aren't parsed; the buffer is capped."""
    from portico_gateway.signin import SigninCommand

    calls = 0
    real = signin.parse_signin_link

    def counting(lines):  # type: ignore[no-untyped-def]
        nonlocal calls
        calls += 1
        return real(lines)

    monkeypatch.setattr(signin, "parse_signin_link", counting)
    seen: list[tuple[str | None, str | None]] = []

    async def on_link(url: str | None, code: str | None) -> None:
        seen.append((url, code))

    body = "echo 'https://device.sso.us-east-1.amazonaws.com/'\necho 'QKXW-RTBN'\n"
    body += "i=0; while [ $i -lt 500 ]; do echo \"noise line $i\"; i=$((i+1)); done\nsleep 5\n"
    cmd = SigninCommand()
    await cmd.start(_script(tmp_path, "noisy", body), on_link)
    try:
        await _until(lambda: len(cmd._lines) >= SigninCommand.MAX_LINES or cmd._seen_lines >= 502)
        await _until(lambda: cmd._seen_lines >= 502)
        assert seen[-1] == ("https://device.sso.us-east-1.amazonaws.com/", "QKXW-RTBN")
        assert calls <= 2, calls
        assert len(cmd._lines) <= SigninCommand.MAX_LINES
    finally:
        await cmd.close()
