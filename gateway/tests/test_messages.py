"""Task 1: the protocol models are the protocol."""

import json

import pytest

from portico_gateway.messages import (
    ProtocolError,
    dump,
    example_messages,
    export_schema,
    parse_client,
    parse_server,
)

TS = "2026-10-27T00:00:00Z"

# One entry per message type per direction (Task 1 inventory).
EXPECTED_KEYS = {
    "server.agent.started",
    "server.agent.progress",
    "server.agent.finished",
    "server.workflow.started",
    "server.workflow.phase",
    "server.workflow.finished",
    "client.hello",
    "client.chat.new",
    "client.chat.open",
    "client.chat.stop",
    "client.chat.alias",
    "client.chat.remove",
    "client.message.send",
    "client.turn.stop",
    "client.card.answer",
    "client.files.list",
    "client.files.roots.set",
    "client.files.edited",
    "client.artifact.opened",
    "client.gateway.stop",
    "client.session.renew",
    "client.files.search",
    "server.hello",
    "server.chat.list",
    "server.chat.state",
    "server.chat.history",
    "server.chat.live",
    "server.turn.started",
    "server.text.delta",
    "server.tool.started",
    "server.tool.finished",
    "server.turn.finished",
    "server.user.text",
    "server.card.ask",
    "server.card.answered",
    "server.card.cancel",
    "server.artifact.created",
    "server.files.list",
    "server.files.roots",
    "server.status.set",
    "server.context.usage",
    "server.chat.compacted",
    "server.session.renewed",
    "server.files.results",
    "server.error",
    "client.session.mode",
    "server.chat.notice",
    "server.config.stale",
    "server.update.available",
    "client.session.log",
    "client.service.restart",
    "client.services.restart_all",
    # v0.11: messages typed while the agent works
    "client.chat.unqueue",
    "server.chat.queued",
    "server.chat.queue",
    "server.session.logged",
    "server.services.status",
    "client.sessions.clear",
    "server.chat.commands",
    "server.viewer.act",
    "client.viewer.settings",
    "client.viewer.result",
    # v0.12 spaces
    "server.spaces.list",
    "client.space.refresh",
    "client.space.act",
    "server.deployment.message",
    "client.space.rename",
    "client.space.remove",
    # v0.15 models
    "server.models",
    "client.model.set",
    # v0.16 threads
    "server.thread.proposal",
    "client.thread.start",
    "client.thread.dismiss",
    "client.thread.close",
    # v0.18: MCP servers in Settings
    "client.mcp.list",
    "client.mcp.toggle",
    "client.mcp.reconnect",
    "client.mcp.remove",
    "client.mcp.add",
    "client.mcp.sign_in",
    "client.mcp.sign_out",
    "client.mcp.tool_policy",
    "server.mcp.servers",
    "client.plugins.list",
    "client.plugins.set_enabled",
    "client.plugins.install",
    "client.plugins.uninstall",
    "client.plugins.update",
    "client.plugins.marketplace_add",
    "client.plugins.marketplace_update",
    "client.plugins.details",
    "client.plugins.options",
    "client.plugins.configure",
    "server.plugins.state",
    "client.app.call_tool",
    "client.app.message",
    "client.app.context",
    "client.app.reload",
    "server.app.open",
    "server.app.result",
    "server.app.cancelled",
    "server.app.call_result",
    "server.plugins.details",
    "server.plugins.options",
}


def test_every_type_has_schema_def_and_example():
    schema = export_schema()
    ex = example_messages()
    for key, msg in ex.items():
        assert type(msg).__name__ in schema["$defs"], key
    # v0.1's 30, v0.2's 6, v0.3's session.mode, chat.notice, config.stale,
    # update.available, v0.4's session.log, service.restart, session.logged, services.status,
    # v0.8's services.restart_all, v0.10's agent.started, agent.progress, agent.finished,
    # workflow.started, workflow.phase, workflow.finished, v0.11's sessions.clear,
    # chat.unqueue, chat.queued, chat.queue, chat.commands
    # v0.12's viewer.act, viewer.settings, viewer.result, spaces.list, space.refresh, space.rename, space.remove
    # v0.15's models, model.set
    # v0.16's thread.proposal, thread.start, thread.dismiss, thread.close
    # v0.18's mcp.list, mcp.toggle, mcp.reconnect, mcp.remove, mcp.add, mcp.sign_in, mcp.sign_out,
    # mcp.tool_policy, mcp.servers; plugins.list, plugins.set_enabled, plugins.install, plugins.uninstall,
    # plugins.update, plugins.marketplace_add, plugins.marketplace_update, plugins.details (both ways),
    # plugins.options (both ways), plugins.configure, plugins.state;
    # app.call_tool, app.message, app.context, app.reload, app.open, app.result, app.cancelled, app.call_result
    # v0.22's space.act, deployment.message
    assert len(ex) == 104
    assert set(ex) == EXPECTED_KEYS


def test_example_keys_match_their_type_field():
    for key, msg in example_messages().items():
        direction, _, type_name = key.partition(".")
        assert direction in ("client", "server"), key
        assert msg.type == type_name, key


def test_unknown_field_is_rejected():
    with pytest.raises(ProtocolError) as e:
        parse_client('{"type":"turn.stop","chat":1,"ts":"%s","bogus":1}' % TS)
    assert e.value.code == "protocol.invalid"


def test_unknown_type_is_rejected_with_code():
    with pytest.raises(ProtocolError) as e:
        parse_client('{"type":"nope","ts":"%s"}' % TS)
    assert e.value.code == "protocol.unknown_type"


def test_missing_type_is_rejected_with_code():
    with pytest.raises(ProtocolError) as e:
        parse_client('{"ts":"%s"}' % TS)
    assert e.value.code == "protocol.unknown_type"


def test_malformed_json_is_invalid():
    with pytest.raises(ProtocolError) as e:
        parse_client("{not json")
    assert e.value.code == "protocol.invalid"


def test_deeply_nested_frame_is_invalid_not_a_crash():
    # ~200 KB of nested arrays fits under the WebSocket frame limit but blows
    # the JSON decoder's recursion; it must surface as protocol.invalid on
    # both parsers, never as a RecursionError escaping the dispatch loop.
    frame = "[" * 100_000 + "]" * 100_000
    for parser in (parse_client, parse_server):
        with pytest.raises(ProtocolError) as e:
            parser(frame)
        assert e.value.code == "protocol.invalid"
        assert "nested too deeply" in e.value.message


def test_server_type_is_not_a_client_type():
    # text.delta only flows gateway -> app; the client parser must refuse it.
    with pytest.raises(ProtocolError) as e:
        parse_client('{"type":"text.delta","chat":1,"turn":1,"text":"x","ts":"%s"}' % TS)
    assert e.value.code == "protocol.unknown_type"


def test_parse_client_returns_typed_model():
    msg = parse_client('{"type":"message.send","chat":3,"ts":"%s","text":"hi"}' % TS)
    assert type(msg).__name__ == "MessageSend"
    assert msg.chat == 3 and msg.text == "hi" and msg.attachments == []


def test_examples_round_trip():
    for key, msg in example_messages().items():
        assert dump(msg), key
        assert type(msg).model_validate_json(dump(msg)) == msg, key


def test_examples_parse_through_the_direction_parser():
    for key, msg in example_messages().items():
        parser = parse_client if key.startswith("client.") else parse_server
        assert parser(dump(msg)) == msg, key


def test_dump_is_compact_json_without_nulls():
    msg = parse_client('{"type":"chat.open","chat":1,"ts":"%s"}' % TS)
    raw = dump(msg)
    obj = json.loads(raw)
    assert "since" not in obj and "seq" not in obj and "id" not in obj
    assert obj == {"type": "chat.open", "chat": 1, "ts": TS}


def test_schema_has_client_and_server_unions():
    schema = export_schema()
    assert schema["protocol"] == 1
    client_refs = {r["$ref"].rsplit("/", 1)[-1] for r in schema["$defs"]["ClientMessage"]["oneOf"]}
    server_refs = {r["$ref"].rsplit("/", 1)[-1] for r in schema["$defs"]["ServerMessage"]["oneOf"]}
    assert "HelloClient" in client_refs and "MessageSend" in client_refs
    assert "HelloServer" in server_refs and "TextDelta" in server_refs
    assert not (client_refs & server_refs)


def test_state_words_and_answers_are_exact():
    from portico_gateway.messages import CardAnswer, ChatState

    for word in ("idle", "working", "waiting on you", "stopped"):
        ChatState(chat=1, ts=TS, state=word)
    with pytest.raises(Exception):
        ChatState(chat=1, ts=TS, state="running")
    for scope in ("once", "chat", "always"):
        CardAnswer(chat=1, id="c1", ts=TS, answer={}, scope=scope)
    with pytest.raises(Exception):
        CardAnswer(chat=1, id="c1", ts=TS, answer={}, scope="forever")


def test_v04_messages_parse_and_keep_their_shapes():
    from portico_gateway.messages import ServicesStatus, SessionLog, SessionLogged

    log = parse_client('{"type":"session.log","chat":14,"id":"r1","ts":"%s"}' % TS)
    assert isinstance(log, SessionLog) and log.chat == 14
    restart = parse_client('{"type":"service.restart","service":"memory","ts":"%s"}' % TS)
    assert type(restart).__name__ == "ServiceRestart" and restart.service == "memory"
    with pytest.raises(ProtocolError):
        parse_client('{"type":"service.restart","ts":"%s"}' % TS)  # the service is required

    logged = parse_server(
        '{"type":"session.logged","id":"r1","ts":"%s","chat":{"chat":14,"folder":"/f","state":"idle",'
        '"created":"%s","logged_at":"%s"}}' % (TS, TS, TS)
    )
    assert isinstance(logged, SessionLogged) and logged.chat.chat == 14 and logged.chat.unlogged is False
    status = parse_server(
        '{"type":"services.status","ts":"%s","services":[{"id":"m","name":"M","state":"checking"}]}' % TS
    )
    assert isinstance(status, ServicesStatus) and status.services[0].can_restart is False
    with pytest.raises(ProtocolError):
        parse_server('{"type":"services.status","ts":"%s","services":[{"id":"m","name":"M","state":"sleeping"}]}' % TS)


def test_hello_example_shows_the_v012_fields():
    hello = example_messages()["server.hello"]
    assert hello.viewer_defaults is not None and hello.viewer_defaults.act_hosts == ["figma.com"]
    assert {"spaces.v1", "spaces.refresh"} <= set(hello.capabilities)


def test_v016_thread_frames_round_trip_with_their_wire_shape():
    start = parse_client(json.dumps({"type": "thread.start", "chat": 3, "proposal": "p1", "id": "r1", "ts": TS}))
    assert start.type == "thread.start" and start.chat == 3 and start.proposal == "p1" and start.close is None
    at_limit = parse_client(json.dumps({"type": "thread.start", "chat": 3, "proposal": "p1", "close": 5, "ts": TS}))
    assert at_limit.close == 5
    dismiss = parse_client(json.dumps({"type": "thread.dismiss", "chat": 3, "proposal": "p1", "ts": TS}))
    assert dismiss.type == "thread.dismiss" and dismiss.proposal == "p1"
    close = parse_client(json.dumps({"type": "thread.close", "chat": 5, "id": "r2", "ts": TS}))
    assert close.type == "thread.close" and close.chat == 5
    with pytest.raises(ProtocolError):
        parse_client(json.dumps({"type": "thread.start", "chat": 3, "ts": TS}))

    pending = parse_server(
        json.dumps({"type": "thread.proposal", "chat": 3, "proposal": "p1", "brief": "Review the Acme pricing page", "state": "pending", "ts": TS})
    )
    assert pending.files == [] and pending.tool_use_id is None and pending.thread is None
    assert json.loads(dump(pending)) == {
        "type": "thread.proposal", "chat": 3, "proposal": "p1", "brief": "Review the Acme pricing page",
        "files": [], "state": "pending", "ts": TS,
    }
    with pytest.raises(ProtocolError):
        parse_server(json.dumps({"type": "thread.proposal", "chat": 3, "proposal": "p1", "brief": "b", "state": "open", "ts": TS}))

    listing = example_messages()["server.chat.list"]
    thread = json.loads(dump(listing))["chats"][-1]["thread"]
    assert set(thread) == {"label", "slot", "parent", "brief", "files", "opened_at"}
    assert "thread" not in json.loads(dump(listing))["chats"][0], "absent on a chat that is not a thread"
