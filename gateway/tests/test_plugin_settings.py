"""v0.18 §3: plugins managed from Settings (``plugins.v1``, plan rulings 16–19, controller ruling R-c9).

The app asks with ``plugins.list`` / ``plugins.set_enabled`` / ``plugins.install`` /
``plugins.uninstall`` / ``plugins.update`` / ``plugins.marketplace_add`` /
``plugins.marketplace_update`` (answered with ``plugins.state``),
``plugins.details`` and ``plugins.options`` / ``plugins.configure`` (answered
with ``plugins.details`` / ``plugins.options``), or ``error`` with the id.

Nothing here runs the real ``claude`` CLI: ``FixtureCli`` answers from the
hand-written files in ``tests/fixtures/plugins/`` (neutral names, written
from the plan's shapes, never copied from a real machine).
"""

from __future__ import annotations

import asyncio
import json
import os
from collections.abc import AsyncIterator
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import pytest

from portico_gateway import __version__
from portico_gateway.chats import ChatRegistry
from portico_gateway.config import McpConfig
from portico_gateway.mcp_inventory import CliResult, claude_json_path, invalidate_plugin_cache, plugin_paths_for_engine
from portico_gateway.mcp_settings import McpSettings, ToolPolicy
from portico_gateway.messages import (
    Error,
    McpServers,
    McpToggle,
    PluginsConfigure,
    PluginsDetails,
    PluginsDetailsRequest,
    PluginsInstall,
    PluginsList,
    PluginsOptions,
    PluginsOptionsRequest,
    PluginsSetEnabled,
    PluginsState,
    ProtocolError,
    dump,
)
from portico_gateway.plugin_settings import COMMAND_INSTALL, PluginSettings
from portico_gateway.server import GatewayServer
from portico_gateway.state import StateDir
from tests.conftest import make_config
from tests.test_server import attach, ws_url  # noqa: F401
from tests.test_turns import TS, EngineFactory, recv

FIXTURES = Path(__file__).parent / "fixtures" / "plugins"

# --- the fake CLI ---------------------------------------------------------------------


class FixtureCli:
    """A ``CliRunner`` that answers the plugin commands from ``tests/fixtures/plugins``.

    ``{folder}`` and ``{config}`` in a fixture become Settings' folder and the
    throwaway ``CLAUDE_CONFIG_DIR``. ``results`` overrides an answer by the
    args prefix; ``gates`` hold a command until the test sets them.
    """

    def __init__(self, folder: Path) -> None:
        self.folder = folder
        self.calls: list[tuple[list[str], Path, float, str | None]] = []
        self.results: dict[tuple[str, ...], CliResult] = {}
        self.gates: dict[tuple[str, ...], asyncio.Event] = {}
        self.reached: dict[tuple[str, ...], asyncio.Event] = {}

    def fixture(self, name: str) -> str:
        config = str(claude_json_path().parent)
        return (FIXTURES / name).read_text(encoding="utf-8").replace("{folder}", str(self.folder)).replace("{config}", config)

    def args_seen(self) -> list[list[str]]:
        return [args for args, _, _, _ in self.calls]

    def changes(self) -> list[list[str]]:
        """Every call except the reads (list, marketplace list, details, configure --json)."""
        reads = (["plugin", "list"], ["plugin", "marketplace", "list"], ["plugin", "details"])
        return [
            a for a in self.args_seen()
            if not any(a[: len(r)] == r for r in reads) and not (a[:2] == ["plugin", "configure"] and a[-1] == "--json")
        ]

    async def run(self, args: list[str], *, cwd: Path, timeout: float, stdin_text: str | None = None) -> CliResult:
        self.calls.append((list(args), Path(cwd), timeout, stdin_text))
        for n in range(len(args), 0, -1):
            key = tuple(args[:n])
            if key in self.gates or key in self.results:
                self.reached.setdefault(key, asyncio.Event()).set()
                if key in self.gates:
                    await self.gates[key].wait()
                if key in self.results:
                    return self.results[key]
                break
        if args == ["plugin", "list", "--json"]:
            return CliResult(0, self.fixture("list.json"), "")
        if args == ["plugin", "list", "--json", "--available"]:
            return CliResult(0, self.fixture("available.json"), "")
        if args == ["plugin", "marketplace", "list", "--json"]:
            return CliResult(0, self.fixture("marketplaces.json"), "")
        if args[:2] == ["plugin", "details"]:
            name = args[2].split("@")[0]
            path = FIXTURES / f"details-{name}.txt"
            return CliResult(0, path.read_text(encoding="utf-8"), "") if path.exists() else CliResult(1, "", f"Plugin {args[2]} not found")
        if args[:2] == ["plugin", "configure"] and args[-1] == "--json":
            name = args[2].split("@")[0]
            return CliResult(0, self.fixture(f"configure-{name}.json"), "")
        if args[:2] == ["plugin", "install"]:
            return CliResult(0, self.fixture("install-ok.json"), "")
        return CliResult(0, "", "")


def make_locations(now: datetime) -> None:
    """The marketplaces' checkouts: official checked today, acme today, jordan-local on Oct 24."""
    base = claude_json_path().parent / "plugins" / "marketplaces"
    stamps = {
        "claude-plugins-official": now - timedelta(hours=1),
        "acme": now - timedelta(minutes=5),
        "jordan-local": datetime(2026, 10, 24, 15, 0),
    }
    for name, when in stamps.items():
        path = base / name
        (path / ".claude-plugin").mkdir(parents=True, exist_ok=True)
        manifest = path / ".claude-plugin" / "marketplace.json"
        manifest.write_text("{}", encoding="utf-8")
        old = datetime(2026, 1, 1).timestamp()
        os.utime(manifest, (old, old))
        os.utime(path / ".claude-plugin", (old, old))
        os.utime(path, (when.timestamp(), when.timestamp()))


NOW = datetime(2026, 11, 3, 14, 0)


@pytest.fixture
def folder(tmp_path: Path) -> Path:
    path = (tmp_path / "agent").resolve()
    path.mkdir()
    return path


@pytest.fixture
def cli(folder: Path) -> FixtureCli:
    return FixtureCli(folder)


class Clock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def plugins(folder: Path, cli: FixtureCli, clock: Clock) -> PluginSettings:
    make_locations(NOW)
    return PluginSettings(folder=lambda: folder, cli=cli, lock=asyncio.Lock(), clock=clock, now=lambda: NOW)


def by_id(rows: list[Any], id: str) -> Any:
    return next(r for r in rows if r.id == id)


# --- the service ---------------------------------------------------------------------


async def test_list_installed_and_marketplaces(plugins: PluginSettings, cli: FixtureCli, folder: Path) -> None:
    state = await plugins.state(id="p-1")
    assert isinstance(state, PluginsState) and state.id == "p-1"
    # One row per id; the other project's local and project entries are not this folder's.
    assert [r.id for r in state.installed] == ["design-review@acme", "meeting-notes@claude-plugins-official", "release-helper@acme"]
    review = by_id(state.installed, "design-review@acme")
    assert (review.name, review.version, review.scope, review.enabled) == ("design-review", "1.4.0", "local", True)
    assert review.description == "Critiques a screen against your design system"
    assert review.marketplace == "acme"
    assert review.update_to == "1.5.0"
    assert by_id(state.installed, "release-helper@acme").update_to is None
    assert by_id(state.installed, "meeting-notes@claude-plugins-official").update_to is None
    assert state.available is None  # only a list that asks for it carries it
    marketplaces = {m.name: m for m in state.marketplaces}
    assert [m.name for m in state.marketplaces] == ["claude-plugins-official", "acme", "jordan-local"]
    assert marketplaces["claude-plugins-official"].source_label is None
    assert marketplaces["acme"].source_label == "github.com/acme/plugins"
    assert marketplaces["jordan-local"].source_label == "/Users/jordan/plugins"
    assert (marketplaces["claude-plugins-official"].plugin_count, marketplaces["acme"].plugin_count) == (2, 2)
    assert marketplaces["jordan-local"].plugin_count == 0
    assert (marketplaces["acme"].checked, marketplaces["jordan-local"].checked) == ("today", "Oct 24")
    # Every run is in Settings' folder.
    assert {cwd for _, cwd, _, _ in cli.calls} == {folder}


async def test_list_with_available(plugins: PluginSettings) -> None:
    state = await plugins.state(id="p-1", available=True)
    assert state.available is not None
    assert [a.id for a in state.available] == [
        "budget-watch@claude-plugins-official", "design-review@acme", "meeting-notes@claude-plugins-official", "release-helper@acme",
    ]
    budget = by_id(state.available, "budget-watch@claude-plugins-official")
    assert (budget.name, budget.description, budget.marketplace, budget.version, budget.installed) == (
        "budget-watch", "", "claude-plugins-official", None, False,
    )
    assert by_id(state.available, "design-review@acme").installed is True
    assert by_id(state.available, "design-review@acme").version == "1.5.0"


async def test_available_is_fetched_once_and_kept_five_minutes(plugins: PluginSettings, cli: FixtureCli, clock: Clock) -> None:
    def available_runs() -> int:
        return sum(1 for a in cli.args_seen() if a == ["plugin", "list", "--json", "--available"])

    await plugins.state(available=True)
    await plugins.state()
    await plugins.state(available=True)
    assert available_runs() == 1
    clock.t += 299
    await plugins.state()
    assert available_runs() == 1
    clock.t += 2
    await plugins.state()
    assert available_runs() == 2


async def test_checked_words(folder: Path, cli: FixtureCli) -> None:
    make_locations(NOW)
    base = claude_json_path().parent / "plugins" / "marketplaces" / "acme"
    yesterday = (NOW - timedelta(days=1)).replace(hour=9)
    os.utime(base, (yesterday.timestamp(), yesterday.timestamp()))
    service = PluginSettings(folder=lambda: folder, cli=cli, lock=asyncio.Lock(), now=lambda: NOW)
    state = await service.state()
    assert {m.name: m.checked for m in state.marketplaces}["acme"] == "yesterday"
    # A newer file inside counts: the newest mtime wins.
    fresh = base / ".claude-plugin" / "marketplace.json"
    os.utime(fresh, (NOW.timestamp() - 60, NOW.timestamp() - 60))
    state = await service.state()
    assert {m.name: m.checked for m in state.marketplaces}["acme"] == "today"


async def test_enable_uses_the_entry_scope(plugins: PluginSettings, cli: FixtureCli) -> None:
    state = await plugins.set_enabled("design-review@acme", False, id="e-1")
    assert isinstance(state, PluginsState) and state.id == "e-1"
    assert cli.changes() == [["plugin", "disable", "design-review@acme", "--scope", "local"]]
    await plugins.set_enabled("release-helper@acme", True)
    assert cli.changes()[-1] == ["plugin", "enable", "release-helper@acme", "--scope", "user"]


async def test_install_and_command_install_refused(plugins: PluginSettings, cli: FixtureCli) -> None:
    state = await plugins.install("meeting-notes@claude-plugins-official", id="i-1")
    assert isinstance(state, PluginsState) and state.id == "i-1"
    assert cli.changes() == [["plugin", "install", "meeting-notes@claude-plugins-official", "--json"]]

    cli.calls.clear()
    cli.results[("plugin", "install")] = CliResult(1, cli.fixture("install-command.json"), "")
    with pytest.raises(ProtocolError) as e:
        await plugins.install("meeting-notes@claude-plugins-official")
    assert e.value.message == "This plugin runs a command to install. Install it in Claude Code, where you can read the command first."
    assert e.value.message == COMMAND_INSTALL
    assert cli.changes() == [["plugin", "install", "meeting-notes@claude-plugins-official", "--json"]]  # no second run
    assert not any("--accept-command" in a or "-y" in a or "--yes" in a for a in cli.args_seen())


async def test_command_shown_on_exit_zero_is_refused_too(plugins: PluginSettings, cli: FixtureCli) -> None:
    cli.results[("plugin", "install")] = CliResult(0, cli.fixture("install-command.json"), "")
    with pytest.raises(ProtocolError) as e:
        await plugins.install("meeting-notes@claude-plugins-official")
    assert e.value.message == COMMAND_INSTALL


async def test_uninstall_and_update_args(plugins: PluginSettings, cli: FixtureCli) -> None:
    await plugins.uninstall("design-review@acme", id="u-1")
    assert cli.changes() == [["plugin", "uninstall", "design-review@acme", "--scope", "local"]]
    cli.calls.clear()
    await plugins.update("design-review@acme", id="u-2")
    assert cli.changes() == [["plugin", "update", "design-review@acme", "--scope", "local", "--json"]]
    cli.calls.clear()
    cli.results[("plugin", "update")] = CliResult(1, cli.fixture("install-command.json"), "")
    with pytest.raises(ProtocolError) as e:
        await plugins.update("design-review@acme")
    assert e.value.message == COMMAND_INSTALL


async def test_marketplace_add_and_update(plugins: PluginSettings, cli: FixtureCli) -> None:
    await plugins.marketplace_add("  acme/plugins  ", id="m-1")
    await plugins.marketplace_update("acme", id="m-2")
    assert cli.changes() == [["plugin", "marketplace", "add", "acme/plugins"], ["plugin", "marketplace", "update", "acme"]]
    with pytest.raises(ProtocolError):
        await plugins.marketplace_add("   ")
    with pytest.raises(ProtocolError):
        await plugins.marketplace_add("--force")
    with pytest.raises(ProtocolError):
        await plugins.marketplace_update("nowhere")


async def test_a_marketplace_change_fetches_available_again(plugins: PluginSettings, cli: FixtureCli) -> None:
    await plugins.state(available=True)
    await plugins.marketplace_update("acme")
    assert sum(1 for a in cli.args_seen() if a == ["plugin", "list", "--json", "--available"]) == 2


async def test_unknown_and_bad_ids_are_refused_without_a_run(plugins: PluginSettings, cli: FixtureCli) -> None:
    for call in (
        plugins.set_enabled("nothing@acme", True),
        plugins.uninstall("nothing@acme"),
        plugins.update("nothing@acme"),
        plugins.details("nothing@acme"),
        plugins.options("nothing@acme"),
    ):
        with pytest.raises(ProtocolError) as e:
            await call
        assert e.value.code == "plugins.unknown"
    for bad in ("--scope", "no-marketplace", "two words@acme", ""):
        with pytest.raises(ProtocolError) as e:
            await plugins.install(bad)
        assert e.value.code == "plugins.invalid"
    assert cli.changes() == []


async def test_cli_failure_is_its_last_stderr_line(plugins: PluginSettings, cli: FixtureCli) -> None:
    long = "x" * 300
    cli.results[("plugin", "enable")] = CliResult(1, "", f"warming up\nFailed: see https://acme.example/p?token=secret {long}\n\n")
    with pytest.raises(ProtocolError) as e:
        await plugins.set_enabled("release-helper@acme", True)
    assert e.value.code == "plugins.failed"
    assert e.value.message.startswith("Failed: see https://acme.example/p ")
    assert "secret" not in e.value.message and len(e.value.message) == 240


async def test_details_text(plugins: PluginSettings) -> None:
    reply = await plugins.details("design-review@acme", id="d-1")
    assert isinstance(reply, PluginsDetails)
    assert (reply.id, reply.plugin) == ("d-1", "design-review@acme")
    assert reply.text.startswith("design-review@acme 1.4.0") and "Projected token cost" in reply.text


async def test_configure_hides_sensitive_values(plugins: PluginSettings, cli: FixtureCli) -> None:
    reply = await plugins.options("design-review@acme", id="o-1")
    assert isinstance(reply, PluginsOptions) and reply.id == "o-1" and reply.plugin == "design-review@acme"
    options = {o.key: o for o in reply.options}
    assert list(options) == ["region", "api_key", "strict"]
    key = options["api_key"]
    assert (key.title, key.description, key.sensitive, key.set, key.value) == ("API key", "Your Acme key", True, True, None)
    region = options["region"]
    assert (region.title, region.sensitive, region.set, region.value) == ("Region", False, True, "us")
    strict = options["strict"]
    assert (strict.title, strict.set, strict.value) == ("strict", False, "false")
    assert "acme-key-that-must-never-leave" not in dump(reply)
    assert (await plugins.options("release-helper@acme")).options == []

    cli.calls.clear()
    reply = await plugins.configure("design-review@acme", {"region": "eu"}, id="c-1")
    assert isinstance(reply, PluginsOptions) and reply.id == "c-1"
    (args, _, _, stdin_text), = [c for c in cli.calls if c[0][-1] == "--values-stdin"]
    assert args == ["plugin", "configure", "design-review@acme", "--values-stdin"]
    assert stdin_text == '{"region": "eu"}'


async def test_configure_refuses_a_value_on_two_lines(plugins: PluginSettings, cli: FixtureCli) -> None:
    with pytest.raises(ProtocolError) as e:
        await plugins.configure("design-review@acme", {"region": "eu\nus"})
    assert e.value.code == "plugins.invalid"
    with pytest.raises(ProtocolError):
        await plugins.configure("design-review@acme", {})
    assert cli.changes() == []


async def test_changes_invalidate_the_engine_plugin_cache(plugins: PluginSettings, cli: FixtureCli, folder: Path) -> None:
    invalidate_plugin_cache()
    await plugin_paths_for_engine(cli, folder, ["project"])
    await plugin_paths_for_engine(cli, folder, ["project"])

    def list_runs() -> int:
        return sum(1 for a in cli.args_seen() if a == ["plugin", "list", "--json"])

    assert list_runs() == 1  # cached
    await plugins.set_enabled("design-review@acme", False)
    before = list_runs()
    await plugin_paths_for_engine(cli, folder, ["project"])
    assert list_runs() == before + 1


# --- R-c9: one lock for every writer of Claude Code's config ---------------------------


async def test_config_writers_share_one_lock(folder: Path, cli: FixtureCli, state_dir: StateDir) -> None:
    """A toggle requested while a blocked ``mcp remove`` holds the lock ends after it; a plugin install waits too."""
    lock = asyncio.Lock()
    claude_json_path().write_text(json.dumps({"mcpServers": {"docs": {"command": "docs-mcp"}, "acme-tracker": {"type": "http", "url": "https://mcp.acme.example/"}}}))
    pushes: list[Any] = []

    async def push(frame: Any) -> None:
        pushes.append(frame)

    mcp = McpSettings(
        folder=lambda: folder, core=lambda: [], cli=cli, engines=lambda: [], policy=ToolPolicy.load(state_dir),
        push=push, spawn=lambda coro, name: asyncio.ensure_future(coro), config_lock=lock,
    )
    plugins = PluginSettings(folder=lambda: folder, cli=cli, lock=lock, now=lambda: NOW)
    gate = asyncio.Event()
    cli.gates[("mcp", "remove")] = gate
    order: list[str] = []

    async def remove() -> None:
        await mcp.remove("docs")
        order.append("remove")

    async def toggle() -> None:
        await mcp.toggle("acme-tracker", False)
        order.append("toggle")

    async def install() -> None:
        await plugins.install("meeting-notes@claude-plugins-official")
        order.append("install")

    removing = asyncio.create_task(remove())
    await asyncio.wait_for(cli.reached.setdefault(("mcp", "remove"), asyncio.Event()).wait(), 5)
    toggling = asyncio.create_task(toggle())
    installing = asyncio.create_task(install())
    await asyncio.sleep(0.05)
    assert not toggling.done() and not installing.done()
    assert ["plugin", "install", "meeting-notes@claude-plugins-official", "--json"] not in cli.args_seen()
    assert "disabledMcpServers" not in claude_json_path().read_text()
    gate.set()
    await asyncio.wait_for(asyncio.gather(removing, toggling, installing), 5)
    assert order[0] == "remove" and set(order) == {"remove", "toggle", "install"}


async def test_reads_and_sign_in_do_not_take_the_lock(folder: Path, cli: FixtureCli, state_dir: StateDir) -> None:
    lock = asyncio.Lock()
    plugins = PluginSettings(folder=lambda: folder, cli=cli, lock=lock, now=lambda: NOW)
    claude_json_path().write_text(json.dumps({"mcpServers": {"acme-tracker": {"type": "http", "url": "https://mcp.acme.example/"}}}))
    tasks: list[asyncio.Task[Any]] = []

    async def push(frame: Any) -> None:
        pass

    mcp = McpSettings(
        folder=lambda: folder, core=lambda: [], cli=cli, engines=lambda: [], policy=ToolPolicy.load(state_dir),
        push=push, spawn=lambda coro, name: tasks.append(asyncio.ensure_future(coro)), config_lock=lock,
    )
    async with lock:
        await asyncio.wait_for(plugins.state(available=True), 5)
        await asyncio.wait_for(plugins.details("design-review@acme"), 5)
        await asyncio.wait_for(plugins.options("design-review@acme"), 5)
        await asyncio.wait_for(mcp.sign_in("acme-tracker"), 5)
        await asyncio.wait_for(asyncio.gather(*tasks), 5)
    assert ["mcp", "login", "acme-tracker"] in cli.args_seen()


# --- the wire ------------------------------------------------------------------------


@pytest.fixture
async def server(state_dir: StateDir, folder: Path, cli: FixtureCli) -> AsyncIterator[GatewayServer]:
    make_locations(datetime.now())
    cfg = make_config(setting_sources=["project"], default_folder=str(folder), mcp=McpConfig(core=[]))
    registry = ChatRegistry(index=state_dir.load_index(), state=state_dir, history_buffer=cfg.history_buffer)
    srv = GatewayServer(
        config=cfg, state=state_dir, registry=registry, engine_factory=EngineFactory(), version=__version__, cli=cli
    )
    await srv.serve(0)
    try:
        yield srv
    finally:
        await srv.shutdown()


async def ask(conn: Any, msg: Any) -> Any:
    await conn.send(dump(msg))
    while True:
        got = await recv(conn)
        if isinstance(got, (PluginsState, PluginsDetails, PluginsOptions, McpServers, Error)) and got.id == msg.id:
            return got


async def test_hello_advertises_plugins_v1(server: GatewayServer) -> None:
    from portico_gateway.config import hello_for

    assert "plugins.v1" in hello_for(server.config, server.epoch, server.version).capabilities


async def test_requests_over_the_wire(server: GatewayServer, cli: FixtureCli) -> None:
    conn = await attach(server)
    try:
        state = await ask(conn, PluginsList(ts=TS, id="w-1", available=True))
        assert isinstance(state, PluginsState) and state.available is not None and len(state.installed) == 3
        state = await ask(conn, PluginsSetEnabled(ts=TS, id="w-2", plugin="design-review@acme", enabled=False))
        assert isinstance(state, PluginsState) and state.available is None
        details = await ask(conn, PluginsDetailsRequest(ts=TS, id="w-3", plugin="design-review@acme"))
        assert isinstance(details, PluginsDetails) and "Skills (2)" in details.text
        options = await ask(conn, PluginsOptionsRequest(ts=TS, id="w-4", plugin="design-review@acme"))
        assert isinstance(options, PluginsOptions) and len(options.options) == 3
        options = await ask(conn, PluginsConfigure(ts=TS, id="w-5", plugin="design-review@acme", values={"region": "eu"}))
        assert isinstance(options, PluginsOptions)
        cli.results[("plugin", "install")] = CliResult(1, cli.fixture("install-command.json"), "")
        err = await ask(conn, PluginsInstall(ts=TS, id="w-6", plugin="meeting-notes@claude-plugins-official"))
        assert isinstance(err, Error) and err.message == COMMAND_INSTALL and err.id == "w-6"
    finally:
        await conn.close()


async def test_a_slow_install_does_not_hold_other_frames(server: GatewayServer, cli: FixtureCli) -> None:
    gate = asyncio.Event()
    cli.gates[("plugin", "install")] = gate
    conn = await attach(server)
    try:
        await conn.send(dump(PluginsInstall(ts=TS, id="s-1", plugin="meeting-notes@claude-plugins-official")))
        await asyncio.wait_for(cli.reached.setdefault(("plugin", "install"), asyncio.Event()).wait(), 5)
        first = await ask(conn, PluginsList(ts=TS, id="s-2"))
        assert isinstance(first, PluginsState)
        gate.set()
        second = await asyncio.wait_for(recv(conn), 5)
        assert isinstance(second, PluginsState) and second.id == "s-1"
    finally:
        await conn.close()


async def test_a_toggle_waits_for_a_slow_plugin_install_without_holding_frames(server: GatewayServer, cli: FixtureCli, folder: Path) -> None:
    """R-c9 at the server: the toggle queues behind the install; ``plugins.list`` (a read) answers meanwhile."""
    claude_json_path().write_text(json.dumps({"mcpServers": {"acme-tracker": {"type": "http", "url": "https://mcp.acme.example/"}}}))
    gate = asyncio.Event()
    cli.gates[("plugin", "install")] = gate
    conn = await attach(server)
    try:
        await conn.send(dump(PluginsInstall(ts=TS, id="q-1", plugin="meeting-notes@claude-plugins-official")))
        await asyncio.wait_for(cli.reached.setdefault(("plugin", "install"), asyncio.Event()).wait(), 5)
        await conn.send(dump(McpToggle(ts=TS, id="q-2", name="acme-tracker", enabled=False)))
        read = await ask(conn, PluginsList(ts=TS, id="q-3"))
        assert isinstance(read, PluginsState)
        assert "disabledMcpServers" not in claude_json_path().read_text()
        gate.set()
        got = {}
        while len(got) < 2:
            frame = await asyncio.wait_for(recv(conn), 5)
            if getattr(frame, "id", None) in ("q-1", "q-2"):
                got[frame.id] = frame
        assert isinstance(got["q-1"], PluginsState) and isinstance(got["q-2"], McpServers)
    finally:
        await conn.close()


def test_fixtures_name_no_real_plugins() -> None:
    """The fixtures are hand-written: neutral names only."""
    text = " ".join(p.read_text(encoding="utf-8") for p in FIXTURES.iterdir())
    for word in ("superpowers", "telegram", "figma"):
        assert word not in text.lower()
