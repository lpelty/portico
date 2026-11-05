"""The app builds on a Mac with only the Command Line Tools (v0.18.1).

Most people who install the app have no Xcode. SwiftUI's macro plugin
(libSwiftUIMacros) ships only with Xcode, so any SwiftUI macro in the app's
source breaks their build while every build on a Mac with Xcode passes.
"""

import os
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SOURCES = REPO / "app" / "Sources"
CLT = Path("/Library/Developer/CommandLineTools")

# SwiftUI's macros that need Xcode's plugin. @State and friends are macros only
# in the 27 SDK, which the build script falls back from; these fail on every SDK.
XCODE_ONLY = re.compile(r"@Entry\b|@Previewable\b|#Preview\b")


def test_the_source_uses_no_swiftui_macro_that_needs_xcode():
    hits: list[str] = []
    for f in sorted(SOURCES.rglob("*.swift")):
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("//", 1)[0]
            if XCODE_ONLY.search(code):
                hits.append(f"{f.relative_to(REPO)}:{n}: {line.strip()}")
    assert not hits, "Xcode-only SwiftUI macros (write the EnvironmentKey by hand):\n" + "\n".join(hits)


@pytest.mark.skipif(os.environ.get("PORTICO_CLT_BUILD") != "1", reason="opt-in: PORTICO_CLT_BUILD=1, a release check")
@pytest.mark.skipif(not CLT.is_dir(), reason="the Command Line Tools are not installed")
def test_the_app_builds_with_only_the_command_line_tools():
    env = {**os.environ, "DEVELOPER_DIR": str(CLT)}
    env.pop("SDKROOT", None)
    env.pop("PORTICO_SDKROOT", None)
    done = subprocess.run(
        ["bash", str(REPO / "app" / "Packaging" / "build-app.sh"), str(REPO)],
        env=env,
        capture_output=True,
        text=True,
        timeout=1800,
        stdin=subprocess.DEVNULL,
    )
    assert done.returncode == 0, done.stderr[-4000:]
