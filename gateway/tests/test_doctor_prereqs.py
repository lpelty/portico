"""v0.3: the doctor's prerequisite checks — Command Line Tools, swift, uv, the engine SDK pin, the app's macOS SDK.

Every machine probe goes through an injected runner, so these run the same on any Mac
(and never call the real /usr/bin/swift shim, which opens an installer without the CLT).
"""

from __future__ import annotations

import subprocess
from collections.abc import Callable
from pathlib import Path

import pytest

from portico_gateway.doctor import (
    BUILD_RECORD,
    check_app_sdk,
    check_clt,
    check_sdk_lock,
    check_swift,
    check_uv,
    format_check,
    locked_version,
    prerequisite_checks,
)
from portico_gateway import REPO_ROOT


def done(argv: list[str], code: int = 0, out: str = "", err: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(argv, code, out, err)


def runner(answers: dict[str, tuple[int, str]], calls: list[list[str]] | None = None) -> Callable[[list[str]], subprocess.CompletedProcess[str]]:
    """Answers keyed by the command's first word plus first argument; anything else is 'not found'."""

    def run(argv: list[str]) -> subprocess.CompletedProcess[str]:
        if calls is not None:
            calls.append(argv)
        key = f"{Path(argv[0]).name} {argv[1] if len(argv) > 1 else ''}".strip()
        if key not in answers:
            raise FileNotFoundError(argv[0])
        code, out = answers[key]
        return done(argv, code, out if code == 0 else "", "" if code == 0 else out)

    return run


PKG_INFO = "package-id: com.apple.pkg.CLTools_Executables\nversion: 27.0.0.0.1788430756\nvolume: /\n"


def test_clt_names_the_version_and_the_developer_dir(tmp_path: Path) -> None:
    run = runner({"xcode-select -p": (0, f"{tmp_path}\n"), "pkgutil --pkg-info=com.apple.pkg.CLTools_Executables": (0, PKG_INFO)})
    check = check_clt(run)
    assert check.ok
    assert "27.0.0.0.1788430756" in check.line and str(tmp_path) in check.line


def test_clt_missing_says_how_to_install_without_xcode() -> None:
    check = check_clt(runner({"xcode-select -p": (2, "xcode-select: error: unable to get active developer directory")}))
    assert not check.ok
    assert "xcode-select --install" in check.line and "Xcode is not needed" in check.line
    assert format_check(check).startswith("FAIL command line tools:")


def test_clt_with_only_xcode_is_ok(tmp_path: Path) -> None:
    run = runner({"xcode-select -p": (0, str(tmp_path)), "pkgutil --pkg-info=com.apple.pkg.CLTools_Executables": (1, "No receipt")})
    check = check_clt(run)
    assert check.ok and str(tmp_path) in check.line


def test_swift_names_its_version() -> None:
    run = runner({"swift --version": (0, "swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1)\nTarget: arm64")})
    check = check_swift(run, which=lambda name: "/usr/bin/swift")
    assert check.ok and check.line == "Swift 6.4 (/usr/bin/swift)"


def test_swift_that_does_not_run_fails_in_plain_words() -> None:
    run = runner({"swift --version": (1, "xcrun: error: invalid active developer path")})
    check = check_swift(run, which=lambda name: "/usr/bin/swift")
    assert not check.ok
    assert "swift does not run" in check.line and "xcode-select --install" in check.line


def test_swift_is_not_asked_without_developer_tools() -> None:
    calls: list[list[str]] = []
    check = check_swift(runner({}, calls), which=lambda name: "/usr/bin/swift", clt_present=False)
    assert not check.ok and "not checked" in check.line
    assert calls == []  # the /usr/bin/swift shim would open the installer dialog


def test_uv_missing_names_where_to_get_it() -> None:
    check = check_uv(runner({}), which=lambda name: None)
    assert not check.ok and "uv is not on PATH" in check.line and "docs.astral.sh/uv" in check.line


def test_uv_present_names_its_version() -> None:
    check = check_uv(runner({"uv --version": (0, "uv 0.10.8 (c021be36a 2026-03-03)\n")}), which=lambda name: "/x/uv")
    assert check.ok and "uv 0.10.8" in check.line


LOCK = """version = 1

[[package]]
name = "anyio"
version = "4.0.0"

[[package]]
name = "claude-agent-sdk"
version = "0.2.174"
"""


def test_sdk_lock_matches(tmp_path: Path) -> None:
    lock = tmp_path / "uv.lock"
    lock.write_text(LOCK)
    check = check_sdk_lock(lock, installed=lambda: "0.2.174")
    assert check.ok and "0.2.174" in check.line


def test_sdk_lock_mismatch_names_both_versions(tmp_path: Path) -> None:
    lock = tmp_path / "uv.lock"
    lock.write_text(LOCK)
    check = check_sdk_lock(lock, installed=lambda: "0.2.180")
    assert not check.ok
    assert "0.2.180 is installed" in check.line and "pins 0.2.174" in check.line and "bin/install" in check.line


def test_sdk_lock_not_installed_fails(tmp_path: Path) -> None:
    lock = tmp_path / "uv.lock"
    lock.write_text(LOCK)
    check = check_sdk_lock(lock, installed=lambda: None)
    assert not check.ok and "not installed" in check.line


def test_sdk_lock_without_a_pin_is_not_compared(tmp_path: Path) -> None:
    check = check_sdk_lock(tmp_path / "missing.lock", installed=lambda: "0.2.174")
    assert check.ok and "not compared" in check.line


def test_the_real_lock_pins_the_sdk_and_this_env_matches_it() -> None:
    lock = REPO_ROOT / "gateway" / "uv.lock"
    assert locked_version(lock)
    assert check_sdk_lock(lock).ok


def write_record(repo: Path, **values: str) -> None:
    path = repo / BUILD_RECORD
    path.parent.mkdir(parents=True)
    path.write_text("".join(f"{k}={v}\n" for k, v in values.items()))


def test_app_sdk_names_the_recorded_fallback(tmp_path: Path) -> None:
    sdk = tmp_path / "MacOSX26.5.sdk"
    sdk.mkdir()
    write_record(tmp_path, sdk=str(sdk), sdk_version="26.5", chosen="fallback")
    check = check_app_sdk(tmp_path, runner({}))
    assert check.ok
    assert "macOS 26.5 SDK" in check.line and str(sdk) in check.line and "default SDK does not compile" in check.line


def test_app_sdk_that_is_gone_fails(tmp_path: Path) -> None:
    write_record(tmp_path, sdk=str(tmp_path / "MacOSX26.sdk"), sdk_version="26.5", chosen="fallback")
    check = check_app_sdk(tmp_path, runner({}))
    assert not check.ok and "no longer installed" in check.line and "bin/install" in check.line


def test_app_sdk_before_a_build_names_the_default(tmp_path: Path) -> None:
    run = runner({"xcrun --sdk": (0, "/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk\n")})
    check = check_app_sdk(tmp_path, run)
    assert check.ok and "not built yet" in check.line and "MacOSX27.0.sdk" in check.line


def test_prerequisites_without_developer_tools_fail_once_and_ask_nothing_else(tmp_path: Path) -> None:
    calls: list[list[str]] = []
    run = runner({"xcode-select -p": (2, "no developer directory"), "uv --version": (0, "uv 0.10.8")}, calls)
    checks = prerequisite_checks(tmp_path, run, which=lambda name: f"/usr/bin/{name}")
    got = {c.name: c for c in checks}
    assert not got["command line tools"].ok
    assert not got["swift"].ok and "not checked" in got["swift"].line
    assert got["uv"].ok
    assert not got["macos sdk"].ok and "not checked" in got["macos sdk"].line
    assert not any(Path(argv[0]).name in ("swift", "xcrun") for argv in calls)
    for check in checks:
        assert "\n" not in check.line


@pytest.mark.parametrize("name", ["command line tools", "swift", "uv", "macos sdk"])
def test_prerequisites_run_on_this_machine(name: str) -> None:
    got = {c.name: c for c in prerequisite_checks()}
    assert got[name].line
