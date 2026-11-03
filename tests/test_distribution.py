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
    version = (REPO / "VERSION").read_text().strip()
    assert version == "0.17.0"
    assert f"## v{version} (" in (REPO / "CHANGELOG.md").read_text()


def test_scripts_assume_no_checkout_or_home_path():
    """v0.17 §5: the shipped scripts work from any checkout and any home folder."""
    import re

    scripts = sorted((REPO / "bin").iterdir()) + sorted((REPO / "app" / "Packaging").glob("*.sh"))
    assert len(scripts) >= 7
    state_literal = re.compile(r"(?<!\w)\.portico(?![\w-])")  # a folder, not dev.portico.<slug> or .portico-home
    hits: list[str] = []
    for f in scripts:
        for number, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            where = f"{f.relative_to(REPO)}:{number}"
            if "dev-projects" in line:
                hits.append(f"{where}: dev-projects")
            if "/Users/" in line:
                hits.append(f"{where}: /Users/")
            if not line.lstrip().startswith("#") and state_literal.search(line):
                hits.append(f"{where}: a .portico path")
    assert not hits, "scripts assume a place:\n" + "\n".join(hits)
