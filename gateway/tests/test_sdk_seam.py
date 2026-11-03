"""v0.18 ruling 29: the engine's MCP seam, and the options that bring the person's servers and plugins in.

``mcp_app_read`` and ``mcp_app_call`` reach the CLI through the SDK's private
``Query._send_control_request``; the first test fails the day it goes away.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from portico_gateway.config import ConfigError, load_config
from portico_gateway.engine import SHOW_SERVER, SDKEngine, build_options

from tests.conftest import RecordingCallbacks

TRACKER = {"type": "http", "url": "https://mcp.acme.example/"}


class BareCallbacks:
    """An owner with no viewer and no threads: Portico gives it no tools of its own."""

    async def on_event(self, event: Any) -> None: ...

    async def on_permission(self, tool: str, input: dict[str, Any], suggestions: list[dict[str, Any]], tool_use_id: str) -> str:
        return "allow"

    async def on_question(self, questions: list[dict[str, Any]], tool_use_id: str = "") -> dict[str, Any]:
        return {}

    async def on_compacted(self, trigger: str) -> None: ...


def test_portico_server_name_agrees() -> None:
    from portico_gateway.mcp_inventory import PORTICO_SERVER

    assert PORTICO_SERVER == SHOW_SERVER


def test_private_control_request_exists() -> None:
    from claude_agent_sdk._internal.query import Query

    assert callable(getattr(Query, "_send_control_request", None))


def test_build_options_passes_servers_and_plugins(tmp_path: Path) -> None:
    options = build_options(
        tmp_path,
        None,
        ["project"],
        RecordingCallbacks(),
        extra_servers={"acme-tracker": TRACKER},
        plugin_paths=["/p/a"],
    )
    assert isinstance(options.mcp_servers, dict)
    assert set(options.mcp_servers) == {SHOW_SERVER, "acme-tracker"}
    assert options.mcp_servers["acme-tracker"] == TRACKER
    assert options.plugins == [{"type": "local", "path": "/p/a"}]
    assert options.setting_sources == ["project"]


def test_build_options_without_tools_still_passes_servers(tmp_path: Path) -> None:
    options = build_options(tmp_path, None, ["project"], BareCallbacks(), extra_servers={"acme-tracker": TRACKER})
    assert options.mcp_servers == {"acme-tracker": TRACKER}
    assert options.plugins == []


def test_build_options_defaults_unchanged(tmp_path: Path) -> None:
    options = build_options(tmp_path, None, ["project"], BareCallbacks())
    assert options.mcp_servers == {}
    assert options.plugins == []


class RecordingQuery:
    def __init__(self, reply: dict[str, Any]) -> None:
        self.reply = reply
        self.requests: list[dict[str, Any]] = []

    async def _send_control_request(self, request: dict[str, Any], timeout: float = 60.0) -> dict[str, Any]:
        self.requests.append(request)
        return self.reply


class StubClient:
    def __init__(self, query: RecordingQuery) -> None:
        self._query = query
        self.toggles: list[tuple[str, bool]] = []
        self.reconnects: list[str] = []

    async def get_mcp_status(self) -> dict[str, Any]:
        return {"mcpServers": [{"name": "acme-tracker", "status": "connected"}]}

    async def toggle_mcp_server(self, name: str, enabled: bool) -> None:
        self.toggles.append((name, enabled))

    async def reconnect_mcp_server(self, name: str) -> None:
        self.reconnects.append(name)


async def test_seam_sends_the_documented_requests() -> None:
    contents = {"contents": [{"uri": "ui://t/a.html", "mimeType": "text/html;profile=mcp-app", "text": "<p>hi</p>"}]}
    query = RecordingQuery(contents)
    engine = SDKEngine(chat=3)
    engine._client = StubClient(query)  # type: ignore[assignment]

    assert await engine.mcp_app_read("acme-tracker", "ui://t/a.html") == contents
    assert query.requests[-1] == {"subtype": "mcp_read_resource", "serverName": "acme-tracker", "uri": "ui://t/a.html"}

    await engine.mcp_app_call("mcp__acme-tracker__update_task", {"id": 1})
    assert query.requests[-1] == {
        "subtype": "mcp_call",
        "tool": "mcp__acme-tracker__update_task",
        "arguments": {"id": 1},
        "result_not_for_model": True,
    }

    assert await engine.mcp_status() == [{"name": "acme-tracker", "status": "connected"}]
    await engine.mcp_toggle("acme-tracker", False)
    await engine.mcp_reconnect("acme-tracker")
    assert engine._client.toggles == [("acme-tracker", False)]  # type: ignore[union-attr]
    assert engine._client.reconnects == ["acme-tracker"]  # type: ignore[union-attr]
    assert len(query.requests) == 2  # only the app read and call go through the private path


async def test_seam_before_start_raises() -> None:
    engine = SDKEngine()
    assert engine.apps_capable is False
    with pytest.raises(RuntimeError):
        await engine.mcp_status()
    with pytest.raises(RuntimeError):
        await engine.mcp_app_read("acme-tracker", "ui://t/a.html")


def test_config_mcp_core(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text('[mcp]\ncore = ["team-knowledge"]\n', encoding="utf-8")
    assert load_config(path).mcp.core == ["team-knowledge"]
    assert load_config(tmp_path / "missing.toml").mcp.core == []

    path.write_text("[mcp]\nother = 1\n", encoding="utf-8")
    with pytest.raises(ConfigError, match=r"mcp\.other"):
        load_config(path)
