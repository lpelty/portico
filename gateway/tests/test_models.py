"""v0.15: the model picker's gateway half.

The engine's initialize answer (``get_server_info()["models"]``) is the
CLI's ``/model`` list. The gateway sends it as ``models {chat, current,
choices}`` after ``hello`` (from the list it kept), after each engine start,
and after a switch. ``model.set`` switches the running engine and keeps the
choice in the index, so new sessions and a restarted gateway start on it.
Only an app that declared ``models.v1`` hears ``models``.
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path

import pytest

from websockets.asyncio.client import ClientConnection, connect

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import CAPABILITIES, MODELS_CAPABILITY
from portico_gateway.engine import SDKEngine, build_options, model_choices
from portico_gateway.messages import (
    ChatHistory,
    ChatList,
    ChatNotice,
    ChatOpen,
    ChatState,
    Error,
    HelloClient,
    HelloServer,
    MessageSend,
    Models,
    ModelChoice,
    ModelSet,
    ServerMessage,
    SessionRenew,
    SessionRenewed,
    dump,
    parse_client,
    parse_server,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import ChatRecord, Index, StateDir
from tests.conftest import Block, FakeEngine, RecordingCallbacks, make_config
from tests.test_server import attach, ws_url
from tests.test_sessions import drain, start_server
from tests.test_turns import EngineFactory, recv, recv_until

TS = "2026-11-01T12:00:00Z"

RAW = [
    {"value": "default", "displayName": "Default (recommended)", "description": "Opus 5 for complex work", "resolvedModel": "x"},
    {"value": "sonnet", "displayName": "Sonnet", "description": "Sonnet 5.5 · Efficient for routine tasks", "resolvedModel": "y"},
]
CHOICES = [
    ModelChoice(value="default", display_name="Default (recommended)", description="Opus 5 for complex work"),
    ModelChoice(value="sonnet", display_name="Sonnet", description="Sonnet 5.5 · Efficient for routine tasks"),
]
# The same list as the engine gives it, with what each entry resolves to (v0.15 amendment 11-02).
RESOLVED = [
    ModelChoice(value="default", display_name="Default (recommended)", description="Opus 5 for complex work", resolved_model="x"),
    ModelChoice(value="sonnet", display_name="Sonnet", description="Sonnet 5.5 · Efficient for routine tasks", resolved_model="y"),
]
OPUS = ModelChoice(value="opus", display_name="Opus", description="Opus 5 for the hardest work")


class ModelsFactory(EngineFactory):
    """Engines that offer ``choices`` once started."""

    def __init__(self, choices: list[ModelChoice] | None = CHOICES) -> None:
        super().__init__()
        self.choices = choices

    def __call__(self) -> FakeEngine:
        engine = super().__call__()
        engine.model_entries = self.choices
        return engine


async def attach_models(server: GatewayServer, capabilities: list[str] | None = None) -> tuple[ClientConnection, list[ServerMessage]]:
    """Connect declaring ``models.v1`` (or ``capabilities``); returns the connection and what followed ``hello``."""
    conn = await connect(ws_url(server, server.token))
    caps = [MODELS_CAPABILITY] if capabilities is None else capabilities
    await conn.send(dump(HelloClient(ts=TS, app_version="0.15.0", capabilities=caps)))
    assert isinstance(parse_server(await conn.recv()), HelloServer)
    return conn, await drain(conn)


async def new_chat(conn: ClientConnection, folder: Path) -> tuple[int, list[ServerMessage]]:
    """``chat.new``; the chat's number and every frame up to its ``chat.list``."""
    from portico_gateway.messages import ChatNew

    await conn.send(dump(ChatNew(ts=TS, id="req-new", folder=str(folder))))
    got = await recv_until(conn, ChatList)
    state = next(m for m in got if isinstance(m, ChatState))
    assert state.chat is not None
    return state.chat, got


def models_in(frames: list[ServerMessage]) -> list[Models]:
    return [m for m in frames if isinstance(m, Models)]


def notices(frames: list[ServerMessage]) -> list[str]:
    return [m.text for m in frames if isinstance(m, ChatNotice)]


async def set_model(conn: ClientConnection, chat: int, value: str | None, id: str = "req-m") -> list[ServerMessage]:
    await conn.send(dump(ModelSet(ts=TS, chat=chat, value=value, id=id)))
    return await drain(conn)


def folder_at(tmp_path: Path) -> Path:
    path = tmp_path / "demo"
    path.mkdir(exist_ok=True)
    return path


# --- pure ---------------------------------------------------------------------------


def test_model_choices_map_the_engine_list() -> None:
    raw = [*RAW, {"value": "", "displayName": "nameless"}, "junk", {"value": "haiku"}]
    assert model_choices(raw) == [*RESOLVED, ModelChoice(value="haiku", display_name="haiku", description="")]
    assert model_choices(None) is None
    assert model_choices({"value": "x"}) is None


def test_the_sdk_engine_keeps_the_models_from_its_server_info() -> None:
    engine = SDKEngine()
    assert engine.models() is None
    engine._note_models_from_server_info({"models": RAW})
    assert engine.models() == RESOLVED


def test_build_options_passes_the_model_only_when_set(tmp_path: Path) -> None:
    cb = RecordingCallbacks()
    assert build_options(tmp_path, None, [], cb).model is None
    assert build_options(tmp_path, None, [], cb, model="sonnet").model == "sonnet"


def test_the_wire_shapes_round_trip() -> None:
    frame = Models(ts=TS, chat=3, current="sonnet", choices=CHOICES)
    assert parse_server(dump(frame)) == frame
    request = ModelSet(ts=TS, chat=3, value=None, id="r1")
    assert parse_client(dump(request)) == request


def test_an_old_index_loads_without_models(state_dir: StateDir) -> None:
    state_dir.index_path.write_text('{"chats": [], "next_chat": 4}')
    index = state_dir.load_index()
    assert index.model is None and index.models == []


def test_capability() -> None:
    assert MODELS_CAPABILITY == "models.v1"
    assert MODELS_CAPABILITY in CAPABILITIES


# --- the gateway ------------------------------------------------------------------------


async def test_capability_in_hello(state_dir: StateDir) -> None:
    srv = await start_server(state_dir, ModelsFactory())
    try:
        conn = await connect(ws_url(srv, srv.token))
        await conn.send(dump(HelloClient(ts=TS, app_version="0.15.0")))
        hello = parse_server(await conn.recv())
        assert isinstance(hello, HelloServer) and "models.v1" in hello.capabilities
        await conn.close()
    finally:
        await srv.shutdown()


async def test_models_from_server_info(state_dir: StateDir, tmp_path: Path) -> None:
    factory = ModelsFactory()
    srv = await start_server(state_dir, factory)
    try:
        conn, first = await attach_models(srv)
        assert models_in(first) == []  # nothing kept yet
        number, got = await new_chat(conn, folder_at(tmp_path))
        (frame,) = models_in(got)
        assert frame.chat == number and frame.current is None and frame.choices == CHOICES
        assert frame.seq is None
        await conn.close()
    finally:
        await srv.shutdown()
    assert state_dir.load_index().models == CHOICES


async def test_models_cached_before_start(state_dir: StateDir, tmp_path: Path) -> None:
    folder = folder_at(tmp_path)
    record = ChatRecord(chat=5, folder=str(folder), state="idle", created=TS)
    state_dir.save_index(Index(chats=[record], next_chat=6, model="sonnet", models=CHOICES))
    factory = ModelsFactory()
    srv = await start_server(state_dir, factory)
    try:
        conn, first = await attach_models(srv)
        (frame,) = models_in(first)
        assert (frame.chat, frame.current, frame.choices) == (5, "sonnet", CHOICES)
        assert factory.engines == []
        await conn.close()
    finally:
        await srv.shutdown()


async def test_set_model_live(state_dir: StateDir, tmp_path: Path) -> None:
    factory = ModelsFactory()
    srv = await start_server(state_dir, factory)
    try:
        conn, _ = await attach_models(srv)
        number, _ = await new_chat(conn, folder_at(tmp_path))
        got = await set_model(conn, number, "sonnet")
        assert factory.last.model_switches == ["sonnet"]
        (frame,) = models_in(got)
        assert frame.current == "sonnet" and frame.id == "req-m" and frame.chat == number
        assert notices(got) == ["Model: Sonnet"]
        await conn.close()
    finally:
        await srv.shutdown()
    assert state_dir.load_index().model == "sonnet"


async def test_set_model_before_start(state_dir: StateDir, tmp_path: Path) -> None:
    folder = folder_at(tmp_path)
    record = ChatRecord(chat=5, folder=str(folder), state="idle", created=TS)
    state_dir.save_index(Index(chats=[record], next_chat=6, models=CHOICES))
    factory = ModelsFactory()
    srv = await start_server(state_dir, factory)
    try:
        conn, _ = await attach_models(srv)
        got = await set_model(conn, 5, "sonnet")
        assert factory.engines == []
        assert models_in(got)[0].current == "sonnet"
        await conn.send(dump(MessageSend(ts=TS, chat=5, id="s1", text="hello")))
        await drain(conn)
        assert factory.last.started_model == "sonnet"
        assert factory.last.model_switches == []
        await conn.close()
    finally:
        await srv.shutdown()


async def test_set_model_default(state_dir: StateDir, tmp_path: Path) -> None:
    state_dir.save_index(Index(model="sonnet", models=CHOICES))
    factory = ModelsFactory()
    srv = await start_server(state_dir, factory)
    try:
        conn, _ = await attach_models(srv)
        number, got = await new_chat(conn, folder_at(tmp_path))
        assert factory.last.started_model == "sonnet"
        got = await set_model(conn, number, "default")
        assert factory.last.model_switches == [None]
        assert notices(got) == ["Model: Default (recommended)"]
        assert models_in(got)[0].current is None
        got = await set_model(conn, number, None, id="req-n")
        assert factory.last.model_switches == [None, None]
        await conn.close()
    finally:
        await srv.shutdown()
    assert state_dir.load_index().model is None


async def test_choice_carries_to_new_session(state_dir: StateDir, tmp_path: Path) -> None:
    factory = ModelsFactory()
    srv = await start_server(state_dir, factory)
    try:
        conn, _ = await attach_models(srv)
        number, _ = await new_chat(conn, folder_at(tmp_path))
        await set_model(conn, number, "sonnet")
        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=number)))
        got = await recv_until(conn, SessionRenewed)
        renewed = got[-1]
        assert isinstance(renewed, SessionRenewed)
        following = renewed.next.chat
        got += await drain(conn)
        assert [(m.chat, m.current) for m in models_in(got)] == [(following, "sonnet")]
        await conn.send(dump(MessageSend(ts=TS, chat=following, id="s1", text="hello")))
        await drain(conn)
        assert len(factory.engines) == 2 and factory.last.started_model == "sonnet"
        await conn.close()
    finally:
        await srv.shutdown()


async def test_dropped_model(state_dir: StateDir, tmp_path: Path) -> None:
    state_dir.save_index(Index(model="opus", models=[*CHOICES, OPUS]))
    factory = ModelsFactory(CHOICES)
    srv = await start_server(state_dir, factory)
    try:
        conn, _ = await attach_models(srv)
        number, got = await new_chat(conn, folder_at(tmp_path))
        got += await drain(conn)
        engine = factory.last
        assert engine.started_model == "opus"
        assert engine.model_switches == [None]
        assert notices(got) == ["Model: Default (Opus is no longer offered here)"]
        (frame,) = models_in(got)
        assert frame.current is None and frame.choices == CHOICES
        await conn.close()
    finally:
        await srv.shutdown()
    index = state_dir.load_index()
    assert index.model is None and index.models == CHOICES


async def test_dropped_model_unknown_to_the_old_list_uses_its_value(state_dir: StateDir, tmp_path: Path) -> None:
    state_dir.save_index(Index(model="claude-old-1"))
    srv = await start_server(state_dir, ModelsFactory(CHOICES))
    try:
        conn, _ = await attach_models(srv)
        _, got = await new_chat(conn, folder_at(tmp_path))
        got += await drain(conn)
        assert notices(got) == ["Model: Default (claude-old-1 is no longer offered here)"]
        await conn.close()
    finally:
        await srv.shutdown()


async def test_set_model_while_busy(state_dir: StateDir, tmp_path: Path) -> None:
    factory = ModelsFactory()
    srv = await start_server(state_dir, factory)
    try:
        conn, _ = await attach_models(srv)
        number, _ = await new_chat(conn, folder_at(tmp_path))
        factory.last.script(Block())
        await conn.send(dump(MessageSend(ts=TS, chat=number, id="s1", text="work")))
        await factory.last.wait_blocked()
        got = await set_model(conn, number, "sonnet")
        errors = [m for m in got if isinstance(m, Error)]
        assert [(e.id, e.message) for e in errors] == [("req-m", "Change the model after this reply")]
        assert factory.last.model_switches == [] and models_in(got) == []
        await factory.last.interrupt()
        await conn.close()
    finally:
        await srv.shutdown()
    assert state_dir.load_index().model is None


async def test_unknown_value(state_dir: StateDir, tmp_path: Path) -> None:
    factory = ModelsFactory()
    srv = await start_server(state_dir, factory)
    try:
        conn, _ = await attach_models(srv)
        number, _ = await new_chat(conn, folder_at(tmp_path))
        got = await set_model(conn, number, "gpt")
        errors = [m for m in got if isinstance(m, Error)]
        assert [(e.id, e.message) for e in errors] == [("req-m", "That model isn't offered here.")]
        assert factory.last.model_switches == [] and notices(got) == []
        await conn.close()
    finally:
        await srv.shutdown()


async def test_models_not_sent_to_old_app(state_dir: StateDir, tmp_path: Path) -> None:
    folder = folder_at(tmp_path)
    record = ChatRecord(chat=5, folder=str(folder), state="idle", created=TS)
    state_dir.save_index(Index(chats=[record], next_chat=6, models=CHOICES))
    factory = ModelsFactory()
    srv = await start_server(state_dir, factory)
    try:
        conn = await attach(srv)  # an app without models.v1
        got = await drain(conn)
        await conn.send(dump(MessageSend(ts=TS, chat=5, id="s1", text="hello")))
        got += await drain(conn)
        got += await set_model(conn, 5, "sonnet")
        assert models_in(got) == []
        assert "Model: Sonnet" in notices(got)
        await conn.send(dump(ChatOpen(ts=TS, chat=5)))
        opened = await drain(conn)
        history = [m for m in opened if isinstance(m, ChatHistory)]
        assert history and not any(isinstance(e, Models) for h in history for e in h.events)
        assert models_in(opened) == []
        await conn.close()
    finally:
        await srv.shutdown()


async def test_set_model_on_an_ended_session_is_refused(state_dir: StateDir, tmp_path: Path) -> None:
    folder = folder_at(tmp_path)
    record = ChatRecord(chat=5, folder=str(folder), state="stopped", created=TS, ended=TS)
    state_dir.save_index(Index(chats=[record], next_chat=6, models=CHOICES))
    srv = await start_server(state_dir, ModelsFactory())
    try:
        conn, first = await attach_models(srv)
        assert models_in(first) == []  # no live session to carry it
        got = await set_model(conn, 5, "sonnet")
        assert [e.code for e in got if isinstance(e, Error)] == ["session.ended"]
        await conn.close()
    finally:
        await srv.shutdown()


async def test_an_engine_without_a_list_sends_nothing(state_dir: StateDir, tmp_path: Path) -> None:
    srv = await start_server(state_dir, ModelsFactory(None))
    try:
        conn, _ = await attach_models(srv)
        _, got = await new_chat(conn, folder_at(tmp_path))
        assert models_in(got + await drain(conn)) == []
        await conn.close()
    finally:
        await srv.shutdown()


async def test_a_switch_in_one_chat_leaves_another_chats_engine(state_dir: StateDir, tmp_path: Path) -> None:
    factory = ModelsFactory()
    srv = await start_server(state_dir, factory)
    try:
        conn, _ = await attach_models(srv)
        a, _ = await new_chat(conn, folder_at(tmp_path))
        engine_a = factory.last
        other = tmp_path / "other"
        other.mkdir()
        b, _ = await new_chat(conn, other)
        engine_b = factory.last
        await set_model(conn, a, "sonnet")
        assert engine_a.model_switches == ["sonnet"] and engine_b.model_switches == []
        await conn.close()
        # Reconnect: each live chat's frame carries the model its engine runs on.
        conn, first = await attach_models(srv)
        assert {m.chat: m.current for m in models_in(first)} == {a: "sonnet", b: None}
        # B's next session starts on the new choice.
        await conn.send(dump(SessionRenew(ts=TS, id="req-r", chat=b)))
        got = await recv_until(conn, SessionRenewed)
        renewed = got[-1]
        assert isinstance(renewed, SessionRenewed)
        following = renewed.next.chat
        got += await drain(conn)
        assert [(m.chat, m.current) for m in models_in(got)] == [(following, "sonnet")]
        await conn.send(dump(MessageSend(ts=TS, chat=following, id="s1", text="hello")))
        await drain(conn)
        assert factory.last is not engine_b and factory.last.started_model == "sonnet"
        await conn.close()
    finally:
        await srv.shutdown()


async def test_a_choice_made_with_no_list_is_dropped_at_start(state_dir: StateDir, tmp_path: Path) -> None:
    folder = folder_at(tmp_path)
    record = ChatRecord(chat=5, folder=str(folder), state="idle", created=TS)
    state_dir.save_index(Index(chats=[record], next_chat=6))
    factory = ModelsFactory()
    srv = await start_server(state_dir, factory)
    try:
        conn, _ = await attach_models(srv)
        got = await set_model(conn, 5, "gpt")  # no list kept: taken, checked at the start
        assert models_in(got)[0].current == "gpt" and notices(got) == ["Model: gpt"]
        await conn.send(dump(MessageSend(ts=TS, chat=5, id="s1", text="hello")))
        got = await drain(conn)
        assert factory.last.started_model == "gpt" and factory.last.model_switches == [None]
        assert notices(got) == ["Model: Default (gpt is no longer offered here)"]
        assert [m.current for m in models_in(got)] == [None]
        await conn.close()
    finally:
        await srv.shutdown()
    index = state_dir.load_index()
    assert index.model is None and index.models == CHOICES


async def test_a_failed_switch_keeps_the_choice_and_answers_an_error(state_dir: StateDir, tmp_path: Path) -> None:
    factory = ModelsFactory()
    srv = await start_server(state_dir, factory)
    try:
        conn, _ = await attach_models(srv)
        number, _ = await new_chat(conn, folder_at(tmp_path))

        async def refuse(value: str | None) -> None:
            raise RuntimeError("engine said no")

        factory.last.set_model = refuse  # type: ignore[method-assign]
        got = await set_model(conn, number, "sonnet")
        errors = [m for m in got if isinstance(m, Error)]
        assert [(e.code, e.id, e.chat) for e in errors] == [("gateway.error", "req-m", number)]
        assert "engine said no" in errors[0].message
        assert models_in(got) == [] and notices(got) == []
        await conn.close()
    finally:
        await srv.shutdown()
    assert state_dir.load_index().model is None


# --- the list before the first message (v0.15 amendment 11-02) ----------------------------


class ProbingFactory(ModelsFactory):
    """``ModelsFactory`` plus the gateway-start probe; ``gate`` (when set) holds the probe until released."""

    def __init__(self, answer: list[ModelChoice] | None = RESOLVED, error: Exception | None = None) -> None:
        super().__init__()
        self.answer = answer
        self.error = error
        self.gate: asyncio.Event | None = None
        self.hang = False
        self.probes: list[tuple[Path, list[str]]] = []
        self.disconnected = False

    async def probe_models(self, folder: Path, setting_sources: list[str]) -> list[ModelChoice] | None:
        self.probes.append((folder, list(setting_sources)))
        try:
            if self.gate is not None:
                await self.gate.wait()
            if self.hang:
                await asyncio.Event().wait()
            if self.error is not None:
                raise self.error
            return self.answer
        finally:
            # Like the real probe: disconnecting takes a moment and is awaited.
            await asyncio.sleep(0.05)
            self.disconnected = True


def live_index(state_dir: StateDir, tmp_path: Path, **index: object) -> None:
    record = ChatRecord(chat=5, folder=str(folder_at(tmp_path)), state="idle", created=TS)
    state_dir.save_index(Index(chats=[record], next_chat=6, **index))  # type: ignore[arg-type]


async def test_resolved_model_round_trips() -> None:
    assert model_choices(RAW) == RESOLVED
    frame = Models(ts=TS, chat=3, current=None, choices=RESOLVED)
    assert parse_server(dump(frame)) == frame
    assert '"resolved_model":"x"' in dump(frame)
    assert "resolved_model" not in dump(Models(ts=TS, chat=3, choices=CHOICES))  # additive: absent when unknown


def test_an_index_with_resolved_models_round_trips(state_dir: StateDir) -> None:
    state_dir.save_index(Index(models=RESOLVED))
    assert state_dir.load_index().models == RESOLVED


async def test_the_probe_records_and_broadcasts_without_delaying_hello(state_dir: StateDir, tmp_path: Path) -> None:
    live_index(state_dir, tmp_path)
    factory = ProbingFactory()
    factory.gate = asyncio.Event()
    srv = await start_server(state_dir, factory, default_folder=str(tmp_path))
    try:
        conn, first = await attach_models(srv)  # hello arrives while the probe is held
        assert models_in(first) == []
        factory.gate.set()
        got = await recv_until(conn, Models)
        (frame,) = models_in(got)
        assert (frame.chat, frame.current, frame.choices) == (5, None, RESOLVED)
        assert factory.engines == []  # no engine started, no message sent
        assert factory.probes == [(tmp_path.resolve(), list(srv.config.setting_sources))]
        await conn.close()
    finally:
        await srv.shutdown()
    assert state_dir.load_index().models == RESOLVED


async def test_the_probe_list_is_heard_by_an_app_that_attaches_later(state_dir: StateDir, tmp_path: Path) -> None:
    live_index(state_dir, tmp_path)
    factory = ProbingFactory()
    srv = await start_server(state_dir, factory)
    try:
        for _ in range(50):
            if srv.registry.models:
                break
            await asyncio.sleep(0.01)
        conn, first = await attach_models(srv)
        (frame,) = models_in(first)
        assert frame.choices == RESOLVED
        await conn.close()
    finally:
        await srv.shutdown()


async def test_a_failed_probe_keeps_the_stored_list_and_logs(
    state_dir: StateDir, tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    live_index(state_dir, tmp_path, models=CHOICES)
    factory = ProbingFactory(error=RuntimeError("no CLI here"))
    with caplog.at_level(logging.WARNING, logger="portico_gateway.server"):
        srv = await start_server(state_dir, factory)
        try:
            conn, first = await attach_models(srv)
            assert [m.choices for m in models_in(first)] == [CHOICES]
            await drain(conn)
            assert srv.registry.models == CHOICES
            await conn.close()
        finally:
            await srv.shutdown()
    assert any("model list" in r.getMessage() and r.levelno == logging.WARNING for r in caplog.records)
    assert state_dir.load_index().models == CHOICES


async def test_a_probe_that_hangs_times_out(state_dir: StateDir, tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    live_index(state_dir, tmp_path, models=CHOICES)
    factory = ProbingFactory()
    factory.hang = True
    cfg = make_config()
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=cfg.history_buffer)
    srv = GatewayServer(config=cfg, state=state_dir, registry=registry, engine_factory=factory, version=__version__)
    srv.model_probe_timeout = 0.05
    with caplog.at_level(logging.WARNING, logger="portico_gateway.server"):
        await srv.serve(0)
        try:
            for _ in range(200):  # up to 2 s; fails below if the timeout never fires
                if any("no answer within" in r.getMessage() for r in caplog.records):
                    break
                await asyncio.sleep(0.01)
            assert any("no answer within" in r.getMessage() for r in caplog.records)
            assert srv.registry.models == CHOICES
        finally:
            await srv.shutdown()


async def test_an_unchanged_probe_list_is_not_rewritten(state_dir: StateDir, tmp_path: Path) -> None:
    live_index(state_dir, tmp_path, models=RESOLVED)
    factory = ProbingFactory()
    srv = await start_server(state_dir, factory)
    try:
        calls: list[object] = []
        original = srv.registry.record_models
        srv.registry.record_models = lambda choices: (calls.append(choices), original(choices))  # type: ignore[method-assign]
        await srv._probe_models()
        assert calls == []
    finally:
        await srv.shutdown()


async def test_no_probe_without_the_seam(state_dir: StateDir, tmp_path: Path) -> None:
    live_index(state_dir, tmp_path)
    srv = await start_server(state_dir, ModelsFactory())
    try:
        assert not any(t.get_name() == "portico-model-probe" for t in srv._tasks)
    finally:
        await srv.shutdown()


async def test_the_sdk_probe_reads_server_info_and_sends_nothing(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[str] = []

    class Client:
        def __init__(self, options: object) -> None:
            seen.append(f"options cwd={getattr(options, 'cwd', None)} sources={getattr(options, 'setting_sources', None)}")

        async def connect(self) -> None:
            seen.append("connect")

        async def get_server_info(self) -> dict[str, object]:
            seen.append("info")
            return {"models": RAW}

        async def query(self, *_: object) -> None:  # pragma: no cover - must not be called
            seen.append("query")

        async def disconnect(self) -> None:
            seen.append("disconnect")

    monkeypatch.setattr("portico_gateway.engine.ClaudeSDKClient", Client)
    got = await SDKEngine.probe_models(tmp_path, ["user", "project"])
    assert got == RESOLVED
    assert seen == [f"options cwd={tmp_path} sources=['user', 'project']", "connect", "info", "disconnect"]


async def test_the_sdk_probe_disconnects_after_a_failure(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[str] = []

    class Client:
        def __init__(self, options: object) -> None:
            pass

        async def connect(self) -> None:
            seen.append("connect")

        async def get_server_info(self) -> dict[str, object]:
            raise RuntimeError("broken")

        async def disconnect(self) -> None:
            seen.append("disconnect")

    monkeypatch.setattr("portico_gateway.engine.ClaudeSDKClient", Client)
    with pytest.raises(RuntimeError):
        await SDKEngine.probe_models(tmp_path, [])
    assert seen == ["connect", "disconnect"]


async def test_shutdown_mid_probe_waits_for_its_disconnect(state_dir: StateDir, tmp_path: Path) -> None:
    live_index(state_dir, tmp_path)
    factory = ProbingFactory()
    factory.hang = True
    srv = await start_server(state_dir, factory)
    for _ in range(100):
        if factory.probes:
            break
        await asyncio.sleep(0.01)
    assert factory.probes and not factory.disconnected
    await asyncio.wait_for(srv.shutdown(), 5)
    assert factory.disconnected


async def test_the_probe_disables_the_deployments_hooks(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import json

    captured: list[object] = []

    class Client:
        def __init__(self, options: object) -> None:
            captured.append(options)

        async def connect(self) -> None:
            pass

        async def get_server_info(self) -> dict[str, object]:
            return {"models": RAW}

        async def disconnect(self) -> None:
            pass

    monkeypatch.setattr("portico_gateway.engine.ClaudeSDKClient", Client)
    await SDKEngine.probe_models(tmp_path, ["project"])
    (options,) = captured
    assert json.loads(options.settings) == {"disableAllHooks": True}  # type: ignore[attr-defined]
    # A real engine's options never carry it.
    assert build_options(tmp_path, None, ["project"], RecordingCallbacks()).settings is None


def test_hooks_off_merges_into_existing_settings() -> None:
    import json

    from portico_gateway.engine import with_hooks_disabled

    assert json.loads(with_hooks_disabled(None)) == {"disableAllHooks": True}
    assert json.loads(with_hooks_disabled('{"model": "sonnet"}')) == {"model": "sonnet", "disableAllHooks": True}


def test_model_choices_drop_the_price_from_descriptions() -> None:
    """Larry 11-02: no pricing in the menu (API-key logins add it; it's wrong for Bedrock); the rest stays."""
    raw = [
        {"value": "default", "displayName": "Default (recommended)",
         "description": "Use the default model (currently Opus 5.5) · $4/$20 per Mtok"},
        {"value": "haiku", "displayName": "Haiku 5.5",
         "description": "Haiku 5.5 · Fastest for quick answers · $0.10/$0.50 per Mtok ($0.50/$2.50 for prompts over 100k)"},
        {"value": "fable", "displayName": "Fable 5.1",
         "description": "Fable 5.1 · Most capable for your hardest and longest-running tasks"},
    ]
    assert [c.description for c in model_choices(raw)] == [
        "Use the default model (currently Opus 5.5)",
        "Haiku 5.5 · Fastest for quick answers",
        "Fable 5.1 · Most capable for your hardest and longest-running tasks",
    ]
