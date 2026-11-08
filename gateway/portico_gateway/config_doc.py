"""v0.24 §5–6: one entry per config key, and what is built from them.

``KEY_DOCS`` documents every key the config models define (a test fails
when the two differ, so the reference can't drift). From it and the
models come ``config show`` (each key's value in force and where it came
from), ``CONFIGURATION.md`` and ``config.example.toml``.

The entries live here rather than in the models' field descriptions
because ``brand``, ``actions`` and ``roots`` are protocol models whose
published schema would change with config prose (v0.24 ruling 8).
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Literal, get_args, get_origin

from pydantic import BaseModel
from pydantic_core import PydanticUndefined

from .config import Config, ConfigLayers

Scope = Literal["deployment", "personal", "either"]

GW = "gateway restart"
PROMPT_APPLIES = "gateway restart; the prompt then applies to the next new or renewed session (a running session keeps its prompt until it compacts)"
FILE_APPLIES = "the file's text: the next new or renewed session; the key itself: gateway restart"
REINSTALL = "reinstall (bin/install)"


@dataclass(frozen=True)
class KeyDoc:
    """One key: what it means, an example (a TOML line), when a change applies, where it usually belongs."""

    text: str
    example: str
    applies: str = GW
    scope: Scope = "deployment"
    sensitive: bool = False


# Grouping for ``config show`` and the reference, in the README's order; newer sections last.
SECTION_ORDER: list[str] = [
    "general", "brand", "update", "deployment", "actions", "services", "roots", "sessions", "threads",
    "files", "viewer", "links", "apps", "mcp", "spaces", "person", "voice",
]

# Fields of shared models the gateway fills itself; never set in config.
NOT_CONFIG = frozenset({"roots[].extra", "roots[].missing"})

KEY_DOCS: dict[str, KeyDoc] = {
    # --- general ---------------------------------------------------------------------
    "setting_sources": KeyDoc(
        "Which Claude Code settings the agent loads: `user`, `project` (the folder's CLAUDE.md, skills, hooks), `local`. Never empty: an empty list drops the folder's instructions and hooks.",
        'setting_sources = ["user", "project"]',
    ),
    "before_first_chat": KeyDoc("A command (/bin/sh -c) run once per launch before the first engine starts.", 'before_first_chat = "bin/prepare"'),
    "on_stop": KeyDoc("A command (/bin/sh -c) run on the way out, when the gateway stops.", 'on_stop = "bin/cleanup"'),
    "command_timeout_seconds": KeyDoc("How long a deployment command (before_first_chat, on_stop, restarts, update) may run. At least 1.", "command_timeout_seconds = 120"),
    "default_folder": KeyDoc("Where a new session works when the person has not chosen a folder.", 'default_folder = "~/work"', scope="either"),
    "card_hold_seconds": KeyDoc("How long a permission card waits with no app attached before it is denied; 0 denies at once.", "card_hold_seconds = 600"),
    "history_buffer": KeyDoc("Events kept per chat so a reconnecting app catches up. At least 1.", "history_buffer = 2000"),
    "presentation": KeyDoc('`"single"`: one live session at a time, renewed; `"multiple"`: a list of chats.', 'presentation = "single"'),
    "log_prompt": KeyDoc("The log step (Log session, /log, and a renewal first), sent as a message; unset means no log step.", 'log_prompt = "/session-close"'),
    "plugins": KeyDoc("Plug-in modules, imported at start.", 'plugins = ["my_deployment_plugin"]'),
    "plugin_paths": KeyDoc("Absolute folders put on the import path for the plug-ins (outside the checkout).", 'plugin_paths = ["~/my-plugins"]'),
    "permission_mode": KeyDoc(
        'A new session\'s mode: `"auto"` (the engine\'s classifier decides), `"acceptEdits"` (file edits allowed), `"default"` (ask each time).',
        'permission_mode = "auto"', scope="either",
    ),
    "services_interval_seconds": KeyDoc("How often the [[services]] checks run. At least 5.", "services_interval_seconds = 30"),
    "titles": KeyDoc(
        '`"generated"`: after a session\'s first clean turn a small model names it; `"first_line"`: the first line of the first message, no extra model call.',
        'titles = "generated"', scope="either",
    ),
    "title_model": KeyDoc('The model for generated titles; unset is "haiku", the provider\'s small model.', 'title_model = "my-small-model"'),
    "system_prompt": KeyDoc(
        '`"claude_code"` (or `"default"`): Claude Code\'s own prompt, which updates with Claude Code. `"custom"`: system_prompt_file\'s text is the whole prompt. `"none"` (legacy): the SDK\'s empty prompt. Portico\'s own lines always come last.',
        'system_prompt = "custom"', applies=PROMPT_APPLIES, scope="either",
    ),
    "system_prompt_file": KeyDoc(
        'The whole prompt, as an absolute path, required with system_prompt = "custom" and ignored otherwise. Read at each engine start. `bin/portico-gateway capture-prompt` makes a starting copy.',
        'system_prompt_file = "~/prompts/mine.md"', applies=FILE_APPLIES, scope="personal",
    ),
    "system_prompt_append": KeyDoc(
        "An absolute path to text added after the prompt, in any mode. Read at each engine start.",
        'system_prompt_append = "~/my-deployment/prompt.md"', applies=FILE_APPLIES,
    ),
    "login_shell_path": KeyDoc("The engine gets the person's login-shell PATH first, so it finds npx, node, uvx; false keeps the inherited PATH.", "login_shell_path = true"),
    # --- brand ------------------------------------------------------------------------
    "brand.name": KeyDoc("The product name the app shows.", 'name = "Acme"'),
    "brand.agent_name": KeyDoc("What the agent is called in the app.", 'agent_name = "Ace"'),
    "brand.accent": KeyDoc("The accent colour, CSS hex.", 'accent = "#3B6EF5"'),
    "brand.icon": KeyDoc("An image for the mark; a flat square is rounded in the macOS icon shape.", 'icon = "/path/to/icon.png"'),
    "brand.header_image": KeyDoc("An absolute path to an image that replaces the mark and name in the toolbar, 28 pt tall (SVG or PDF stays sharp).", 'header_image = "/path/to/lockup.svg"'),
    "brand.version": KeyDoc("The deployment's version; the About panel shows it in place of the app's.", 'version = "1.4.0"'),
    "brand.about": KeyDoc('The About panel\'s text under the version; {app_version} and {built} are filled in, "" shows nothing.', 'about = "Questions: help@example.com"'),
    "brand.app_icon": KeyDoc("A 1024×1024 PNG for the app bundle (bin/install); never sent to the app.", 'app_icon = "~/icons/app.png"', applies=REINSTALL),
    "brand.app_icon_assets": KeyDoc("A precompiled asset catalog (Assets.car) for the app bundle; with app_icon_name.", 'app_icon_assets = "~/icons/Assets.car"', applies=REINSTALL),
    "brand.app_icon_name": KeyDoc("The icon's name inside app_icon_assets.", 'app_icon_name = "AppIcon"', applies=REINSTALL),
    # --- update -----------------------------------------------------------------------
    "update.check": KeyDoc("A command that exits 0 and prints a version when an update is available.", 'check = "my-tool update --check"'),
    "update.run": KeyDoc("A command that performs the update; the app's Update available runs it.", 'run = "my-tool update"'),
    # --- deployment -------------------------------------------------------------------
    "deployment.restart": KeyDoc("One command that restarts all the deployment's services (Restart all services).", 'restart = "my-tool restart-all"'),
    "deployment.status": KeyDoc('One command printing {"services": [...]} rows that replace the [[services]] checks.', 'status = "my-tool status --json"'),
    # --- actions ----------------------------------------------------------------------
    "actions": KeyDoc("Buttons in the input bar; each sends its text.", '[[actions]] label = "Review", text = "/review"', scope="either"),
    "actions[].label": KeyDoc("The button's label.", 'label = "Review"', scope="either"),
    "actions[].text": KeyDoc("What the button sends.", 'text = "/review"', scope="either"),
    # --- services ---------------------------------------------------------------------
    "services": KeyDoc("What the deployment depends on, shown in the app's services menu.", '[[services]] id = "memory", name = "Memory", check = "…"'),
    "services[].id": KeyDoc("Unique; lowercase letters, digits and dashes.", 'id = "memory"'),
    "services[].name": KeyDoc("The name the menu shows.", 'name = "Memory"'),
    "services[].check": KeyDoc("A command (/bin/sh -c): exit 0 is up, 75 is stuck, anything else down.", 'check = "curl -sf http://localhost:8888/health"'),
    "services[].restart": KeyDoc("A command the menu's Restart runs.", 'restart = "my-tool restart memory"'),
    "services[].up_detail": KeyDoc("A line shown while it is up.", 'up_detail = "recall and capture"'),
    "services[].timeout_seconds": KeyDoc("The check is killed after this. At least 1.", "timeout_seconds = 10"),
    # --- roots ------------------------------------------------------------------------
    "roots": KeyDoc("Folders the Files pane can browse.", '[[roots]] name = "projects", path = "~/projects"', scope="either"),
    "roots[].name": KeyDoc("The folder's name in the pane.", 'name = "projects"', scope="either"),
    "roots[].path": KeyDoc("An absolute path; a leading ~ is expanded.", 'path = "~/projects"', scope="either"),
    # --- sessions ---------------------------------------------------------------------
    "sessions.next_number": KeyDoc("A command whose output is the next session's number.", 'next_number = "my-tool next-session"'),
    "sessions.lock_folder": KeyDoc('True fixes "Works in" to the deployment\'s folder.', "lock_folder = false"),
    # --- threads ----------------------------------------------------------------------
    "threads.max": KeyDoc("Threads open beside Main, 0 to 2; 0 turns threads off.", "max = 2", scope="either"),
    # --- files ------------------------------------------------------------------------
    "files.hide_session_folder": KeyDoc("True lists only the [[roots]] in the Files pane, not the session's own folder.", "hide_session_folder = false", scope="either"),
    # --- viewer -----------------------------------------------------------------------
    "viewer.agent_can_see": KeyDoc("The default for Settings › Agent can see the viewer.", "agent_can_see = true", scope="either"),
    "viewer.agent_checks_html": KeyDoc("The default for Settings › Agent checks HTML it creates.", "agent_checks_html = true", scope="either"),
    "viewer.act_hosts": KeyDoc("Outside sites the agent may click and type on (bare host names; subdomains included).", 'act_hosts = ["figma.com"]'),
    "viewer.properties": KeyDoc('How a Markdown page\'s Properties first open: `"folded"` or `"open"`.', 'properties = "folded"', scope="either"),
    # --- links ------------------------------------------------------------------------
    "links.sites": KeyDoc("Host (or a parent domain) to the name a link chip shows.", 'sites = { "tracker.example.com" = "Tracker" }'),
    # --- apps -------------------------------------------------------------------------
    "apps.enabled": KeyDoc("MCP Apps: a tool's page shown in the chat; false keeps every tool a plain row.", "enabled = true"),
    # --- mcp --------------------------------------------------------------------------
    "mcp.core": KeyDoc("Servers in the folder's .mcp.json that are part of the deployment itself.", 'core = ["tracker"]'),
    # --- spaces -----------------------------------------------------------------------
    "spaces.folder": KeyDoc("A folder of pages the agent keeps current; must exist. Unset: <state dir>/spaces.", 'folder = "~/Spaces"', scope="either"),
    "spaces.refresh": KeyDoc("A command run for Refresh, with $PORTICO_SPACE set.", 'refresh = "my-tool refresh-space"'),
    "spaces.remove": KeyDoc("A command run after a space's file is moved to the Trash.", 'remove = "my-tool forget-space"'),
    "spaces.act": KeyDoc("A command for space-action: links, with $PORTICO_ACTION and $PORTICO_ITEM.", 'act = "my-tool space-action"'),
    "spaces.require_folder": KeyDoc("A page is a space only with a folder of its name beside it.", "require_folder = true"),
    # --- person -----------------------------------------------------------------------
    "person.name": KeyDoc("The person's real name for comments; unset uses the computer's full user name.", 'name = "Sam Rivera"', scope="personal"),
    # --- voice ------------------------------------------------------------------------
    "voice.read_aloud": KeyDoc(
        "Read aloud on each reply: true shows the switch in Settings; the person's on/off choice stays in the app.",
        "read_aloud = true", applies="gateway restart (the app follows when it reconnects)", scope="personal",
    ),
}


def _model_of(annotation: Any) -> tuple[type[BaseModel] | None, bool]:
    if isinstance(annotation, type) and issubclass(annotation, BaseModel):
        return annotation, False
    if get_origin(annotation) is list:
        (inner,) = get_args(annotation)
        if isinstance(inner, type) and issubclass(inner, BaseModel):
            return inner, True
    return None, False


def model_keys(model: type[BaseModel] = Config, prefix: str = "") -> list[str]:
    """Every config key the models define, dotted; a list of tables is ``name`` and ``name[].field``."""
    out: list[str] = []
    for name, field in model.model_fields.items():
        key = prefix + name
        inner, is_list = _model_of(field.annotation)
        if inner is None:
            out.append(key)
        elif is_list:
            out.append(key)
            out += [k for k in model_keys(inner, key + "[].") if k not in NOT_CONFIG]
        else:
            out += model_keys(inner, key + ".")
    return out


def section_of(key: str) -> str:
    head = key.split(".", 1)[0].split("[", 1)[0]
    return head if head in SECTION_ORDER and ("." in key or "[" in key or head in ("actions", "services", "roots")) else "general"


def show_keys() -> list[str]:
    """The keys ``config show`` lists: every scalar, and each list of tables as one row; in section order."""
    keys = [k for k in model_keys() if "[]" not in k]
    return sorted(keys, key=lambda k: (SECTION_ORDER.index(section_of(k)), model_keys().index(k)))


def _lookup(node: Any, dotted: str) -> Any:
    for part in dotted.split("."):
        node = getattr(node, part)
    return node


def _plain(value: Any) -> Any:
    if isinstance(value, BaseModel):
        return value.model_dump(mode="json", exclude_defaults=True)
    if isinstance(value, list):
        return [_plain(v) for v in value]
    if isinstance(value, dict):
        return {k: _plain(v) for k, v in value.items()}
    return value


def format_value(value: Any) -> str:
    """A value as a TOML-like literal: strings quoted, booleans lowercase, lists and tables as JSON; ``None`` is ``(not set)``."""
    if value is None:
        return "(not set)"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return json.dumps(_plain(value), ensure_ascii=False)


def default_of(key: str) -> Any:
    """The key's default as the models give it (``None`` for an unset optional; ``required`` keys have none)."""
    model: type[BaseModel] = Config
    parts = key.split(".")
    for part in parts[:-1]:
        model = _model_of(model.model_fields[part].annotation)[0]  # type: ignore[assignment]
    field = model.model_fields[parts[-1]]
    if field.default is PydanticUndefined and field.default_factory is None:
        return _lookup(Config(), key)
    return field.get_default(call_default_factory=True)


@dataclass
class ShowRow:
    key: str
    value: Any
    default: Any
    source: str
    applies: str
    note: str = ""
    sensitive: bool = False

    @property
    def changed(self) -> bool:
        return _plain(self.value) != _plain(self.default)


def _prompt_note(config: Config) -> str:
    from .engine import prompt_header_version

    if config.system_prompt != "custom" or not config.system_prompt_file:
        return ""
    version = prompt_header_version(config.system_prompt_file)
    seen = f"captured from Claude Code {version}" if version else "no capture header"
    return f"file {config.system_prompt_file} ({seen})"


def show_rows(layers: ConfigLayers, config: Config) -> list[ShowRow]:
    """Every key with its value in force, its default, where the value came from and when a change applies."""
    rows: list[ShowRow] = []
    for key in show_keys():
        doc = KEY_DOCS[key]
        note = ""
        if key == "system_prompt":
            note = _prompt_note(config)
        elif key == "system_prompt_file" and config.system_prompt_file and config.system_prompt != "custom":
            note = 'ignored unless system_prompt = "custom"'
        rows.append(
            ShowRow(
                key=key,
                value=_lookup(config, key),
                default=default_of(key),
                source=layers.source_of(key),
                applies=doc.applies,
                note=note,
                sensitive=doc.sensitive,
            )
        )
    return rows


def _shown(row: ShowRow) -> str:
    if row.sensitive:
        return "(not set)" if row.value in (None, "", [], {}) else "(set)"
    return format_value(row.value)


def format_show(rows: list[ShowRow], changed: bool = False) -> str:
    """``config show``'s text: by section, ``key = value  [source]  (applies)`` and any note."""
    lines: list[str] = []
    current = None
    for row in rows:
        if changed and not row.changed:
            continue
        section = section_of(row.key)
        if section != current:
            if lines:
                lines.append("")
            lines.append(f"[{section}]")
            current = section
        line = f"{row.key} = {_shown(row)}  [{row.source}]  ({row.applies})"
        if row.note:
            line += f"  · {row.note}"
        lines.append(line)
    if not lines:
        return "every key is at its default"
    return "\n".join(lines)


def rows_json(rows: list[ShowRow], changed: bool = False) -> list[dict[str, Any]]:
    """The same rows for agents: key, value, default, source, applies, note (secrets as ``(set)``)."""
    out = []
    for row in rows:
        if changed and not row.changed:
            continue
        out.append(
            {
                "key": row.key,
                "section": section_of(row.key),
                "value": _shown(row) if row.sensitive else _plain(row.value),
                "default": None if row.sensitive else _plain(row.default),
                "source": row.source,
                "applies": row.applies,
                "note": row.note,
            }
        )
    return out


# --- §6: CONFIGURATION.md and config.example.toml -------------------------------------

GENERATED = "Generated by `bin/portico-gateway export-config-doc` from `gateway/portico_gateway/config_doc.py`; edit there, not here."

INTRO = """# Configuration

<!-- {generated} -->

Two files in the state folder (`~/.portico/` unless `PORTICO_HOME` or `--state` says otherwise) configure
the gateway, and both are optional:

- **`config.toml`** is the deployment's: what every person using it gets. An update may replace it.
- **`config.local.toml`**, beside it, is the person's own overrides. Nothing writes it but the person (or an
  agent they ask). Tables merge key by key; any other value, arrays included, replaces the deployment's
  (a local `[[services]]` list replaces the whole list). Any key may be overridden.

The merged result is checked as one file; an error names the file and the key, and an invalid file stops
the gateway from starting (`bin/doctor` says why). A deployment that keeps its `config.toml` in a git
repository adds `config.local.toml` to that repository's `.gitignore`.

## For an agent asked to "change X for me"

1. Put a person's change in `config.local.toml`; put the deployment's change in `config.toml`.
2. Run `bin/portico-gateway config show` before and after (`--changed` for only what differs from the
   defaults, `--json` to read it). Each key shows its value in force and where it came from:
   `[default]`, `[config.toml]` or `[config.local.toml]`.
3. Say what the change needs: most keys apply after a gateway restart (`bin/portico-gateway stop`; the app
   starts a fresh one and says when one is needed); the entries below say which apply sooner or later.
4. Never edit `config.toml` for a personal preference.

"""

SCOPE_TEXT: dict[str, str] = {
    "deployment": "the deployment's `config.toml`",
    "personal": "commonly a personal override in `config.local.toml`",
    "either": "either: the deployment sets a default, a person often overrides it",
}

SECTION_TITLES: dict[str, str] = {
    "general": "General (top-level keys)",
    "actions": "[[actions]]",
    "services": "[[services]]",
    "roots": "[[roots]]",
}


def _field(key: str) -> Any:
    model: type[BaseModel] = Config
    parts = key.replace("[]", "").split(".")
    for part in parts[:-1]:
        model = _model_of(model.model_fields[part].annotation)[0]  # type: ignore[assignment]
    return model.model_fields[parts[-1]]


def type_name(annotation: Any) -> str:
    """A key's type in words: ``text``, ``whole number``, ``true/false``, ``list of text``, ``one of "a", "b"``…"""
    origin = get_origin(annotation)
    args = [a for a in get_args(annotation) if a is not type(None)]
    if origin is Literal:
        return "one of " + ", ".join(f'"{a}"' for a in get_args(annotation))
    if origin is list:
        inner = args[0] if args else Any
        if isinstance(inner, type) and issubclass(inner, BaseModel):
            return "list of tables"
        return f"list of {type_name(inner)}"
    if origin is dict:
        return "table of text"
    if args and len(args) == 1 and origin is not None:
        return type_name(args[0]) + " (optional)"
    return {str: "text", int: "whole number", bool: "true/false", float: "number"}.get(annotation, str(annotation))


def _default_text(key: str) -> str:
    field = _field(key)
    if "[]" in key:
        if field.default is PydanticUndefined and field.default_factory is None:
            return "required"
        return format_value(field.get_default(call_default_factory=True)).replace("(not set)", "not set")
    return format_value(default_of(key)).replace("(not set)", "not set")


def _sections() -> list[tuple[str, list[str]]]:
    keys = model_keys()
    out = []
    for section in SECTION_ORDER:
        members = [k for k in keys if section_of(k) == section]
        if members:
            out.append((section, members))
    return out


def render_markdown() -> str:
    """``CONFIGURATION.md``: the introduction, then every key by section with its meaning, type, default, example, when it applies and where it belongs."""
    parts = [INTRO.format(generated=GENERATED)]
    for section, keys in _sections():
        title = SECTION_TITLES.get(section, f"[{section}]")
        parts.append(f"## {title}\n")
        for key in keys:
            doc = KEY_DOCS[key]
            parts.append(f"### `{key}`\n")
            parts.append(f"{doc.text}\n")
            parts.append(f"- **Type:** {type_name(_field(key).annotation)} · **Default:** `{_default_text(key)}`")
            parts.append(f"- **Example:** `{doc.example}`")
            parts.append(f"- **Applies:** {doc.applies}")
            parts.append(f"- **Belongs in:** {SCOPE_TEXT[doc.scope]}\n")
    return "\n".join(parts).rstrip() + "\n"


def _comment(text: str, width: int = 100) -> list[str]:
    import textwrap

    return ["## " + line for line in textwrap.wrap(text, width - 3)]


def render_example() -> str:
    """``config.example.toml``: every key commented out at its default, by section, each with its meaning.

    Lines starting ``## `` explain; ``# key = value`` lines are the defaults
    (uncomment to change one); a key unset by default shows its example as
    ``## e.g. …``. A list of tables is one commented sample.
    """
    lines = [
        f"## {GENERATED}",
        "## Copy what you change into config.toml (the deployment's) or config.local.toml (a person's own).",
        "## The reference, with when each change applies: CONFIGURATION.md.",
        "",
    ]
    for section, keys in _sections():
        lines.append("")
        if section in ("actions", "services", "roots"):
            lines += _comment(KEY_DOCS[section].text)
            lines.append(f"# [[{section}]]")
            for key in keys[1:]:
                field_doc = KEY_DOCS[key]
                lines.append(f"#   {field_doc.example}    ## {_default_text(key)}")
            continue
        if section != "general":
            lines.append(f"# [{section}]")
        for key in keys:
            doc = KEY_DOCS[key]
            lines += _comment(doc.text)
            name = key.rsplit(".", 1)[-1]
            default = default_of(key)
            if default is None:
                lines.append(f"## e.g. {doc.example}  (not set by default)")
            else:
                lines.append(f"# {name} = {format_value(default)}")
    return "\n".join(lines).rstrip() + "\n"
