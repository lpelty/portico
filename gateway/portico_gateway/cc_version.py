"""v0.24: the version of Claude Code the engine runs (``claude --version``).

The custom-prompt change warning compares it with the version a captured
prompt file's header records. ``--version`` reads no settings and calls no
model.
"""

from __future__ import annotations

import subprocess
from collections.abc import Callable

# Said by the gateway log (once per engine version) and by doctor when they differ.
PROMPT_CHANGED = (
    "Claude Code's own prompt may have changed since your custom prompt was copied (v{old} → v{new}); "
    "run capture-prompt to compare."
)


def _run_version(args: list[str]) -> str | None:
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=15, stdin=subprocess.DEVNULL, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout if done.returncode == 0 else None


def claude_code_version(run: Callable[[list[str]], str | None] | None = None) -> str | None:
    """The engine's version (``2.1.310 (Claude Code)`` gives ``2.1.310``), or ``None`` when it can't say."""
    from .mcp_inventory import cli_path

    out = (run or _run_version)([cli_path(), "--version"])
    if not out or not out.strip():
        return None
    return out.split()[0]


class CachedVersion:
    """``claude_code_version`` asked once per process; the gateway keeps one."""

    def __init__(self, fn: Callable[[], str | None] = claude_code_version) -> None:
        self._fn = fn
        self._asked = False
        self._value: str | None = None

    def __call__(self) -> str | None:
        if not self._asked:
            self._value = self._fn()
            self._asked = True
        return self._value
