"""Chats: numbering, state words, the per-chat sequence ring buffer, persistence.

A ``Chat`` is one numbered conversation with one folder and (while the
gateway runs) one engine. Chats are integers from 1, handed out by the
``ChatRegistry`` from the index's ``next_chat`` and never reused — a removed
number stays gone across launches.

Every chat-scoped event the gateway sends is ``stamp``ed with the chat's
next ``seq`` and kept in a ring of the newest ``history_buffer`` events.
``events_since`` is how a reattaching app catches up: it gets the events
after the last ``seq`` it saw, and a ``truncated`` flag when the ring has
already dropped some of what it asked for (so it should refetch history).

The ring, ``seq``, ``turn`` and the engine belong to one gateway launch. What survives in ``index.json`` is the ``ChatRecord``:
number, folder, engine session id, alias, state word, creation time,
the artifacts the chat produced, and (v0.2) the session facts: title,
ended, logged, parent, compactions and the last context percentage, and
(v0.3) the permission mode and the session's chat-scoped allows. A chat that came back from the index with
a session is ``restored``: its conversation before this launch lives in
the engine's transcript, which the server replays on ``chat.open``.
"""

from __future__ import annotations

from collections import deque
from datetime import UTC, datetime
from pathlib import Path
from typing import TYPE_CHECKING, get_args

from .messages import Artifact, ChatState, ChatStateWord, ChatSummary, PermissionMode, ServerMessage
from .state import ChatRecord, Index, StateDir

if TYPE_CHECKING:
    from .engine import Engine

STATE_WORDS: frozenset[str] = frozenset(get_args(ChatStateWord))

# A session's title: the first line of its first message, at most this long.
TITLE_LIMIT = 60

# A chat recorded in one of these states comes back ``idle`` on the next
# launch: no turn can be running when the gateway has just started.
_TRANSIENT_STATES: frozenset[str] = frozenset({"working", "waiting on you"})


class UnknownChat(KeyError):
    """No chat with that number. The message is the number, for ``error.message``."""

    def __init__(self, number: int) -> None:
        super().__init__(number)
        self.number = number

    def __str__(self) -> str:
        return f"no chat {self.number}"


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def title_from(text: str) -> str | None:
    """The first non-blank line of ``text``, shortened to ``TITLE_LIMIT``; ``None`` when there is none.

    A longer line is cut back to a word boundary when one falls in its second
    half, and ends with an ellipsis.
    """
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if len(line) <= TITLE_LIMIT:
            return line
        cut = line[:TITLE_LIMIT]
        space = cut.rfind(" ")
        if space >= TITLE_LIMIT // 2:
            cut = cut[:space]
        return cut.strip(" ,;:.-") + "…"
    return None


class Chat:
    """One numbered conversation. Mutable; the registry owns its lifetime."""

    def __init__(
        self,
        number: int,
        folder: Path,
        history_buffer: int,
        *,
        session_id: str | None = None,
        alias: str | None = None,
        state: ChatStateWord = "idle",
        created: str | None = None,
        artifacts: list[Artifact] | None = None,
        title: str | None = None,
        ended: str | None = None,
        logged: bool | None = None,
        parent: int | None = None,
        compactions: int = 0,
        context_percent: float | None = None,
        mode: PermissionMode | None = None,
        allows: list[str] | None = None,
    ) -> None:
        if number < 1:
            raise ValueError(f"chat numbers start at 1, got {number}")
        if history_buffer < 1:
            raise ValueError(f"history_buffer must be at least 1, got {history_buffer}")
        self.number = number
        self.folder = Path(folder)
        self.session_id = session_id
        self.alias = alias
        self.state: ChatStateWord = _checked_state(state)
        self.created = created or _now()
        self.turn = 0
        self.seq = 0
        self.ring: deque[ServerMessage] = deque(maxlen=history_buffer)
        self.artifacts: list[Artifact] = list(artifacts or [])
        # Session facts: ``ended`` is when a renewal closed this session;
        # ``logged`` whether its log step finished cleanly (``None`` when
        # none ran); ``parent`` the session this one followed.
        self.title = title
        self.ended = ended
        self.logged = logged
        self.parent = parent
        self.compactions = compactions
        self.context_percent = context_percent
        # The session's permission mode (v0.3); the registry fills in the
        # deployment's default for a chat that has none.
        self.mode: PermissionMode | None = mode
        # Chat-scoped allows: bare tool names, or ``Tool(rule)`` keys for a
        # command tool (``cards.CardBroker.chat_allow_keys``). Kept on the
        # record (v0.3), so they last as long as the session does.
        self.chat_allows: set[str] = set(allows or [])
        self.engine: Engine | None = None
        # True for a chat restored from the index with a session: the ring
        # cannot hold what happened before this launch, so a replay from
        # the beginning comes from the engine's transcript.
        self.restored = False

    def __repr__(self) -> str:
        return f"Chat({self.number}, {str(self.folder)!r}, state={self.state!r}, seq={self.seq})"

    # --- sequence ring --------------------------------------------------------

    def stamp(self, msg: ServerMessage) -> ServerMessage:
        """Assign the next ``seq`` to a copy of ``msg``, keep it in the ring, return it."""
        self.seq += 1
        stamped = msg.model_copy(update={"seq": self.seq})
        self.ring.append(stamped)
        return stamped

    def events_since(self, since: int | None) -> tuple[list[ServerMessage], bool]:
        """Events with ``seq`` after ``since`` (``None`` = from the beginning).

        The flag is ``True`` when the ring no longer holds everything after
        ``since``: the replay then starts later than asked and the caller
        should refetch full history.
        """
        base = 0 if since is None else max(since, 0)
        if base >= self.seq:
            return [], False
        oldest = self.ring[0].seq if self.ring else self.seq + 1
        assert oldest is not None
        truncated = oldest > base + 1
        return [m for m in self.ring if m.seq is not None and m.seq > base], truncated

    # --- state ----------------------------------------------------------------

    def set_state(self, word: ChatStateWord) -> ChatState:
        """Set the state word and emit the stamped ``chat.state`` event for it."""
        self.state = _checked_state(word)
        return self.stamp(ChatState(chat=self.number, state=self.state, mode=self.mode, ts=_now()))  # type: ignore[return-value]

    # --- views ----------------------------------------------------------------

    def _session_facts(self) -> dict[str, object]:
        return {
            "title": self.title,
            "ended": self.ended,
            "logged": self.logged,
            "parent": self.parent,
            "compactions": self.compactions,
            "context_percent": self.context_percent,
            "mode": self.mode,
        }

    def summary(self) -> ChatSummary:
        return ChatSummary(
            chat=self.number,
            folder=str(self.folder),
            alias=self.alias,
            state=self.state,
            created=self.created,
            **self._session_facts(),  # type: ignore[arg-type]
        )

    def record(self) -> ChatRecord:
        return ChatRecord(
            chat=self.number,
            folder=str(self.folder),
            session_id=self.session_id,
            alias=self.alias,
            state=self.state,
            created=self.created,
            artifacts=list(self.artifacts),
            allows=sorted(self.chat_allows),
            **self._session_facts(),  # type: ignore[arg-type]
        )

    @classmethod
    def from_record(cls, record: ChatRecord, history_buffer: int) -> Chat:
        state = "idle" if record.state in _TRANSIENT_STATES else record.state
        chat = cls(
            record.chat,
            Path(record.folder),
            history_buffer,
            session_id=record.session_id,
            alias=record.alias,
            state=state,  # type: ignore[arg-type]
            created=record.created,
            artifacts=record.artifacts,
            title=record.title,
            ended=record.ended,
            logged=record.logged,
            parent=record.parent,
            compactions=record.compactions,
            context_percent=record.context_percent,
            mode=record.mode,
            allows=record.allows,
        )
        chat.restored = record.session_id is not None
        return chat


def _checked_state(word: str) -> ChatStateWord:
    if word not in STATE_WORDS:
        raise ValueError(f"not a chat state: {word!r} (one of {', '.join(sorted(STATE_WORDS))})")
    return word  # type: ignore[return-value]


class ChatRegistry:
    """The chats, in number order, backed by the index. Numbers come from ``index.next_chat``."""

    def __init__(
        self, index: Index, state: StateDir, history_buffer: int, default_mode: PermissionMode = "auto"
    ) -> None:
        self._index = index
        self._state = state
        self._history_buffer = history_buffer
        # The mode a new session starts with (config ``permission_mode``).
        self.default_mode: PermissionMode = default_mode
        self._chats: dict[int, Chat] = {}
        for record in index.chats:
            chat = Chat.from_record(record, history_buffer)
            if chat.mode is None:
                chat.mode = default_mode
            self._chats[record.chat] = chat
        if self._chats:
            self._index.next_chat = max(self._index.next_chat, max(self._chats) + 1)

    def __len__(self) -> int:
        return len(self._chats)

    def __contains__(self, number: object) -> bool:
        return number in self._chats

    def chats(self) -> list[Chat]:
        return [self._chats[n] for n in sorted(self._chats)]

    def create(self, folder: Path, parent: int | None = None) -> Chat:
        """A new chat on ``folder`` with the next number; saved to the index at once."""
        number = self._index.next_chat
        self._index.next_chat = number + 1
        chat = Chat(number, Path(folder), self._history_buffer, parent=parent, mode=self.default_mode)
        self._chats[number] = chat
        self.persist()
        return chat

    def get(self, number: int) -> Chat:
        try:
            return self._chats[number]
        except KeyError:
            raise UnknownChat(number) from None

    def list(self) -> list[ChatRecord]:
        return [chat.record() for chat in self.chats()]

    def summaries(self) -> list[ChatSummary]:
        return [chat.summary() for chat in self.chats()]

    def remove(self, number: int) -> Chat:
        """Forget a chat. Its number is never handed out again. The caller closes its engine."""
        chat = self.get(number)
        del self._chats[number]
        self.persist()
        return chat

    def persist(self) -> None:
        """Write every chat's record and ``next_chat`` to the index."""
        self._index.chats = self.list()
        self._state.save_index(self._index)
