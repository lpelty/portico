"""The gateway's state directory: token, ledger, index, lock.

Everything the gateway keeps between launches lives in one directory,
``$PORTICO_HOME`` or ``~/.portico``:

- ``token``        per-launch secret the app presents at connect (mode 0600)
- ``ledger.json``  host, port, pid, epoch of the running gateway — a hint the
                   app probes with ``hello`` and the token, never trusted
- ``index.json``   the chats: numbers, folders, engine session ids, artifacts
- ``gateway.lock`` flock that refuses a second gateway on the same directory
- ``config.toml``  the deployment's configuration (read by ``config.py``)
"""

from __future__ import annotations

import fcntl
import os
import secrets
import tempfile
from pathlib import Path

from pydantic import BaseModel, ConfigDict, ValidationError

from .messages import Artifact, ChatStateWord, PermissionMode, PermissionOutcome

ENV_HOME = "PORTICO_HOME"
DEFAULT_DIRNAME = ".portico"


class StateError(Exception):
    """State on disk that cannot be used; the message says which file and why."""


class Ledger(BaseModel):
    """Where the running gateway is listening. Written at ready, read by the app."""

    model_config = ConfigDict(extra="forbid")

    host: str
    port: int
    pid: int
    epoch: str


class ToolPermission(BaseModel):
    """What became of one tool use's permission (v0.3), drawn on its tool row."""

    model_config = ConfigDict(extra="forbid")

    outcome: PermissionOutcome
    note: str | None = None


class ChatRecord(BaseModel):
    """One chat as the gateway remembers it across launches.

    ``state`` is one of the protocol's exact words, so a hand-edited or
    foreign-written index with any other word fails in ``load_index`` as a
    ``StateError`` (one plain line) rather than deep inside the registry.
    """

    chat: int
    folder: str
    session_id: str | None = None
    alias: str | None = None
    state: ChatStateWord
    created: str
    artifacts: list[Artifact] = []
    # Session facts (v0.2). Defaults so a v0.1 index loads unchanged.
    title: str | None = None
    ended: str | None = None
    logged: bool | None = None
    parent: int | None = None
    compactions: int = 0
    context_percent: float | None = None
    # v0.3: the session's permission mode (``None`` in a v0.2 index: the
    # deployment's ``permission_mode`` applies).
    mode: PermissionMode | None = None
    # v0.3: the session's chat-scoped allows ("Allow for this session"), so
    # a gateway restart keeps them; a new session starts with none.
    allows: list[str] = []
    # v0.3: the permission outcome of each tool use that had one, by
    # ``tool_use_id`` (newest ``TOOL_PERMISSIONS_KEPT``), so rows replayed
    # from the transcript after a restart read as they did live.
    permissions: dict[str, ToolPermission] = {}
    # v0.4: when the session was last logged (``session.log``, or a
    # renewal's log step that finished cleanly), and whether a turn has
    # finished since (``None`` in an older index: the registry infers it).
    logged_at: str | None = None
    work_since_log: bool | None = None
    # v0.6: when a turn last finished (``None`` before the first, or in an
    # older index).
    last_reply: str | None = None


class Index(BaseModel):
    """The chats and the next number to hand out. Numbers are never reused."""

    chats: list[ChatRecord] = []
    next_chat: int = 1
    # v0.11: the ``default_folder`` (resolved) the gateway last ran with, so
    # a change can be told from a folder the person chose (``None`` in an
    # older index).
    default_folder: str | None = None


class StateDir:
    """The state directory. Creating one makes the directory (mode 0700)."""

    @staticmethod
    def default_path() -> Path:
        """``$PORTICO_HOME`` when set, else ``~/.portico``. Creates nothing."""
        env = os.environ.get(ENV_HOME)
        return Path(env).expanduser() if env else Path.home() / DEFAULT_DIRNAME

    def __init__(self, path: Path | None = None) -> None:
        self.path = Path(path) if path is not None else self.default_path()
        self.path.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._lock_fd: int | None = None

    # --- paths ----------------------------------------------------------------

    @property
    def token_path(self) -> Path:
        return self.path / "token"

    @property
    def ledger_path(self) -> Path:
        return self.path / "ledger.json"

    @property
    def index_path(self) -> Path:
        return self.path / "index.json"

    @property
    def lock_path(self) -> Path:
        return self.path / "gateway.lock"

    @property
    def config_path(self) -> Path:
        return self.path / "config.toml"

    # --- token ----------------------------------------------------------------

    def write_token(self) -> str:
        """Write a fresh per-launch token (32 url-safe bytes), mode 0600, overwriting."""
        token = secrets.token_urlsafe(32)
        fd = os.open(self.token_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.fchmod(fd, 0o600)  # the mode arg only applies on create
            os.write(fd, (token + "\n").encode("ascii"))
        finally:
            os.close(fd)
        return token

    def read_token(self) -> str | None:
        """The current token, or ``None`` when there is no usable token file."""
        try:
            text = self.token_path.read_text(encoding="ascii").strip()
        except (FileNotFoundError, UnicodeDecodeError):
            return None
        return text or None

    # --- ledger ---------------------------------------------------------------

    def write_ledger(self, host: str, port: int, pid: int, epoch: str) -> None:
        ledger = Ledger(host=host, port=port, pid=pid, epoch=epoch)
        self._atomic_write(self.ledger_path, ledger.model_dump_json(indent=2) + "\n")

    def read_ledger(self) -> Ledger | None:
        """The ledger, or ``None`` when missing or unreadable — it is only a hint."""
        try:
            raw = self.ledger_path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return None
        try:
            return Ledger.model_validate_json(raw)
        except ValidationError:
            return None

    def clear_ledger(self) -> None:
        try:
            self.ledger_path.unlink()
        except FileNotFoundError:
            pass

    # --- index ----------------------------------------------------------------

    def load_index(self) -> Index:
        """The index, or defaults when there is none. Corrupt is an error, not a reset."""
        try:
            raw = self.index_path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return Index()
        try:
            return Index.model_validate_json(raw)
        except ValidationError as e:
            raise StateError(
                f"{self.index_path} is not a usable index.json; refusing to start and "
                f"re-number chats from 1. Move it aside to start fresh. ({e.error_count()} problem(s))"
            ) from e

    def save_index(self, index: Index) -> None:
        """Write the whole index through a temp file and rename, so a crash never leaves half a file."""
        self._atomic_write(self.index_path, index.model_dump_json(indent=2) + "\n")

    # --- lock -----------------------------------------------------------------

    def acquire_lock(self) -> bool:
        """Take the gateway lock without blocking. ``False`` means another gateway holds it."""
        if self._lock_fd is not None:
            return True
        fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            return False
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getpid()}\n".encode("ascii"))
        self._lock_fd = fd
        return True

    def release_lock(self) -> None:
        if self._lock_fd is None:
            return
        try:
            fcntl.flock(self._lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(self._lock_fd)
            self._lock_fd = None

    # --- helpers --------------------------------------------------------------

    def _atomic_write(self, target: Path, text: str) -> None:
        fd, tmp_name = tempfile.mkstemp(prefix=f".{target.name}.", suffix=".tmp", dir=self.path)
        tmp = Path(tmp_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(text)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, target)
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise
