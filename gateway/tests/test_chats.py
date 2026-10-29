"""Task 5: chats — numbering, state words, the per-chat sequence ring buffer, persistence."""

from __future__ import annotations

from pathlib import Path

import pytest

from portico_gateway.chats import Chat, ChatRegistry, UnknownChat
from portico_gateway.messages import (
    Artifact,
    ChatState,
    ChatSummary,
    TextDelta,
    TurnFinished,
    TurnStarted,
)
from portico_gateway.state import ChatRecord, Index, StateDir, StateError

FOLDER_A = "/Users/someone/projects/demo"
FOLDER_B = "/Users/someone/projects/other"
TS = "2026-10-27T12:00:00Z"


@pytest.fixture
def state(tmp_path: Path) -> StateDir:
    return StateDir(tmp_path / "portico-home")


def registry_for(state: StateDir, history_buffer: int = 2000) -> ChatRegistry:
    return ChatRegistry(index=state.load_index(), state=state, history_buffer=history_buffer)


def delta(chat: int, text: str, turn: int = 1) -> TextDelta:
    return TextDelta(chat=chat, turn=turn, text=text, ts=TS)


# --- numbering ----------------------------------------------------------------


def test_numbers_are_sequential_and_never_reused(state: StateDir) -> None:
    reg = registry_for(state)
    one = reg.create(Path(FOLDER_A))
    two = reg.create(Path(FOLDER_B))
    three = reg.create(Path(FOLDER_A))
    assert [one.number, two.number, three.number] == [1, 2, 3]
    assert one.folder == Path(FOLDER_A)
    assert one.state == "idle" and one.turn == 0 and one.seq == 0
    assert one.session_id is None and one.alias is None and one.engine is None
    assert one.artifacts == [] and one.chat_allows == set()

    reg.remove(2)
    with pytest.raises(UnknownChat):
        reg.get(2)
    assert [c.chat for c in reg.list()] == [1, 3]

    # The removed number is gone for good: the next chat is 4, not 2.
    assert reg.create(Path(FOLDER_B)).number == 4

    # And it stays gone across a reload of the index.
    again = registry_for(state)
    assert [c.chat for c in again.list()] == [1, 3, 4]
    assert again.create(Path(FOLDER_A)).number == 5


def test_get_unknown_chat_raises(state: StateDir) -> None:
    reg = registry_for(state)
    with pytest.raises(UnknownChat):
        reg.get(1)
    with pytest.raises(UnknownChat):
        reg.remove(7)


# --- sequence ring ------------------------------------------------------------


def test_seq_increments_and_ring_truncates_at_buffer(state: StateDir) -> None:
    reg = registry_for(state, history_buffer=3)
    chat = reg.create(Path(FOLDER_A))

    first = chat.stamp(TurnStarted(chat=1, turn=1, ts=TS))
    assert first.seq == 1 and chat.seq == 1
    assert isinstance(first, TurnStarted) and first.chat == 1 and first.turn == 1

    stamped = [chat.stamp(delta(1, t)) for t in ("a", "b", "c", "d")]
    assert [m.seq for m in stamped] == [2, 3, 4, 5]
    assert chat.seq == 5

    # The ring keeps the newest ``history_buffer`` events; older ones fall off.
    assert len(chat.ring) == 3
    assert [m.seq for m in chat.ring] == [3, 4, 5]
    assert [m.text for m in chat.ring] == ["b", "c", "d"]  # type: ignore[union-attr]

    # Stamping never mutates the caller's object; it returns the stamped copy.
    unstamped = delta(1, "e")
    out = chat.stamp(unstamped)
    assert unstamped.seq is None and out.seq == 6


def test_events_since_reports_truncation(state: StateDir) -> None:
    reg = registry_for(state, history_buffer=4)
    chat = reg.create(Path(FOLDER_A))

    # Nothing yet: empty, not truncated, whatever was asked.
    assert chat.events_since(None) == ([], False)
    assert chat.events_since(0) == ([], False)

    for t in "abcdef":  # seq 1..6; ring holds 3..6
        chat.stamp(delta(1, t))

    # since=None means "from the beginning": the ring lost 1 and 2, say so.
    events, truncated = chat.events_since(None)
    assert [m.seq for m in events] == [3, 4, 5, 6] and truncated is True

    # since older than the ring: truncated, replay starts at the oldest kept.
    events, truncated = chat.events_since(1)
    assert [m.seq for m in events] == [3, 4, 5, 6] and truncated is True

    # since exactly one before the oldest kept: gapless, not truncated.
    events, truncated = chat.events_since(2)
    assert [m.seq for m in events] == [3, 4, 5, 6] and truncated is False

    # since inside the ring: only what follows it.
    events, truncated = chat.events_since(4)
    assert [m.seq for m in events] == [5, 6] and truncated is False

    # since at or beyond the head: nothing to replay, not truncated.
    assert chat.events_since(6) == ([], False)
    assert chat.events_since(99) == ([], False)

    # A buffer large enough to hold everything is never truncated.
    big = registry_for(state, history_buffer=100).create(Path(FOLDER_B))
    for t in "abc":
        big.stamp(delta(big.number, t))
    events, truncated = big.events_since(None)
    assert [m.seq for m in events] == [1, 2, 3] and truncated is False


# --- state words --------------------------------------------------------------


def test_state_words_exact(state: StateDir) -> None:
    reg = registry_for(state)
    chat = reg.create(Path(FOLDER_A))
    assert chat.state == "idle"

    for word in ("working", "waiting on you", "stopped", "idle"):
        event = chat.set_state(word)
        assert chat.state == word
        # set_state emits the stamped ``chat.state`` event so the ring and the app agree.
        assert isinstance(event, ChatState) and event.chat == 1 and event.state == word
        assert event.seq == chat.seq and chat.ring[-1] is event

    for bad in ("Idle", "waiting", "waiting_on_you", "running", "", "done"):
        with pytest.raises(ValueError):
            chat.set_state(bad)  # type: ignore[arg-type]
    assert chat.state == "idle"

    # The summary carries the exact word.
    assert chat.summary() == ChatSummary(chat=1, folder=FOLDER_A, alias=None, state="idle", created=chat.created, mode="auto")


# --- persistence --------------------------------------------------------------


def test_registry_persists_to_index(state: StateDir) -> None:
    reg = registry_for(state)
    one = reg.create(Path(FOLDER_A))
    two = reg.create(Path(FOLDER_B))
    assert state.index_path.exists()  # create saves immediately

    artifact = Artifact(
        id="art-1", kind="file", location=f"{FOLDER_A}/summary.md", media="markdown",
        title="summary.md", source="tool", open=True,
    )
    one.session_id = "sess-1"
    one.alias = "report draft"
    one.artifacts.append(artifact)
    one.chat_allows.add("Bash")  # v0.3: the session's allows are on the record
    one.set_state("working")
    one.stamp(TurnFinished(chat=1, turn=1, outcome="done", ts=TS))
    two.set_state("stopped")
    reg.persist()

    index = state.load_index()
    assert index.next_chat == 3
    assert index.chats == [
        ChatRecord(chat=1, folder=FOLDER_A, session_id="sess-1", alias="report draft", state="working",
                   created=one.created, artifacts=[artifact], mode="auto", allows=["Bash"], work_since_log=False),
        ChatRecord(chat=2, folder=FOLDER_B, session_id=None, alias=None, state="stopped",
                   created=two.created, artifacts=[], mode="auto", work_since_log=False),
    ]
    assert reg.list() == index.chats

    # A new registry on the same index rebuilds the chats: numbers, folders,
    # sessions, aliases, artifacts and (v0.3) chat allows come back; the ring,
    # seq, turn and engine do not (they belong to a gateway launch). A chat recorded
    # mid-turn comes back ``idle`` — no turn can be running after a launch.
    again = ChatRegistry(index=index, state=state, history_buffer=2000)
    r1, r2 = again.get(1), again.get(2)
    assert isinstance(r1, Chat)
    assert (r1.number, r1.folder, r1.session_id, r1.alias) == (1, Path(FOLDER_A), "sess-1", "report draft")
    assert r1.artifacts == [artifact]
    assert r1.state == "idle" and r2.state == "stopped"
    assert r1.seq == 0 and r1.turn == 0 and len(r1.ring) == 0
    assert r1.engine is None and r1.chat_allows == {"Bash"} and r2.chat_allows == set()
    assert r1.created == one.created

    # Removing persists too, and the ledger of numbers moves on.
    again.remove(1)
    assert [c.chat for c in state.load_index().chats] == [2]
    assert state.load_index().next_chat == 3


def test_registry_never_sees_a_bad_state_word_from_disk(state: StateDir) -> None:
    # The gateway builds its registry from ``load_index``; an index carrying a
    # word outside the four is refused there as a StateError, so the
    # registry's own check is never the first thing a person sees.
    state.index_path.write_text(
        '{"chats": [{"chat": 1, "folder": "/x", "state": "running", "created": "2026-10-27T12:00:00Z"}], "next_chat": 2}'
    )
    with pytest.raises(StateError):
        registry_for(state)


def test_registry_starts_from_an_index_with_a_high_next_chat(state: StateDir) -> None:
    # The index is the authority on numbering, even when it lists no chats.
    reg = ChatRegistry(index=Index(chats=[], next_chat=42), state=state, history_buffer=2000)
    assert reg.create(Path(FOLDER_A)).number == 42
    assert state.load_index().next_chat == 43
