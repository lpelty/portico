"""Spaces (v0.12): files the agent keeps current, listed from the deployment's spaces folder.

A space is one Markdown or HTML file; its id is the file name without the
extension. Its name, icon and order come from front matter (``---`` YAML-style
lines) or, for any file, a leading ``<!-- key: value -->`` block. The gateway
scans the folder (``scan``), watches it by modification time
(``SpacesWatcher``), and carries out the app's rename, remove, refresh and (v0.22) act.
Portico schedules nothing: the deployment rewrites the files.

Front matter is read with a small parser (``key: value`` lines, optional
quotes, trailing `` # comment``) rather than a YAML library: the gateway has no
YAML dependency and these keys need none.
"""

from __future__ import annotations

import asyncio
import codecs
import logging
import re
import shutil
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from .artifacts import media_for
from .lifecycle import run_command

log = logging.getLogger(__name__)

EXTENSIONS = (".md", ".markdown", ".html", ".htm")
DEFAULT_ICON = "doc.text"
# How often the folder is looked at.
SCAN_SECONDS = 5.0
# ``[spaces] refresh`` / ``remove`` / ``act`` commands, like ``[deployment]``'s.
COMMAND_SECONDS = 30.0
# Only the start of a file is read for its keys.
HEAD_BYTES = 64 * 1024
# v0.22: what ``space.act`` may name as its action and item (they reach a command's environment).
ACT_NAME = re.compile(r"[A-Za-z0-9._:-]{1,128}")


class SpaceError(Exception):
    """A space action that cannot be done; ``code`` is the ``error`` frame's code."""

    def __init__(self, message: str, code: str = "space.failed") -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class Space:
    id: str
    title: str
    icon: str
    order: int | None
    location: str
    media: str
    updated: str  # the file's modification time, UTC ISO 8601
    # v0.22: the space's own notification wording (``notice``; "" = none), the
    # fragment a click opens, and ``removable: false`` for a fixed space.
    notice: str | None = None
    notice_target: str | None = None
    removable: bool = True


# --- reading the keys -------------------------------------------------------------

_COMMENT_OPEN = "<!--"
_KEY_LINE = re.compile(r"^([A-Za-z_][\w-]*)\s*:(?:\s+(.*))?$")


def _decode_head(path: Path) -> str:
    """The start of ``path`` as text; ``UnicodeDecodeError`` for a file that is not UTF-8 (a cut at the end is fine)."""
    with path.open("rb") as f:
        raw = f.read(HEAD_BYTES)
    return codecs.getincrementaldecoder("utf-8")().decode(raw, final=False)


def _value(raw: str) -> str:
    """A value as written: quotes removed, a trailing `` # comment`` dropped from an unquoted one."""
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] in "\"'":
        quote = raw[0]
        end = raw.find(quote, 1)
        while quote == '"' and end > 0 and raw[end - 1] == "\\":
            end = raw.find(quote, end + 1)
        if end > 0:
            inner = raw[1:end]
            return inner.replace('\\"', '"').replace("\\\\", "\\") if quote == '"' else inner
    return re.split(r"\s+#", raw, maxsplit=1)[0].strip()


def _block(text: str) -> tuple[list[str], int, int] | None:
    """The leading key block of ``text``: (its lines, where they start, where the closing marker starts).

    ``None`` when there is none. Raises ``ValueError`` for one that never closes.
    """
    body = text.lstrip("\ufeff")
    lead = len(text) - len(body)
    if body.startswith("---"):
        first_end = body.find("\n")
        if first_end < 0 or body[:first_end].strip() != "---":
            return None
        start = first_end + 1
        pos = start
        while pos <= len(body):
            nl = body.find("\n", pos)
            line = body[pos : nl if nl >= 0 else len(body)]
            if line.strip() == "---":
                return body[start:pos].splitlines(), lead + start, lead + pos
            if nl < 0:
                break
            pos = nl + 1
        raise ValueError("front matter never closes")
    stripped = body.lstrip()
    if stripped.startswith(_COMMENT_OPEN):
        start = lead + (len(body) - len(stripped)) + len(_COMMENT_OPEN)
        end = text.find("-->", start)
        if end < 0:
            raise ValueError("comment block never closes")
        return text[start:end].split("\n"), start, end
    return None


def _parse(text: str) -> dict[str, str]:
    """The ``key: value`` pairs of the leading block ({} when none); ``ValueError`` when it is malformed."""
    found = _block(text)
    if found is None:
        return {}
    lines, _, _ = found
    comment = not text.lstrip("\ufeff").startswith("---")
    keys: dict[str, str] = {}
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#") or (not comment and line[0] in " \t-"):
            continue  # blank, a comment, or the inside of a nested value
        m = _KEY_LINE.match(line.strip())
        if not m:
            raise ValueError(f"not a key: {line.strip()[:40]!r}")
        keys[m.group(1).lower()] = _value(m.group(2) or "")
    return keys


def _updated(mtime: float) -> str:
    return datetime.fromtimestamp(mtime, UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")


def _space_for(path: Path) -> Space | None:
    """One file as a space, or ``None`` when it vanished. A file that cannot be read is listed by its stem."""
    try:
        mtime = path.stat().st_mtime
        resolved = path.resolve()
    except OSError:
        return None
    title, icon, order = path.stem, DEFAULT_ICON, None
    notice, notice_target, removable = None, None, True
    try:
        keys = _parse(_decode_head(path))
        order = int(keys["order"]) if keys.get("order") else None
        title = keys.get("title") or path.stem
        icon = keys.get("icon") or DEFAULT_ICON
        notice = keys.get("notice")  # "" is kept: it means no notification for an update
        notice_target = keys.get("notice_target", "").lstrip("#").strip() or None
        removable = keys.get("removable", "").strip().lower() not in ("false", "no")
    except (OSError, UnicodeDecodeError, ValueError) as e:
        if not isinstance(e, FileNotFoundError):
            log.debug("space %s: listed by its file name: %s", path.name, e)
        title, icon, order = path.stem, DEFAULT_ICON, None
        notice, notice_target, removable = None, None, True
    return Space(
        id=path.stem, title=title, icon=icon, order=order, location=str(resolved), media=media_for(path), updated=_updated(mtime),
        notice=notice, notice_target=notice_target, removable=removable,
    )


def _has_folder(path: Path) -> bool:
    """v0.21: a folder of the page's name sits beside it (``brief.html`` and ``brief/``)."""
    try:
        return (path.parent / path.stem).is_dir()
    except OSError:
        return False


def scan(folder: Path, require_folder: bool = False) -> list[Space]:
    """The spaces in ``folder`` (not looking inside folders), in the order the switcher shows them.

    ``.md``, ``.markdown``, ``.html`` and ``.htm`` files whose names do not
    start with ``.`` or ``_``; symbolic links are left out. Order by ``order`` (those without one last),
    then title. Two files with one stem: the first by name is the space.
    ``require_folder`` (v0.21, ``[spaces] require_folder``): only a page with
    a folder of its name beside it, so a README there for the agent is not a space.
    """
    try:
        names = sorted(p for p in Path(folder).iterdir() if p.suffix.lower() in EXTENSIONS and p.name[0] not in "._")
    except OSError:
        return []
    try:
        home = Path(folder).resolve()
    except (OSError, RuntimeError):
        return []
    out: dict[str, Space] = {}
    for path in names:
        try:
            # A link is never a space: rename would write, and remove would
            # trash, the file it points at, which may be anywhere.
            if path.is_symlink() or not path.is_file() or path.resolve().parent != home:
                continue
        except (OSError, RuntimeError):
            continue
        if require_folder and not _has_folder(path):
            continue
        space = _space_for(path)
        if space is not None and space.id not in out:
            out[space.id] = space
    return sorted(out.values(), key=lambda s: (s.order is None, s.order or 0, s.title.lower()))


def lookup(folder: Path, id: str, require_folder: bool = False) -> Space:
    """v0.22: space ``id`` as scanned; ``SpaceError`` (``space.not_found``) when there is none."""
    if not id or "/" in id or "\\" in id or id.startswith("."):
        raise SpaceError(f"there is no space {id!r}", "space.not_found")
    for space in scan(folder, require_folder):
        if space.id == id:
            return space
    raise SpaceError(f"there is no space {id!r}", "space.not_found")


def find(folder: Path, id: str, require_folder: bool = False) -> Path:
    """The file for space ``id``; ``SpaceError`` (``space.not_found``) when there is none."""
    return Path(lookup(folder, id, require_folder).location)


def fixed(space: Space) -> SpaceError:
    """v0.22: the refusal for a rename or remove of a space whose front matter says ``removable: false``."""
    return SpaceError(f"{space.title!r} is a fixed space; it cannot be removed or renamed", "space.fixed")


def space_id_for(folder: Path, location: str | Path, require_folder: bool = False) -> str | None:
    """The id of the space ``location`` is, else ``None``: a file directly in ``folder`` of a space's kind."""
    path = Path(location)
    try:
        if path.resolve().parent != Path(folder).resolve():
            return None
    except OSError:
        return None
    if path.suffix.lower() not in EXTENSIONS or path.name[0] in "._":
        return None
    if require_folder and not _has_folder(path):
        return None
    return path.stem


# --- watching ---------------------------------------------------------------------

OnChange = Callable[[list[Space]], Awaitable[None]]


class SpacesWatcher:
    """Looks at the folder every ``interval`` seconds and calls ``on_change`` only when the list differs."""

    def __init__(
        self, folder: Path, on_change: OnChange, interval: float = SCAN_SECONDS, require_folder: bool = False
    ) -> None:
        self.folder = Path(folder)
        self.on_change = on_change
        self.interval = interval
        self.require_folder = require_folder
        self.spaces: list[Space] = self.scan()

    def scan(self) -> list[Space]:
        return scan(self.folder, self.require_folder)

    async def poll(self) -> list[Space]:
        """Scan once; tell ``on_change`` if anything is different from last time."""
        current = await asyncio.to_thread(self.scan)
        if current != self.spaces:
            self.spaces = current
            await self.on_change(current)
        return current

    async def run(self) -> None:
        while True:
            await asyncio.sleep(self.interval)
            try:
                await self.poll()
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("spaces: the scan of %s failed; trying again", self.folder)


# --- rename -----------------------------------------------------------------------


def _key_of(line: str, comment: bool) -> str | None:
    """The key a block line sets (lowercased), or ``None`` for a blank, a comment, or the inside of a nested value."""
    if not line.strip() or line.lstrip().startswith("#") or (not comment and line[0] in " \t-"):
        return None
    m = _KEY_LINE.match(line.strip())
    return m.group(1).lower() if m else None


def _quote_if_needed(title: str) -> str:
    if (
        re.search(r"""[:#"'\[\]{}&*!|>%@`]|^\s|\s$|^[-?]""", title)
        or title.lower() in ("true", "false", "yes", "no", "on", "off", "y", "n", "null", "~")
        or re.fullmatch(r"[-+]?(\d[\d_]*\.?\d*([eE][-+]?\d+)?|\.\d+|0x[0-9a-fA-F]+|0o[0-7]+|\.inf|\.nan)", title, re.I)
    ):
        return '"' + title.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return title


def rename(folder: Path, id: str, title: str, require_folder: bool = False) -> None:
    """Write ``title`` as space ``id``'s title; every other key and the body stay as they are."""
    title = " ".join(title.split())
    if not title:
        raise SpaceError("a space needs a title", "space.invalid")
    space = lookup(folder, id, require_folder)
    if not space.removable:
        raise fixed(space)
    path = Path(space.location)
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise SpaceError(f"{path.name} could not be read: {e}") from None
    line = f"title: {_quote_if_needed(title)}"
    try:
        found = _block(text)
    except ValueError:
        found = None  # a block that never closes is left alone; a new one goes in front
    in_comment = (found is None and path.suffix.lower() in (".html", ".htm")) or (
        found is not None and not text.lstrip("\ufeff").startswith("---")
    )
    if in_comment and "--" in title:
        raise SpaceError('this space keeps its title in an HTML comment, which cannot hold "--"', "space.invalid")
    if found is None:
        new = f"<!-- {line} -->\n{text}" if path.suffix.lower() in (".html", ".htm") else f"---\n{line}\n---\n{text}"
    else:
        lines, start, close = found
        comment = not text.lstrip("\ufeff").startswith("---")
        for n, existing in enumerate(lines):
            if _key_of(existing, comment) == "title":
                pad = existing[: len(existing) - len(existing.lstrip())]
                lines[n] = pad + line + existing[len(existing.rstrip()) :]
                break
        else:
            if comment:
                lines[-1] = lines[-1].rstrip()
            lines.append(line)
        if comment:
            new = text[:start] + "\n".join(lines) + " " + text[close:]
        else:
            new = text[:start] + "".join(f"{each}\n" for each in lines) + text[close:]
    try:
        path.write_text(new, encoding="utf-8")
    except OSError as e:
        raise SpaceError(f"{path.name} could not be written: {e}") from None


# --- remove and refresh -----------------------------------------------------------


def _trash(path: Path) -> Path:
    """Move ``path`` into ``~/.Trash`` under a name that is not taken; where it went."""
    trash = Path.home() / ".Trash"
    try:
        trash.mkdir(exist_ok=True)
        target, n = trash / path.name, 1
        while target.exists() or target.is_symlink():
            n += 1
            target = trash / f"{path.stem} {n}{path.suffix}"
        shutil.move(str(path), str(target))
    except OSError as e:
        raise SpaceError(f"{path.name} could not be moved to the Trash: {e}") from None
    return target


async def _command(command: str, id: str, timeout: float, what: str, extra: dict[str, str] | None = None) -> None:
    lines: list[str] = []

    async def seen(line: str) -> None:
        lines.append(line)

    try:
        code = await run_command(command, seen, timeout, env={"PORTICO_SPACE": id, **(extra or {})})
    except TimeoutError:
        raise SpaceError(f"the {what} command did not finish in {timeout:g} s and was stopped") from None
    except OSError as e:
        raise SpaceError(f"the {what} command could not start: {e}") from None
    if code != 0:
        last = lines[-1].strip()[:200] if lines else ""
        log.error("spaces: %s command for %s exited %d: %s", what, id, code, last)
        raise SpaceError(f"the {what} command exited {code}" + (f": {last}" if last else ""))


async def remove(
    folder: Path, id: str, command: str | None, timeout: float = COMMAND_SECONDS, require_folder: bool = False
) -> None:
    """Move space ``id``'s file to the Trash, then run ``command`` (``$PORTICO_SPACE`` = id) so the deployment can drop it.

    A failing command is reported (``SpaceError``) after the file has gone.
    """
    space = await asyncio.to_thread(lookup, folder, id, require_folder)
    if not space.removable:
        raise fixed(space)  # v0.22: before anything is touched
    target = await asyncio.to_thread(_trash, Path(space.location))
    log.info("spaces: %s moved to %s", id, target)
    if command:
        try:
            await _command(command, id, timeout, "remove")
        except SpaceError as e:
            raise SpaceError(f"{e} (the file is already in the Trash)", e.code) from None


async def refresh(id: str, command: str, timeout: float = COMMAND_SECONDS) -> None:
    """Run the deployment's ``refresh`` command for space ``id`` (``$PORTICO_SPACE`` = id)."""
    await _command(command, id, timeout, "refresh")


async def act(id: str, action: str, item: str | None, command: str, timeout: float = COMMAND_SECONDS) -> None:
    """v0.22: run the deployment's ``act`` command for space ``id``.

    ``$PORTICO_SPACE``, ``$PORTICO_ACTION`` and ``$PORTICO_ITEM`` (empty with no item)
    reach it through the environment, never the command string.
    """
    if not ACT_NAME.fullmatch(action) or (item is not None and not ACT_NAME.fullmatch(item)):
        raise SpaceError("an action and an item are letters, digits and . _ : - (up to 128)", "protocol.invalid")
    await _command(command, id, timeout, "act", {"PORTICO_ACTION": action, "PORTICO_ITEM": item or ""})


__all__ = [
    "DEFAULT_ICON",
    "Space",
    "SpaceError",
    "SpacesWatcher",
    "act",
    "find",
    "lookup",
    "refresh",
    "remove",
    "rename",
    "scan",
    "space_id_for",
]
