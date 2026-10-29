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
    assert config.brand.for_hello() == Brand(name="Portico", agent_name="Agent")
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
    assert config.presentation == "single"
    assert config.permission_mode == "auto"
    assert config.update.check is None and config.update.run is None
    assert config.brand.app_icon is None
    assert config.log_prompt is None
    assert config.plugins == []
    assert config.plugin_paths == []
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
header_image = "/Users/someone/lockup.svg"

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
    assert config.brand.for_hello() == Brand(
        name="Front Door",
        agent_name="Helper",
        accent="#3B6EF5",
        icon="/Users/someone/icon.png",
        header_image="/Users/someone/lockup.svg",
    )
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
    assert hello.brand == config.brand.for_hello()
    assert hello.actions == config.actions
    assert hello.roots == config.roots
    assert hello.commands == []
    assert hello.capabilities == ["cards.form", "files", "producer", "sessions", "files.search", "context", "agents.v1"]
    assert hello.presentation == "single"
    assert hello.can_log is False
    assert hello.config_stale is False and hello.can_update is False
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


# --- v0.2: sessions and plug-ins ----------------------------------------------


def test_session_keys_load(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    path = tmp_path / "config.toml"
    path.write_text(
        'presentation = "single"\n'
        'log_prompt = "/session-close"\n'
        'plugins = ["my_plugin"]\n'
        'plugin_paths = ["~/portico-plugins"]\n'
    )
    config = load_config(path)
    assert config.presentation == "single"
    assert config.log_prompt == "/session-close"
    assert config.plugins == ["my_plugin"]
    assert config.plugin_paths == [str(tmp_path / "portico-plugins")]


def test_unknown_presentation_is_refused(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text('presentation = "tabs"\n')
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert "presentation" in str(e.value)


def test_relative_plugin_path_is_refused(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text('plugin_paths = ["plugins"]\n')
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert "plugin_paths" in str(e.value) and "absolute" in str(e.value)


def test_hello_carries_presentation_and_can_log_from_log_prompt() -> None:
    hello = hello_for(Config(presentation="single", log_prompt="/session-close"), epoch="e", gateway_version="0.2.0")
    assert hello.presentation == "single"
    assert hello.can_log is True
    assert parse_server(dump(hello)) == hello


def test_hello_without_a_log_step_cannot_log() -> None:
    hello = hello_for(Config(presentation="single"), epoch="e", gateway_version="0.2.0")
    assert hello.can_log is False


# --- v0.3: permission mode, update commands, the app icon ----------------------


def test_v03_keys_load(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    path = tmp_path / "config.toml"
    path.write_text(
        'permission_mode = "acceptEdits"\n'
        "[brand]\n"
        'name = "Front Door"\n'
        'agent_name = "Helper"\n'
        'app_icon = "~/icons/front-door.png"\n'
        "[update]\n"
        'check = "deploy-tool update --check"\n'
        'run = "deploy-tool update"\n'
    )
    config = load_config(path)
    assert config.permission_mode == "acceptEdits"
    assert config.brand.app_icon == str(tmp_path / "icons" / "front-door.png")
    assert config.update.check == "deploy-tool update --check" and config.update.run == "deploy-tool update"


def test_hello_never_carries_the_app_icon_and_says_it_can_update() -> None:
    config = Config.model_validate(
        {"brand": {"name": "Front Door", "agent_name": "Helper", "app_icon": "/icons/front-door.png"}, "update": {"run": "deploy-tool update"}}
    )
    hello = hello_for(config, epoch="e", gateway_version="0.3.0", config_stale=True)
    assert hello.brand == Brand(name="Front Door", agent_name="Helper")
    assert "app_icon" not in dump(hello)
    assert hello.can_update is True and hello.config_stale is True
    assert parse_server(dump(hello)) == hello


@pytest.mark.parametrize(
    "text, key",
    [
        ('permission_mode = "bypassPermissions"\n', "permission_mode"),
        ('[update]\nchek = "x"\n', "update"),
        ('[brand]\nname = "a"\nagent_name = "b"\napp_icon = "icon.png"\n', "app_icon"),
    ],
)
def test_bad_v03_keys_are_refused_naming_the_key(tmp_path: Path, text: str, key: str) -> None:
    path = tmp_path / "config.toml"
    path.write_text(text)
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert key in str(e.value)


def test_app_icon_assets_and_name_load_expanded_and_never_reach_hello(tmp_path: Path) -> None:
    """v0.5: a precompiled asset catalog and the icon's name in it, for bin/install only."""
    path = tmp_path / "config.toml"
    path.write_text(
        "[brand]\n"
        'name = "Front Door"\n'
        'agent_name = "Helper"\n'
        'app_icon = "/icons/front-door.png"\n'
        'app_icon_assets = "~/icons/Assets.car"\n'
        'app_icon_name = "FrontDoor"\n'
    )
    config = load_config(path)
    assert config.brand.app_icon_assets == str(Path("~/icons/Assets.car").expanduser())
    assert config.brand.app_icon_name == "FrontDoor"
    hello = hello_for(config, epoch="e", gateway_version="0.5.0")
    assert hello.brand == Brand(name="Front Door", agent_name="Helper")
    assert "app_icon" not in dump(hello)


def test_app_icon_assets_and_name_default_to_unset() -> None:
    assert Config().brand.app_icon_assets is None and Config().brand.app_icon_name is None


@pytest.mark.parametrize(
    "line, key",
    [
        ('app_icon_assets = "Assets.car"\n', "brand.app_icon_assets"),
        ('app_icon_name = ""\n', "brand.app_icon_name"),
        ('app_icon_name = "icons/App"\n', "brand.app_icon_name"),
        ('app_icon_assets = 3\n', "app_icon_assets"),
    ],
)
def test_bad_app_icon_assets_keys_are_refused_naming_the_key(tmp_path: Path, line: str, key: str) -> None:
    path = tmp_path / "config.toml"
    path.write_text('[brand]\nname = "a"\nagent_name = "b"\n' + line)
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert key in str(e.value)


def test_config_value_reads_dotted_keys() -> None:
    from portico_gateway.config import config_value

    config = Config.model_validate({"brand": {"name": "Front Door", "agent_name": "Helper", "app_icon": "/i.png"}})
    assert config_value(config, "brand.name") == "Front Door"
    assert config_value(config, "brand.app_icon") == "/i.png"
    assert config_value(config, "brand.accent") is None
    assert config_value(config, "update.run") is None
    assert config_value(config, "permission_mode") == "auto"
    assert config_value(config, "no.such.key") is None
    assert config_value(config, "brand.name.deeper") is None


def test_hello_carries_default_folder_expanded(tmp_path: Path) -> None:
    from portico_gateway.config import Config, hello_for

    assert hello_for(Config(), "e", "0.3.0").default_folder is None
    hello = hello_for(Config(default_folder="~/work"), "e", "0.3.0")
    assert hello.default_folder == str(Path("~/work").expanduser())


def test_hello_carries_the_mode_a_new_session_starts_in() -> None:
    from portico_gateway.config import Config, hello_for

    assert hello_for(Config(), "e", "0.3.0").permission_mode == "auto"
    assert hello_for(Config(permission_mode="default"), "e", "0.3.0").permission_mode == "default"
    assert hello_for(Config(permission_mode="acceptEdits"), "e", "0.3.0").permission_mode == "acceptEdits"


# --- v0.4: services, the log command -------------------------------------------------


def test_services_load(tmp_path: Path) -> None:
    path = tmp_path / "config.toml"
    path.write_text(
        "services_interval_seconds = 15\n"
        "[[services]]\n"
        'id = "memory"\n'
        'name = "Memory (recall server)"\n'
        'check = "curl -sf http://localhost:8888/health"\n'
        'restart = "launchctl kickstart -k gui/$UID/com.example.memory"\n'
        'up_detail = "recall and capture"\n'
        "[[services]]\n"
        'id = "search-2"\n'
        'name = "Search"\n'
        'check = "true"\n'
        "timeout_seconds = 3\n"
    )
    config = load_config(path)
    assert config.services_interval_seconds == 15
    memory, search = config.services
    assert (memory.id, memory.name, memory.up_detail) == ("memory", "Memory (recall server)", "recall and capture")
    assert memory.restart and "$UID" in memory.restart, "the command is kept as written; the shell expands it"
    assert (search.id, search.restart, search.up_detail) == ("search-2", None, None)
    assert (memory.timeout_seconds, search.timeout_seconds) == (10, 3), "a check is bounded by 10 s unless it says"


def test_services_default_to_none_every_30_seconds() -> None:
    assert Config().services == [] and Config().services_interval_seconds == 30


@pytest.mark.parametrize(
    "text, words",
    [
        ('[[services]]\nid = "Memory"\nname = "M"\ncheck = "true"\n', ["services", "'Memory'", "lowercase"]),
        ('[[services]]\nid = "a b"\nname = "M"\ncheck = "true"\n', ["services", "'a b'"]),
        ('[[services]]\nid = "m"\nname = "  "\ncheck = "true"\n', ["services", "name"]),
        ('[[services]]\nid = "m"\nname = "M"\ncheck = ""\n', ["services", "check"]),
        ('[[services]]\nid = "m"\nname = "M"\n', ["services.0.check"]),
        ('[[services]]\nname = "M"\ncheck = "true"\n', ["services.0.id"]),
        ('[[services]]\nid = "m"\nname = "M"\ncheck = "true"\nrestrat = "x"\n', ["services.0.restrat"]),
        (
            '[[services]]\nid = "m"\nname = "M"\ncheck = "true"\n[[services]]\nid = "m"\nname = "N"\ncheck = "true"\n',
            ["services", "'m'", "twice"],
        ),
        ("services_interval_seconds = 4\n", ["services_interval_seconds"]),
        ('[[services]]\nid = "a\\n"\nname = "M"\ncheck = "true"\n', ["services", "lowercase"]),
        ('[[services]]\nid = "m"\nname = "M"\ncheck = "true"\ntimeout_seconds = 0\n', ["services.0.timeout_seconds"]),
    ],
)
def test_bad_services_are_refused_naming_the_key(tmp_path: Path, text: str, words: list[str]) -> None:
    path = tmp_path / "config.toml"
    path.write_text(text)
    with pytest.raises(ConfigError) as e:
        load_config(path)
    for word in words:
        assert word in str(e.value), (word, str(e.value))


@pytest.mark.parametrize(
    "text, keys",
    [
        ('[[services]]\nid = "Memory"\nname = "M"\ncheck = "true"\n', {"services"}),
        ("services_interval_seconds = 4\n", {"services_interval_seconds"}),
        # Words in the message never decide which key failed.
        ("servicess = 1\n", {"servicess"}),
        ('roots = [{ name = "x", path = "relative/services" }]\n', {"roots"}),
        ("not toml [", set()),
    ],
)
def test_a_config_error_names_its_top_level_keys(tmp_path: Path, text: str, keys: set[str]) -> None:
    path = tmp_path / "config.toml"
    path.write_text(text)
    with pytest.raises(ConfigError) as e:
        load_config(path)
    assert e.value.keys == keys


def test_hello_commands_list_log_when_the_deployment_can_log() -> None:
    assert hello_for(Config(log_prompt="/session-close"), epoch="e", gateway_version="0.4.0").commands == ["log"]
    assert hello_for(Config(), epoch="e", gateway_version="0.4.0").commands == []


def test_a_relative_header_image_stops_the_load(tmp_path: Path) -> None:
    # v0.7: the toolbar's header image is a path the app reads, so it is
    # absolute (~ expanded), like the icons.
    path = tmp_path / "config.toml"
    path.write_text('[brand]\nname = "Front Door"\nagent_name = "Helper"\nheader_image = "lockup.svg"\n')
    with pytest.raises(ConfigError, match="brand.header_image"):
        load_config(path)
    path.write_text('[brand]\nname = "Front Door"\nagent_name = "Helper"\nheader_image = "~/lockup.svg"\n')
    assert load_config(path).brand.for_hello().header_image == str(Path("~/lockup.svg").expanduser())
