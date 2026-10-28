"""Task 3: the deployment's configuration and the ``hello`` it produces."""

from pathlib import Path

import pytest

from portico_gateway.config import Config, ConfigError, hello_for, load_config
from portico_gateway.messages import Action, Brand, HelloServer, Root, parse_server, dump

EMPTY_SOURCES_MESSAGE = (
    "setting_sources must not be empty: an empty list drops the folder's instructions and hooks"
)


def test_defaults_when_no_file(tmp_path: Path) -> None:
    config = load_config(tmp_path / "config.toml")
    assert config == Config()
    assert config.brand == Brand(name="Portico", agent_name="Agent")
    assert config.brand.accent is None and config.brand.icon is None
    assert config.actions == []
    assert config.roots == []
    assert config.setting_sources == ["project"]
    assert config.before_first_chat is None
    assert config.on_stop is None
    assert config.command_timeout_seconds == 120
    assert config.default_folder is None
    assert config.card_hold_seconds == 600
    assert config.history_buffer == 2000
    # Loading defaults never creates the file.
    assert not (tmp_path / "config.toml").exists()


def test_full_file_round_trips_every_field(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text(
        """
setting_sources = ["project", "user"]
before_first_chat = "bin/prepare"
on_stop = "bin/cleanup"
command_timeout_seconds = 30
default_folder = "/Users/someone/projects"
card_hold_seconds = 60
history_buffer = 500

[brand]
name = "Front Door"
agent_name = "Helper"
accent = "#3B6EF5"
icon = "/Users/someone/icon.png"

[[actions]]
label = "Review"
text = "/review"

[[actions]]
label = "Plan"
text = "/plan"

[[roots]]
name = "projects"
path = "/Users/someone/projects"
"""
    )
    config = load_config(path)
    assert config.brand == Brand(name="Front Door", agent_name="Helper", accent="#3B6EF5", icon="/Users/someone/icon.png")
    assert config.actions == [Action(label="Review", text="/review"), Action(label="Plan", text="/plan")]
    assert config.roots == [Root(name="projects", path="/Users/someone/projects")]
    assert config.setting_sources == ["project", "user"]
    assert config.before_first_chat == "bin/prepare"
    assert config.on_stop == "bin/cleanup"
    assert config.command_timeout_seconds == 30
    assert config.default_folder == "/Users/someone/projects"
    assert config.card_hold_seconds == 60
    assert config.history_buffer == 500


def test_empty_setting_sources_refused_with_exact_message(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text('setting_sources = []\n')
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert str(e.value) == EMPTY_SOURCES_MESSAGE
    assert isinstance(e.value, ValueError)

    # The model refuses it too, not only the loader: nobody can build one by
    # hand. (Pydantic wraps the validator's error, so the type is ValueError
    # here; the exact ConfigError is the loader's contract.)
    with pytest.raises(ValueError) as e2:
        Config(setting_sources=[])
    assert EMPTY_SOURCES_MESSAGE in str(e2.value)


def test_unknown_key_refused(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text('model = "something"\n')
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert "model" in str(e.value)
    assert "config.toml" in str(e.value)

    # Nested tables are strict as well.
    path.write_text('[brand]\nname = "X"\nagent_name = "Y"\ncolour = "red"\n')
    with pytest.raises(ConfigError) as e2:
        load_config(path)
    assert "colour" in str(e2.value)


def test_malformed_toml_is_a_config_error(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text("this is = = not toml\n")
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert "config.toml" in str(e.value)


def test_wrong_type_is_a_config_error(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text('card_hold_seconds = "ten minutes"\n')
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert "card_hold_seconds" in str(e.value)


@pytest.mark.parametrize(
    "line",
    [
        "command_timeout_seconds = 0",
        "command_timeout_seconds = -1",
        "card_hold_seconds = -1",
        "history_buffer = 0",
        "history_buffer = -5",
    ],
)
def test_out_of_range_number_is_refused_naming_the_key(tmp_path: Path, line: str) -> None:
    # A typo must fail at load with the key named, not downstream (a timeout
    # that can never elapse, a ring buffer that drops every event).
    path = tmp_path / "config.toml"
    path.write_text(line + "\n")
    with pytest.raises(ConfigError) as e:
        load_config(path)
    key = line.split(" = ")[0]
    assert key in str(e.value) and "config.toml" in str(e.value)


def test_zero_card_hold_is_allowed(tmp_path: Path) -> None:
    # No hold at all is a deployment's choice: with nobody attached a card is
    # denied at once. The smallest timeout and ring are 1.
    path = tmp_path / "config.toml"
    path.write_text("card_hold_seconds = 0\ncommand_timeout_seconds = 1\nhistory_buffer = 1\n")
    config = load_config(path)
    assert config.card_hold_seconds == 0
    assert config.command_timeout_seconds == 1 and config.history_buffer == 1


def test_hello_carries_brand_actions_roots_and_protocol_1() -> None:
    config = Config(
        brand=Brand(name="Front Door", agent_name="Helper", accent="#3B6EF5"),
        actions=[Action(label="Review", text="/review")],
        roots=[Root(name="projects", path="/Users/someone/projects")],
    )
    hello = hello_for(config, epoch="7f1c4a2e-3b5d-4c6e-9a8b-0d1e2f3a4b5c", gateway_version="0.1.0")

    assert isinstance(hello, HelloServer)
    assert hello.type == "hello"
    assert hello.protocol == 1
    assert hello.gateway_version == "0.1.0"
    assert hello.epoch == "7f1c4a2e-3b5d-4c6e-9a8b-0d1e2f3a4b5c"
    assert hello.brand == config.brand
    assert hello.actions == config.actions
    assert hello.roots == config.roots
    assert hello.commands == []
    assert hello.capabilities == ["cards.form", "files", "producer"]
    assert hello.chat is None and hello.seq is None
    assert hello.ts

    # It is a valid wire frame.
    assert parse_server(dump(hello)) == hello


def test_hello_with_defaults_has_default_brand_and_no_actions() -> None:
    hello = hello_for(Config(), epoch="e", gateway_version="0.1.0")
    assert hello.brand == Brand(name="Portico", agent_name="Agent")
    assert hello.actions == [] and hello.roots == []


def test_root_path_with_a_tilde_is_expanded_at_load(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    # The gateway is a detached process: a root must name an absolute
    # directory, and "~/vault" is how a person writes one in config.
    monkeypatch.setenv("HOME", str(tmp_path))
    path = tmp_path / "config.toml"
    path.write_text('[[roots]]\nname = "vault"\npath = "~/vault"\n')
    config = load_config(path)
    assert config.roots == [Root(name="vault", path=str(tmp_path / "vault"))]
    hello = hello_for(config, epoch="e", gateway_version="0.1.0")
    assert hello.roots[0].path == str(tmp_path / "vault")


def test_relative_root_path_is_refused_naming_the_root(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text('[[roots]]\nname = "vault"\npath = "vault"\n')
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert "vault" in str(e.value) and "absolute" in str(e.value)
