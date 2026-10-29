"""v0.3: install packaging — prerequisites, SDK selection, and the assembled .app.

The scripts under ``app/Packaging`` are run against throwaway directories: a stand-in
``swift`` (``PORTICO_SWIFT``) decides which SDKs "compile", and a copy of ``/usr/bin/true``
stands in for the release binary. Nothing here runs a real build or opens an app.
"""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
from pathlib import Path

import pytest

from portico_gateway import REPO_ROOT

PACKAGING = REPO_ROOT / "app" / "Packaging"
BUILD_APP = PACKAGING / "build-app.sh"
MAKE_APP = PACKAGING / "make-app.sh"
PREREQS = PACKAGING / "prereqs.sh"
SHAPE_ICON = PACKAGING / "shape-app-icon.swift"
DEFAULT_ICON = PACKAGING / "AppIcon.png"

pytestmark = pytest.mark.skipif(shutil.which("codesign") is None, reason="macOS tools are not available")


def run(argv: list[str], env: dict[str, str] | None = None, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(a) for a in argv], env=env, cwd=cwd, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL
    )


# --- SDK selection ------------------------------------------------------------

FAKE_SWIFT = """#!/usr/bin/env bash
# Stand-in swift: "compiles" only with an SDK whose path matches $GOOD_SDK (or the default when DEFAULT_OK=1).
for a in "$@"; do
  if [ "$a" = --show-bin-path ]; then echo "$PRODUCTS"; exit 0; fi
done
echo "${SDKROOT:-<default>}" >> "$ATTEMPTS"
if [ -z "${SDKROOT:-}" ] && [ "${DEFAULT_OK:-0}" = 1 ]; then echo "Build complete!"; exit 0; fi
if [ -n "${SDKROOT:-}" ] && [ -n "${GOOD_SDK:-}" ] && [ "$SDKROOT" = "$GOOD_SDK" ]; then echo "Build complete!"; exit 0; fi
printf '\\033[1;31merror: \\033[0mcannot find %s in scope\\n' "'\\$x'"
echo "note: some noise the person never needs"
exit 1
"""


def make_sdk(root: Path, name: str, version: str) -> Path:
    sdk = root / name
    sdk.mkdir(parents=True)
    with (sdk / "SDKSettings.plist").open("wb") as f:
        plistlib.dump({"Version": version}, f)
    return sdk


@pytest.fixture
def build_env(tmp_path: Path) -> dict[str, object]:
    """A fake repo, a fake developer dir with three SDKs (MacOSX.sdk an alias of the newest), a fake swift."""
    repo = tmp_path / "repo"
    (repo / "app").mkdir(parents=True)
    dev = tmp_path / "dev"
    sdks = dev / "SDKs"
    newest = make_sdk(sdks, "MacOSX27.0.sdk", "27.0")
    middle = make_sdk(sdks, "MacOSX26.5.sdk", "26.5")
    oldest = make_sdk(sdks, "MacOSX15.5.sdk", "15.5")
    (sdks / "MacOSX.sdk").symlink_to("MacOSX27.0.sdk")
    (sdks / "MacOSX26.sdk").symlink_to("MacOSX26.5.sdk")
    products = tmp_path / "products"
    products.mkdir()
    swift = tmp_path / "swift"
    swift.write_text(FAKE_SWIFT)
    swift.chmod(0o755)
    attempts = tmp_path / "attempts.log"
    env = {k: v for k, v in os.environ.items() if k not in ("SDKROOT", "PORTICO_SDKROOT", "PORTICO_SDK_CANDIDATES")}
    env.update(
        PORTICO_SWIFT=str(swift),
        DEVELOPER_DIR=str(dev),
        ATTEMPTS=str(attempts),
        PRODUCTS=str(products),
    )
    return {
        "repo": repo,
        "env": env,
        "attempts": attempts,
        "products": products,
        "newest": newest.resolve(),
        "middle": middle.resolve(),
        "oldest": oldest.resolve(),
    }


def attempts(b: dict[str, object]) -> list[str]:
    return Path(b["attempts"]).read_text().splitlines()  # type: ignore[arg-type]


def record(b: dict[str, object]) -> dict[str, str]:
    path = Path(b["repo"]) / "app" / ".build" / "portico-build.env"  # type: ignore[arg-type]
    return dict(line.split("=", 1) for line in path.read_text().splitlines())


def test_default_sdk_that_builds_is_used_without_fallback(build_env: dict[str, object]) -> None:
    env = {**build_env["env"], "DEFAULT_OK": "1"}  # type: ignore[dict-item]
    done = run([BUILD_APP, build_env["repo"]], env)
    assert done.returncode == 0, done.stderr
    assert done.stdout.strip().splitlines()[-1] == str(build_env["products"])
    assert attempts(build_env) == ["<default>"]
    assert record(build_env)["chosen"] == "default"
    assert "error" not in done.stderr


def test_failing_default_falls_back_newest_first_and_says_which_worked(build_env: dict[str, object]) -> None:
    env = {**build_env["env"], "GOOD_SDK": str(build_env["oldest"])}  # type: ignore[dict-item]
    done = run([BUILD_APP, build_env["repo"]], env)
    assert done.returncode == 0, done.stderr
    # The aliases (MacOSX.sdk, MacOSX26.sdk) are tried once, by their real paths, newest first.
    assert attempts(build_env) == ["<default>", str(build_env["newest"]), str(build_env["middle"]), str(build_env["oldest"])]
    assert f"built with the macOS 15.5 SDK ({build_env['oldest']})" in done.stderr
    assert "cannot find" not in done.stderr  # compiler output stays quiet when an attempt succeeds
    rec = record(build_env)
    assert rec == {"sdk": str(build_env["oldest"]), "sdk_version": "15.5", "chosen": "fallback"}


def test_every_sdk_failing_shows_the_last_attempts_errors_plainly(build_env: dict[str, object]) -> None:
    done = run([BUILD_APP, build_env["repo"]], build_env["env"])  # type: ignore[arg-type]
    assert done.returncode == 1
    assert "did not build with any installed macOS SDK" in done.stderr
    assert "macOS 27.0 SDK" in done.stderr and "macOS 15.5 SDK" in done.stderr
    assert "error: cannot find '$x' in scope" in done.stderr  # colour codes stripped
    assert "some noise" not in done.stderr
    assert "PORTICO_SDKROOT" in done.stderr
    assert done.stdout == ""


def test_candidates_can_be_given_explicitly(build_env: dict[str, object], tmp_path: Path) -> None:
    other = make_sdk(tmp_path / "elsewhere", "MacOSX26.1.sdk", "26.1")
    env = {**build_env["env"], "GOOD_SDK": str(other.resolve()), "PORTICO_SDK_CANDIDATES": f"{build_env['middle']}\n{other}"}  # type: ignore[dict-item]
    done = run([BUILD_APP, build_env["repo"]], env)
    assert done.returncode == 0, done.stderr
    assert attempts(build_env) == ["<default>", str(build_env["middle"]), str(other)]


def test_portico_sdkroot_is_the_only_sdk_tried(build_env: dict[str, object]) -> None:
    env = {**build_env["env"], "PORTICO_SDKROOT": str(build_env["middle"]), "GOOD_SDK": str(build_env["middle"])}  # type: ignore[dict-item]
    done = run([BUILD_APP, build_env["repo"]], env)
    assert done.returncode == 0, done.stderr
    assert attempts(build_env) == [str(build_env["middle"])]
    assert record(build_env)["chosen"] == "PORTICO_SDKROOT"

    Path(build_env["attempts"]).unlink()  # type: ignore[arg-type]
    env["GOOD_SDK"] = "/nowhere"
    done = run([BUILD_APP, build_env["repo"]], env)
    assert done.returncode == 1
    assert attempts(build_env) == [str(build_env["middle"])]  # no fallback when the SDK is chosen by hand
    assert "does not build with the SDK in PORTICO_SDKROOT" in done.stderr and "error: cannot find" in done.stderr


# --- the .app -----------------------------------------------------------------


@pytest.fixture
def products(tmp_path: Path) -> Path:
    """A release-build stand-in: an executable named Portico and a SwiftPM resource bundle."""
    out = tmp_path / "products"
    (out / "Portico_Portico.bundle" / "Resources").mkdir(parents=True)
    (out / "Portico_Portico.bundle" / "Resources" / "viewer.html").write_text("<html></html>")
    shutil.copyfile("/usr/bin/true", out / "Portico")
    (out / "Portico").chmod(0o755)
    return out


def make_app(
    products: Path,
    dest: Path,
    name: str = "Acme Agent",
    icon: Path = DEFAULT_ICON,
    extra: list[object] | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return run(
        [
            MAKE_APP,
            "--products", products,
            "--dest", dest,
            "--name", name,
            "--icon", icon,
            "--version", "0.3.0",
            "--gateway-bin", "/opt/portico/bin/portico-gateway",
            "--min-macos", "15.0",
            *(extra or []),
        ],
        env,
    )  # fmt: skip


def test_app_bundle_has_the_info_plist_keys(products: Path, tmp_path: Path) -> None:
    dest = tmp_path / "Applications"
    done = make_app(products, dest)
    assert done.returncode == 0, done.stderr
    app = dest / "Acme Agent.app"
    assert done.stdout.strip().splitlines()[-1] == str(app.resolve())
    with (app / "Contents" / "Info.plist").open("rb") as f:
        info = plistlib.load(f)
    assert info["CFBundleName"] == info["CFBundleDisplayName"] == "Acme Agent"
    assert info["CFBundleIdentifier"] == "dev.portico.acme-agent"
    assert info["CFBundleExecutable"] == "Acme Agent"
    assert info["CFBundleIconFile"] == "AppIcon"
    assert info["CFBundlePackageType"] == "APPL"
    assert info["LSMinimumSystemVersion"] == "15.0"
    assert info["NSHighResolutionCapable"] is True
    assert info["CFBundleShortVersionString"] == "0.3.0"
    assert info["PorticoGatewayBin"] == "/opt/portico/bin/portico-gateway"
    assert os.access(app / "Contents" / "MacOS" / "Acme Agent", os.X_OK)
    assert (app / "Contents" / "Resources" / "Portico_Portico.bundle" / "Resources" / "viewer.html").is_file()
    assert run(["plutil", "-lint", app / "Contents" / "Info.plist"]).returncode == 0


def test_app_icon_has_every_size_and_the_bundle_verifies(products: Path, tmp_path: Path) -> None:
    dest = tmp_path / "Applications"
    assert make_app(products, dest).returncode == 0
    app = dest / "Acme Agent.app"
    icns = app / "Contents" / "Resources" / "AppIcon.icns"
    assert icns.is_file() and icns.stat().st_size > 10_000
    iconset = tmp_path / "out.iconset"
    assert run(["iconutil", "-c", "iconset", icns, "-o", iconset]).returncode == 0
    names = {p.name for p in iconset.iterdir()}
    for size in (16, 32, 128, 256, 512):
        assert f"icon_{size}x{size}.png" in names and f"icon_{size}x{size}@2x.png" in names
    verify = run(["codesign", "--verify", "--deep", "--strict", app])
    assert verify.returncode == 0, verify.stderr


def test_app_replaces_an_existing_bundle_and_leaves_no_temporaries(products: Path, tmp_path: Path) -> None:
    dest = tmp_path / "Applications"
    assert make_app(products, dest).returncode == 0
    stale = dest / "Acme Agent.app" / "Contents" / "stale-file"
    stale.write_text("from the old install")
    done = make_app(products, dest)
    assert done.returncode == 0, done.stderr
    assert not stale.exists()
    assert sorted(p.name for p in dest.iterdir()) == ["Acme Agent.app"]
    assert run(["codesign", "--verify", "--deep", "--strict", dest / "Acme Agent.app"]).returncode == 0


def test_app_name_becomes_a_safe_file_name_and_identifier(products: Path, tmp_path: Path) -> None:
    dest = tmp_path / "Applications"
    done = make_app(products, dest, name="Acme / Agent: Beta")
    assert done.returncode == 0, done.stderr
    app = dest / "Acme - Agent- Beta.app"
    with (app / "Contents" / "Info.plist").open("rb") as f:
        info = plistlib.load(f)
    assert info["CFBundleIdentifier"] == "dev.portico.acme-agent-beta"


def test_a_custom_icon_that_is_not_1024_is_scaled_with_a_warning(products: Path, tmp_path: Path) -> None:
    small = tmp_path / "small.png"
    assert run(["sips", "-z", "300", "300", DEFAULT_ICON, "--out", small]).returncode == 0
    done = make_app(products, tmp_path / "Applications", icon=small)
    assert done.returncode == 0, done.stderr
    assert "300x300" in done.stderr and "1024x1024" in done.stderr
    assert (tmp_path / "Applications" / "Acme Agent.app" / "Contents" / "Resources" / "AppIcon.icns").is_file()


def test_the_default_icon_is_a_1024_png() -> None:
    done = run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "format", DEFAULT_ICON])
    assert "pixelWidth: 1024" in done.stdout and "pixelHeight: 1024" in done.stdout and "format: png" in done.stdout


# --- the icon on the macOS grid (v0.5) --------------------------------------------


@pytest.fixture
def square_icon(tmp_path: Path) -> Path:
    """A full-bleed square 1024 PNG: the default icon flattened through JPEG (no alpha left)."""
    jpeg, png = tmp_path / "square.jpg", tmp_path / "square.png"
    assert run(["sips", "-s", "format", "jpeg", DEFAULT_ICON, "--out", jpeg]).returncode == 0
    assert run(["sips", "-s", "format", "png", jpeg, "--out", png]).returncode == 0
    return png


def shape(src: Path, out: Path) -> subprocess.CompletedProcess[str]:
    return run(["swift", SHAPE_ICON, src, out])


def test_a_full_bleed_square_icon_is_shaped_and_a_shaped_one_is_left_alone(square_icon: Path, tmp_path: Path) -> None:
    out = tmp_path / "shaped.png"
    done = shape(square_icon, out)
    assert done.returncode == 0, done.stderr
    assert done.stdout.strip() == "shaped"
    size = run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", out]).stdout
    assert "pixelWidth: 1024" in size and "pixelHeight: 1024" in size
    # Its corners are transparent now, so a second pass uses it as given, byte for byte.
    again = tmp_path / "again.png"
    done = shape(out, again)
    assert done.returncode == 0 and done.stdout.strip() == "as given"
    assert again.read_bytes() == out.read_bytes()
    # Portico's own icon is already on the grid.
    assert shape(DEFAULT_ICON, tmp_path / "default.png").stdout.strip() == "as given"


def test_the_app_icon_of_a_square_png_comes_out_rounded(products: Path, square_icon: Path, tmp_path: Path) -> None:
    dest = tmp_path / "Applications"
    done = make_app(products, dest, icon=square_icon)
    assert done.returncode == 0, done.stderr
    iconset = tmp_path / "out.iconset"
    icns = dest / "Acme Agent.app" / "Contents" / "Resources" / "AppIcon.icns"
    assert run(["iconutil", "-c", "iconset", icns, "-o", iconset]).returncode == 0
    largest = iconset / "icon_512x512@2x.png"
    assert shape(largest, tmp_path / "check.png").stdout.strip() == "as given"  # transparent corners


def test_when_the_icon_cannot_be_shaped_it_is_used_as_given_with_a_warning(products: Path, square_icon: Path, tmp_path: Path) -> None:
    env = {**os.environ, "PORTICO_SWIFT": "/usr/bin/false"}
    done = make_app(products, tmp_path / "Applications", icon=square_icon, env=env)
    assert done.returncode == 0, done.stderr
    assert "could not put" in done.stderr and "used as given" in done.stderr
    assert (tmp_path / "Applications" / "Acme Agent.app" / "Contents" / "Resources" / "AppIcon.icns").is_file()


def test_an_asset_catalog_is_copied_with_its_icon_name_and_the_icns_stays(products: Path, tmp_path: Path) -> None:
    car = tmp_path / "built" / "Assets.car"
    car.parent.mkdir()
    car.write_bytes(b"compiled asset catalog stand-in")
    dest = tmp_path / "Applications"
    done = make_app(products, dest, extra=["--icon-assets", car, "--icon-name", "AppIcon"])
    assert done.returncode == 0, done.stderr
    app = dest / "Acme Agent.app"
    assert (app / "Contents" / "Resources" / "Assets.car").read_bytes() == car.read_bytes()
    assert (app / "Contents" / "Resources" / "AppIcon.icns").is_file()
    with (app / "Contents" / "Info.plist").open("rb") as f:
        info = plistlib.load(f)
    assert info["CFBundleIconName"] == "AppIcon" and info["CFBundleIconFile"] == "AppIcon"
    assert run(["codesign", "--verify", "--deep", "--strict", app]).returncode == 0


def test_without_an_asset_catalog_there_is_no_icon_name(products: Path, tmp_path: Path) -> None:
    dest = tmp_path / "Applications"
    assert make_app(products, dest).returncode == 0
    with (dest / "Acme Agent.app" / "Contents" / "Info.plist").open("rb") as f:
        assert "CFBundleIconName" not in plistlib.load(f)
    assert not (dest / "Acme Agent.app" / "Contents" / "Resources" / "Assets.car").exists()


def test_asset_catalog_arguments_go_together_and_must_exist(products: Path, tmp_path: Path) -> None:
    dest = tmp_path / "Applications"
    done = make_app(products, dest, extra=["--icon-name", "AppIcon"])
    assert done.returncode == 2 and "go together" in done.stderr
    done = make_app(products, dest, extra=["--icon-assets", tmp_path / "missing.car", "--icon-name", "AppIcon"])
    assert done.returncode == 1 and "missing.car" in done.stderr
    assert not (dest / "Acme Agent.app").exists()


# --- prerequisites --------------------------------------------------------------


def stub(dir_: Path, name: str, body: str) -> None:
    path = dir_ / name
    path.write_text("#!/bin/bash\n" + body + "\n")
    path.chmod(0o755)


@pytest.fixture
def prereq_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    (repo / "gateway").mkdir(parents=True)
    shutil.copy2(REPO_ROOT / "gateway" / "pyproject.toml", repo / "gateway" / "pyproject.toml")
    return repo


def prereq_env(stubs: Path) -> dict[str, str]:
    return {"PATH": f"{stubs}:/usr/bin:/bin", "HOME": os.environ.get("HOME", "/tmp")}


def test_prereqs_without_command_line_tools_fail_in_plain_words(prereq_repo: Path, tmp_path: Path) -> None:
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    stub(stubs, "xcode-select", 'echo "xcode-select: error: unable to get active developer directory" >&2; exit 2')
    stub(stubs, "swift", 'echo "swift must not be asked" >&2; exit 99')
    stub(stubs, "uv", 'case "$1" in --version) echo "uv 0.10.8";; *) exit 2;; esac')
    done = run([PREREQS, prereq_repo], prereq_env(stubs))
    assert done.returncode == 1
    assert "FAIL command line tools: not installed. Run: xcode-select --install (Xcode is not needed)" in done.stdout
    assert "FAIL swift: not checked" in done.stdout
    assert "must not be asked" not in done.stdout + done.stderr
    assert "ok   uv: uv 0.10.8" in done.stdout


def test_prereqs_without_uv_fail_and_python_says_uv_provides_it(prereq_repo: Path, tmp_path: Path) -> None:
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    stub(stubs, "xcode-select", f'echo "{tmp_path}"')
    stub(stubs, "swift", 'echo "Apple Swift version 6.4 (swiftlang-6.4)"')
    done = run([PREREQS, prereq_repo], prereq_env(stubs))
    assert done.returncode == 1
    assert "ok   swift: Swift version 6.4" in done.stdout
    assert "FAIL uv: uv is not on PATH" in done.stdout and "docs.astral.sh/uv" in done.stdout
    assert "Python 3.13 comes from uv" in done.stdout


def test_prereqs_without_python_313_let_uv_provide_it(prereq_repo: Path, tmp_path: Path) -> None:
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    stub(stubs, "xcode-select", f'echo "{tmp_path}"')
    stub(stubs, "swift", 'echo "Apple Swift version 6.4"')
    stub(stubs, "uv", 'case "$1" in --version) echo "uv 0.10.8";; python) exit 2;; esac')
    stub(stubs, "python3", 'case "$*" in *print*) echo "3.9.6";; *) exit 1;; esac')
    done = run([PREREQS, prereq_repo], prereq_env(stubs))
    assert done.returncode == 0, done.stdout
    assert "ok   python: no Python 3.13 or newer yet; uv downloads a managed one during the install" in done.stdout
    assert "the system python3 is 3.9.6, which the gateway does not use" in done.stdout


def test_install_stops_before_installing_anything_when_a_prerequisite_is_missing(tmp_path: Path) -> None:
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    stub(stubs, "xcode-select", "exit 2")
    env = {**prereq_env(stubs), "PORTICO_APP_DIR": str(tmp_path / "Applications")}
    done = run([REPO_ROOT / "bin" / "install"], env)
    assert done.returncode == 1
    assert "FAIL command line tools" in done.stdout
    assert "nothing was installed" in done.stderr
    assert "uv sync" not in done.stdout
    assert not (tmp_path / "Applications").exists()


def test_install_stops_with_the_reason_when_the_config_does_not_load(tmp_path: Path) -> None:
    """v0.5: a config missing brand.agent_name used to build a default "Portico.app"."""
    if run([PREREQS, REPO_ROOT]).returncode != 0:
        pytest.skip("this machine does not meet the prerequisites")
    home = tmp_path / "home"
    home.mkdir()
    (home / "config.toml").write_text('[brand]\nname = "Front Door"\n')
    env = {**os.environ, "PORTICO_HOME": str(home), "PORTICO_APP_DIR": str(tmp_path / "Applications")}
    done = run([REPO_ROOT / "bin" / "install"], env)
    assert done.returncode == 1
    assert "brand.agent_name" in done.stderr and "Field required" in done.stderr
    assert "does not load" in done.stderr and "nothing was installed" in done.stderr
    assert "== app" not in done.stdout  # stopped before the build
    assert not (tmp_path / "Applications").exists()
