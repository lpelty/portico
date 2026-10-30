"""The deployment's configuration and the ``hello`` built from it.

``config.toml`` lives in the state directory (``StateDir.config_path``). It
is read once at start; what a person sees of it goes out in ``hello``
(brand, actions, roots). Everything else steers the gateway itself.

Nothing here names a model, a provider, or a credential: those come from the
environment only.
"""

from __future__ import annotations

import re
import tomllib
from datetime import UTC, datetime
from pathlib import Path
from typing import TYPE_CHECKING, Any, ClassVar, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, ValidationInfo, field_validator

from .messages import Action, Brand, HelloServer, PermissionMode, Presentation, Root

if TYPE_CHECKING:
    from .plugins import Plugins

EMPTY_SETTING_SOURCES_MESSAGE = (
    "setting_sources must not be empty: an empty list drops the folder's instructions and hooks"
)

# What this gateway can do beyond the protocol's baseline; the app keys
# optional UI on these.
# v0.10: ``agents.v1`` — this gateway sends subagent and workflow frames to an
# app that lists the same capability in its ``hello``.
CAPABILITIES: list[str] = ["cards.form", "files", "producer", "sessions", "files.search", "context", "agents.v1"]

# v0.8: advertised when the deployment can restart all its services at once
# (``[deployment] restart`` or a plug-in's ``restart_services``); the app
# then offers Restart all services and sends ``services.restart_all``.
RESTART_ALL_CAPABILITY = "services.restart_all"


class ConfigError(ValueError):
    """``config.toml`` cannot be used; the message says which key and why.

    ``keys`` names the top-level config keys the error is about (``services``,
    ``roots``, ...) when it came from validating them; it is empty when the
    file as a whole cannot be used (unreadable, not TOML). Callers that care
    which section failed read ``keys``, never the message.
    """

    def __init__(self, message: str, keys: frozenset[str] = frozenset()) -> None:
        super().__init__(message)
        self.keys = keys


class ConfigBrand(Brand):
    """The protocol's ``Brand`` plus what only the install reads.

    ``app_icon`` is the deployment's 1024×1024 PNG for the ``.app`` bundle
    (``bin/install`` reads it with ``portico-gateway config-value
    brand.app_icon``). ``app_icon_assets`` (v0.5) is a precompiled asset
    catalog (``Assets.car`` from Icon Composer or actool) and
    ``app_icon_name`` the icon's name inside it; ``bin/install`` copies the
    catalog into the bundle and sets ``CFBundleIconName`` when both are set.
    None of the three is ever sent in ``hello``: ``hello_for`` builds the
    protocol ``Brand`` without them.
    """

    INSTALL_ONLY: ClassVar[frozenset[str]] = frozenset({"app_icon", "app_icon_assets", "app_icon_name"})

    app_icon: str | None = None
    app_icon_assets: str | None = None
    app_icon_name: str | None = None

    @field_validator("app_icon", "app_icon_assets", "header_image")
    @classmethod
    def _absolute_path(cls, value: str | None, info: ValidationInfo) -> str | None:
        if value is None:
            return None
        path = Path(value).expanduser()
        if not path.is_absolute():
            raise ConfigError(
                f"brand.{info.field_name}: {value!r} is relative; it must be an absolute path (~ is expanded)"
            )
        return str(path)

    @field_validator("app_icon_name")
    @classmethod
    def _icon_name(cls, value: str | None) -> str | None:
        if value is None:
            return None
        if not value.strip() or "/" in value:
            raise ConfigError(
                f"brand.app_icon_name: {value!r} must be the icon's name in the asset catalog (not empty, no slashes)"
            )
        return value

    def for_hello(self) -> Brand:
        return Brand.model_validate(self.model_dump(exclude=set(self.INSTALL_ONLY)))


class UpdateConfig(BaseModel):
    """``[update]``: the deployment's own update commands, run with ``/bin/sh -c``.

    ``check`` exits 0 and prints a version when an update is available (any
    other exit, or no output, means none); ``run`` performs the update.
    Portico owns when they run and the window around them; the deployment
    owns what they do.
    """

    model_config = ConfigDict(extra="forbid")

    check: str | None = None
    run: str | None = None


SERVICE_ID = re.compile(r"[a-z0-9-]+")


class ServiceConfig(BaseModel):
    """``[[services]]`` (v0.4): one thing the deployment depends on, and how to tell it is up.

    ``check`` runs with ``/bin/sh -c``; exit 0 means up. ``restart``, when
    set, is what the menu's Restart runs. ``up_detail`` is the line shown
    while it is up. ``timeout_seconds`` bounds each check (a restart is
    bounded by ``command_timeout_seconds``). Portico never knows what a
    service is.
    """

    model_config = ConfigDict(extra="forbid")

    id: str
    name: str
    check: str
    restart: str | None = None
    up_detail: str | None = None
    timeout_seconds: int = Field(default=10, ge=1)

    @field_validator("id")
    @classmethod
    def _id_shape(cls, value: str) -> str:
        if not SERVICE_ID.fullmatch(value):
            raise ConfigError(
                f"services: id {value!r} must be lowercase letters, digits and dashes (like \"memory\" or \"search-index\")"
            )
        return value

    @field_validator("name", "check")
    @classmethod
    def _not_blank(cls, value: str, info: Any) -> str:
        if not value.strip():
            raise ConfigError(f"services: {info.field_name} must not be empty")
        return value

    @field_validator("restart", "up_detail")
    @classmethod
    def _blank_is_unset(cls, value: str | None) -> str | None:
        return value if value is not None and value.strip() else None


class DeploymentConfig(BaseModel):
    """``[deployment]`` (v0.8): one restart and one status for all the deployment's services.

    Both run with ``/bin/sh -c``, bounded by ``command_timeout_seconds``.
    ``restart`` is what Restart all services runs (exit 0 is done).
    ``status`` prints ``{"services": [{"id", "name", "up", "detail"?}]}``;
    when set, the services menu shows its rows instead of running each
    ``[[services]]`` check, and a row's Restart comes from the
    ``[[services]]`` entry with the same ``id``, when one gives it.
    """

    model_config = ConfigDict(extra="forbid")

    restart: str | None = None
    status: str | None = None

    @field_validator("restart", "status")
    @classmethod
    def _blank_is_unset(cls, value: str | None) -> str | None:
        return value if value is not None and value.strip() else None


class Config(BaseModel):
    model_config = ConfigDict(extra="forbid")

    brand: ConfigBrand = ConfigBrand(name="Portico", agent_name="Agent")
    actions: list[Action] = []
    roots: list[Root] = []
    setting_sources: list[str] = ["project"]
    before_first_chat: str | None = None
    on_stop: str | None = None
    # Bounds are checked at load so a typo fails here with the key named,
    # not downstream: a timeout of 0 or less can never elapse, a ring of 0
    # drops every event. A hold of 0 is a choice (deny at once when nobody
    # is attached); a negative one is not.
    command_timeout_seconds: int = Field(default=120, ge=1)
    default_folder: str | None = None
    card_hold_seconds: int = Field(default=600, ge=0)
    history_buffer: int = Field(default=2000, ge=1)
    # Sessions (v0.2): ``single`` shows one live session at a time and
    # renews it; ``multiple`` is the v0.1 list of chats. ``log_prompt`` is
    # the default log step a renewal runs in the ending session, sent as a
    # message (a slash command the folder already has, typically).
    presentation: Presentation = "single"
    log_prompt: str | None = None
    # Plug-ins: module names, imported at start; ``plugin_paths`` are the
    # directories (outside the checkout) put on ``sys.path`` first.
    plugins: list[str] = []
    plugin_paths: list[str] = []
    # v0.3: how a new session's engine decides on tool use (the SDK's
    # ``permission_mode``); ``session.mode`` changes it per session.
    permission_mode: PermissionMode = "auto"
    update: UpdateConfig = UpdateConfig()
    # v0.4: the deployment's services, checked every
    # ``services_interval_seconds`` (at least 5) and shown in the app's
    # services menu.
    services: list[ServiceConfig] = []
    services_interval_seconds: int = Field(default=30, ge=5)
    # v0.8: the deployment's one restart and one status command.
    deployment: DeploymentConfig = DeploymentConfig()
    # v0.8: a session's title. ``generated`` asks a small model for one
    # after the first turn finishes cleanly (the first line until then, and
    # if the call fails); ``first_line`` makes no extra model call.
    # ``title_model`` overrides the model (default: the provider's small
    # model, by the alias ``haiku``).
    titles: Literal["generated", "first_line"] = "generated"
    title_model: str | None = None
    # v0.10: the agent's system prompt. ``claude_code`` is Claude Code's own
    # (the agent behaves as in a terminal); ``none`` is the SDK's empty
    # prompt, as before v0.10. ``system_prompt_append`` is a file of the
    # deployment's (outside the checkout) added after it, read at each
    # engine start. The viewer line always comes last.
    system_prompt: Literal["claude_code", "none"] = "claude_code"
    system_prompt_append: str | None = None
    # v0.11: started from the app, the gateway has launchd's bare PATH. With
    # ``login_shell_path`` it asks the person's login shell for theirs and
    # puts it first, so the engine and its MCP servers find npx, node, uvx
    # and the like. ``false`` keeps the inherited PATH.
    login_shell_path: bool = True

    @field_validator("title_model")
    @classmethod
    def _title_model_blank_is_unset(cls, value: str | None) -> str | None:
        return value.strip() if value is not None and value.strip() else None

    @field_validator("services")
    @classmethod
    def _service_ids_unique(cls, value: list[ServiceConfig]) -> list[ServiceConfig]:
        seen: set[str] = set()
        for service in value:
            if service.id in seen:
                raise ConfigError(f"services: id {service.id!r} is used twice; each service needs its own id")
            seen.add(service.id)
        return value

    @field_validator("brand", mode="before")
    @classmethod
    def _brand_from_protocol_brand(cls, value: Any) -> Any:
        # A plain protocol ``Brand`` (code and tests build one) is taken as its fields.
        if isinstance(value, Brand) and not isinstance(value, ConfigBrand):
            return value.model_dump()
        return value

    @field_validator("setting_sources")
    @classmethod
    def _sources_not_empty(cls, value: list[str]) -> list[str]:
        if not value:
            raise ConfigError(EMPTY_SETTING_SOURCES_MESSAGE)
        return value

    @field_validator("roots")
    @classmethod
    def _roots_absolute(cls, value: list[Root]) -> list[Root]:
        # The gateway is a detached process with no working directory a
        # person could mean: a root is an absolute path, written with a
        # leading ``~`` if they like. The expanded path is what ``hello``
        # carries and what ``files.list`` reads.
        out: list[Root] = []
        for root in value:
            path = Path(root.path).expanduser()
            if not path.is_absolute():
                raise ConfigError(
                    f"roots: {root.name!r} has the relative path {root.path!r}; a root must be an absolute path (~ is expanded)"
                )
            out.append(Root(name=root.name, path=str(path)))
        return out

    @field_validator("system_prompt_append")
    @classmethod
    def _append_file_exists(cls, value: str | None) -> str | None:
        if value is None or not value.strip():
            return None
        path = Path(value.strip()).expanduser()
        if not path.is_absolute():
            raise ConfigError(
                f"system_prompt_append: {value!r} is relative; it must be an absolute path (~ is expanded)"
            )
        if not path.is_file():
            raise ConfigError(f"system_prompt_append: {path} is not a file")
        return str(path)

    @field_validator("plugin_paths")
    @classmethod
    def _plugin_paths_absolute(cls, value: list[str]) -> list[str]:
        out: list[str] = []
        for raw in value:
            path = Path(raw).expanduser()
            if not path.is_absolute():
                raise ConfigError(
                    f"plugin_paths: {raw!r} is relative; a plug-in directory must be an absolute path (~ is expanded)"
                )
            out.append(str(path))
        return out


def _describe(path: Path, e: ValidationError) -> str:
    parts = []
    for err in e.errors():
        loc = ".".join(str(p) for p in err["loc"]) or "<root>"
        parts.append(f"{loc}: {err['msg']}")
    return f"{path}: " + "; ".join(parts)


def _validate(path: Path, data: dict[str, Any]) -> Config:
    try:
        return Config.model_validate(data)
    except ConfigError:
        raise
    except ValidationError as e:
        # A ConfigError raised inside a field validator is wrapped by
        # pydantic; surface its exact text rather than the wrapped form,
        # naming the top-level key it was raised for.
        for err in e.errors():
            ctx = err.get("ctx") or {}
            inner = ctx.get("error")
            if isinstance(inner, ConfigError):
                raise ConfigError(str(inner), keys=_top_keys([err])) from None
        raise ConfigError(_describe(path, e), keys=_top_keys(e.errors())) from e


def _top_keys(errors: Any) -> frozenset[str]:
    """The top-level config keys pydantic's errors are located under."""
    return frozenset(str(err["loc"][0]) for err in errors if err.get("loc"))


def load_config(path: Path) -> Config:
    """Read ``config.toml``; a missing file means defaults."""
    path = Path(path)
    if not path.exists():
        return Config()
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except OSError as e:
        raise ConfigError(f"{path}: cannot read: {e}") from e
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f"{path}: not valid TOML: {e}") from e
    return _validate(path, data)


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def hello_for(
    config: Config, epoch: str, gateway_version: str, plugins: Plugins | None = None, config_stale: bool = False
) -> HelloServer:
    """The ``hello`` the gateway sends first on every connection.

    ``can_log`` is true when renewing has a log step to run: ``log_prompt``
    is set or a plug-in provides ``on_renew``. Each plug-in's ``on_hello``
    then sees the result, in list order. ``config_stale`` is the server's
    reading of the config file's modification time; ``can_update`` is
    whether ``[update] run`` is set; ``permission_mode`` is the mode a new
    session starts in; ``commands`` lists ``log`` when the deployment can log.
    ``capabilities`` (v0.8) adds ``services.restart_all`` when the
    deployment can restart all its services.
    """
    can_log = bool(config.log_prompt) or (plugins is not None and plugins.renew is not None)
    capabilities = list(CAPABILITIES)
    if can_restart_all(config, plugins):
        capabilities.append(RESTART_ALL_CAPABILITY)
    hello = HelloServer(
        ts=_now(),
        gateway_version=gateway_version,
        epoch=epoch,
        brand=config.brand.for_hello(),
        actions=list(config.actions),
        roots=list(config.roots),
        # Portico's own commands the deployment offers (v0.4: ``log`` when it
        # can log; the app turns a typed ``/log`` into ``session.log``).
        commands=["log"] if can_log else [],
        capabilities=capabilities,
        presentation=config.presentation,
        can_log=can_log,
        config_stale=config_stale,
        can_update=bool(config.update.run),
        default_folder=str(Path(config.default_folder).expanduser()) if config.default_folder else None,
        permission_mode=config.permission_mode,
    )
    return plugins.on_hello(hello) if plugins is not None else hello


def can_restart_all(config: Config, plugins: Plugins | None = None) -> bool:
    """Whether Restart all services has something to run: a plug-in's ``restart_services`` or ``[deployment] restart``."""
    return bool(config.deployment.restart) or (plugins is not None and plugins.restart_services is not None)


def config_value(config: Config, dotted: str) -> Any:
    """The value at ``dotted`` (``brand.name``, ``update.run``…), or ``None`` when there is no such key."""
    node: Any = config
    for part in dotted.split("."):
        if isinstance(node, BaseModel):
            if part not in type(node).model_fields:
                return None
            node = getattr(node, part)
        elif isinstance(node, dict):
            node = node.get(part)
        else:
            return None
        if node is None:
            return None
    return node
