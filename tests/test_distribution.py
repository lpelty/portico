"""Distributed files never name a deployment, a company, or a household."""

import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
THIS = Path(__file__).resolve()

# The Global Constraints list, lowercased; matched case-insensitively.
FORBIDDEN = [
    "smartsheet",
    "atlas",
    "ethos",
    "lares",
    "daedalus",
    "hindsight",
    "chroma",
    "bedrock",
]


def _distributed_files() -> list[Path]:
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=REPO,
        check=True,
        capture_output=True,
    ).stdout
    files = [REPO / p for p in out.decode().split("\0") if p]
    return [f for f in files if f.is_file() and f != THIS]


def test_no_deployment_names_in_distributed_files():
    hits: list[str] = []
    for f in _distributed_files():
        text = f.read_text(encoding="utf-8", errors="ignore").lower()
        for token in FORBIDDEN:
            if token in text:
                hits.append(f"{f.relative_to(REPO)}: {token}")
    assert not hits, "forbidden tokens found:\n" + "\n".join(hits)


def test_version_and_changelog_agree():
    assert (REPO / "VERSION").read_text().strip() == "0.1.0"
    assert "## v0.1.0" in (REPO / "CHANGELOG.md").read_text()
