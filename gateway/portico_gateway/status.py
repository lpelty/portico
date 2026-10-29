"""Whether a gateway runs on a state directory, and what it is doing — for ``status``, ``stop`` and the doctor.

The signal is the gateway's own lock: a gateway holds ``gateway.lock`` for
as long as it runs (and wrote its pid into it), so a lock another process
holds is a running gateway and a lock anyone can take is none. What it is
doing comes from the running gateway itself (``GET /v1/status`` with the
token), so it is never stale. The lock file and the ledger stay internal:
``portico-gateway status --json`` is the documented signal.
"""

from __future__ import annotations

import fcntl
import json
import os
import signal
import time
import urllib.error
import urllib.request
from typing import Any

from .state import StateDir

STATUS_VERSION = 1
STATUS_PATH = "/v1/status"
HTTP_TIMEOUT = 2.0


def running_pid(state: StateDir) -> int | None:
    """The pid of the gateway holding ``state``'s lock, or ``None`` when no gateway runs there.

    Probing takes the lock for an instant when it is free; a gateway that
    starts in exactly that instant is refused as a second copy and can be
    started again.
    """
    try:
        fd = os.open(state.lock_path, os.O_RDONLY)
    except FileNotFoundError:
        return None
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raw = os.read(fd, 64).decode("ascii", errors="replace").strip()
            try:
                return int(raw.splitlines()[0])
            except (ValueError, IndexError):
                return 0  # held, but the pid is not written yet (the gateway is just starting)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return None
    finally:
        os.close(fd)


def live_status(state: StateDir) -> dict[str, Any] | None:
    """What the running gateway says at ``GET /v1/status``; ``None`` when it cannot be asked."""
    ledger = state.read_ledger()
    token = state.read_token()
    if ledger is None or token is None:
        return None
    request = urllib.request.Request(
        f"http://{ledger.host}:{ledger.port}{STATUS_PATH}", headers={"Authorization": f"Bearer {token}"}
    )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:  # noqa: S310 - loopback, our own gateway
            body = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, ValueError):
        return None
    return body if isinstance(body, dict) else None


def gateway_status(state: StateDir) -> dict[str, Any]:
    """``{"version": 1, "running": bool, ...}``: everything known, nothing guessed (unknown keys are left out)."""
    pid = running_pid(state)
    if pid is None:
        return {"version": STATUS_VERSION, "running": False}
    out: dict[str, Any] = {"version": STATUS_VERSION, "running": True}
    if pid:
        out["pid"] = pid
    live = live_status(state)
    if live is not None and (not pid or live.get("pid") == pid):
        out.update({k: v for k, v in live.items() if v is not None and k not in ("version", "running")})
    else:
        ledger = state.read_ledger()
        if ledger is not None and ledger.pid == pid:
            out["port"] = ledger.port
    return out


def describe(status: dict[str, Any], state: StateDir) -> str:
    """One human line for ``portico-gateway status``."""
    if not status.get("running"):
        return f"no gateway running on {state.path}"
    parts = [f"gateway running: pid {status.get('pid', '?')}"]
    if "port" in status:
        parts.append(f"port {status['port']}")
    if "session" in status:
        what = ", ".join(str(status[k]) for k in ("state", "mode") if k in status)
        parts.append(f"session {status['session']}" + (f" ({what})" if what else "") + (f" in {status['folder']}" if "folder" in status else ""))
    if "started_at" in status:
        parts.append(f"started {status['started_at']}")
    line = ", ".join(parts)
    if status.get("config_stale"):
        line += "; the config changed after it started: restart the gateway to apply"
    return line


def stop_gateway(state: StateDir, timeout: float) -> int | None:
    """SIGTERM the running gateway and wait for it to let go of its lock.

    Returns the pid that was stopped, ``None`` when none ran. Raises
    ``TimeoutError`` when it is still running after ``timeout`` seconds.
    The gateway's own stop path runs (turns interrupted and reported,
    ``on_stop``, the index saved), exactly as for ``gateway.stop``.
    """
    pid = running_pid(state)
    if pid is None:
        return None
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + timeout
    while running_pid(state) is not None:
        if time.monotonic() >= deadline:
            raise TimeoutError(f"the gateway (pid {pid}) is still running after {timeout:g} seconds")
        time.sleep(0.1)
    return pid
