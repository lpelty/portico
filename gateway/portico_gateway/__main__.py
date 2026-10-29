"""``portico-gateway`` command line.

Subcommands: ``run``, ``doctor``, ``check-env``, ``export-schema``, ``export-examples``. ``run`` holds the
state directory lock, serves until ``gateway.stop`` or SIGINT/SIGTERM, and exits 0 after ``on_stop``.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys
from pathlib import Path

from portico_gateway import REPO_ROOT, __version__
from portico_gateway.messages import canonical_json, example_messages, export_schema, to_json_obj

PROTOCOL_DIR = REPO_ROOT / "protocol"


def cmd_run(args: argparse.Namespace) -> int:
    """Run the gateway until ``gateway.stop`` or SIGINT/SIGTERM. Refuses a second copy on the same state directory."""
    from portico_gateway.config import ConfigError, hello_for, load_config
    from portico_gateway.lifecycle import AlreadyRunning, single_instance
    from portico_gateway.plugins import PluginError, load_plugins
    from portico_gateway.state import StateDir, StateError

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    try:
        state = StateDir(Path(args.state).expanduser() if args.state else None)
        config = load_config(Path(args.config).expanduser() if args.config else state.config_path)
        plugins = load_plugins(config.plugins, config.plugin_paths)
        hello_for(config, "start", __version__, plugins)  # a plug-in's on_hello fails here, not at the app's connect
        single_instance(state)
    except (ConfigError, PluginError, StateError, AlreadyRunning, OSError) as e:
        print(f"portico-gateway: {e}", file=sys.stderr)
        return 1
    try:
        return asyncio.run(_run_server(config, state, args.port, plugins=plugins))
    except StateError as e:
        print(f"portico-gateway: {e}", file=sys.stderr)
        return 1
    finally:
        state.release_lock()


async def _run_server(config, state, port: int, engine_factory=None, plugins=None) -> int:  # noqa: ANN001 - types live in the modules below
    """Serve until ``stop`` has run (``gateway.stop`` from the app, or a stop signal), then shut down; exit 0."""
    from portico_gateway.chats import ChatRegistry
    from portico_gateway.lifecycle import install_stop_signals
    from portico_gateway.server import GatewayServer

    if engine_factory is None:
        from portico_gateway.engine import SDKEngine

        engine_factory = SDKEngine
    registry = ChatRegistry(index=state.load_index(), state=state, history_buffer=config.history_buffer)
    server = GatewayServer(
        config=config, state=state, registry=registry, engine_factory=engine_factory, version=__version__, plugins=plugins
    )
    install_stop_signals(asyncio.get_running_loop(), server.request_stop)
    await server.serve(port)
    try:
        await server.stopping.wait()
    finally:
        await server.shutdown()
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    """Print one line per check; exit 1 when any check fails."""
    from portico_gateway.doctor import doctor, format_check
    from portico_gateway.state import StateDir

    state = StateDir(Path(args.state).expanduser() if args.state else None)
    config_path = Path(args.config).expanduser() if args.config else state.config_path
    checks = doctor(state, config_path)
    for check in checks:
        print(format_check(check))
    failed = sum(1 for c in checks if not c.ok)
    warned = sum(1 for c in checks if c.ok and c.warn)
    note = f" ({warned} warning{'s' if warned != 1 else ''})" if warned else ""
    print((f"{len(checks) - failed} of {len(checks)} checks passed" if failed else f"all {len(checks)} checks passed") + note)
    return 1 if failed else 0


def cmd_check_env(args: argparse.Namespace) -> int:
    """Exit 0 when every line of the env file is ``KEY=value``; else print the bad line numbers and exit 1.

    The same parser ``run`` and ``doctor`` load the file with; the file is never
    sourced by a shell. A line's content is never printed: it may hold a credential.
    """
    from portico_gateway.doctor import env_file_bad_lines

    path = Path(args.path)
    if not path.is_file():
        return 0
    try:
        bad = env_file_bad_lines(path)
    except OSError as e:
        print(f"{path} could not be read: {e}", file=sys.stderr)
        return 1
    if bad:
        print(" ".join(str(n) for n in bad[:3]))
        return 1
    return 0


def _state_and_config_path(args: argparse.Namespace):  # noqa: ANN202 - StateDir lives in state.py
    from portico_gateway.state import StateDir

    state = StateDir(Path(args.state).expanduser() if getattr(args, "state", None) else None)
    config_path = Path(args.config).expanduser() if getattr(args, "config", None) else state.config_path
    return state, config_path


def cmd_config_value(args: argparse.Namespace) -> int:
    """Print one config value (``brand.name``, ``brand.app_icon``…) or nothing; exit 0.

    Strings print as they are, booleans as ``true``/``false``, lists and
    tables as JSON. An unknown or unset key prints nothing. A config file
    that does not load is the one failure: its reason on stderr, exit 1.
    """
    import json

    from portico_gateway.config import ConfigError, config_value, load_config

    _, config_path = _state_and_config_path(args)
    try:
        config = load_config(config_path)
    except ConfigError as e:
        print(f"portico-gateway: {e}", file=sys.stderr)
        return 1
    value = config_value(config, args.key)
    if value is None:
        return 0
    if isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, (str, int, float)):
        print(value)
    else:
        print(json.dumps(value, default=lambda o: o.model_dump(mode="json")))
    return 0


def cmd_export_schema(args: argparse.Namespace) -> int:
    out = Path(args.out) if args.out else PROTOCOL_DIR / "schema" / "portico.schema.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(canonical_json(export_schema()), encoding="utf-8")
    print(f"wrote {out}")
    return 0


def cmd_export_examples(args: argparse.Namespace) -> int:
    out_dir = Path(args.out) if args.out else PROTOCOL_DIR / "examples"
    out_dir.mkdir(parents=True, exist_ok=True)
    examples = example_messages()
    for key, msg in sorted(examples.items()):
        (out_dir / f"{key}.json").write_text(canonical_json(to_json_obj(msg)), encoding="utf-8")
    print(f"wrote {len(examples)} examples to {out_dir}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="portico-gateway", description="Portico reference gateway")
    parser.add_argument("--version", action="version", version=f"portico-gateway {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("run", help="run the gateway (prints PORTICO_READY port=<n> once listening)")
    p.add_argument("--port", type=int, default=0, help="port on 127.0.0.1; 0 (default) picks a free one")
    p.add_argument("--state", help="state directory (default: $PORTICO_HOME or ~/.portico)")
    p.add_argument("--config", help="config file (default: <state>/config.toml)")
    p.add_argument("--verbose", action="store_true", help="debug logging on stderr")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("doctor", help="check this machine, the state directory and the config; one line per check")
    p.add_argument("--state", help="state directory (default: $PORTICO_HOME or ~/.portico)")
    p.add_argument("--config", help="config file (default: <state>/config.toml)")
    p.set_defaults(func=cmd_doctor)

    p = sub.add_parser("check-env", help="exit 1 and print the line numbers when an env file has a line that is not KEY=value")
    p.add_argument("path", help="the env file to check; a missing file passes")
    p.set_defaults(func=cmd_check_env)

    p = sub.add_parser("config-value", help="print one config value (e.g. brand.name, brand.app_icon), or nothing")
    p.add_argument("key", help="dotted key: brand.name, brand.app_icon, update.run, ...")
    p.add_argument("--state", help="state directory (default: $PORTICO_HOME or ~/.portico)")
    p.add_argument("--config", help="config file (default: <state>/config.toml)")
    p.set_defaults(func=cmd_config_value)

    p = sub.add_parser("export-schema", help="write protocol/schema/portico.schema.json from the models")
    p.add_argument("--out", help="write the schema to this path instead")
    p.set_defaults(func=cmd_export_schema)

    p = sub.add_parser("export-examples", help="write protocol/examples/<direction>.<type>.json from the models")
    p.add_argument("--out", help="write the examples into this directory instead")
    p.set_defaults(func=cmd_export_examples)

    return parser


def _load_env_file(args: argparse.Namespace) -> None:
    """Load ``<state>/env`` into this process's environment before ``run`` or ``doctor``.

    Values are literal (never sourced by a shell). Variables already set win. A
    malformed file loads nothing and is named by line number on stderr; the
    doctor then reports it as its ``env`` check, so this never stops the command.
    """
    import os

    from portico_gateway.doctor import ENV_FILE, EnvFileError, apply_env_file
    from portico_gateway.state import StateDir

    state_arg = getattr(args, "state", None)
    path = (Path(state_arg).expanduser() if state_arg else StateDir.default_path()) / ENV_FILE
    try:
        apply_env_file(path, os.environ)
    except EnvFileError as e:
        print(f"portico-gateway: {path} not loaded: {e}; run bin/doctor", file=sys.stderr)
    except OSError as e:
        print(f"portico-gateway: {path} not loaded: {e}; run bin/doctor", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command in ("run", "doctor"):
        _load_env_file(args)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
