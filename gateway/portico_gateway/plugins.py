"""Plug-ins: deployment code that replaces one of the gateway's default mechanics.

A plug-in is a Python module named in ``config.plugins`` and kept outside
the checkout (``config.plugin_paths`` puts its directory on ``sys.path``),
so updating Portico never touches it. Each module sets
``PORTICO_PLUGIN_API = 1`` and defines any of:

- ``on_hello(hello) -> hello`` — adjust the ``hello`` the app receives.
  Every plug-in's runs, in list order.
- ``async on_renew(ctx, chat) -> bool`` — the log step a renewal runs in
  the ending session, instead of sending ``config.log_prompt``. ``ctx`` is
  a ``RenewContext``; ``chat`` the session's ``ChatSummary``. Returns
  whether the session was logged.
- ``search(root, query) -> list[Hit]`` (sync or async) — ``files.search``
  instead of Spotlight. ``root`` is the root's directory; hit paths are
  relative to it.

For ``on_renew`` and ``search`` the last plug-in in the list that names
the hook is the one used. A module that is missing, raises on import, or
sets a different API number stops the gateway at start with one line
saying which and why; the doctor reports the same.
"""

from __future__ import annotations

import asyncio
import importlib
import inspect
import logging
import sys
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Any

from .messages import ChatSummary, HelloServer, Hit, Outcome

log = logging.getLogger(__name__)

PLUGIN_API = 1
API_ATTRIBUTE = "PORTICO_PLUGIN_API"

RenewHook = Callable[["RenewContext", ChatSummary], Awaitable[bool]]
SearchHook = Callable[[Path, str], Any]


class PluginError(Exception):
    """A configured plug-in cannot be used; the message names the module and why."""


@dataclass
class RenewContext:
    """What a plug-in's ``on_renew`` gets to run a log step in the ending session.

    ``send(text)`` sends ``text`` into the session as a message — a turn
    the app shows like any other, cards included — and returns the turn's
    outcome once it finishes: ``"done"``, ``"stopped"`` or ``"error"``.
    """

    chat: int
    folder: Path
    log_prompt: str | None
    send: Callable[[str], Awaitable[Outcome]]


def _add_paths(paths: list[str]) -> None:
    for raw in reversed(paths):
        if raw not in sys.path:
            sys.path.insert(0, raw)


def _import(name: str) -> ModuleType:
    """Import one plug-in module and check its API number; ``PluginError`` otherwise."""
    try:
        module = importlib.import_module(name)
    except ModuleNotFoundError as e:
        if e.name is not None and (name == e.name or name.startswith(e.name + ".")):
            raise PluginError(f"plug-in {name!r}: module not found (is its directory in plugin_paths?)") from None
        raise PluginError(f"plug-in {name!r}: import failed: {type(e).__name__}: {e}") from e
    except Exception as e:
        raise PluginError(f"plug-in {name!r}: import failed: {type(e).__name__}: {e}") from e
    if not hasattr(module, API_ATTRIBUTE):
        raise PluginError(f"plug-in {name!r}: {API_ATTRIBUTE} is not defined; this gateway needs {PLUGIN_API}")
    api = getattr(module, API_ATTRIBUTE)
    if api != PLUGIN_API:
        raise PluginError(f"plug-in {name!r}: {API_ATTRIBUTE} is {api!r}; this gateway speaks {PLUGIN_API}")
    renew = getattr(module, "on_renew", None)
    if renew is not None and not inspect.iscoroutinefunction(renew):
        raise PluginError(f"plug-in {name!r}: on_renew must be an async function (async def)")
    for hook in ("on_hello", "search"):
        value = getattr(module, hook, None)
        if value is not None and not callable(value):
            raise PluginError(f"plug-in {name!r}: {hook} is not callable")
    return module


def _hooks(module: ModuleType) -> list[str]:
    return [hook for hook in ("on_hello", "on_renew", "search") if getattr(module, hook, None) is not None]


class Plugins:
    """The loaded plug-ins and the hooks they provide."""

    def __init__(self, modules: list[ModuleType]) -> None:
        self.modules = list(modules)
        self.renew: RenewHook | None = None
        self.search: SearchHook | None = None
        for module in self.modules:
            self.renew = getattr(module, "on_renew", None) or self.renew
            self.search = getattr(module, "search", None) or self.search

    @classmethod
    def none(cls) -> Plugins:
        return cls([])

    @property
    def names(self) -> list[str]:
        return [m.__name__ for m in self.modules]

    def on_hello(self, hello: HelloServer) -> HelloServer:
        for module in self.modules:
            hook = getattr(module, "on_hello", None)
            if hook is None:
                continue
            changed = hook(hello)
            if not isinstance(changed, HelloServer):
                raise PluginError(f"plug-in {module.__name__!r}: on_hello must return the hello it was given (or a copy)")
            hello = changed
        return hello

    async def run_search(self, root: Path, query: str) -> list[Hit]:
        """The plug-in's ``search``, sync (in a thread) or async; results as ``Hit``s."""
        assert self.search is not None
        if inspect.iscoroutinefunction(self.search):
            raw = await self.search(root, query)
        else:
            raw = await asyncio.to_thread(self.search, root, query)
            if inspect.isawaitable(raw):
                raw = await raw
        return [h if isinstance(h, Hit) else Hit.model_validate(h) for h in (raw or [])]


def load_plugins(names: list[str], paths: list[str]) -> Plugins:
    """Import every module in ``names`` (after putting ``paths`` on ``sys.path``); ``PluginError`` on the first bad one."""
    _add_paths(paths)
    return Plugins([_import(name) for name in names])


def check_plugin(name: str, paths: list[str]) -> tuple[bool, str]:
    """The doctor's view of one plug-in: whether it loads, and one line naming its hooks or the problem."""
    _add_paths(paths)
    try:
        module = _import(name)
    except PluginError as e:
        return False, str(e)
    hooks = _hooks(module)
    return True, f"API {PLUGIN_API}; " + (", ".join(hooks) if hooks else "no hooks")
