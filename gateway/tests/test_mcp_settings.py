"""v0.18 §3.1: MCP servers managed from Settings (``mcp.v1``, plan rulings 4–15).

The app asks with ``mcp.list`` / ``mcp.toggle`` / ``mcp.reconnect`` /
``mcp.remove`` / ``mcp.add`` / ``mcp.sign_in`` / ``mcp.sign_out`` /
``mcp.tool_policy``; each is answered with ``mcp.servers`` carrying the
request's id, or ``error`` with the id. Rows merge the four sources
(``mcp_inventory.read_servers``) with the status of the most recently
started live engine on Settings' folder. Nothing here runs the real
``claude`` CLI or reads the person's ``~/.claude.json``: the conftest
fixture points ``CLAUDE_CONFIG_DIR`` at a throwaway folder, and every test
injects a ``ScriptedCli``.
"""

from __future__ import annotations

import asyncio
import json
import os
import stat
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest
from websockets.asyncio.client import ClientConnection

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import McpConfig
from portico_gateway.mcp_inventory import CliResult, claude_json_path
from portico_gateway.mcp_settings import ToolPolicy
from portico_gateway.messages import (
    CardAsk,
    ChatNotice,
    Error,
    McpAdd,
    McpList,
    McpReconnect,
    McpRemove,
    McpServers,
    McpSignIn,
    McpToggle,
    McpToolPolicy,
    MessageSend,
    TurnFinished,
    dump,
)
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from tests.conftest import make_config
from tests.test_server import attach, ws_url  # noqa: F401
from tests.test_turns import TS, EngineFactory, new_chat, recv, recv_until

# --- fakes -------------------------------------------------------------------------


class ScriptedCli:
    """A ``CliRunner`` that records every call; answers by subcommand (``args[:2]``), optionally after a gate."""

    def __init__(self) -> None:
        self.calls: list[tuple[list[str], Path, float]] = []
        self.results: dict[tuple[str, ...], CliResult] = {}
        self.gates: dict[tuple[str, ...], asyncio.Event] = {}
        self.reached: dict[tuple[str, ...], asyncio.Event] = {}

    def mcp_calls(self) -> list[list[str]]:
        return [args for args, _, _ in self.calls if args[:1] == ["mcp"]]

    async def run(self, args: list[str], *, cwd: Path, timeout: float, stdin_text: str | None = None) -> CliResult:
        self.calls.append((list(args), Path(cwd), timeout))
        key = tuple(args[:2])
        self.reached.setdefault(key, asyncio.Event()).set()
        gate = self.gates.get(key)
        if gate is not None:
            await gate.wait()
        if key == ("plugin", "list"):
            return CliResult(0, "[]", "")
        return self.results.get(key, CliResult(0, "", ""))


def tools(prefix: str, n: int) -> list[dict[str, Any]]:
    return [{"name": f"{prefix}_{i}", "description": f"Tool {i}"} for i in range(n)]


TRACKER_TOOLS = [
    {"name": "show_project", "description": "Shows a project's status and tasks", "annotations": {"readOnly": True}},
    {"name": "list_tasks", "description": "Lists tasks, with filters", "annotations": {"readOnly": True}},
    {"name": "update_task", "description": "Changes a task's status or owner"},
    {"name": "create_task", "description": "Adds a task to a project"},
    {"name": "delete_task", "description": "Deletes a task", "annotations": {"destructive": True}},
    {"name": "archive_task", "description": "Archives a task"},
    {"name": "assign_task", "description": "Assigns a task"},
    {"name": "comment_task", "description": "Comments on a task"},
]

STATUS: list[dict[str, Any]] = [
    {"name": "portico", "status": "connected", "config": {"type": "sdk", "name": "portico"}, "tools": tools("p", 9)},
    {"name": "team-knowledge", "status": "connected", "config": {"type": "stdio", "command": "tk"}, "tools": tools("k", 5)},
    {
        "name": "acme-tracker",
        "status": "connected",
        "serverInfo": {"name": "acme-tracker", "version": "1.0", "title": "Acme Tracker"},
        "config": {"type": "http", "url": "https://mcp.acme.example/"},
        "tools": TRACKER_TOOLS,
    },
    {"name": "acme-calendar", "status": "needs-auth", "config": {"type": "http", "url": "https://cal.acme.example/"}},
    {"name": "docs", "status": "failed", "config": {"type": "stdio", "command": "docs-mcp"}},
    {"name": "acme-crm", "status": "connected", "config": {"type": "stdio", "command": "crm"}, "tools": tools("c", 12)},
    {"name": "design-files", "status": "disabled", "config": {"type": "stdio", "command": "df"}},
    {"name": "claude.ai Acme Drive", "status": "connected", "scope": "claudeai", "config": {"type": "claudeai-proxy", "url": "https://x", "id": "d1"}, "tools": tools("d", 2)},
    # R-c4: never listed — a plugin's server, and one from no known source.
    {"name": "plugin:acme:notes", "status": "connected", "scope": "dynamic", "config": {"type": "stdio", "command": "n"}, "tools": tools("n", 1)},
    {"name": "stray", "status": "connected", "scope": "dynamic", "config": {"type": "stdio", "command": "s"}},
]


def write_claude_json(data: dict[str, Any], mode: int = 0o600) -> Path:
    path = claude_json_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")
    os.chmod(path, mode)
    return path


def read_claude_json() -> dict[str, Any]:
    return json.loads(claude_json_path().read_text(encoding="utf-8"))


def seed(folder: Path, *, disabled: list[str] | None = None) -> None:
    """The four sources: user, local (for ``folder``) and ``folder/.mcp.json`` (one core, two shipped)."""
    write_claude_json(
        {
            "numStartups": 4,
            "mcpServers": {
                "acme-tracker": {"type": "http", "url": "https://mcp.acme.example/"},
                "acme-calendar": {"type": "http", "url": "https://cal.acme.example/"},
                "docs": {"type": "stdio", "command": "docs-mcp", "args": []},
            },
            "projects": {
                str(folder): {
                    "allowedTools": [],
                    "mcpServers": {"sales-data": {"type": "stdio", "command": "sales"}},
                    "disabledMcpServers": ["sales-data", "design-files"] if disabled is None else disabled,
                }
            },
        }
    )
    (folder / ".mcp.json").write_text(
        json.dumps(
            {
                "mcpServers": {
                    "team-knowledge": {"command": "tk"},
                    "acme-crm": {"command": "crm"},
                    "design-files": {"command": "df"},
                }
            }
        ),
        encoding="utf-8",
    )


# --- fixtures ----------------------------------------------------------------------


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = (tmp_path / "agent").resolve()
    path.mkdir()
    return path


@pytest.fixture
def cli() -> ScriptedCli:
    return ScriptedCli()


@pytest.fixture
def factory() -> EngineFactory:
    return EngineFactory()


@pytest.fixture
async def server(state_dir: StateDir, factory: EngineFactory, folder: Path, cli: ScriptedCli) -> AsyncIterator[GatewayServer]:
    cfg = make_config(setting_sources=["project"], default_folder=str(folder), mcp=McpConfig(core=["team-knowledge"]))
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=cfg.history_buffer)
    srv = GatewayServer(
        config=cfg, state=state_dir, registry=registry, engine_factory=factory, version=__version__, cli=cli
    )
    await srv.serve(0)
    try:
        yield srv
    finally:
        await srv.shutdown()


async def live_engine(server: GatewayServer, conn: ClientConnection, folder: Path, status: list[dict[str, Any]], id: str = "req-new"):
    """A chat in ``folder`` with a started engine whose ``mcp_status`` answers ``status``."""
    number = await new_chat(conn, folder, id=id)
    chat = server.registry.get(number)
    engine = await server._ensure_engine(chat)
    engine.mcp_status_value = [dict(s) for s in status]  # type: ignore[attr-defined]
    return engine


async def ask(conn: ClientConnection, msg: Any) -> McpServers | Error:
    """Send ``msg``; the first ``mcp.servers`` or ``error`` with its id."""
    await conn.send(dump(msg))
    while True:
        got = await recv(conn)
        if isinstance(got, (McpServers, Error)) and got.id == msg.id:
            return got


def row(reply: McpServers, name: str):
    return next(r for r in reply.servers if r.name == name)


# --- tests -------------------------------------------------------------------------


async def test_hello_advertises_mcp_v1(server: GatewayServer) -> None:
    from portico_gateway.config import hello_for

    assert "mcp.v1" in hello_for(server.config, server.epoch, server.version).capabilities


async def test_list_groups_and_status_words(server: GatewayServer, folder: Path) -> None:
    seed(folder)
    conn = await attach(server)
    try:
        await live_engine(server, conn, folder, STATUS)
        reply = await ask(conn, McpList(ts=TS, id="l-1"))
        assert isinstance(reply, McpServers) and reply.live is True
        assert [(r.name, r.group) for r in reply.servers] == [
            ("portico", "core"),
            ("team-knowledge", "core"),
            ("acme-tracker", "user"),
            ("acme-calendar", "user"),
            ("docs", "user"),
            ("sales-data", "local"),
            ("acme-crm", "shipped"),
            ("design-files", "shipped"),
            ("claude.ai Acme Drive", "account"),
        ]
        tracker = row(reply, "acme-tracker")
        assert (tracker.title, tracker.status, tracker.detail, tracker.tool_count) == (
            "Acme Tracker", "connected", "Connected · 8 tools", 8,
        )
        assert tracker.transport == "http" and tracker.can_toggle and tracker.can_remove
        assert tracker.can_sign_out is True  # http and connected
        assert [(t.name, t.read_only, t.policy) for t in tracker.tools][:3] == [
            ("show_project", True, "allow"), ("list_tasks", True, "allow"), ("update_task", False, "ask"),
        ]
        cal = row(reply, "acme-calendar")
        assert (cal.title, cal.status, cal.detail) == ("acme-calendar", "needs_auth", "Needs you to sign in")
        docs = row(reply, "docs")
        assert (docs.status, docs.detail, docs.transport) == ("failed", "Couldn't start: it stopped as soon as it opened", "stdio")
        sales = row(reply, "sales-data")
        assert (sales.status, sales.detail) == ("off", "Off")
        crm = row(reply, "acme-crm")
        assert (crm.status, crm.detail, crm.can_toggle, crm.can_remove) == ("connected", "Connected · 12 tools", True, False)
        design = row(reply, "design-files")
        assert (design.status, design.detail, design.can_remove) == ("off", "Off for you · it stays off through updates", False)
        portico = row(reply, "portico")
        assert portico.detail == "Connected · the viewer, files and screen · 9 tools"
        assert portico.can_toggle is False and portico.can_remove is False
        knowledge = row(reply, "team-knowledge")
        assert knowledge.can_toggle is False and knowledge.can_remove is False
        drive = row(reply, "claude.ai Acme Drive")
        assert (drive.can_toggle, drive.can_remove, drive.transport) == (True, False, "other")
        assert all(r.account is None for r in reply.servers)  # never invented
    finally:
        await conn.close()


async def test_failed_error_is_cut_to_120(server: GatewayServer, folder: Path) -> None:
    seed(folder)
    conn = await attach(server)
    try:
        status = [dict(s) for s in STATUS]
        next(s for s in status if s["name"] == "docs")["error"] = "e" * 200
        await live_engine(server, conn, folder, status)
        reply = await ask(conn, McpList(ts=TS, id="l-1"))
        assert isinstance(reply, McpServers)
        assert row(reply, "docs").detail == "Couldn't start: " + "e" * 120
    finally:
        await conn.close()


async def test_list_without_a_live_engine(server: GatewayServer, folder: Path) -> None:
    seed(folder)
    conn = await attach(server)
    try:
        reply = await ask(conn, McpList(ts=TS, id="l-1"))
        assert isinstance(reply, McpServers) and reply.live is False
        for r in reply.servers:
            assert r.tool_count is None and r.tools == []
            if r.group not in ("core",) and r.status != "off":
                assert r.detail == "Starts with your next chat", r
    finally:
        await conn.close()


async def test_toggle_writes_disabled_mcp_servers(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    seed(folder, disabled=[])
    conn = await attach(server)
    try:
        engine = await live_engine(server, conn, folder, STATUS)
        reply = await ask(conn, McpToggle(ts=TS, id="t-1", name="acme-crm", enabled=False))
        assert isinstance(reply, McpServers)
        assert row(reply, "acme-crm").status == "off"
        assert read_claude_json()["projects"][str(folder)]["disabledMcpServers"] == ["acme-crm"]
        reply = await ask(conn, McpToggle(ts=TS, id="t-2", name="acme-crm", enabled=True))
        assert isinstance(reply, McpServers)
        assert read_claude_json()["projects"][str(folder)]["disabledMcpServers"] == []
        assert engine.toggles == []  # ruling 5: the next engine start, not the running one
    finally:
        await conn.close()


async def test_toggle_creates_a_missing_project_entry(server: GatewayServer, folder: Path) -> None:
    write_claude_json({"mcpServers": {"acme-tracker": {"type": "http", "url": "https://mcp.acme.example/"}}})
    conn = await attach(server)
    try:
        reply = await ask(conn, McpToggle(ts=TS, id="t-1", name="acme-tracker", enabled=False))
        assert isinstance(reply, McpServers)
        assert read_claude_json()["projects"] == {str(folder): {"disabledMcpServers": ["acme-tracker"]}}
    finally:
        await conn.close()


async def test_toggle_keeps_every_other_key(server: GatewayServer, folder: Path) -> None:
    original = {
        "numStartups": 4,
        "oauthAccount": {"emailAddress": "sam@acme.example", "organizationUuid": "o-1"},
        "mcpServers": {"acme-tracker": {"type": "http", "url": "https://mcp.acme.example/", "headers": {"X-Key": "k"}}},
        "projects": {
            "/elsewhere": {"allowedTools": ["Bash"], "history": [{"display": "hi"}]},
            str(folder): {"allowedTools": [], "nested": {"deep": [1, 2, {"three": 3}]}, "disabledMcpServers": []},
        },
        "tipsHistory": {"a": 1},
    }
    path = write_claude_json(original, mode=0o600)
    conn = await attach(server)
    try:
        reply = await ask(conn, McpToggle(ts=TS, id="t-1", name="acme-tracker", enabled=False))
        assert isinstance(reply, McpServers)
        after = read_claude_json()
        assert list(after) == list(original)
        assert list(after["projects"]) == list(original["projects"])
        assert list(after["projects"][str(folder)]) == list(original["projects"][str(folder)])
        assert after["projects"][str(folder)].pop("disabledMcpServers") == ["acme-tracker"]
        original["projects"][str(folder)].pop("disabledMcpServers")
        assert after == original
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
        assert [p.name for p in path.parent.iterdir()] == [".claude.json"]  # the temp file went with os.replace
    finally:
        await conn.close()


async def test_toggle_refuses_a_file_that_does_not_parse(server: GatewayServer, folder: Path) -> None:
    path = claude_json_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("{not json", encoding="utf-8")
    conn = await attach(server)
    try:
        reply = await ask(conn, McpToggle(ts=TS, id="t-1", name="acme-tracker", enabled=False))
        assert isinstance(reply, Error)
        assert path.read_text(encoding="utf-8") == "{not json"  # never rewritten
    finally:
        await conn.close()


async def test_toggle_core_refused(server: GatewayServer, folder: Path) -> None:
    seed(folder)
    conn = await attach(server)
    try:
        for name in ("portico", "team-knowledge"):
            reply = await ask(conn, McpToggle(ts=TS, id=f"t-{name}", name=name, enabled=False))
            assert isinstance(reply, Error) and reply.message == "Built-in servers can't be turned off"
    finally:
        await conn.close()


async def test_remove_runs_the_cli_and_refuses_shipped(server: GatewayServer, folder: Path, cli: ScriptedCli) -> None:
    seed(folder)
    conn = await attach(server)
    try:
        reply = await ask(conn, McpRemove(ts=TS, id="r-1", name="acme-tracker"))
        assert isinstance(reply, McpServers)
        args, cwd, timeout = next(c for c in cli.calls if c[0][:2] == ["mcp", "remove"])
        assert args == ["mcp", "remove", "acme-tracker", "--scope", "user"]
        assert cwd == folder and timeout == 60
        reply = await ask(conn, McpRemove(ts=TS, id="r-2", name="sales-data"))
        assert cli.mcp_calls()[-1] == ["mcp", "remove", "sales-data", "--scope", "local"]
        before = len(cli.calls)
        for name in ("acme-crm", "portico", "team-knowledge"):
            reply = await ask(conn, McpRemove(ts=TS, id=f"r-{name}", name=name))
            assert isinstance(reply, Error), name
        assert len(cli.calls) == before
    finally:
        await conn.close()


async def test_add_http_and_stdio(server: GatewayServer, folder: Path, cli: ScriptedCli) -> None:
    write_claude_json({"mcpServers": {"docs-old": {"command": "x"}}, "projects": {str(folder): {"mcpServers": {"docs": {"command": "d"}}}}})
    conn = await attach(server)
    try:
        reply = await ask(
            conn, McpAdd(ts=TS, id="a-1", name="acme-tracker", transport="http", url="https://mcp.acme.example/", where="user")
        )
        assert isinstance(reply, McpServers)
        assert cli.mcp_calls()[-1] == ["mcp", "add", "--scope", "user", "--transport", "http", "acme-tracker", "https://mcp.acme.example/"]
        reply = await ask(
            conn, McpAdd(ts=TS, id="a-2", name="docs2", transport="stdio", command="npx -y @acme/docs-mcp --stdio", where="local")
        )
        assert isinstance(reply, McpServers)
        assert cli.mcp_calls()[-1] == ["mcp", "add", "--scope", "local", "docs2", "--", "npx", "-y", "@acme/docs-mcp", "--stdio"]
        before = len(cli.calls)
        reply = await ask(conn, McpAdd(ts=TS, id="a-3", name="docs search", transport="stdio", command="x", where="local"))
        assert isinstance(reply, Error) and reply.message == "Use letters, numbers, - and _ only"
        reply = await ask(conn, McpAdd(ts=TS, id="a-4", name="docs", transport="stdio", command="x", where="user"))
        assert isinstance(reply, Error) and reply.message == "There's already a server called docs"
        assert len(cli.calls) == before
    finally:
        await conn.close()


async def test_add_stdio_brief_example(server: GatewayServer, folder: Path, cli: ScriptedCli) -> None:
    conn = await attach(server)
    try:
        reply = await ask(
            conn, McpAdd(ts=TS, id="a-1", name="docs", transport="stdio", command="npx -y @acme/docs-mcp --stdio", where="local")
        )
        assert isinstance(reply, McpServers)
        assert cli.mcp_calls()[-1] == ["mcp", "add", "--scope", "local", "docs", "--", "npx", "-y", "@acme/docs-mcp", "--stdio"]
    finally:
        await conn.close()


async def test_add_http_then_sign_in_when_needed(server: GatewayServer, folder: Path, cli: ScriptedCli) -> None:
    conn = await attach(server)
    try:
        engine = await live_engine(server, conn, folder, [])
        plain_reconnect = engine.mcp_reconnect

        async def reconnect(name: str) -> None:
            # The CLI wrote it (the fake does not), and once reconnected it wants a sign-in.
            write_claude_json({"mcpServers": {name: {"type": "http", "url": "https://mcp.acme.example/"}}})
            await plain_reconnect(name)
            engine.mcp_status_value = [
                {"name": name, "status": "needs-auth", "config": {"type": "http", "url": "https://mcp.acme.example/"}}
            ]

        engine.mcp_reconnect = reconnect  # type: ignore[method-assign]
        reply = await ask(
            conn, McpAdd(ts=TS, id="a-1", name="acme-tracker", transport="http", url="https://mcp.acme.example/", where="user")
        )
        assert isinstance(reply, McpServers)
        await asyncio.wait_for(cli.reached.setdefault(("mcp", "login"), asyncio.Event()).wait(), 5)
        mcp = cli.mcp_calls()
        assert mcp[-2][:2] == ["mcp", "add"] and mcp[-1] == ["mcp", "login", "acme-tracker"]
        login = next(c for c in cli.calls if c[0][:2] == ["mcp", "login"])
        assert login[2] == 300 and engine.reconnects[:1] == ["acme-tracker"]
        assert row(reply, "acme-tracker").status == "signing_in"
    finally:
        await conn.close()


async def test_add_http_without_needs_auth_does_not_sign_in(server: GatewayServer, folder: Path, cli: ScriptedCli) -> None:
    conn = await attach(server)
    try:
        await live_engine(server, conn, folder, [])
        reply = await ask(
            conn, McpAdd(ts=TS, id="a-1", name="acme-tracker", transport="http", url="https://mcp.acme.example/", where="user")
        )
        assert isinstance(reply, McpServers)
        await asyncio.sleep(0.05)
        assert not any(c[0][:2] == ["mcp", "login"] for c in cli.calls)
    finally:
        await conn.close()


async def test_sign_in_answers_at_once_then_pushes(server: GatewayServer, folder: Path, cli: ScriptedCli) -> None:
    seed(folder)
    gate = asyncio.Event()
    cli.gates[("mcp", "login")] = gate
    conn = await attach(server)
    try:
        engine = await live_engine(server, conn, folder, STATUS)
        reply = await ask(conn, McpSignIn(ts=TS, id="s-1", name="acme-tracker"))
        assert isinstance(reply, McpServers)
        tracker = row(reply, "acme-tracker")
        assert (tracker.status, tracker.detail) == ("signing_in", "Signing in… finish in your browser")
        assert not gate.is_set() and engine.reconnects == []
        gate.set()
        pushed = (await recv_until(conn, McpServers))[-1]
        assert isinstance(pushed, McpServers) and pushed.id is None
        assert row(pushed, "acme-tracker").status == "connected"
        assert engine.reconnects == ["acme-tracker"]
        assert ["mcp", "login", "acme-tracker"] in cli.mcp_calls()
    finally:
        await conn.close()


async def test_reconnect_reaches_live_engines_on_that_folder(server: GatewayServer, folder: Path, tmp_path: Path) -> None:
    seed(folder)
    other = tmp_path / "other"
    other.mkdir()
    conn = await attach(server)
    try:
        here = await live_engine(server, conn, folder, STATUS, id="n-1")
        there = await live_engine(server, conn, other, STATUS, id="n-2")
        reply = await ask(conn, McpReconnect(ts=TS, id="c-1", name="docs"))
        assert isinstance(reply, McpServers)
        assert here.reconnects == ["docs"] and there.reconnects == []
    finally:
        await conn.close()


async def test_cli_failure_message(server: GatewayServer, folder: Path, cli: ScriptedCli) -> None:
    seed(folder)
    cli.results[("mcp", "remove")] = CliResult(1, "", "x\nServer not found\n")
    conn = await attach(server)
    try:
        reply = await ask(conn, McpRemove(ts=TS, id="r-1", name="docs"))
        assert isinstance(reply, Error) and reply.message == "Server not found"
        cli.results[("mcp", "remove")] = CliResult(1, "", "y" * 300 + "\n\n")
        reply = await ask(conn, McpRemove(ts=TS, id="r-2", name="docs"))
        assert isinstance(reply, Error) and reply.message == "y" * 240
    finally:
        await conn.close()


async def test_tool_policy_round_trip(server: GatewayServer, folder: Path, state_dir: StateDir) -> None:
    seed(folder)
    conn = await attach(server)
    try:
        await live_engine(server, conn, folder, STATUS)
        reply = await ask(conn, McpToolPolicy(ts=TS, id="p-1", server="acme-tracker", tool="update_task", policy="allow"))
        assert isinstance(reply, McpServers)
        assert next(t for t in row(reply, "acme-tracker").tools if t.name == "update_task").policy == "allow"
        policy_file = state_dir.path / "mcp_tools.json"
        assert json.loads(policy_file.read_text()) == {"mcp__acme-tracker__update_task": "allow"}
        assert stat.S_IMODE(policy_file.stat().st_mode) == 0o600

        chat = next(c for c in server.registry.chats() if c.engine is not None)
        decision = await asyncio.wait_for(
            server.ask_permission(chat, "mcp__acme-tracker__update_task", {"id": 1}, [], "toolu_9"), 2
        )
        assert decision == "allow"
        assert not any(isinstance(m, CardAsk) for m in chat.ring)
        assert chat.permissions["toolu_9"].outcome == "session"
        assert chat.permissions["toolu_9"].note == "Set to run without asking in Settings"

        # A read-only tool set to its own default stores nothing.
        reply = await ask(conn, McpToolPolicy(ts=TS, id="p-2", server="acme-tracker", tool="list_tasks", policy="allow"))
        assert json.loads(policy_file.read_text()) == {"mcp__acme-tracker__update_task": "allow"}
        reply = await ask(conn, McpToolPolicy(ts=TS, id="p-3", server="acme-tracker", tool="update_task", policy=None))
        assert isinstance(reply, McpServers)
        assert json.loads(policy_file.read_text()) == {}
        assert ToolPolicy.load(state_dir).effective("acme-tracker", "update_task", False) == "ask"
    finally:
        await conn.close()


def test_tool_policy_effective_defaults(state_dir: StateDir) -> None:
    policy = ToolPolicy.load(state_dir)
    assert policy.effective("s", "read", True) == "allow"
    assert policy.effective("s", "write", False) == "ask"
    policy.set("s", "read", "ask")
    assert ToolPolicy.load(state_dir).effective("s", "read", True) == "ask"
    policy.set("s", "read", None)
    assert ToolPolicy.load(state_dir).effective("s", "read", True) == "allow"


async def test_slash_mcp_from_an_older_app(server: GatewayServer, factory: EngineFactory, folder: Path) -> None:
    conn = await attach(server)
    try:
        number = await new_chat(conn, folder)
        for text in ("/mcp", "/plugin"):
            await conn.send(dump(MessageSend(ts=TS, chat=number, id=f"m-{text}", text=text)))
            frames = await recv_until(conn, TurnFinished)
            notices = [m.text for m in frames if isinstance(m, ChatNotice)]
            assert notices == ["Open Settings to manage MCP servers and plugins."]
        assert all(c[0] != "send" for e in factory.engines for c in e.calls)
    finally:
        await conn.close()


# --- fix round 1 ------------------------------------------------------------------


async def test_plugin_and_unknown_servers_are_left_out(server: GatewayServer, folder: Path) -> None:
    """R-c4: only claude.ai connectors make the account group; plugin servers are not listed, nor managed."""
    seed(folder)
    conn = await attach(server)
    try:
        await live_engine(server, conn, folder, STATUS)
        reply = await ask(conn, McpList(ts=TS, id="l-1"))
        assert isinstance(reply, McpServers)
        names = [r.name for r in reply.servers]
        assert "plugin:acme:notes" not in names and "stray" not in names
        assert [r.name for r in reply.servers if r.group == "account"] == ["claude.ai Acme Drive"]
        for i, frame in enumerate(
            (
                McpToggle(ts=TS, id="x-1", name="plugin:acme:notes", enabled=False),
                McpSignIn(ts=TS, id="x-2", name="plugin:acme:notes"),
                McpToolPolicy(ts=TS, id="x-3", server="plugin:acme:notes", tool="n_0", policy="allow"),
            )
        ):
            got = await ask(conn, frame)
            assert isinstance(got, Error) and got.message == "There's no server called plugin:acme:notes", got
        assert "plugin:acme:notes" not in json.dumps(read_claude_json())
    finally:
        await conn.close()


async def test_account_rows_show_off(server: GatewayServer, folder: Path) -> None:
    seed(folder, disabled=["claude.ai Acme Drive"])
    conn = await attach(server)
    try:
        await live_engine(server, conn, folder, STATUS)
        reply = await ask(conn, McpList(ts=TS, id="l-1"))
        assert isinstance(reply, McpServers)
        drive = row(reply, "claude.ai Acme Drive")
        assert (drive.status, drive.detail, drive.can_toggle) == ("off", "Off", True)
        reply = await ask(conn, McpToggle(ts=TS, id="t-1", name="claude.ai Acme Drive", enabled=True))
        assert isinstance(reply, McpServers) and row(reply, "claude.ai Acme Drive").status == "connected"
    finally:
        await conn.close()


async def test_remove_drops_the_servers_policies(server: GatewayServer, folder: Path, state_dir: StateDir) -> None:
    seed(folder)
    conn = await attach(server)
    try:
        await live_engine(server, conn, folder, STATUS)
        await ask(conn, McpToolPolicy(ts=TS, id="p-1", server="acme-tracker", tool="update_task", policy="allow"))
        await ask(conn, McpToolPolicy(ts=TS, id="p-2", server="docs", tool="find", policy="allow"))
        reply = await ask(conn, McpRemove(ts=TS, id="r-1", name="acme-tracker"))
        assert isinstance(reply, McpServers)
        assert json.loads((state_dir.path / "mcp_tools.json").read_text()) == {"mcp__docs__find": "allow"}
    finally:
        await conn.close()


async def test_a_failed_remove_keeps_the_policies(server: GatewayServer, folder: Path, cli: ScriptedCli, state_dir: StateDir) -> None:
    seed(folder)
    cli.results[("mcp", "remove")] = CliResult(1, "", "Server not found")
    conn = await attach(server)
    try:
        await live_engine(server, conn, folder, STATUS)
        await ask(conn, McpToolPolicy(ts=TS, id="p-1", server="acme-tracker", tool="update_task", policy="allow"))
        assert isinstance(await ask(conn, McpRemove(ts=TS, id="r-1", name="acme-tracker")), Error)
        assert json.loads((state_dir.path / "mcp_tools.json").read_text()) == {"mcp__acme-tracker__update_task": "allow"}
    finally:
        await conn.close()


async def test_tool_policy_refuses_built_in_servers(server: GatewayServer, folder: Path) -> None:
    seed(folder)
    conn = await attach(server)
    try:
        for name in ("portico", "team-knowledge"):
            got = await ask(conn, McpToolPolicy(ts=TS, id=f"p-{name}", server=name, tool="t", policy="allow"))
            assert isinstance(got, Error) and got.message == "Built-in servers' tools can't be changed"
    finally:
        await conn.close()


@pytest.mark.parametrize(
    ("server_name", "tool", "full"),
    [
        ("claude.ai Acme", "search", "mcp__claude_ai_Acme__search"),
        ("claude.ai  Acme Drive!", "find", "mcp__claude_ai_Acme_Drive__find"),
        ("docs.v2 search", "find", "mcp__docs_v2_search__find"),
        ("acme__tracker", "update", "mcp__acme__tracker__update"),
    ],
)
def test_tool_names_follow_the_cli(state_dir: StateDir, server_name: str, tool: str, full: str) -> None:
    """R-c8: the key is the full tool name as the CLI builds it (server normalised, tool as given)."""
    policy = ToolPolicy.load(state_dir)
    assert ToolPolicy.key(server_name, tool) == full
    policy.set(server_name, tool, "allow")
    assert json.loads(policy.path.read_text()) == {full: "allow"}
    assert ToolPolicy.load(state_dir).allows(full)
    assert not policy.allows(full + "x") and not policy.allows(full.replace("mcp__", "mcp_", 1))


async def test_ask_permission_matches_the_full_name_exactly(server: GatewayServer, folder: Path) -> None:
    """A server with ``__`` and a claude.ai connector with a space: allowed by their exact names only."""
    write_claude_json({"mcpServers": {"acme__tracker": {"type": "http", "url": "https://mcp.acme.example/"}}})
    status = [
        {"name": "acme__tracker", "status": "connected", "config": {"type": "http", "url": "https://mcp.acme.example/"},
         "tools": [{"name": "update"}]},
        {"name": "claude.ai Acme", "status": "connected", "scope": "claudeai", "config": {"type": "claudeai-proxy", "url": "https://x", "id": "a"},
         "tools": [{"name": "search"}]},
    ]
    conn = await attach(server)
    try:
        await live_engine(server, conn, folder, status)
        for srv_name, tool in (("acme__tracker", "update"), ("claude.ai Acme", "search")):
            got = await ask(conn, McpToolPolicy(ts=TS, id=f"p-{tool}", server=srv_name, tool=tool, policy="allow"))
            assert isinstance(got, McpServers), got
        chat = next(c for c in server.registry.chats() if c.engine is not None)
        for i, name in enumerate(("mcp__acme__tracker__update", "mcp__claude_ai_Acme__search")):
            assert await asyncio.wait_for(server.ask_permission(chat, name, {}, [], f"toolu_{i}"), 2) == "allow"
        # Close but not the same: these ask (a card goes out; the test stops it).
        task = asyncio.create_task(server.ask_permission(chat, "mcp__acme__tracker_update", {}, [], "toolu_x"))
        card = (await recv_until(conn, CardAsk))[-1]
        assert isinstance(card, CardAsk)
        task.cancel()
    finally:
        await conn.close()


async def test_toggle_follows_a_symlinked_claude_json(server: GatewayServer, folder: Path, tmp_path: Path) -> None:
    real = tmp_path / "dotfiles" / "claude.json"
    real.parent.mkdir()
    real.write_text(json.dumps({"mcpServers": {"docs": {"command": "d"}}}), encoding="utf-8")
    os.chmod(real, 0o600)
    link = claude_json_path()
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(real)
    conn = await attach(server)
    try:
        reply = await ask(conn, McpToggle(ts=TS, id="t-1", name="docs", enabled=False))
        assert isinstance(reply, McpServers)
        assert link.is_symlink() and link.resolve() == real.resolve()
        assert json.loads(real.read_text())["projects"][str(folder)]["disabledMcpServers"] == ["docs"]
        assert stat.S_IMODE(real.stat().st_mode) == 0o600
    finally:
        await conn.close()


async def test_url_queries_never_reach_the_app(server: GatewayServer, folder: Path, cli: ScriptedCli) -> None:
    seed(folder)
    cli.results[("mcp", "remove")] = CliResult(1, "", "Callback failed at https://auth.acme.example/cb?code=s3cret&state=x for docs\n")
    conn = await attach(server)
    try:
        status = [dict(s) for s in STATUS]
        next(s for s in status if s["name"] == "docs")["error"] = "401 from https://mcp.acme.example/?token=abc"
        await live_engine(server, conn, folder, status)
        reply = await ask(conn, McpList(ts=TS, id="l-1"))
        assert isinstance(reply, McpServers)
        assert row(reply, "docs").detail == "Couldn't start: 401 from https://mcp.acme.example/"
        got = await ask(conn, McpRemove(ts=TS, id="r-1", name="docs"))
        assert isinstance(got, Error) and got.message == "Callback failed at https://auth.acme.example/cb for docs"
    finally:
        await conn.close()


def test_strip_url_queries_takes_out_userinfo_too() -> None:
    """R-c13: ``user:pass@`` in an http(s) address never reaches the app, nor a query string."""
    from portico_gateway.mcp_settings import strip_url_queries

    assert strip_url_queries("401 from https://sam:s3cret@mcp.acme.example/v1?token=abc") == "401 from https://mcp.acme.example/v1"
    assert strip_url_queries("see http://token@acme.example and https://acme.example/a@b") == (
        "see http://acme.example and https://acme.example/a@b"
    )
    assert strip_url_queries("mail sam@acme.example") == "mail sam@acme.example"


async def test_a_slow_remove_does_not_hold_other_frames(server: GatewayServer, folder: Path, cli: ScriptedCli) -> None:
    """R-c6: the CLI runs in a task; ``mcp.list`` sent after a blocked remove answers first."""
    seed(folder)
    gate = asyncio.Event()
    cli.gates[("mcp", "remove")] = gate
    conn = await attach(server)
    try:
        await conn.send(dump(McpRemove(ts=TS, id="r-1", name="docs")))
        await asyncio.wait_for(cli.reached.setdefault(("mcp", "remove"), asyncio.Event()).wait(), 5)
        await conn.send(dump(McpList(ts=TS, id="l-1")))
        first = await recv(conn)
        assert isinstance(first, McpServers) and first.id == "l-1"
        gate.set()
        second = await recv(conn)
        assert isinstance(second, McpServers) and second.id == "r-1"
    finally:
        await conn.close()
