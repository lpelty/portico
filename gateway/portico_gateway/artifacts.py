"""Artifacts: what a turn produced, found without any deployment knowledge.

An artifact is a file or a URL the person may want to see. The gateway
finds them from three signals (spec §5.3), plus the explicit producer
endpoint the server exposes (``POST /v1/artifact``):

1. **Tool events** — the file-writing tools (``Write``, ``Edit``,
   ``MultiEdit``, ``NotebookEdit``) name the path they touch.
2. **Local URLs in the agent's text** — ``http://localhost[:port]/…`` and
   ``http://127.0.0.1[:port]/…``; a dev server is just a URL.
3. **Viewable paths named in the agent's text** that exist on disk when
   the turn ends — a report a script wrote through the shell produces no
   file-tool event, but the agent nearly always names the path.

The ``TurnCollector`` gathers those signals through one turn and settles
them at ``finish``: duplicates by location collapse into one artifact (the
first signal decides the ``source``, the last mention decides the order),
a file must exist on disk to count (a denied or failed write leaves
nothing), and ``open`` is true on exactly one artifact — the newest
viewable one — or on none. Everything else is listed for the history and
never auto-opens: source files, configs, plain text, anything the viewer
cannot render.

v0.10 decision 6: a file the text merely names that was not changed
during the turn (an earlier file the reply mentions in passing) is listed
but never takes ``open`` from what the turn made. A file the agent showed
during the turn (``show_in_viewer``, or a caught ``open``) was reported
then: it is not reported again, and when it is the newest, nothing else
opens over it.

The gateway never diffs the folder. A deployment that needs more is a
producer.
"""

from __future__ import annotations

import os
import re
import time
import uuid
from collections.abc import Iterable
from pathlib import Path
from typing import TYPE_CHECKING, Any, get_args

from .messages import Artifact, Media

if TYPE_CHECKING:
    from .chats import Chat

__all__ = [
    "FILE_TOOLS",
    "TEXT_EXTENSIONS",
    "VIEWABLE_MEDIA",
    "TurnCollector",
    "artifact_for_location",
    "from_tool",
    "is_url",
    "is_viewable",
    "media_for",
    "new_artifact_id",
    "paths_in",
    "title_for",
    "urls_in",
]

MEDIA_BY_EXTENSION: dict[str, Media] = {
    ".md": "markdown",
    ".markdown": "markdown",
    ".png": "image",
    ".jpg": "image",
    ".jpeg": "image",
    ".gif": "image",
    ".webp": "image",
    ".svg": "image",
    ".html": "html",
    ".htm": "html",
    ".pdf": "pdf",
}

# Plain text and code: the viewer draws these monospaced (and `.csv`/`.tsv`
# as a table, by extension). Still `text`, never a new media word, so an
# older app decodes them; `text` never auto-opens.
TEXT_EXTENSIONS: tuple[str, ...] = (
    ".txt", ".log", ".csv", ".tsv",
    ".json", ".jsonl", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf", ".xml", ".plist",
    ".py", ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".swift", ".rb", ".go", ".rs",
    ".java", ".kt", ".c", ".h", ".cpp", ".hpp", ".m", ".cs", ".php", ".pl", ".lua", ".r",
    ".sh", ".bash", ".zsh", ".fish", ".css", ".scss", ".sql", ".diff", ".patch",
)
MEDIA_BY_EXTENSION.update(dict.fromkeys(TEXT_EXTENSIONS, "text"))

# The kinds the viewer renders and therefore the only ones that auto-open.
VIEWABLE_MEDIA: frozenset[str] = frozenset({"markdown", "image", "html", "pdf", "url"})

# Tools whose input names the file they produce or change, and the input key.
FILE_TOOLS: dict[str, str] = {
    "Write": "file_path",
    "Edit": "file_path",
    "MultiEdit": "file_path",
    "NotebookEdit": "notebook_path",
}

_VIEWABLE_EXTENSIONS: frozenset[str] = frozenset(
    ext for ext, media in MEDIA_BY_EXTENSION.items() if media in VIEWABLE_MEDIA
)

# A local address: scheme, localhost or the loopback IP, optional port, optional path.
_LOCAL_URL = re.compile(r"https?://(?:localhost|127\.0\.0\.1)(?::\d{1,5})?(?:/[^\s<>\"'`]*)?", re.IGNORECASE)
_URL_SCHEME = re.compile(r"^https?://", re.IGNORECASE)

# Characters that wrap or trail a path or URL in prose and markdown.
_WRAP = "`'\"()[]{}<>*_"
_TRAIL = ".,;:!?"
# The target of a markdown link, ``[label](target "title")``: a whitespace
# split sees ``label](target`` and never finds the file.
_LINK_TARGET = re.compile(r"\]\(\s*([^\s)]+)")

_ID_LENGTH = 12


def new_artifact_id() -> str:
    """A fresh artifact id, unique across chats and launches."""
    return f"art-{uuid.uuid4().hex[:_ID_LENGTH]}"


# --- media ----------------------------------------------------------------------


def media_for(path: Path) -> Media:
    """The media kind of a file by its extension; anything unknown is ``other``."""
    return MEDIA_BY_EXTENSION.get(Path(path).suffix.lower(), "other")


def is_viewable(media: str) -> bool:
    """``True`` for the kinds the viewer renders: markdown, image, html, pdf, url."""
    return media in VIEWABLE_MEDIA


def is_url(location: str) -> bool:
    return bool(_URL_SCHEME.match(location))


def title_for(location: str) -> str:
    """A URL's title is the URL; a file's is its name."""
    if is_url(location):
        return location
    return Path(location).name or location


# --- detection --------------------------------------------------------------------


def from_tool(tool: str, input: dict[str, Any]) -> Path | None:
    """The file a file-writing tool call names, or ``None`` for every other tool."""
    key = FILE_TOOLS.get(tool)
    if key is None:
        return None
    value = input.get(key)
    if not isinstance(value, str) or not value.strip():
        return None
    return Path(value)


def _strip(token: str) -> str:
    token = token.strip(_WRAP)
    return token.rstrip(_TRAIL).rstrip(_WRAP)


def _dedup(items: Iterable[Any]) -> list[Any]:
    seen: set[Any] = set()
    out: list[Any] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def _urls_at(text: str) -> list[tuple[int, str]]:
    """``(offset, url)`` for every local address in ``text``, in order of appearance."""
    found: list[tuple[int, str]] = []
    for match in _LOCAL_URL.finditer(text):
        url = match.group(0).rstrip(_TRAIL)
        # A closing bracket that was not opened inside the URL belongs to the prose.
        for open_char, close_char in ("()", "[]", "{}"):
            while url.endswith(close_char) and url.count(close_char) > url.count(open_char):
                url = url[:-1].rstrip(_TRAIL)
        found.append((match.start(), url))
    return found


def _existing_viewable(token: str, folder: Path) -> Path | None:
    """``token`` as a viewable file that exists (relative to ``folder``), or ``None``."""
    token = _strip(token)
    if not token or Path(token).suffix.lower() not in _VIEWABLE_EXTENSIONS or is_url(token):
        return None
    candidate = Path(token)
    if not candidate.is_absolute():
        candidate = folder / candidate
    return candidate if candidate.is_file() else None


def _paths_at(text: str, folder: Path) -> list[tuple[int, Path]]:
    """``(offset, path)`` for every viewable file named in ``text`` that exists, in order of appearance.

    Whitespace-separated tokens first, then the targets of markdown links.
    """
    folder = Path(folder)
    found: list[tuple[int, Path]] = []
    for match in re.finditer(r"\S+", text):
        candidate = _existing_viewable(match.group(0), folder)
        if candidate is not None:
            found.append((match.start(), candidate))
    for match in _LINK_TARGET.finditer(text):
        candidate = _existing_viewable(match.group(1), folder)
        if candidate is not None:
            found.append((match.start(1), candidate))
    return sorted(found, key=lambda item: item[0])


def urls_in(text: str) -> list[str]:
    """Local addresses (``localhost`` / ``127.0.0.1``) in ``text``, in order, without repeats."""
    return _dedup(url for _, url in _urls_at(text))


def paths_in(text: str, folder: Path) -> list[Path]:
    """Viewable files named in ``text`` that exist: absolute paths, or tokens relative to ``folder``."""
    return _dedup(path for _, path in _paths_at(text, folder))


# --- building artifacts -----------------------------------------------------------


def artifact_for_location(
    location: str, *, source: str, title: str | None = None, open: bool = False, folder: Path | None = None
) -> Artifact:
    """An ``Artifact`` for a file path or a URL. A relative path is resolved against ``folder``."""
    if is_url(location):
        return Artifact(
            id=new_artifact_id(),
            kind="url",
            location=location,
            media="url",
            title=title or location,
            source=source,  # type: ignore[arg-type]
            open=open,
        )
    path = Path(location)
    if not path.is_absolute() and folder is not None:
        path = Path(folder) / path
    return Artifact(
        id=new_artifact_id(),
        kind="file",
        location=str(path),
        media=media_for(path),
        title=title or path.name or str(path),
        source=source,  # type: ignore[arg-type]
        open=open,
    )


# --- the per-turn collector ---------------------------------------------------------


# How much older than the turn's start a named file's modification time may
# be and still count as changed during the turn (file systems round it).
MTIME_SLACK_SECONDS = 2.0


def _changed_since(path: Path, started: float) -> bool:
    try:
        return os.stat(path).st_mtime >= started - MTIME_SLACK_SECONDS
    except OSError:
        return False


def _stamp(path: Path) -> tuple[float, int] | None:
    """A file's modification time and size, for telling it was written again."""
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_mtime, st.st_size)


def _same_file(location: str) -> str:
    """A file location in the form two signals for one file agree on."""
    try:
        return str(Path(location).resolve())
    except OSError:
        return location


class TurnCollector:
    """Gathers one turn's artifact signals; ``finish`` settles them into artifacts."""

    def __init__(self, chat: Chat, started: float | None = None) -> None:
        self.chat = chat
        # When the turn began (wall clock), for telling a file the turn
        # changed from one the text only names.
        self.started = time.time() if started is None else started
        # In arrival order: ("tool", Path) for a file-writing tool call,
        # ("text", str) for a text delta, ("shown", Path) for a file shown
        # in the viewer during the turn.
        self._signals: list[tuple[str, Any]] = []

    def note_shown(self, path: Path) -> None:
        """A file was shown in the viewer during the turn (already reported, ``open``)."""
        self._signals.append(("shown", Path(path)))

    def note_tool(self, tool: str, input: dict[str, Any]) -> None:
        path = from_tool(tool, input)
        if path is not None:
            self._signals.append(("tool", path))

    def note_text(self, text: str) -> None:
        if text:
            self._signals.append(("text", text))

    def finish(self, folder: Path) -> list[Artifact]:
        """The turn's artifacts, one per location, ``open`` on the newest viewable one only."""
        folder = Path(folder)
        # location -> (source, last position); insertion order is the first mention.
        found: dict[str, tuple[str, int]] = {}
        position = 0

        def note(location: str, source: str) -> None:
            nonlocal position
            position += 1
            previous = found.get(location)
            found[location] = (previous[0] if previous else source, position)

        # Text is scanned as one body: a path or URL may be split across deltas.
        pending_text: list[str] = []

        def flush_text() -> None:
            if not pending_text:
                return
            text = "".join(pending_text)
            pending_text.clear()
            # URLs and paths in the order the text mentions them, so "newest" means last named.
            mentions: list[tuple[int, str]] = [(offset, url) for offset, url in _urls_at(text)]
            mentions += [(offset, str(path)) for offset, path in _paths_at(text, folder)]
            for _, location in sorted(mentions, key=lambda item: item[0]):
                note(location, "text")

        shown: set[str] = set()
        for kind, value in self._signals:
            if kind == "text":
                pending_text.append(value)
                continue
            flush_text()
            path: Path = value
            if kind == "shown":
                shown.add(_same_file(str(path)))
                note(str(path), "tool")
            elif path.is_file():
                note(str(path), "tool")
        flush_text()

        ordered = sorted(found.items(), key=lambda item: item[1][1])
        artifacts = [artifact_for_location(location, source=source) for location, (source, _) in ordered]
        artifacts = [a for a in artifacts if not self._already_listed(a)]
        for artifact in reversed(artifacts):
            if not is_viewable(artifact.media):
                continue
            if artifact.source == "text" and artifact.kind == "file" and not _changed_since(Path(artifact.location), self.started):
                continue
            artifact.open = True
            break
        out = [a for a in artifacts if a.kind != "file" or _same_file(a.location) not in shown]
        for artifact in out:
            if artifact.kind == "file":
                stamp = _stamp(Path(artifact.location))
                if stamp is not None:
                    self.chat.artifact_stamps[_same_file(artifact.location)] = stamp
        return out

    def _already_listed(self, artifact: Artifact) -> bool:
        """A file the chat already lists at this location and not written since: no new entry.

        Unchanged means the same modification time and size as when it was
        last listed; with none recorded (a stored artifact from before a
        restart), not changed during this turn.
        """
        if artifact.kind != "file":
            return False
        key = _same_file(artifact.location)
        if not any(a.kind == "file" and _same_file(a.location) == key for a in self.chat.artifacts):
            return False
        known = self.chat.artifact_stamps.get(key)
        if known is not None:
            return _stamp(Path(artifact.location)) == known
        return not _changed_since(Path(artifact.location), self.started)
