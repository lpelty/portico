"""v0.18 §3: plugins managed from Settings (``plugins.v1``, plan rulings 16–19).

``PluginSettings`` answers the app's ``plugins.*`` requests by running the
bundled CLI (``CliRunner``) in Settings' folder:

- ``plugin list --json``: the installed plugins, one row per id. An entry
  scoped ``local`` or ``project`` to another folder is not this folder's
  and is left out; of several entries for one id the one that governs here
  wins (local, then project, then user, then the rest).
- ``plugin list --json --available``: what the marketplaces offer. Fetched
  once per list and kept 5 minutes (a marketplace change drops it): an
  installed row's ``description`` and ``marketplace`` come from it, joined
  by id, and so does its ``update_to``.
- ``plugin marketplace list --json``: the marketplaces, each with its plugin
  count (from the available list) and when its checkout last changed.
- ``plugin enable|disable|install|uninstall|update``, ``plugin marketplace
  add|update`` and ``plugin configure --values-stdin`` change things. Each
  holds the gateway-wide Claude Code config lock (R-c9) while it runs, and
  drops the engines' plugin cache (``invalidate_plugin_cache``) so the next
  engine start reads the list fresh. None touches a running engine (ruling 5).
- A plugin that installs by running a command (the ``--json`` result
  carries ``shownCommand``) is refused (ruling 18); Portico never passes
  ``--accept-command`` or ``--yes``.
- A sensitive option's value never leaves the gateway (ruling 19).
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from collections.abc import Callable, Iterable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .mcp_inventory import CliRunner, invalidate_plugin_cache
from .mcp_settings import CLI_TIMEOUT, _cli_message, _same_folder, strip_url_queries
from .messages import (
    AvailablePlugin,
    PluginMarketplace,
    PluginOption,
    PluginRow,
    PluginsDetails,
    PluginsOptions,
    PluginsState,
    ProtocolError,
)

log = logging.getLogger(__name__)

AVAILABLE_SECONDS = 300.0
OFFICIAL_MARKETPLACE = "claude-plugins-official"

# Ruling 18: exact copy.
COMMAND_INSTALL = (
    "This plugin runs a command to install. Install it in Claude Code, where you can read the command first."
)
# The CLI's failure codes for a command a person must read first (its result line's ``failureCode``).
_COMMAND_FAILURES = frozenset(
    {"command_source_refused", "command_source_declined", "entry_helper_unconfirmed", "entry_helper_declined"}
)

# Scopes the CLI's enable, disable and uninstall take (``--scope``).
_SCOPES = ("local", "project", "user")
# Which of several entries for one id governs this folder.
_PRECEDENCE = {"local": 0, "project": 1, "user": 2}

# A plugin id as the CLI prints it: ``name@marketplace``, no spaces, never a flag.
_PLUGIN_ID = re.compile(r"^[^\s@-][^\s@]*@[^\s@]+$")

NOT_THIS_SCOPE = "This plugin comes with your Claude account; change it in Claude Code"
BAD_ID = "That isn't a plugin id (name@marketplace)"
BAD_SOURCE = "Enter the marketplace's GitHub repo, web address or folder"
ONE_LINE = "Each value has to fit on one line"
NOTHING_CHANGED = "There's nothing to save"


def _parse_json(text: str, what: str) -> Any:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        raise ProtocolError("plugins.failed", f"Claude Code's {what} wasn't readable") from None


def _result_lines(stdout: str) -> list[dict[str, Any]]:
    """The ``--json`` result line(s) a plugin command prints; anything else on stdout is ignored."""
    out = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            out.append(obj)
    return out


def _runs_a_command(stdout: str) -> bool:
    return any(r.get("shownCommand") or r.get("failureCode") in _COMMAND_FAILURES for r in _result_lines(stdout))


def checked_word(when: datetime, now: datetime) -> str:
    """ "today", "yesterday", else the month and day ("Oct 24"), in local time."""
    days = (now.date() - when.date()).days
    if days <= 0:
        return "today"
    if days == 1:
        return "yesterday"
    return f"{when.strftime('%b')} {when.day}"


def _newest_mtime(path: Path) -> float | None:
    """The newest mtime of ``path`` and what is directly in it (and in its ``.claude-plugin``)."""
    try:
        newest = path.stat().st_mtime
    except OSError:
        return None
    for folder in (path, path / ".claude-plugin"):
        try:
            children = list(folder.iterdir())
        except OSError:
            continue
        for child in children:
            try:
                newest = max(newest, child.lstat().st_mtime)
            except OSError:
                continue
    return newest


def _source_label(entry: dict[str, Any]) -> str | None:
    """Its repo or path, as AR4 shows it; ``None`` for the official marketplace."""
    if entry.get("name") == OFFICIAL_MARKETPLACE:
        return None
    repo = entry.get("repo")
    if isinstance(repo, str) and repo:
        return f"github.com/{repo}"
    for key in ("url", "path"):
        value = entry.get(key)
        if isinstance(value, str) and value:
            return strip_url_queries(value)
    return None


def _str(value: Any) -> str:
    return value if isinstance(value, str) else ""


class PluginSettings:
    """The ``plugins.*`` requests. Every method returns its reply or raises ``ProtocolError``.

    ``folder`` gives Settings' folder (ruling 4); ``lock`` is the gateway-wide
    Claude Code config lock (R-c9); ``clock`` (monotonic seconds) times the
    available cache; ``now`` gives local time for "checked".
    """

    def __init__(
        self,
        *,
        folder: Callable[[], Path],
        cli: CliRunner,
        lock: asyncio.Lock,
        clock: Callable[[], float] = time.monotonic,
        now: Callable[[], datetime] = datetime.now,
    ) -> None:
        self._folder = folder
        self.cli = cli
        self._lock = lock
        self._clock = clock
        self._now = now
        # (folder, when read, entries)
        self._available: tuple[str, float, list[dict[str, Any]]] | None = None
        self._available_failure_logged = False

    def folder(self) -> Path:
        return self._folder()

    # --- reading --------------------------------------------------------------

    async def _read(self, args: list[str]) -> str:
        """A read-only run (no lock): its stdout, or ``plugins.failed``."""
        try:
            result = await self.cli.run(args, cwd=self.folder(), timeout=CLI_TIMEOUT)
        except Exception as e:
            raise ProtocolError("plugins.failed", f"Couldn't run Claude Code: {type(e).__name__}") from e
        if result.code != 0:
            raise ProtocolError("plugins.failed", _cli_message(result.stderr, args, result.code))
        return result.stdout

    async def _installed_entries(self) -> list[dict[str, Any]]:
        data = _parse_json(await self._read(["plugin", "list", "--json"]), "plugin list")
        if not isinstance(data, list):
            raise ProtocolError("plugins.failed", "Claude Code's plugin list wasn't readable")
        return [e for e in data if isinstance(e, dict)]

    async def _available_entries(self, *, required: bool) -> list[dict[str, Any]]:
        """The marketplaces' plugins, from the 5-minute cache or one ``--available`` run.

        A failed run is an error when ``required`` (Browse asked); otherwise it
        is ``[]`` (rows go without descriptions), logged once.
        """
        key = str(self.folder())
        now = self._clock()
        if self._available is not None:
            folder, when, entries = self._available
            if folder == key and now - when < AVAILABLE_SECONDS:
                return entries
        try:
            data = _parse_json(await self._read(["plugin", "list", "--json", "--available"]), "plugin catalogue")
            raw = data.get("available") if isinstance(data, dict) else None
            if not isinstance(raw, list):
                raise ProtocolError("plugins.failed", "Claude Code's plugin catalogue wasn't readable")
        except ProtocolError as e:
            if required:
                raise
            if not self._available_failure_logged:
                log.warning("could not list the marketplaces' plugins (%s)", e.message)
                self._available_failure_logged = True
            return []
        self._available_failure_logged = False
        entries = [e for e in raw if isinstance(e, dict) and isinstance(e.get("pluginId"), str)]
        self._available = (key, now, entries)
        return entries

    def _forget_available(self) -> None:
        self._available = None

    def _rows(self, entries: Iterable[dict[str, Any]], available: list[dict[str, Any]]) -> list[PluginRow]:
        here = self.folder()
        chosen: dict[str, dict[str, Any]] = {}
        for e in entries:
            pid = e.get("id")
            if not isinstance(pid, str) or not pid:
                continue
            scope = _str(e.get("scope"))
            if scope in ("local", "project") and not _same_folder(Path(_str(e.get("projectPath")) or "/nonexistent"), here):
                continue  # another folder's plugin
            current = chosen.get(pid)
            if current is None or _PRECEDENCE.get(scope, 9) < _PRECEDENCE.get(_str(current.get("scope")), 9):
                chosen[pid] = e
        by_id = {a["pluginId"]: a for a in available}
        rows = []
        for pid, e in chosen.items():
            offer = by_id.get(pid, {})
            version = _str(e.get("version"))
            newer = offer.get("version")
            rows.append(
                PluginRow(
                    id=pid,
                    name=_str(offer.get("name")) or pid.split("@", 1)[0],
                    version=version,
                    scope=_str(e.get("scope")),
                    enabled=e.get("enabled") is True,
                    description=_str(offer.get("description")),
                    marketplace=_str(offer.get("marketplaceName")) or pid.split("@", 1)[-1],
                    update_to=newer if isinstance(newer, str) and newer and newer != version else None,
                )
            )
        rows.sort(key=lambda r: (r.name.casefold(), r.id))
        return rows

    async def _marketplaces(self, available: list[dict[str, Any]]) -> list[PluginMarketplace]:
        data = _parse_json(await self._read(["plugin", "marketplace", "list", "--json"]), "marketplace list")
        if not isinstance(data, list):
            raise ProtocolError("plugins.failed", "Claude Code's marketplace list wasn't readable")
        counts: dict[str, int] = {}
        for a in available:
            name = _str(a.get("marketplaceName"))
            counts[name] = counts.get(name, 0) + 1
        now = self._now()
        out = []
        for m in data:
            if not isinstance(m, dict) or not isinstance(m.get("name"), str):
                continue
            location = _str(m.get("installLocation"))
            mtime = _newest_mtime(Path(location)) if location else None
            checked = checked_word(datetime.fromtimestamp(mtime), now) if mtime is not None else ""
            out.append(
                PluginMarketplace(
                    name=m["name"], source_label=_source_label(m), plugin_count=counts.get(m["name"], 0), checked=checked
                )
            )
        return out

    async def state(self, id: str | None = None, available: bool = False) -> PluginsState:
        offers = await self._available_entries(required=available)
        rows = self._rows(await self._installed_entries(), offers)
        marketplaces = await self._marketplaces(offers)
        browse = None
        if available:
            installed = {r.id for r in rows}
            browse = sorted(
                (
                    AvailablePlugin(
                        id=a["pluginId"],
                        name=_str(a.get("name")) or a["pluginId"].split("@", 1)[0],
                        description=_str(a.get("description")),
                        marketplace=_str(a.get("marketplaceName")) or a["pluginId"].split("@", 1)[-1],
                        version=a.get("version") if isinstance(a.get("version"), str) else None,
                        installed=a["pluginId"] in installed,
                    )
                    for a in offers
                ),
                key=lambda p: (p.name.casefold(), p.id),
            )
        return PluginsState(ts=_now(), id=id, installed=rows, available=browse, marketplaces=marketplaces)

    async def _row(self, plugin: str) -> PluginRow:
        """The installed row for ``plugin`` (``plugins.unknown`` when there is none here)."""
        _check_id(plugin)
        for row in self._rows(await self._installed_entries(), await self._available_entries(required=False)):
            if row.id == plugin:
                return row
        raise ProtocolError("plugins.unknown", f"There's no plugin {plugin} installed here")

    async def details(self, plugin: str, id: str | None = None) -> PluginsDetails:
        await self._row(plugin)
        text = await self._read(["plugin", "details", plugin])
        return PluginsDetails(ts=_now(), id=id, plugin=plugin, text=strip_url_queries(text.rstrip()))

    async def options(self, plugin: str, id: str | None = None) -> PluginsOptions:
        await self._row(plugin)
        return PluginsOptions(ts=_now(), id=id, plugin=plugin, options=await self._options(plugin))

    async def _options(self, plugin: str) -> list[PluginOption]:
        data = _parse_json(await self._read(["plugin", "configure", plugin, "--json"]), "plugin options")
        if not isinstance(data, dict):
            return []
        schema = data.get("schema") if isinstance(data.get("schema"), dict) else {}
        inputs = data.get("inputs") if isinstance(data.get("inputs"), dict) else {}
        configured = data.get("configured") if isinstance(data.get("configured"), list) else []
        out = []
        for key, spec in schema.items():
            spec = spec if isinstance(spec, dict) else {}
            sensitive = spec.get("sensitive") is True
            value = inputs.get(key)
            out.append(
                PluginOption(
                    key=str(key),
                    title=_str(spec.get("title")) or str(key),
                    description=_str(spec.get("description")),
                    sensitive=sensitive,
                    set=key in configured,
                    # Ruling 19: a sensitive value is never sent, whatever the CLI printed.
                    value=None if sensitive or not isinstance(value, str) else value,
                )
            )
        return out

    # --- changing -------------------------------------------------------------

    async def _change(self, args: list[str], *, stdin_text: str | None = None, command_check: bool = False) -> None:
        """A run that changes Claude Code's config: under the config lock (R-c9), then the engines' cache is dropped."""
        async with self._lock:
            try:
                result = await self.cli.run(args, cwd=self.folder(), timeout=CLI_TIMEOUT, stdin_text=stdin_text)
            except Exception as e:
                raise ProtocolError("plugins.failed", f"Couldn't run Claude Code: {type(e).__name__}") from e
            finally:
                invalidate_plugin_cache()
        if command_check and _runs_a_command(result.stdout):
            log.info("refused %s: the plugin runs a command to install", " ".join(args[:2]))
            raise ProtocolError("plugins.refused", COMMAND_INSTALL)
        if result.code != 0:
            raise ProtocolError("plugins.failed", _cli_message(result.stderr, args, result.code))
        # R-c13: a marketplace's source can be an address carrying a key; it is never logged.
        shown = args[:3] if args[1:3] == ["marketplace", "add"] else args[:4]
        log.info("claude %s: done", " ".join(shown))

    async def set_enabled(self, plugin: str, enabled: bool, id: str | None = None) -> PluginsState:
        row = await self._row(plugin)
        if row.scope not in _SCOPES:
            raise ProtocolError("plugins.refused", NOT_THIS_SCOPE)
        await self._change(["plugin", "enable" if enabled else "disable", plugin, "--scope", row.scope])
        return await self.state(id)

    async def install(self, plugin: str, id: str | None = None) -> PluginsState:
        _check_id(plugin)
        await self._change(["plugin", "install", plugin, "--json"], command_check=True)
        return await self.state(id)

    async def uninstall(self, plugin: str, id: str | None = None) -> PluginsState:
        row = await self._row(plugin)
        if row.scope not in _SCOPES:
            raise ProtocolError("plugins.refused", NOT_THIS_SCOPE)
        await self._change(["plugin", "uninstall", plugin, "--scope", row.scope])
        return await self.state(id)

    async def update(self, plugin: str, id: str | None = None) -> PluginsState:
        row = await self._row(plugin)
        scope = ["--scope", row.scope] if row.scope in _SCOPES else []
        await self._change(["plugin", "update", plugin, *scope, "--json"], command_check=True)
        return await self.state(id)

    async def marketplace_add(self, source: str, id: str | None = None) -> PluginsState:
        source = source.strip()
        if not source or source.startswith("-") or any(c.isspace() for c in source):
            raise ProtocolError("plugins.invalid", BAD_SOURCE)
        try:
            await self._change(["plugin", "marketplace", "add", source])
        finally:
            self._forget_available()
        return await self.state(id)

    async def marketplace_update(self, name: str, id: str | None = None) -> PluginsState:
        data = _parse_json(await self._read(["plugin", "marketplace", "list", "--json"]), "marketplace list")
        names = {m.get("name") for m in data if isinstance(m, dict)} if isinstance(data, list) else set()
        if name not in names:
            raise ProtocolError("plugins.unknown", f"There's no marketplace called {name}")
        try:
            await self._change(["plugin", "marketplace", "update", name])
        finally:
            self._forget_available()
        return await self.state(id)

    async def configure(self, plugin: str, values: dict[str, str], id: str | None = None) -> PluginsOptions:
        await self._row(plugin)
        if not values:
            raise ProtocolError("plugins.invalid", NOTHING_CHANGED)
        if any("\n" in v or "\r" in v for v in values.values()):
            raise ProtocolError("plugins.invalid", ONE_LINE)
        # The values go on stdin, never in args or the log (they can be keys).
        await self._change(["plugin", "configure", plugin, "--values-stdin"], stdin_text=json.dumps(values))
        return PluginsOptions(ts=_now(), id=id, plugin=plugin, options=await self._options(plugin))


def _check_id(plugin: str) -> None:
    if not _PLUGIN_ID.match(plugin or ""):
        raise ProtocolError("plugins.invalid", BAD_ID)


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
