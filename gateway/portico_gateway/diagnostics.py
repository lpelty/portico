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
    (d / "README").write_text(README_TEXT + "\n", encoding="utf-8")
    switch = d / SWITCH
    fd = os.open(switch, os.O_WRONLY | os.O_CREAT, 0o600)
    os.close(fd)
    switch.chmod(0o600)
    return d


def turn_off(state: StateDir) -> int:
    """Delete the whole diagnostics directory and nothing else; return the files removed (0 when absent)."""
    d = diagnostics_dir(state)
    if not d.is_dir():
        return 0
    removed = sum(1 for p in d.rglob("*") if p.is_file() or p.is_symlink())
    shutil.rmtree(d, ignore_errors=True)
    return removed


def status(state: StateDir) -> dict:
    """``{"on": bool, "files": [{"name": relative path, "bytes": size}]}``, files sorted by name."""
    d = diagnostics_dir(state)
    files = sorted(
        ({"name": p.relative_to(d).as_posix(), "bytes": p.stat().st_size} for p in d.rglob("*") if p.is_file()),
        key=lambda f: f["name"],
    ) if d.is_dir() else []
    return {"on": (d / SWITCH).is_file(), "files": files}
