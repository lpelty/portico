"""v0.28 (PORT-38): Main and its threads message each other through the engine's own peer messaging.

What the engine does was checked with two real engines on 2026-11-20 (CLI
2.1.310): ``--name`` gives an engine its peer name, ``--replay-user-messages``
puts a peer's message in the receiver's stream, a send is not asked about
unless a ``PreToolUse`` hook says ``ask``, and a send to a closed peer answers
``{"success":false,"message":"No agent named … is reachable.…"}``.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
from claude_agent_sdk import AssistantMessage, ToolResultBlock, ToolUseBlock, UserMessage

from portico_gateway.config import ConfigError
from portico_gateway.engine import (
    PEER_SEND_TOOL,
    PeerSends,
    build_options,
    build_peer_send_hook,
    history_events,
    peer_message,
    result_summary,
    summarize_tool,
)
from portico_gateway.messages import ChatNotice, ChatState, TextDelta, TurnFinished, TurnStarted, UserText
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from portico_gateway.threads import PEER_NOTICE, PEER_TEXT_LIMIT, peer_label, peer_name, peer_notice_text, peers_prompt
from tests.conftest import RecordingCallbacks, fake_result, make_config
from tests.test_engine_translate import _finished, _result, _started_engine, _text_delta, _until, sdk_client  # noqa: F401
from tests.test_threads import attach_threads, factory, folder, propose, servers, start_thread, threads_server  # noqa: F401
from tests.test_turns import EngineFactory, new_chat, recv_until, text_delta


def wrapped(sender: str, text: str) -> str:
    """A peer's message as the engine writes it into the receiving conversation."""
    return (
        "Another Claude session sent a message:\n"
        f'<cross-session-message from="uds:/tmp/cc-socks/1.sock" from-name="{sender}" from-mode="prompting">\n'
        f"{text}\n</cross-session-message>\n\n"
        "This came from another Claude session — not typed by your user, but very likely working on their behalf."
    )


# --- names, labels, the prompt line -------------------------------------------


def test_peer_names_are_the_folder_the_launch_token_and_the_place() -> None:
    assert peer_name("work", "ab12", None) == "work-ab12-main"
    assert peer_name("work", "ab12", 2) == "work-ab12-thread-2"
    assert peer_name("My Work (2026)!", "ab12", 1) == "my-work-2026-ab12-thread-1"
    assert peer_name("…", "ab12", None) == "portico-ab12-main"
    assert len(peer_name("a" * 80, "ab12", None)) == 24 + len("-ab12-main")


def test_a_peer_name_reads_as_main_or_the_thread_whatever_the_launch() -> None:
    assert peer_label("work-ab12-main", "work") == "Main"
    assert peer_label("work-ab12-thread-2", "work") == "Thread 2"
    assert peer_label("work-ffff-thread-1", "work") == "Thread 1", "an earlier launch's name, in a replayed transcript"
    assert peer_label("bill-68", "work") == "bill-68", "any other session keeps its name"
    assert peer_label("other-ab12-main", "work") == "other-ab12-main"
    assert peer_label("work-ab12-thread-0", "work") == "work-ab12-thread-0"


def test_the_prompt_line_names_the_others_and_when_to_message() -> None:
    main = peers_prompt("work", "ab12", None, 2)
    assert main.startswith("Your peer name is work-ab12-main. ")
    assert "Thread 1 is work-ab12-thread-1, Thread 2 is work-ab12-thread-2." in main
    thread = peers_prompt("work", "ab12", 1, 2)
    assert thread.startswith("Your peer name is work-ab12-thread-1. ")
    assert "the main conversation is work-ab12-main, Thread 2 is work-ab12-thread-2." in thread
    assert "Thread 1 is" not in thread
    assert "Thread 2" not in peers_prompt("work", "ab12", None, 1)
    for line in (main, thread):
        assert "only when your task overlaps its work, you changed a file it is using, you found a pitfall it will hit" in line
        assert "Never send progress reports, and never pass a message for the person through another conversation" in line


def test_the_notice_is_one_line_and_bounded() -> None:
    assert peer_notice_text("Thread 2", "I changed\n  notes.md.\n") == "Message from Thread 2: I changed notes.md."
    assert peer_notice_text("Main", "  ") == "Message from Main"
    long = peer_notice_text("Main", "x" * 2000)
    assert len(long) == len("Message from Main: ") + PEER_TEXT_LIMIT and long.endswith("…")


# --- reading a peer's message -------------------------------------------------


def test_a_peers_message_is_read_from_the_engines_wrapper() -> None:
    assert peer_message(wrapped("work-ab12-main", "Stop editing notes.md.\nI have it.")) == (
        "work-ab12-main",
        "Stop editing notes.md.\nI have it.",
    )
    assert peer_message([{"type": "text", "text": wrapped("bill-68", "hi")}]) == ("bill-68", "hi")
    assert peer_message('<cross-session-message from="uds:/x">\nhi\n</cross-session-message>') == ("", "hi")
    assert peer_message("Tell me about <cross-session-message from-name=\"a\">x</cross-session-message>") is None
    assert peer_message("hello") is None
    assert peer_message([{"type": "tool_result", "tool_use_id": "t"}]) is None
    assert peer_message(None) is None


def test_the_send_and_its_answer_read_plainly() -> None:
    assert summarize_tool(PEER_SEND_TOOL, {"to": "work-ab12-thread-1", "summary": "notes.md is mine", "message": "long"}) == (
        "work-ab12-thread-1: notes.md is mine"
    )
    assert summarize_tool(PEER_SEND_TOOL, {"to": "work-ab12-main", "message": "First line\nsecond"}) == "work-ab12-main: First line"
    assert summarize_tool(PEER_SEND_TOOL, {}) == PEER_SEND_TOOL
    gone = '{"success":false,"message":"No agent named \'work-ab12-thread-1\' is reachable.\\nUse ListAgents to see everyone you can message."}'
    assert result_summary([{"type": "text", "text": gone}]) == "No agent named 'work-ab12-thread-1' is reachable."
    assert result_summary('{"success":true}') == '{"success":true}'
    assert result_summary('{"success": broken') == '{"success": broken'
    assert result_summary("plain") == "plain"


# --- asking before a send -----------------------------------------------------


async def test_the_hook_asks_before_every_send() -> None:
    hook = build_peer_send_hook()
    ask = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask"}}
    assert await hook({"tool_name": PEER_SEND_TOOL, "tool_input": {"to": "work-ab12-thread-1", "message": "x"}}, "t1", None) == ask
    assert await hook({"tool_name": PEER_SEND_TOOL, "tool_input": {"to": "Work-AB12-thread-1 ", "message": "x"}}, "t2", None) == ask
    assert await hook({"tool_name": PEER_SEND_TOOL, "tool_input": {"to": "researcher", "message": "x"}}, "t3", None) == ask
    assert await hook({"tool_name": PEER_SEND_TOOL}, "t4", None) == ask, "nothing to read: it still asks"
    assert await hook(None, None, None) == ask


class Owner(RecordingCallbacks):
    def __init__(self, peer: str | None, send: str = "ask") -> None:
        super().__init__()
        self.peer_name = peer
        self.peer_send = send

    def peer_label(self, name: str) -> str:
        return peer_label(name, "work")


def _send_hooks(options: Any) -> list[Any]:
    return [m for m in options.hooks["PreToolUse"] if m.matcher == PEER_SEND_TOOL]


def test_a_named_engine_takes_its_name_repeats_user_messages_and_asks_before_a_send(tmp_path: Path) -> None:
    options = build_options(tmp_path, None, [], Owner("work-ab12-main"))
    assert options.extra_args == {"name": "work-ab12-main", "replay-user-messages": None}
    assert len(_send_hooks(options)) == 1
    allowed = build_options(tmp_path, None, [], Owner("work-ab12-main", send="allow"))
    assert allowed.extra_args == {"name": "work-ab12-main", "replay-user-messages": None}
    assert _send_hooks(allowed) == [], "[threads] messages = allow: no card"
    plain = build_options(tmp_path, None, [], Owner(None))
    assert plain.extra_args == {} and _send_hooks(plain) == [], "without threads an engine starts as before"
    assert PEER_SEND_TOOL not in (options.allowed_tools or [])


def test_messages_is_ask_or_allow() -> None:
    assert make_config().threads.messages == "ask"
    assert make_config(threads={"messages": "allow"}).threads.messages == "allow"
    with pytest.raises((ConfigError, ValueError)):
        make_config(threads={"messages": "always"})


# --- the receiving engine -----------------------------------------------------


async def test_a_peers_message_begins_a_turn_and_shows_before_the_reply(tmp_path: Path, sdk_client: Any) -> None:  # noqa: F811
    cb = Owner("work-ab12-thread-1")
    eng, client = await _started_engine(tmp_path, cb)
    assert eng.turn == 0, "no turn has run in this engine"
    client.push = client._queue.put_nowait
    client.push(UserMessage(content=wrapped("work-ab12-main", "notes.md is mine now.")))
    client.push(_text_delta("Understood."))
    client.push(_result())
    await _until(lambda: len(_finished(cb)) == 1)
    kinds = [type(e).__name__ for e in cb.events]
    assert kinds[:3] == ["TurnStarted", "ChatNotice", "TextDelta"], kinds
    notice = cb.events[1]
    assert isinstance(notice, ChatNotice) and notice.kind == PEER_NOTICE
    assert notice.text == "Message from Main: notes.md is mine now."
    assert [(d.turn, d.text) for d in cb.events if isinstance(d, TextDelta)] == [(1, "Understood.")]
    assert [(f.turn, f.outcome) for f in _finished(cb)] == [(1, "done")]
    # A person's own message, repeated by the engine, is nothing new.
    client.script = [UserMessage(content="thanks"), _text_delta("Any time."), _result()]
    await eng.send("thanks")
    await _until(lambda: len(_finished(cb)) == 2)
    assert [e for e in cb.events if isinstance(e, ChatNotice)] == [notice]
    assert not [e for e in cb.events if isinstance(e, TurnStarted) and e.turn == 2], "a sent turn is the owner's to start"
    await eng.close()


async def test_a_peers_message_during_a_turn_joins_it(tmp_path: Path, sdk_client: Any) -> None:  # noqa: F811
    cb = Owner("work-ab12-main")
    eng, client = await _started_engine(tmp_path, cb)
    client.script = [_text_delta("Working."), UserMessage(content=wrapped("work-ab12-thread-2", "Careful with a.md")), _result()]
    await eng.send("go")
    await _until(lambda: len(_finished(cb)) == 1)
    assert [e for e in cb.events if isinstance(e, TurnStarted)] == [], "the turn in flight has it"
    assert [e.text for e in cb.events if isinstance(e, ChatNotice)] == ["Message from Thread 2: Careful with a.md"]
    await eng.close()


def test_a_replayed_transcript_shows_the_message_not_a_bubble() -> None:
    transcript = [
        {"type": "user", "uuid": "u1", "message": {"role": "user", "content": "hello"}},
        {"type": "assistant", "uuid": "a1", "message": {"role": "assistant", "content": [{"type": "text", "text": "Hi."}]}},
        {"type": "user", "uuid": "u2", "message": {"role": "user", "content": wrapped("work-ffff-thread-2", "I renamed a.md to b.md.")}},
        {"type": "assistant", "uuid": "a2", "message": {"role": "assistant", "content": [{"type": "text", "text": "Noted."}]}},
    ]
    events = history_events(transcript, 7, peer_label=lambda name: peer_label(name, "work"))
    assert [type(e).__name__ for e in events] == [
        "TurnStarted", "UserText", "TextDelta", "TurnFinished",
        "TurnStarted", "ChatNotice", "TextDelta", "TurnFinished",
    ]
    assert [e.text for e in events if isinstance(e, UserText)] == ["hello"]
    notice = next(e for e in events if isinstance(e, ChatNotice))
    assert (notice.kind, notice.text, notice.chat) == (PEER_NOTICE, "Message from Thread 2: I renamed a.md to b.md.", 7)
    assert [e.turn for e in events if isinstance(e, TurnFinished)] == [1, 2]
    bare = history_events(transcript, 7)
    assert next(e for e in bare if isinstance(e, ChatNotice)).text == "Message from work-ffff-thread-2: I renamed a.md to b.md."


# --- v0.28.2: the sending conversation shows what it sent -----------------------

GONE = json.dumps(
    {"success": False, "message": "No agent named 'work-ab12-thread-1' is reachable.\nUse ListAgents to see everyone you can message."},
    separators=(",", ":"),
)


def test_the_line_for_a_sent_message_reads_like_the_received_one() -> None:
    assert peer_notice_text("Thread 2", "I changed\n  notes.md.\n", sent=True) == "Message to Thread 2: I changed notes.md."
    assert peer_notice_text("Main", "  ", sent=True) == "Message to Main"
    long = peer_notice_text("Main", "x" * 2000, sent=True)
    assert len(long) == len("Message to Main: ") + PEER_TEXT_LIMIT and long.endswith("…")


def test_a_send_counts_as_sent_only_when_its_answer_says_so() -> None:
    sends = PeerSends()
    sends.started("t1", PEER_SEND_TOOL, {"to": " work-ab12-thread-1 ", "summary": "short", "message": "The whole\nmessage."})
    assert sends.finished("t1", False, '{"success":true}') == ("work-ab12-thread-1", "The whole\nmessage.")
    assert sends.finished("t1", False, '{"success":true}') is None, "answered once"

    sends.started("t2", PEER_SEND_TOOL, {"to": "work-ab12-main", "summary": "only a summary"})
    assert sends.finished("t2", None, [{"type": "text", "text": "Message sent."}]) == ("work-ab12-main", "only a summary")

    sends.started("t3", PEER_SEND_TOOL, {"to": "work-ab12-thread-1", "message": "x"})
    assert sends.finished("t3", False, GONE) is None, "the peer is gone: nothing went"
    sends.started("t4", PEER_SEND_TOOL, {"to": "work-ab12-thread-1", "message": "x"})
    assert sends.finished("t4", True, "The user doesn't want to proceed with this tool use.") is None, "refused on the card"

    sends.started("t5", "Bash", {"to": "work-ab12-main", "message": "x"})
    sends.started("t6", PEER_SEND_TOOL, {"message": "to nobody"})
    sends.started("t7", PEER_SEND_TOOL, None)
    sends.started(None, PEER_SEND_TOOL, {"to": "work-ab12-main", "message": "x"})
    assert [sends.finished(i, False, "ok") for i in ("t5", "t6", "t7", None, "never-started")] == [None] * 5


def _send(tool_use_id: str, to: str, message: str, parent: str | None = None) -> AssistantMessage:
    block = ToolUseBlock(id=tool_use_id, name=PEER_SEND_TOOL, input={"to": to, "summary": "s", "message": message})
    return AssistantMessage(content=[block], model="m", parent_tool_use_id=parent)


def _answer(tool_use_id: str, content: str, is_error: bool = False, parent: str | None = None) -> UserMessage:
    return UserMessage(
        content=[ToolResultBlock(tool_use_id=tool_use_id, content=content, is_error=is_error)], parent_tool_use_id=parent
    )


async def test_the_sending_conversation_shows_a_message_to_line_after_the_send(tmp_path: Path, sdk_client: Any) -> None:  # noqa: F811
    cb = Owner("work-ab12-main", send="allow")
    eng, client = await _started_engine(tmp_path, cb)
    client.script = [
        _send("t1", "work-ab12-thread-2", "notes.md is mine now."),
        _answer("t1", '{"success":true}'),
        _send("t2", "work-ab12-thread-1", "Are you there?"),
        _answer("t2", GONE),
        _send("t3", "work-ab12-thread-2", "never allowed"),
        _answer("t3", "The user doesn't want to proceed with this tool use.", is_error=True),
        _send("t4", "work-ab12-thread-2", "a subagent's send", parent="agent-1"),
        _answer("t4", '{"success":true}', parent="agent-1"),
        _text_delta("Told Thread 2."),
        _result(),
    ]
    await eng.send("tell thread 2")
    await _until(lambda: len(_finished(cb)) == 1)
    notices = [e for e in cb.events if isinstance(e, ChatNotice)]
    assert [(n.kind, n.text) for n in notices] == [(PEER_NOTICE, "Message to Thread 2: notes.md is mine now.")]
    names = [type(e).__name__ for e in cb.events]
    at = names.index("ChatNotice")
    assert names[at - 1] == "ToolFinished", "the line comes once the send has been answered"
    await eng.close()


def test_a_replayed_transcript_shows_the_sent_line_too() -> None:
    def call(tool_use_id: str, to: str, message: str) -> dict[str, Any]:
        block = {"type": "tool_use", "id": tool_use_id, "name": PEER_SEND_TOOL, "input": {"to": to, "message": message}}
        return {"type": "assistant", "uuid": "a" + tool_use_id, "message": {"role": "assistant", "content": [block]}}

    def result(tool_use_id: str, content: str, is_error: bool = False) -> dict[str, Any]:
        block = {"type": "tool_result", "tool_use_id": tool_use_id, "content": content, "is_error": is_error}
        return {"type": "user", "uuid": "u" + tool_use_id, "message": {"role": "user", "content": [block]}}

    transcript = [
        {"type": "user", "uuid": "u0", "message": {"role": "user", "content": "tell main"}},
        call("t1", "work-ffff-main", "a.md is now b.md."),
        result("t1", '{"success":true}'),
        call("t2", "work-ffff-thread-2", "hello?"),
        result("t2", GONE),
    ]
    events = history_events(transcript, 7, peer_label=lambda name: peer_label(name, "work"))
    assert [type(e).__name__ for e in events] == [
        "TurnStarted", "UserText", "ToolStarted", "ToolFinished", "ChatNotice", "ToolStarted", "ToolFinished", "TurnFinished",
    ]
    notice = next(e for e in events if isinstance(e, ChatNotice))
    assert (notice.kind, notice.text, notice.chat) == (PEER_NOTICE, "Message to Main: a.md is now b.md.", 7)
    bare = history_events(transcript, 7)
    assert next(e for e in bare if isinstance(e, ChatNotice)).text == "Message to work-ffff-main: a.md is now b.md."


# --- Main and a thread in one gateway -----------------------------------------


async def test_main_and_a_thread_know_each_other_and_a_message_shows_in_the_receiver(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]  # noqa: F811
) -> None:
    srv = await threads_server(state_dir, factory, servers)
    conn = await attach_threads(srv)
    try:
        main = await new_chat(conn, folder)
        main_engine = factory.last
        token = srv.peer_token
        assert len(token) == 4
        main_name, thread_name = peer_name(folder.name, token, None), peer_name(folder.name, token, 1)
        assert main_engine.callbacks.peer_name == main_name and main_engine.callbacks.peer_send == "ask"
        assert peers_prompt(folder.name, token, None, 2) in main_engine.system_prompt["append"]
        assert build_options(folder, None, [], main_engine.callbacks).extra_args["name"] == main_name
        _, frame = await propose(srv, main, conn)
        got = await start_thread(conn, main, frame.proposal)
        thread_engine = factory.last
        thread = next(m.chat for m in got if isinstance(m, TurnFinished))
        assert thread != main and thread_engine is not main_engine
        assert thread_engine.callbacks.peer_name == thread_name
        assert peers_prompt(folder.name, token, 1, 2) in thread_engine.system_prompt["append"]
        assert main_name in thread_engine.system_prompt["append"] and thread_name in main_engine.system_prompt["append"]
        # Main sends to the thread: the thread's engine reads it and answers, with nothing sent by the person.
        await thread_engine.arrive(
            UserMessage(content=wrapped(main_name, "Leave notes.md alone; I am rewriting it.")),
            text_delta("I will."),
            fake_result(),
        )
        frames = await recv_until(conn, TurnFinished)
        mine = [f for f in frames if getattr(f, "chat", None) == thread]
        started = next(i for i, f in enumerate(mine) if isinstance(f, TurnStarted))
        notice = next(i for i, f in enumerate(mine) if isinstance(f, ChatNotice))
        reply = next(i for i, f in enumerate(mine) if isinstance(f, TextDelta))
        assert started < notice < reply, "the message shows before the reply"
        assert mine[notice].text == "Message from Main: Leave notes.md alone; I am rewriting it."
        assert mine[notice].kind == PEER_NOTICE and mine[notice].seq is not None, "stamped: it replays from the ring"
        assert not [f for f in mine if isinstance(f, UserText)], "nobody typed it"
        assert [s.state for s in mine if isinstance(s, ChatState)] == ["working"]
        assert not [f for f in frames if getattr(f, "chat", None) == main and isinstance(f, (ChatNotice, TextDelta))], (
            "nothing of the thread's conversation enters Main's"
        )
        # The thread warns Main, which has run no turn in this launch.
        assert main_engine.turn == 0
        await main_engine.arrive(
            UserMessage(content=wrapped(thread_name, "notes.md has a conflict marker on line 4.")),
            text_delta("Thanks."),
            fake_result(),
        )
        frames = await recv_until(conn, TurnFinished)
        texts = [f.text for f in frames if isinstance(f, ChatNotice) and f.chat == main]
        assert texts == ["Message from Thread 1: notes.md has a conflict marker on line 4."]
        assert [f.turn for f in frames if isinstance(f, TurnFinished) and f.chat == main] == [1]
    finally:
        await conn.close()


async def test_allow_and_no_threads(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]  # noqa: F811
) -> None:
    srv = await threads_server(state_dir, factory, servers, threads={"messages": "allow"})
    conn = await attach_threads(srv)
    try:
        await new_chat(conn, folder)
        assert factory.last.callbacks.peer_send == "allow"
        options = build_options(folder, None, [], factory.last.callbacks)
        assert _send_hooks(options) == []
    finally:
        await conn.close()


async def test_without_threads_an_engine_has_no_peer_name(
    state_dir: StateDir, factory: EngineFactory, folder: Path, servers: list[GatewayServer]  # noqa: F811
) -> None:
    srv = await threads_server(state_dir, factory, servers, threads={"max": 0})
    conn = await attach_threads(srv)
    try:
        await new_chat(conn, folder)
        assert factory.last.callbacks.peer_name is None
        assert "Your peer name" not in json.dumps(factory.last.system_prompt)
        assert build_options(folder, None, [], factory.last.callbacks).extra_args == {}
    finally:
        await conn.close()
