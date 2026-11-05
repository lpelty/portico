"""Messages from the deployment (v0.22): a drop folder the gateway polls.

The deployment's routines are scripts. One writes a JSON file into
``<state dir>/messages/`` (``portico-gateway message`` does it, or write the file
directly: ``text`` required; ``title``, ``notify``, ``space``, ``id``, ``ts``
optional; other keys are ignored). The gateway sends each file to the attached
app as ``deployment.message`` and deletes it. A file that does not parse is moved
to ``messages/failed/``. With no app that can show one, files wait, up to
``HOLD_MAX`` (the oldest are dropped beyond that), and go out on the next hello.
No socket, no token: a file survives the gateway restarting.
"""

from __future__ import annotations

import json
import logging
import os
import secrets
import shutil
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .messages import DeploymentMessage

log = logging.getLogger(__name__)

DIRNAME = "messages"
FAILED = "failed"
# How often the folder is looked at.
POLL_SECONDS = 2.0
# How many files wait for an app; the oldest beyond this are deleted.
HOLD_MAX = 50
# A drop file larger than this is not a message.
MAX_BYTES = 256 * 1024


class DropError(Exception):
    """A drop file that cannot be a message; the text says why (it goes in the log)."""


def messages_dir(state_path: Path) -> Path:
    return Path(state_path) / DIRNAME


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def write_message(
    state_path: Path, text: str, title: str | None = None, notify: bool = False, space: str | None = None
) -> Path:
    """Write one drop file under ``state_path``; the file appears whole (written aside, then renamed)."""
    folder = messages_dir(state_path)
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
    ident = f"{stamp}-{secrets.token_hex(4)}"
    body: dict[str, Any] = {"id": ident, "ts": _now(), "text": text}
    if title:
        body["title"] = title
    if notify:
        body["notify"] = True
    if space:
        body["space"] = space
    path = folder / f"{ident}.json"
    aside = folder / f".{ident}.tmp"
    aside.write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")
    os.replace(aside, path)
    return path


def _age(path: Path) -> tuple[int, str]:
    try:
        return path.stat().st_mtime_ns, path.name
    except OSError:
        return 0, path.name


def pending(folder: Path) -> list[Path]:
    """The ``.json`` files waiting in ``folder`` (not looking inside folders), oldest first."""
    try:
        found = [p for p in Path(folder).iterdir() if p.suffix == ".json" and p.name[0] != "." and p.is_file()]
    except OSError:
        return []
    return sorted(found, key=_age)


def _optional(raw: dict[str, Any], key: str, kind: type) -> Any:
    value = raw.get(key)
    if value is not None and not isinstance(value, kind):
        raise DropError(f"{key!r} must be {'true or false' if kind is bool else 'text'}")
    return value


def read_message(path: Path) -> DeploymentMessage:
    """The frame a drop file makes; ``DropError`` when it cannot be one. ``id`` defaults to the file's stem, ``ts`` to now."""
    try:
        if path.stat().st_size > MAX_BYTES:
            raise DropError(f"larger than {MAX_BYTES // 1024} KB")
        raw = json.loads(path.read_text(encoding="utf-8"))
    except OSError as e:
        raise DropError(f"could not be read: {e}") from None
    except (UnicodeDecodeError, ValueError) as e:
        raise DropError(f"is not JSON: {e}") from None
    if not isinstance(raw, dict):
        raise DropError("is not a JSON object")
    text = raw.get("text")
    if not isinstance(text, str) or not text.strip():
        raise DropError("has no text")
    ident = _optional(raw, "id", str) or path.stem
    return DeploymentMessage(
        ts=_optional(raw, "ts", str) or _now(),
        id=ident,
        text=text,
        title=_optional(raw, "title", str) or None,
        notify=_optional(raw, "notify", bool) or None,
        space=_optional(raw, "space", str) or None,
    )


def quarantine(path: Path) -> None:
    """Move an unusable file to ``failed/`` beside it, under a name that is not taken."""
    failed = path.parent / FAILED
    try:
        failed.mkdir(mode=0o700, exist_ok=True)
        target, n = failed / path.name, 1
        while target.exists():
            n += 1
            target = failed / f"{path.stem} {n}{path.suffix}"
        shutil.move(str(path), str(target))
    except OSError as e:
        log.error("messages: %s could not be moved to failed/: %s", path.name, e)


def trim(files: list[Path], keep: int = HOLD_MAX) -> list[Path]:
    """Delete all but the newest ``keep`` of ``files`` (oldest first); the ones kept."""
    over = max(0, len(files) - keep)
    for path in files[:over]:
        log.warning("messages: more than %d are waiting; %s dropped", keep, path.name)
        try:
            path.unlink()
        except OSError:
            pass
    return files[over:]


__all__ = [
    "HOLD_MAX",
    "POLL_SECONDS",
    "DropError",
    "messages_dir",
    "pending",
    "quarantine",
    "read_message",
    "trim",
    "write_message",
]
