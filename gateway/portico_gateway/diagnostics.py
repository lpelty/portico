"""v0.26.4: the diagnostics switch — the deployment's Daedalus looks at the conversation view's behaviour.

Everything lives under ``<state>/diagnostics/``: the ``on`` file is the switch, ``README`` says what
the folder is, and the recordings and traces other parts write sit beside them. Nothing is ever
written at the state directory's root. Paths in, effects out; ``portico-gateway diagnostics`` is
the one caller (``__main__.cmd_diagnostics``).
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

from portico_gateway.state import StateDir

DIRNAME = "diagnostics"
SWITCH = "on"
README_TEXT = (
    "Diagnostics for the deployment's Daedalus to look at the conversation view's behaviour. "
    "Off unless turned on here. Recordings hold sizes, counts and ids, never text, and stay on this machine."
)


def diagnostics_dir(state: StateDir) -> Path:
    return state.path / DIRNAME


def turn_on(state: StateDir) -> Path:
    """Create ``<state>/diagnostics/`` (0700) with the ``on`` switch (0600) and the README; safe to repeat."""
    d = diagnostics_dir(state)
    d.mkdir(mode=0o700, exist_ok=True)
    d.chmod(0o700)
    readme = d / "README"
    fd = os.open(readme, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(README_TEXT + "\n")
    readme.chmod(0o600)
    switch = d / SWITCH
    fd = os.open(switch, os.O_WRONLY | os.O_CREAT, 0o600)
    os.close(fd)
    switch.chmod(0o600)
    return d


class DiagnosticsError(OSError):
    """``turn_off`` could not delete everything; the message names what remains."""


def turn_off(state: StateDir) -> int:
    """Delete the whole diagnostics directory and nothing else; return the files removed (0 when absent).

    A ``diagnostics`` symlink is unlinked, never followed. Raises ``DiagnosticsError`` naming what
    remains when the directory is still there afterwards.
    """
    d = diagnostics_dir(state)
    if d.is_symlink():
        d.unlink()
        return 0
    if not d.is_dir():
        return 0
    removed = sum(1 for p in d.rglob("*") if p.is_file() or p.is_symlink())
    errors: list[str] = []
    shutil.rmtree(d, onerror=lambda _fn, path, exc: errors.append(f"{path}: {exc[1].strerror or exc[1]}"))
    if d.exists() or d.is_symlink():
        left = sorted(p.relative_to(d).as_posix() for p in d.rglob("*")) if d.is_dir() else []
        detail = "; ".join(errors[:3]) or "unknown error"
        raise DiagnosticsError(f"could not delete {d} ({detail}); remains: {', '.join(left[:10]) or 'the directory'}")
    return removed


def status(state: StateDir) -> dict:
    """``{"on": bool, "files": [{"name": relative path, "bytes": size}]}``, files sorted by name."""
    d = diagnostics_dir(state)
    files = sorted(
        ({"name": p.relative_to(d).as_posix(), "bytes": p.stat().st_size} for p in d.rglob("*") if p.is_file()),
        key=lambda f: f["name"],
    ) if d.is_dir() else []
    return {"on": (d / SWITCH).is_file(), "files": files}
