"""v0.2: ``bin/update`` — the newest release tag by version order, ``--channel main``, local changes refused.

Each test builds a throwaway "upstream" repository in ``tmp_path`` holding
a copy of the real ``bin/update`` and stub ``bin/install`` / ``bin/doctor``
that only leave a mark, clones it, and runs the clone's ``bin/update``.
No network: ``origin`` is a local path.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from portico_gateway import REPO_ROOT

UPDATE = REPO_ROOT / "bin" / "update"

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="git is not on PATH")

GIT_ENV = {
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.invalid",
}


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=repo, env={**os.environ, **GIT_ENV}, check=True, capture_output=True, text=True
    ).stdout.strip()


STUB = """#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "{name} ran at $(cat "$here/../RELEASE")" >> "$here/../../{name}.log"
"""


def commit_release(repo: Path, version: str) -> None:
    (repo / "RELEASE").write_text(version + "\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", f"release {version}")
    git(repo, "tag", version)


@pytest.fixture
def upstream(tmp_path: Path) -> Path:
    repo = tmp_path / "upstream"
    (repo / "bin").mkdir(parents=True)
    shutil.copy2(UPDATE, repo / "bin" / "update")
    for name in ("install", "doctor"):
        stub = repo / "bin" / name
        stub.write_text(STUB.replace("{name}", name))
        stub.chmod(0o755)
    git(repo, "init", "-q", "-b", "main")
    commit_release(repo, "v0.1.0")
    return repo


@pytest.fixture
def clone(tmp_path: Path, upstream: Path) -> Path:
    path = tmp_path / "clone" / "portico"
    path.parent.mkdir()
    git(tmp_path, "clone", "-q", str(upstream), str(path))
    git(path, "-c", "advice.detachedHead=false", "checkout", "-q", "v0.1.0")
    return path


def update(clone: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(clone / "bin" / "update"), *args],
        cwd=clone,
        env={**os.environ, **GIT_ENV},
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
        timeout=60,
    )


def ran(clone: Path, name: str) -> list[str]:
    log = clone.parent / f"{name}.log"
    return log.read_text().splitlines() if log.exists() else []


def test_moves_to_the_newest_tag_in_version_order(upstream: Path, clone: Path) -> None:
    for version in ("v0.2.0", "v0.9.0", "v0.10.0"):
        commit_release(upstream, version)
    commit_release(upstream, "v0.11.0-rc1")  # not a release: ignored
    git(upstream, "tag", "not-a-version")

    result = update(clone)
    assert result.returncode == 0, result.stderr
    assert git(clone, "describe", "--tags", "--exact-match") == "v0.10.0"
    assert "v0.1.0 -> v0.10.0" in result.stdout
    assert ran(clone, "install") == ["install ran at v0.10.0"]
    assert ran(clone, "doctor") == ["doctor ran at v0.10.0"]


def test_moves_a_clone_from_v010_to_v020(upstream: Path, clone: Path) -> None:
    commit_release(upstream, "v0.2.0")
    result = update(clone)
    assert result.returncode == 0, result.stderr
    assert (clone / "RELEASE").read_text().strip() == "v0.2.0"


def test_already_on_the_newest_tag_only_runs_the_doctor(clone: Path) -> None:
    result = update(clone)
    assert result.returncode == 0, result.stderr
    assert "already on v0.1.0" in result.stdout
    assert ran(clone, "install") == []
    assert ran(clone, "doctor") == ["doctor ran at v0.1.0"]


def test_refuses_to_update_over_local_changes(upstream: Path, clone: Path) -> None:
    commit_release(upstream, "v0.2.0")
    (clone / "RELEASE").write_text("my local edit\n")
    result = update(clone)
    assert result.returncode == 1
    assert "plug-in" in result.stderr and "upstream" in result.stderr
    assert "RELEASE" in result.stderr
    assert git(clone, "describe", "--tags", "--exact-match") == "v0.1.0"
    assert (clone / "RELEASE").read_text() == "my local edit\n", "the local change is untouched"
    assert ran(clone, "install") == []


def test_an_untracked_file_in_the_checkout_is_a_local_change(upstream: Path, clone: Path) -> None:
    commit_release(upstream, "v0.2.0")
    (clone / "my_plugin.py").write_text("PORTICO_PLUGIN_API = 1\n")
    result = update(clone)
    assert result.returncode == 1
    assert "my_plugin.py" in result.stderr


def test_channel_main_fast_forwards_main(upstream: Path, clone: Path) -> None:
    (upstream / "NEWS").write_text("unreleased\n")
    git(upstream, "add", "NEWS")
    git(upstream, "commit", "-q", "-m", "work on main")
    result = update(clone, "--channel", "main")
    assert result.returncode == 0, result.stderr
    assert git(clone, "rev-parse", "--abbrev-ref", "HEAD") == "main"
    assert (clone / "NEWS").exists()
    assert ran(clone, "install") == ["install ran at v0.1.0"]


def test_no_release_tags_is_a_clear_error(upstream: Path, clone: Path) -> None:
    git(clone, "tag", "-d", "v0.1.0")
    git(upstream, "tag", "-d", "v0.1.0")
    result = update(clone)
    assert result.returncode == 1
    assert "no release tags" in result.stderr and "--channel main" in result.stderr


def test_an_unknown_channel_is_refused(clone: Path) -> None:
    result = update(clone, "--channel", "nightly")
    assert result.returncode == 2
    assert "nightly" in result.stderr
