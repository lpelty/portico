"""v0.18 §3.2: the person's MCP servers and plugins, read for each engine (rulings 1–3).

Every test builds a throwaway ``CLAUDE_CONFIG_DIR`` under ``tmp_path`` and
passes it as ``env``; nothing here reads the machine's own config, and no
test runs the real ``claude`` CLI (the runner is a fake).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from portico_gateway import mcp_inventory
from portico_gateway.mcp_inventory import (
    CliResult,
    claude_json_path,
    invalidate_plugin_cache,
    plugin_paths_for_engine,
    read_servers,
    servers_for_engine,
)

TRACKER = {"type": "http", "url": "https://mcp.acme.example/"}
SALES = {"type": "stdio", "command": "acme-sales", "args": ["--serve"]}
OTHER = {"type": "stdio", "command": "other"}
CRM = {"type": "http", "url": "https://crm.acme.example/mcp"}
KNOWLEDGE = {"type": "stdio", "command": "team-knowledge"}


def setup(
    tmp_path: Path,
    *,
    user: dict[str, Any] | None = None,
    local: dict[str, Any] | None = None,
    disabled: list[str] | None = None,
    shipped: dict[str, Any] | None = None,
) -> tuple[Path, dict[str, str]]:
    """An agent folder with ``.mcp.json`` and a config dir whose ``.claude.json`` knows it."""
    folder = tmp_path / "agent"
    folder.mkdir(exist_ok=True)
    other = tmp_path / "elsewhere"
    other.mkdir(exist_ok=True)
    cfg = tmp_path / "cfg"
    cfg.mkdir(exist_ok=True)
    project: dict[str, Any] = {"mcpServers": local if local is not None else {"sales-data": SALES}}
    if disabled is not None:
        project["disabledMcpServers"] = disabled
    data = {
        "mcpServers": user if user is not None else {"acme-tracker": TRACKER},
        "projects": {str(folder): project, str(other): {"mcpServers": {"other": OTHER}}},
    }
    (cfg / ".claude.json").write_text(json.dumps(data), encoding="utf-8")
    (folder / ".mcp.json").write_text(
        json.dumps({"mcpServers": shipped if shipped is not None else {"acme-crm": CRM, "team-knowledge": KNOWLEDGE}}),
        encoding="utf-8",
    )
    return folder, {"CLAUDE_CONFIG_DIR": str(cfg)}


def test_claude_json_path_follows_config_dir() -> None:
    assert claude_json_path({"CLAUDE_CONFIG_DIR": "/x"}) == Path("/x/.claude.json")
    assert claude_json_path({}) == Path.home() / ".claude.json"


def test_read_servers_groups(tmp_path: Path) -> None:
    folder, env = setup(tmp_path, disabled=["acme-crm"])
    entries = read_servers(folder, ["team-knowledge"], env)
    scopes = {e.name: e.scope for e in entries}
    assert scopes == {
        "portico": "core",
        "team-knowledge": "core",
        "acme-crm": "shipped",
        "sales-data": "local",
        "acme-tracker": "user",
    }
    assert [e.name for e in entries][:2] == ["portico", "team-knowledge"]
    assert "other" not in scopes
    disabled = {e.name for e in entries if e.disabled}
    assert disabled == {"acme-crm"}
    by_name = {e.name: e for e in entries}
    assert by_name["sales-data"].config == SALES
    assert by_name["acme-tracker"].config == TRACKER


def test_servers_for_engine(tmp_path: Path) -> None:
    folder, env = setup(tmp_path)
    core = ["team-knowledge"]
    assert set(servers_for_engine(folder, ["project"], core, env)) == {"acme-tracker", "sales-data"}
    assert servers_for_engine(folder, ["project"], core, env)["acme-tracker"] == TRACKER
    assert set(servers_for_engine(folder, ["project", "user"], core, env)) == {"sales-data"}
    assert set(servers_for_engine(folder, ["project", "local"], core, env)) == {"acme-tracker"}

    folder, env = setup(tmp_path, disabled=["sales-data"])
    assert set(servers_for_engine(folder, ["project"], core, env)) == {"acme-tracker"}


def test_name_clash_shipped_wins(tmp_path: Path) -> None:
    folder, env = setup(tmp_path, user={"acme-crm": TRACKER, "portico": TRACKER}, local={})
    assert servers_for_engine(folder, ["project"], [], env) == {}
    entries = read_servers(folder, [], env)
    crm = [e for e in entries if e.name == "acme-crm"]
    assert len(crm) == 1 and crm[0].scope == "shipped" and crm[0].config == CRM
    assert [e.scope for e in entries if e.name == "portico"] == ["core"]


def test_local_beats_user_same_name(tmp_path: Path) -> None:
    local_docs = {"type": "stdio", "command": "docs-local"}
    folder, env = setup(tmp_path, user={"docs": {"type": "stdio", "command": "docs-user"}}, local={"docs": local_docs})
    assert servers_for_engine(folder, ["project"], [], env) == {"docs": local_docs}
    assert [(e.name, e.scope) for e in read_servers(folder, [], env) if e.name == "docs"] == [("docs", "local")]


def test_unreadable_claude_json_is_empty_and_untouched(tmp_path: Path) -> None:
    folder, env = setup(tmp_path)
    path = Path(env["CLAUDE_CONFIG_DIR"]) / ".claude.json"
    garbage = b"\xff\xfe{not json"
    path.write_bytes(garbage)
    entries = read_servers(folder, ["team-knowledge"], env)
    assert {e.scope for e in entries} == {"core", "shipped"}
    assert servers_for_engine(folder, ["project"], [], env) == {}
    assert path.read_bytes() == garbage


def test_unreadable_claude_json_logs_once_per_mtime(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    import os

    folder, env = setup(tmp_path)
    path = Path(env["CLAUDE_CONFIG_DIR"]) / ".claude.json"
    path.write_bytes(b"{not json")
    caplog.set_level("WARNING", logger=mcp_inventory.__name__)

    def lines() -> int:
        return sum("does not parse" in r.getMessage() for r in caplog.records)

    read_servers(folder, [], env)
    servers_for_engine(folder, ["project"], [], env)
    assert lines() == 1
    st = path.stat()
    os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000_000))
    read_servers(folder, [], env)
    assert lines() == 2
    assert all("{not json" not in r.getMessage() for r in caplog.records)


async def test_plugin_cache_keys_on_the_resolved_folder(tmp_path: Path) -> None:
    folder = tmp_path / "agent"
    folder.mkdir()
    link = tmp_path / "link"
    link.symlink_to(folder)
    runner = ListRunner(stdout=plugin_list(folder, tmp_path / "elsewhere"))
    await plugin_paths_for_engine(runner, folder, ["project"])
    await plugin_paths_for_engine(runner, link, ["project"])
    assert len(runner.calls) == 1


def test_missing_files_are_empty(tmp_path: Path) -> None:
    folder = tmp_path / "bare"
    folder.mkdir()
    env = {"CLAUDE_CONFIG_DIR": str(tmp_path / "none")}
    assert [(e.name, e.scope) for e in read_servers(folder, [], env)] == [("portico", "core")]
    assert servers_for_engine(folder, ["project"], [], env) == {}


# --- plugins (ruling 3) ---------------------------------------------------------


class ListRunner:
    def __init__(self, code: int = 0, stdout: str = "[]", stderr: str = "") -> None:
        self.result = CliResult(code=code, stdout=stdout, stderr=stderr)
        self.calls: list[tuple[list[str], Path, float, str | None]] = []

    async def run(self, args: list[str], *, cwd: Path, timeout: float, stdin_text: str | None = None) -> CliResult:
        self.calls.append((list(args), cwd, timeout, stdin_text))
        return self.result


@pytest.fixture(autouse=True)
def _fresh_cache() -> None:
    invalidate_plugin_cache()
    mcp_inventory._logged_unusable.clear()


def plugin_list(folder: Path, elsewhere: Path) -> str:
    return json.dumps(
        [
            {"id": "a@m", "scope": "user", "enabled": True, "installPath": "/p/a"},
            {"id": "b@m", "scope": "user", "enabled": False, "installPath": "/p/b"},
            {"id": "c@m", "scope": "local", "enabled": True, "projectPath": str(folder), "installPath": "/p/c"},
            {"id": "d@m", "scope": "local", "enabled": True, "projectPath": str(elsewhere), "installPath": "/p/d"},
            {"id": "e@m", "scope": "project", "enabled": True, "projectPath": str(folder), "installPath": "/p/e"},
            {"id": "f@m", "scope": "synced", "enabled": True, "installPath": "/p/f"},
        ]
    )


async def test_plugin_paths_for_engine(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    folder = tmp_path / "agent"
    folder.mkdir()
    runner = ListRunner(stdout=plugin_list(folder, tmp_path / "elsewhere"))
    # Neither the project-scope entry (the "project" source loads it) nor the synced one is passed.
    assert await plugin_paths_for_engine(runner, folder, ["project"]) == ["/p/a", "/p/c"]
    assert runner.calls[0][0] == ["plugin", "list", "--json"]
    assert runner.calls[0][1] == folder
    assert await plugin_paths_for_engine(runner, folder, ["project", "user"]) == ["/p/c"]
    assert len(runner.calls) == 1  # the second and third reads came from the 30 s cache

    # Past 30 s the list runs again.
    real = mcp_inventory.time.monotonic
    monkeypatch.setattr(mcp_inventory.time, "monotonic", lambda: real() + 31)
    assert await plugin_paths_for_engine(runner, folder, ["project", "local"]) == ["/p/a"]
    assert len(runner.calls) == 2


async def test_plugin_list_failure_is_empty(tmp_path: Path) -> None:
    folder = tmp_path / "agent"
    folder.mkdir()
    assert await plugin_paths_for_engine(ListRunner(code=1, stderr="boom"), folder, ["project"]) == []
    invalidate_plugin_cache()
    assert await plugin_paths_for_engine(ListRunner(stdout="not json"), folder, ["project"]) == []


async def test_engine_start_plugin_list_waits_10_seconds(tmp_path: Path) -> None:
    """R-c34: a hung ``plugin list`` holds an engine start 10 s at most (Settings' own list keeps 60 s)."""
    folder = tmp_path / "agent"
    folder.mkdir()
    runner = ListRunner(stdout=plugin_list(folder, tmp_path / "elsewhere"))
    await plugin_paths_for_engine(runner, folder, ["project"])
    assert runner.calls[0][2] == 10.0


async def test_plugin_list_failure_log_is_stripped(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level("WARNING", logger=mcp_inventory.__name__)
    folder = tmp_path / "agent"
    folder.mkdir()
    mcp_inventory._plugin_failure_logged = False
    stderr = "x\nsee https://person:secret@market.example/p?key=abc\n"
    assert await plugin_paths_for_engine(ListRunner(code=1, stderr=stderr), folder, ["project"]) == []

    class Raising(ListRunner):
        async def run(self, args: list[str], *, cwd: Path, timeout: float, stdin_text: str | None = None) -> CliResult:
            raise OSError("no route to https://person:secret@market.example/p?key=abc")

    invalidate_plugin_cache()
    mcp_inventory._plugin_failure_logged = False
    assert await plugin_paths_for_engine(Raising(), folder, ["project"]) == []
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert "secret" not in text and "key=abc" not in text
    assert "exit 1: see https://market.example/p" in text
    assert "OSError: no route to https://market.example/p" in text


async def test_invalidate_plugin_cache_reruns(tmp_path: Path) -> None:
    folder = tmp_path / "agent"
    folder.mkdir()
    runner = ListRunner(stdout=plugin_list(folder, tmp_path / "elsewhere"))
    await plugin_paths_for_engine(runner, folder, ["project"])
    invalidate_plugin_cache()
    await plugin_paths_for_engine(runner, folder, ["project"])
    assert len(runner.calls) == 2


# --- the server's engine start ----------------------------------------------------


async def test_engine_start_brings_servers_and_plugins_in(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from portico_gateway import __version__
    from portico_gateway.chats import ChatRegistry
    from portico_gateway.server import GatewayServer
    from portico_gateway.state import StateDir
    from tests.conftest import FakeCli, FakeEngine, make_config

    folder, env = setup(tmp_path)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", env["CLAUDE_CONFIG_DIR"])
    cli = FakeCli(CliResult(code=0, stdout=plugin_list(folder, tmp_path / "elsewhere"), stderr=""))
    state = StateDir(tmp_path / "home")
    config = make_config(setting_sources=["project"])
    registry = ChatRegistry(index=state.load_index(), state=state, history_buffer=config.history_buffer)
    engines: list[FakeEngine] = []

    def factory() -> FakeEngine:
        engines.append(FakeEngine())
        return engines[-1]

    srv = GatewayServer(config=config, state=state, registry=registry, engine_factory=factory, version=__version__, cli=cli)
    chat = registry.create(folder)
    await srv._start_engine(chat)
    engine = engines[-1]
    assert engine.started_servers == {"acme-tracker": TRACKER, "sales-data": SALES}
    assert engine.started_plugins == ["/p/a", "/p/c"]
    assert engine.calls[0] == ("start", (folder, None, ["project"]))
    assert [c[0] for c in cli.calls] == [["plugin", "list", "--json"]]
    await engine.close()


def test_server_default_cli_is_faked_in_tests(tmp_path: Path) -> None:
    from portico_gateway import __version__
    from portico_gateway.chats import ChatRegistry
    from portico_gateway.server import GatewayServer
    from portico_gateway.state import StateDir
    from tests.conftest import FakeCli, FakeEngine, make_config

    state = StateDir(tmp_path / "home")
    config = make_config()
    registry = ChatRegistry(index=state.load_index(), state=state, history_buffer=config.history_buffer)
    srv = GatewayServer(config=config, state=state, registry=registry, engine_factory=FakeEngine, version=__version__)
    assert isinstance(srv.cli, FakeCli)
