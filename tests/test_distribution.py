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
    assert version == "0.26.1"
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


def test_editor_bundle_matches_its_sources():
    """v0.20 §5: editor.js carries the hash of the editor's sources, so a
    change to app/Editor without `app/Editor/build.sh` fails here."""
    import hashlib

    editor = REPO / "app" / "Editor"
    digest = hashlib.sha256()
    for f in sorted((editor / "src").glob("*.ts"), key=lambda p: p.name.encode()):
        digest.update(f.read_bytes())
    for name in ("build.sh", "bundle.mjs", "package-lock.json"):
        digest.update((editor / name).read_bytes())
    bundle = REPO / "app" / "Sources" / "Portico" / "Resources" / "editor.js"
    first = bundle.read_text(encoding="utf-8").split("\n", 1)[0]
    assert first == f"/* portico-editor {digest.hexdigest()} */", "editor.js is stale: run app/Editor/build.sh"


def test_editor_page_has_each_placeholder_once():
    """The app replaces every occurrence; one in a comment would inline the bundle there."""
    page = (REPO / "app" / "Sources" / "Portico" / "Resources" / "editor.html").read_text(encoding="utf-8")
    for placeholder in ("{{CSS}}", "{{EDITOR}}"):
        assert page.count(placeholder) == 1, placeholder
    bundle = (REPO / "app" / "Sources" / "Portico" / "Resources" / "editor.js").read_text(encoding="utf-8")
    assert "{{" + "CSS}}" not in bundle and "{{" + "EDITOR}}" not in bundle
