"""The person's PATH, as their login shell has it (v0.11, item 57).

Started from the app, the gateway inherits launchd's PATH
(``/usr/bin:/bin:/usr/sbin:/sbin``), so ``npx``, ``node``, ``uvx`` and
anything in Homebrew or ``~/.local/bin`` are missing for the engine and its
MCP servers. ``login_shell_path`` asks ``$SHELL -l -i -c`` for its PATH,
between markers (an interactive shell may print a banner), and ``merged``
puts it first, keeping the inherited entries it lacks.
"""

from __future__ import annotations

import logging
import os
import subprocess
from collections.abc import Mapping, MutableMapping

log = logging.getLogger(__name__)

TIMEOUT = 5.0
_START = "__PORTICO_PATH_START__"
_END = "__PORTICO_PATH_END__"


def login_shell_path(env: Mapping[str, str], timeout: float = TIMEOUT) -> str | None:
    """The PATH the person's login shell sets, or None when it can't be read."""
    shell = env.get("SHELL") or ""
    if not shell or not os.path.isabs(shell) or not os.access(shell, os.X_OK):
        log.warning("login shell PATH not read: no usable $SHELL (%r)", shell)
        return None
    script = f'printf "%s%s%s" "{_START}" "$PATH" "{_END}"'
    try:
        done = subprocess.run(
            [shell, "-l", "-i", "-c", script],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=timeout,
            env=dict(env),
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        log.warning("login shell PATH not read from %s: %s", shell, e)
        return None
    out = done.stdout.decode("utf-8", "replace")
    start = out.rfind(_START)
    end = out.find(_END, start + len(_START)) if start >= 0 else -1
    if start < 0 or end < 0:
        log.warning("login shell PATH not read from %s: no PATH in its output", shell)
        return None
    path = out[start + len(_START) : end].strip()
    return path or None


def merged(first: str, rest: str) -> str:
    """``first``'s entries, then ``rest``'s that ``first`` lacks; empties and repeats dropped."""
    out: list[str] = []
    for entry in [*first.split(os.pathsep), *rest.split(os.pathsep)]:
        if entry and entry not in out:
            out.append(entry)
    return os.pathsep.join(out)


def apply_login_shell_path(env: MutableMapping[str, str], timeout: float = TIMEOUT) -> bool:
    """Put the login shell's PATH first in ``env``; True when it was read."""
    path = login_shell_path(env, timeout)
    if path is None:
        return False
    env["PATH"] = merged(path, env.get("PATH", ""))
    log.info("PATH from the login shell: %s", env["PATH"])
    return True
