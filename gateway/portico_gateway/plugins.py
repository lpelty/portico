"""Plug-ins: deployment code that replaces one of the gateway's default mechanics.

A plug-in is a Python module named in ``config.plugins`` and kept outside
the checkout (``config.plugin_paths`` puts its directory on ``sys.path``),
so updating Portico never touches it. Each module sets
``PORTICO_PLUGIN_API = 1`` and defines any of:

- ``on_hello(hello) -> hello`` — adjust the ``hello`` the app receives.
  Every plug-in's runs, in list order.
- ``async on_renew(ctx, chat) -> bool`` — the deployment's log step,
  instead of sending ``config.log_prompt``: a renewal runs it in the ending
  session, and (v0.4) ``session.log`` runs it in the live session without
  ending it (``ctx.ending`` says which). ``ctx`` is a ``RenewContext``;
  ``chat`` the session's ``ChatSummary``. Returns whether the session was
  logged.
- ``search(root, query) -> list[Hit]`` (sync or async) — ``files.search``
  instead of Spotlight. ``root`` is the root's directory; hit paths are
  relative to it.
- ``restart_services()`` (sync or async, v0.8) — the services menu's
  Restart all services, instead of ``[deployment] restart``. Returning
  ``False`` or raising is a failed restart (the exception's message is the
  reason the app shows); anything else is done.
- ``services_status()`` (sync or async, v0.8) — the deployment's services,
  instead of ``[deployment] status`` or each ``[[services]]`` check: the
  same shape the status command prints, ``{"services": [{"id", "name",
  "up", "detail"?}]}`` (a dict, or that JSON as text).

For ``on_renew``, ``search``, ``restart_services`` and ``services_status``
the last plug-in in the list that names the hook is the one used. A module that is missing, raises on import, or
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
# v0.8: sync or async, no arguments.
ServicesHook = Callable[[], Any]


class PluginError(Exception):
    """A configured plug-in cannot be used; the message names the module and why."""


@dataclass
class RenewContext:
    """What a plug-in's ``on_renew`` gets to run a log step in the session.

    ``send(text)`` sends ``text`` into the session as a message — a turn
    the app shows like any other, cards included — and returns the turn's
    outcome once it finishes: ``"done"``, ``"stopped"`` or ``"error"``.
    ``ending`` (v0.4) is true when a renewal ends the session after the log
    step, false for ``session.log``, which logs and keeps it live; the log
    step itself is the same either way, and the gateway, not the plug-in,
    ends the session.
    """

    chat: int
    folder: Path
    log_prompt: str | None
    send: Callable[[str], Awaitable[Outcome]]
    ending: bool = True


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
    for hook in ("on_hello", "search", "restart_services", "services_status"):
        value = getattr(module, hook, None)
        if value is not None and not callable(value):
            raise PluginError(f"plug-in {name!r}: {hook} is not callable")
    return module


HOOKS = ("on_hello", "on_renew", "search", "restart_services", "services_status")


def _hooks(module: ModuleType) -> list[str]:
    return [hook for hook in HOOKS if getattr(module, hook, None) is not None]


class Plugins:
    """The loaded plug-ins and the hooks they provide."""

    def __init__(self, modules: list[ModuleType]) -> None:
        self.modules = list(modules)
        self.renew: RenewHook | None = None
        self.search: SearchHook | None = None
        self.restart_services: ServicesHook | None = None
        self.services_status: ServicesHook | None = None
        for module in self.modules:
            self.renew = getattr(module, "on_renew", None) or self.renew
            self.search = getattr(module, "search", None) or self.search
            self.restart_services = getattr(module, "restart_services", None) or self.restart_services
            self.services_status = getattr(module, "services_status", None) or self.services_status

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
            try:
                changed = hook(hello)
            except Exception as e:
                raise PluginError(f"plug-in {module.__name__!r}: on_hello failed: {type(e).__name__}: {e}") from e
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


async def call_hook(hook: ServicesHook) -> Any:
    """Run a no-argument hook, sync (in a thread) or async; its result."""
    if inspect.iscoroutinefunction(hook):
        return await hook()
    result = await asyncio.to_thread(hook)
    if inspect.isawaitable(result):
        result = await result
    return result


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
