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
    found = match_kind([text], kinds_for(Config()))
    assert (found.name if found else None) == kind


def test_aws_sso_is_matched_before_claude() -> None:
    found = match_kind(["authentication_failed", "cloud_credential_error"], kinds_for(Config()))
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
