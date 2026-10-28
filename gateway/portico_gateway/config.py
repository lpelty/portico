"""The deployment's configuration and the ``hello`` built from it.

``config.toml`` lives in the state directory (``StateDir.config_path``). It
is read once at start; what a person sees of it goes out in ``hello``
(brand, actions, roots). Everything else steers the gateway itself.

Nothing here names a model, a provider, or a credential: those come from the
environment only.
"""

from __future__ import annotations

import tomllib
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from .messages import Action, Brand, HelloServer, Root

EMPTY_SETTING_SOURCES_MESSAGE = (
    "setting_sources must not be empty: an empty list drops the folder's instructions and hooks"
)

# What this gateway can do beyond the protocol's baseline; the app keys
# optional UI on these.
CAPABILITIES: list[str] = ["cards.form", "files", "producer"]


class ConfigError(ValueError):
    """``config.toml`` cannot be used; the message says which key and why."""


class Config(BaseModel):
    model_config = ConfigDict(extra="forbid")

    brand: Brand = Brand(name="Portico", agent_name="Agent")
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
        # pydantic; surface its exact text rather than the wrapped form.
        for err in e.errors():
            ctx = err.get("ctx") or {}
            inner = ctx.get("error")
            if isinstance(inner, ConfigError):
                raise inner from None
        raise ConfigError(_describe(path, e)) from e


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


def hello_for(config: Config, epoch: str, gateway_version: str) -> HelloServer:
    """The ``hello`` the gateway sends first on every connection."""
    return HelloServer(
        ts=_now(),
        gateway_version=gateway_version,
        epoch=epoch,
        brand=config.brand,
        actions=list(config.actions),
        roots=list(config.roots),
        commands=[],
        capabilities=list(CAPABILITIES),
    )
