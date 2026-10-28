"""v0.2: plug-ins — loading, the API number, the hooks, and the example in ``examples/plugin``.

A plug-in is a Python module named in ``config.plugins``, living outside
the checkout (``config.plugin_paths`` puts its directory on ``sys.path``).
These tests write throwaway modules into ``tmp_path``; nothing here
touches a model.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

from portico_gateway import REPO_ROOT
from portico_gateway.config import Config, hello_for
from portico_gateway.messages import Hit
from portico_gateway.plugins import PLUGIN_API, PluginError, Plugins, check_plugin, load_plugins

EXAMPLE_DIR = REPO_ROOT / "examples" / "plugin"


@pytest.fixture(autouse=True)
def clean_imports(monkeypatch: pytest.MonkeyPatch) -> None:
    """Each test imports its own modules: restore ``sys.path`` and ``sys.modules`` afterwards."""
    monkeypatch.setattr(sys, "path", list(sys.path))
    monkeypatch.setattr(sys, "modules", dict(sys.modules))


def write_module(where: Path, name: str, body: str) -> Path:
    where.mkdir(parents=True, exist_ok=True)
    path = where / f"{name}.py"
    path.write_text(body)
    return path


# --- loading ------------------------------------------------------------------


def test_no_plugins_is_the_default() -> None:
    plugins = load_plugins([], [])
    assert plugins.names == []
    assert plugins.renew is None and plugins.search is None


def test_a_module_on_a_plugin_path_loads(tmp_path: Path) -> None:
    write_module(tmp_path, "pp_ok", "PORTICO_PLUGIN_API = 1\n")
    plugins = load_plugins(["pp_ok"], [str(tmp_path)])
    assert plugins.names == ["pp_ok"]


def test_a_missing_module_is_a_clear_error(tmp_path: Path) -> None:
    with pytest.raises(PluginError) as e:
        load_plugins(["pp_nowhere"], [str(tmp_path)])
    assert "pp_nowhere" in str(e.value) and "not found" in str(e.value)


def test_a_module_without_the_api_number_is_refused(tmp_path: Path) -> None:
    write_module(tmp_path, "pp_bare", "def on_hello(hello):\n    return hello\n")
    with pytest.raises(PluginError) as e:
        load_plugins(["pp_bare"], [str(tmp_path)])
    assert "pp_bare" in str(e.value) and "PORTICO_PLUGIN_API" in str(e.value)


def test_a_different_api_number_is_refused_naming_both(tmp_path: Path) -> None:
    write_module(tmp_path, "pp_future", "PORTICO_PLUGIN_API = 2\n")
    with pytest.raises(PluginError) as e:
        load_plugins(["pp_future"], [str(tmp_path)])
    assert "2" in str(e.value) and str(PLUGIN_API) in str(e.value)


def test_a_module_that_raises_on_import_is_reported(tmp_path: Path) -> None:
    write_module(tmp_path, "pp_broken", "raise RuntimeError('boom')\n")
    with pytest.raises(PluginError) as e:
        load_plugins(["pp_broken"], [str(tmp_path)])
    assert "pp_broken" in str(e.value) and "boom" in str(e.value)


def test_a_sync_on_renew_is_refused(tmp_path: Path) -> None:
    write_module(tmp_path, "pp_sync", "PORTICO_PLUGIN_API = 1\ndef on_renew(ctx, chat):\n    return True\n")
    with pytest.raises(PluginError) as e:
        load_plugins(["pp_sync"], [str(tmp_path)])
    assert "on_renew" in str(e.value) and "async" in str(e.value)


# --- hooks --------------------------------------------------------------------


def test_on_hello_runs_in_list_order(tmp_path: Path) -> None:
    for name, cap in (("pp_a", "a"), ("pp_b", "b")):
        write_module(
            tmp_path,
            name,
            "PORTICO_PLUGIN_API = 1\n"
            "def on_hello(hello):\n"
            f"    return hello.model_copy(update={{'capabilities': [*hello.capabilities, {cap!r}]}})\n",
        )
    plugins = load_plugins(["pp_a", "pp_b"], [str(tmp_path)])
    hello = hello_for(Config(), epoch="e", gateway_version="0.2.0", plugins=plugins)
    assert hello.capabilities[-2:] == ["a", "b"]


def test_a_plugin_on_renew_makes_hello_can_log(tmp_path: Path) -> None:
    write_module(tmp_path, "pp_renew", "PORTICO_PLUGIN_API = 1\nasync def on_renew(ctx, chat):\n    return True\n")
    plugins = load_plugins(["pp_renew"], [str(tmp_path)])
    assert plugins.renew is not None
    hello = hello_for(Config(), epoch="e", gateway_version="0.2.0", plugins=plugins)
    assert hello.can_log is True


def test_the_last_plugin_naming_a_hook_wins(tmp_path: Path) -> None:
    write_module(tmp_path, "pp_s1", "PORTICO_PLUGIN_API = 1\ndef search(root, query):\n    return []\n")
    write_module(tmp_path, "pp_s2", "PORTICO_PLUGIN_API = 1\ndef search(root, query):\n    return []\n")
    plugins = load_plugins(["pp_s1", "pp_s2"], [str(tmp_path)])
    assert plugins.search is not None
    assert plugins.search.__module__ == "pp_s2"


async def test_sync_and_async_search_both_run(tmp_path: Path) -> None:
    write_module(
        tmp_path,
        "pp_sync_search",
        "from portico_gateway.messages import Hit\n"
        "PORTICO_PLUGIN_API = 1\n"
        "def search(root, query):\n    return [Hit(path='a.md')]\n",
    )
    write_module(
        tmp_path,
        "pp_async_search",
        "PORTICO_PLUGIN_API = 1\n"
        "async def search(root, query):\n    return [{'path': 'b.md', 'snippet': str(root) + ':' + query}]\n",
    )
    sync = load_plugins(["pp_sync_search"], [str(tmp_path)])
    assert await sync.run_search(tmp_path, "q") == [Hit(path="a.md")]
    asynchronous = load_plugins(["pp_async_search"], [str(tmp_path)])
    assert await asynchronous.run_search(tmp_path, "q") == [Hit(path="b.md", snippet=f"{tmp_path}:q")]


# --- the doctor's view ----------------------------------------------------------


def test_check_plugin_reports_ok_missing_and_mismatch(tmp_path: Path) -> None:
    write_module(tmp_path, "pp_fine", "PORTICO_PLUGIN_API = 1\nasync def on_renew(ctx, chat):\n    return True\n")
    write_module(tmp_path, "pp_old", "PORTICO_PLUGIN_API = 0\n")
    ok, line = check_plugin("pp_fine", [str(tmp_path)])
    assert ok and "on_renew" in line
    ok, line = check_plugin("pp_gone", [str(tmp_path)])
    assert not ok and "not found" in line
    ok, line = check_plugin("pp_old", [str(tmp_path)])
    assert not ok and "PORTICO_PLUGIN_API" in line


# --- the example ------------------------------------------------------------------


def test_the_example_plugin_loads_and_names_its_hooks() -> None:
    plugins = load_plugins(["portico_example_plugin"], [str(EXAMPLE_DIR)])
    assert plugins.names == ["portico_example_plugin"]
    assert plugins.renew is not None
    hello = hello_for(Config(), epoch="e", gateway_version="0.2.0", plugins=plugins)
    assert "example.plugin" in hello.capabilities
    assert hello.can_log is True


def test_plugins_none_is_empty() -> None:
    assert Plugins.none().names == []
