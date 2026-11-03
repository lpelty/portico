"""The gateway's state directory: token, ledger, index, lock.

Everything the gateway keeps between launches lives in one directory: the
``--state`` given, else ``$PORTICO_HOME``, else the folder named in the
checkout's git-ignored ``.portico-home`` (written by ``bin/install --home``),
else ``~/.portico``:

- ``token``        per-launch secret the app presents at connect (mode 0600)
- ``ledger.json``  host, port, pid, epoch of the running gateway — a hint the
                   app probes with ``hello`` and the token, never trusted
- ``index.json``   the chats: numbers, folders, engine session ids, artifacts;
                   (v0.16) thread proposals
- ``commands.json`` the agent's slash commands, last list per folder (v0.11
                   item 66) — a cache: unreadable is empty, never an error
- ``gateway.lock`` flock that refuses a second gateway on the same directory
- ``config.toml``  the deployment's configuration (read by ``config.py``)
"""

from __future__ import annotations

import fcntl
import json
import os
import secrets
import tempfile
from pathlib import Path

from pydantic import BaseModel, ConfigDict, ValidationError

from . import REPO_ROOT

from .messages import (
    AgentCommand,
    Artifact,
    ChatStateWord,
    ModelChoice,
    PermissionMode,
    PermissionOutcome,
    ProposalState,
    ThreadInfo,
)

ENV_HOME = "PORTICO_HOME"
DEFAULT_DIRNAME = ".portico"
# v0.17: the checkout's record of the folder ``bin/install --home`` chose (one
# line, an absolute path); git-ignored, so ``bin/update`` still sees a clean checkout.
HOME_FILE = ".portico-home"
# v0.17: how ``index.json`` writes a path inside the state folder, so moving the
# folder (re-install with a new ``--home``) leaves no stale absolute path behind.
STATE_PREFIX = "@state"
# v0.11 (item 66): how many folders' command lists ``commands.json`` keeps,
# newest last; older folders are dropped when it is written.
COMMAND_FOLDERS_KEPT = 20


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


class QuestionOutcome(BaseModel):
    """What became of one question tool use (v0.16): its answers, or the decline's key."""

    model_config = ConfigDict(extra="forbid")

    answers: dict[str, str | list[str]] | None = None
    declined: str | None = None


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
    # v0.16: the outcome of each question tool use, by ``tool_use_id``
    # (newest ``TOOL_PERMISSIONS_KEPT``), so the question's row replayed from
    # the transcript carries its answers.
    answers: dict[str, QuestionOutcome] = {}
    # v0.4: when the session was last logged (``session.log``, or a
    # renewal's log step that finished cleanly), and whether a turn has
    # finished since (``None`` in an older index: the registry infers it).
    logged_at: str | None = None
    work_since_log: bool | None = None
    # v0.6: when a turn last finished (``None`` before the first, or in an
    # older index).
    last_reply: str | None = None
    # v0.16: set on a thread (``None`` on Main, every other chat, and in an
    # older index).
    thread: ThreadInfo | None = None


class ProposalRecord(BaseModel):
    """A thread Main's agent proposed (v0.16), kept until started, dismissed, or Main's session ends.

    ``chat`` is the Main session it was proposed in; ``tool_use_id`` the
    ``open_thread`` tool row it belongs to; ``thread`` the chat it started.
    """

    id: str
    chat: int
    tool_use_id: str | None
    brief: str
    files: list[str]
    created: str
    state: ProposalState
    thread: int | None = None


class Index(BaseModel):
    """The chats and the next number to hand out. Numbers are never reused."""

    chats: list[ChatRecord] = []
    next_chat: int = 1
    # v0.11: the ``default_folder`` (resolved) the gateway last ran with, so
    # a change can be told from a folder the person chose (``None`` in an
    # older index).
    default_folder: str | None = None
    # v0.15: the model chosen with ``model.set`` (a ``ModelChoice.value``;
    # ``None``: the deployment's default), which every engine starts on, and
    # the engine's model list as last read, for an app before any engine
    # starts. Defaults so an older index loads unchanged.
    model: str | None = None
    models: list[ModelChoice] = []
    # v0.16: thread proposals, oldest first (the newest ``PROPOSALS_KEPT``).
    proposals: list[ProposalRecord] = []


class CommandLists(BaseModel):
    """``commands.json``: the agent's commands, last list per folder, oldest first (v0.11 item 66)."""

    folders: dict[str, list[AgentCommand]] = {}


class StateDir:
    """The state directory. Creating one makes the directory (mode 0700)."""

    @staticmethod
    def _home_file_folder() -> Path | None:
        """The folder the checkout's ``.portico-home`` names, or ``None`` (no checkout, no file, or empty)."""
        if not (REPO_ROOT / "bin" / "portico-gateway").is_file():
            return None  # not running from a checkout: there is no file to read
        try:
            line = (REPO_ROOT / HOME_FILE).read_text(encoding="utf-8").strip()
        except (OSError, UnicodeDecodeError):
            return None
        return Path(line).expanduser() if line else None

    @staticmethod
    def default_path() -> Path:
        """``$PORTICO_HOME``, else the checkout's ``.portico-home``, else ``~/.portico``. Creates nothing."""
        env = os.environ.get(ENV_HOME)
        if env:
            return Path(env).expanduser()
        return StateDir._home_file_folder() or Path.home() / DEFAULT_DIRNAME

    @staticmethod
    def default_source() -> str:
        """Where ``default_path`` found the folder: ``PORTICO_HOME``, ``.portico-home`` or ``the default``."""
        if os.environ.get(ENV_HOME):
            return ENV_HOME
        return HOME_FILE if StateDir._home_file_folder() is not None else "the default"

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
    def commands_path(self) -> Path:
        return self.path / "commands.json"

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
            data = json.loads(raw)
        except ValueError:
            data = None  # not JSON: pydantic below says so in its own words
        try:
            if data is None:
                return Index.model_validate_json(raw)
            return Index.model_validate_json(json.dumps(self._expand_state_paths(data)))
        except ValidationError as e:
            raise StateError(
                f"{self.index_path} is not a usable index.json; refusing to start and "
                f"re-number chats from 1. Move it aside to start fresh. ({e.error_count()} problem(s))"
            ) from e

    def save_index(self, index: Index) -> None:
        """Write the whole index through a temp file and rename, so a crash never leaves half a file.

        v0.17: a path inside the state folder is written ``@state/<relative>``
        (``load_index`` expands it), so the index survives moving the folder.
        """
        data = self._state_relative_paths(index.model_dump(mode="json"))
        self._atomic_write(self.index_path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")

    def _state_relative_paths(self, value: object) -> object:
        """``value`` with every string that is the state folder or inside it (as given or resolved) as ``@state/…``."""
        if isinstance(value, dict):
            return {k: self._state_relative_paths(v) for k, v in value.items()}
        if isinstance(value, list):
            return [self._state_relative_paths(v) for v in value]
        if isinstance(value, str):
            for root in dict.fromkeys((str(self.path), str(self.path.resolve()))):
                if value == root:
                    return STATE_PREFIX
                if value.startswith(root.rstrip("/") + "/"):
                    return f"{STATE_PREFIX}/{value[len(root.rstrip('/')) + 1:]}"
        return value

    def _expand_state_paths(self, value: object) -> object:
        """``value`` with every ``@state/…`` string as an absolute path in this (resolved) state folder."""
        if isinstance(value, dict):
            return {k: self._expand_state_paths(v) for k, v in value.items()}
        if isinstance(value, list):
            return [self._expand_state_paths(v) for v in value]
        if isinstance(value, str):
            if value == STATE_PREFIX:
                return str(self.path.resolve())
            if value.startswith(STATE_PREFIX + "/"):
                return str(self.path.resolve() / value[len(STATE_PREFIX) + 1 :])
        return value

    # --- commands (v0.11 item 66) ------------------------------------------------

    def load_commands(self) -> dict[str, list[AgentCommand]]:
        """The kept command lists by folder, oldest first; empty when missing or unreadable (a cache)."""
        try:
            raw = self.commands_path.read_text(encoding="utf-8")
        except (FileNotFoundError, UnicodeDecodeError):
            return {}
        try:
            return CommandLists.model_validate_json(raw).folders
        except ValidationError:
            return {}

    def save_commands(self, lists: dict[str, list[AgentCommand]]) -> None:
        """Write the lists (insertion order, newest last), keeping the newest ``COMMAND_FOLDERS_KEPT``."""
        kept = dict(list(lists.items())[-COMMAND_FOLDERS_KEPT:])
        self._atomic_write(self.commands_path, CommandLists(folders=kept).model_dump_json(indent=2) + "\n")

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
