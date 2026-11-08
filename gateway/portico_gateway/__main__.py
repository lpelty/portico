"""``portico-gateway`` command line.

Subcommands: ``run``, ``stop``, ``status``, ``update``, ``doctor``, ``config-value``, ``check-env``,
``sessions`` (list, clear), ``config show``, ``message``, ``capture-prompt``, ``export-schema``, ``export-examples``, ``export-config-doc``. ``run`` holds the state directory lock, serves until
``gateway.stop`` or SIGINT/SIGTERM, and exits 0 after ``on_stop``. ``stop`` sends that SIGTERM to the
gateway holding the lock and waits for it; ``status`` asks the running gateway what it is doing.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys
from pathlib import Path

from portico_gateway import REPO_ROOT, __version__
from portico_gateway.messages import canonical_json, example_messages, example_variants, export_schema, to_json_obj

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
        _export_home(state, given=bool(args.state))
        config_path = Path(args.config).expanduser() if args.config else state.config_path
        config = load_config(config_path)
        plugins = load_plugins(config.plugins, config.plugin_paths)
        hello_for(config, "start", __version__, plugins)  # a plug-in's on_hello fails here, not at the app's connect
        single_instance(state)
    except (ConfigError, PluginError, StateError, AlreadyRunning, OSError) as e:
        print(f"portico-gateway: {e}", file=sys.stderr)
        return 1
    if config.login_shell_path:
        import os

        from portico_gateway.shellpath import apply_login_shell_path

        if apply_login_shell_path(os.environ):
            _env_file_path_first(args)
    try:
        return asyncio.run(_run_server(config, state, args.port, plugins=plugins, config_path=config_path))
    except StateError as e:
        print(f"portico-gateway: {e}", file=sys.stderr)
        return 1
    finally:
        state.release_lock()


async def _run_server(config, state, port: int, engine_factory=None, plugins=None, config_path=None) -> int:  # noqa: ANN001 - types live in the modules below
    """Serve until ``stop`` has run (``gateway.stop`` from the app, or a stop signal), then shut down; exit 0."""
    from portico_gateway.chats import ChatRegistry
    from portico_gateway.lifecycle import install_stop_signals
    from portico_gateway.server import GatewayServer

    if engine_factory is None:
        from portico_gateway.engine import SDKEngine

        engine_factory = SDKEngine
    titler = None
    if config.titles == "generated":
        from portico_gateway.titles import sdk_titler

        titler = sdk_titler(state.path, config.setting_sources)
    registry = ChatRegistry(
        index=state.load_index(), state=state, history_buffer=config.history_buffer, default_mode=config.permission_mode
    )
    server = GatewayServer(
        config=config,
        state=state,
        registry=registry,
        engine_factory=engine_factory,
        version=__version__,
        plugins=plugins,
        config_path=config_path,
        titler=titler,
    )
    install_stop_signals(asyncio.get_running_loop(), server.request_stop)
    await server.serve(port)
    try:
        await server.stopping.wait()
    finally:
        await server.shutdown()
    return 0


def _export_home(state, given: bool) -> None:  # noqa: ANN001 - StateDir lives in state.py
    """v0.17: what the gateway starts (plug-ins, service checks, ``portico-gateway`` itself) uses its folder.

    ``PORTICO_HOME`` is this folder; ``PORTICO_HOME_SOURCE`` says where it came
    from, unless the app that started this gateway already said (``Info.plist``).
    """
    import os

    from portico_gateway.state import ENV_HOME, ENV_HOME_SOURCE, StateDir

    if not os.environ.get(ENV_HOME_SOURCE):
        os.environ[ENV_HOME_SOURCE] = "--state" if given else StateDir.default_source()
    os.environ[ENV_HOME] = str(state.path)


def cmd_doctor(args: argparse.Namespace) -> int:
    """Print one line per check; exit 1 when any check fails."""
    from portico_gateway.doctor import doctor, format_check
    from portico_gateway.state import StateDir

    state = StateDir(Path(args.state).expanduser() if args.state else None)
    config_path = Path(args.config).expanduser() if args.config else state.config_path
    checks = doctor(state, config_path, state_given=bool(args.state))
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


def cmd_config_show(args: argparse.Namespace) -> int:
    """v0.24 §5: every key with its value in force and where it came from; no gateway needed."""
    import json

    from portico_gateway.config import ConfigError, load_config, read_config_layers
    from portico_gateway.config_doc import format_show, rows_json, show_rows

    _, config_path = _state_and_config_path(args)
    try:
        layers = read_config_layers(config_path)
        config = load_config(config_path)
    except ConfigError as e:
        print(f"portico-gateway: {e}", file=sys.stderr)
        return 1
    rows = show_rows(layers, config)
    if args.json:
        print(json.dumps(rows_json(rows, changed=args.changed), ensure_ascii=False))
    else:
        print(f"# {layers.base_path} with {layers.local_path.name} over it" + ("" if layers.local_path.exists() else " (absent)"))
        print(format_show(rows, changed=args.changed))
    return 0


# Exit code of ``stop`` and ``status`` when no gateway runs on the state directory.
EXIT_NONE_RUNNING = 3


def cmd_stop(args: argparse.Namespace) -> int:
    """Stop the gateway running on this state directory; exit 0 when one was stopped, 3 when none ran."""
    from portico_gateway.config import ConfigError, load_config
    from portico_gateway.status import stop_gateway

    state, config_path = _state_and_config_path(args)
    timeout = args.timeout
    if timeout is None:
        # The stop runs the deployment's ``on_stop``, bounded by its timeout; then a margin.
        try:
            timeout = float(load_config(config_path).command_timeout_seconds) + 30.0
        except ConfigError:
            timeout = 150.0
    try:
        pid = stop_gateway(state, timeout)
    except TimeoutError as e:
        print(f"portico-gateway: {e}", file=sys.stderr)
        return 1
    if pid is None:
        print(f"no gateway running on {state.path}")
        return EXIT_NONE_RUNNING
    print(f"stopped the gateway (pid {pid})")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    """Whether a gateway runs here and what it is doing; ``--json`` for programs. Exit 0 running, 3 not."""
    import json

    from portico_gateway.status import describe, gateway_status

    state, _ = _state_and_config_path(args)
    status = gateway_status(state)
    print(json.dumps(status) if args.json else describe(status, state))
    return 0 if status["running"] else EXIT_NONE_RUNNING


def cmd_sessions_clear(args: argparse.Namespace) -> int:
    """Forget every ended session on a stopped gateway's state directory; the live one and the transcripts stay."""
    from portico_gateway.chats import ChatRegistry
    from portico_gateway.config import ConfigError, load_config
    from portico_gateway.status import running_pid

    state, config_path = _state_and_config_path(args)
    if running_pid(state) is not None:
        print("portico-gateway: Stop the gateway first.", file=sys.stderr)
        return 1
    try:
        config = load_config(config_path)
    except ConfigError as e:
        print(f"portico-gateway: {e}", file=sys.stderr)
        return 1
    if config.presentation != "single":
        print("portico-gateway: only a deployment with one live session at a time clears earlier ones", file=sys.stderr)
        return 1
    if not args.yes:
        try:
            answer = input("Clear earlier sessions? The transcripts on disk stay. [y/N] ")
        except EOFError:
            answer = ""
        if answer.strip().lower() not in ("y", "yes"):
            return 0
    registry = ChatRegistry(index=state.load_index(), state=state, history_buffer=config.history_buffer)
    ended = registry.ended_chats()
    for chat in ended:
        registry.remove(chat.number)
    print(f"cleared {len(ended)} earlier session{'s' if len(ended) != 1 else ''}")
    return 0


def cmd_sessions_list(args: argparse.Namespace) -> int:
    """v0.24: every session in the index, newest first, with the prompt it started with; ``--json`` for agents."""
    import json

    from portico_gateway.state import StateDir

    state = StateDir(Path(args.state).expanduser() if getattr(args, "state", None) else None)
    records = sorted(state.load_index().chats, key=lambda r: r.chat, reverse=True)
    if getattr(args, "json", False):
        print(json.dumps([r.model_dump(mode="json", include={"chat", "folder", "title", "created", "ended", "prompt"}) for r in records]))
        return 0
    for r in records:
        parts = [f"#{r.chat}", r.created[:10], "ended" if r.ended else r.state, r.title or r.folder]
        if r.prompt is not None:
            name = Path(r.prompt.source).name if r.prompt.mode == "custom" else r.prompt.source
            parts.append(f"prompt {r.prompt.mode} {name} {r.prompt.sha}")
        print("  ".join(parts))
    return 0


# Exit code of the ``update`` commands when the deployment configured no update command.
EXIT_NOT_CONFIGURED = 2
# ``update --check``: the check command failed (another exit, a timeout, could not start).
EXIT_CHECK_FAILED = 4


def cmd_update(args: argparse.Namespace) -> int:
    """``--check``: the deployment's ``update.check`` (0 + the version, 1 none, 2 not configured, 4 the check failed).

    Without it: stop a running gateway (as ``stop``), run ``update.run`` with
    its output streamed to stdout, exit with its code (2 when not configured).
    """
    import subprocess

    from portico_gateway.config import ConfigError, load_config
    from portico_gateway.status import stop_gateway
    from portico_gateway.update import SHELL, run_check

    state, config_path = _state_and_config_path(args)
    try:
        config = load_config(config_path)
    except ConfigError as e:
        print(f"portico-gateway: {e}", file=sys.stderr)
        return 1
    if args.check:
        if not config.update.check:
            print("portico-gateway: no update check configured ([update] check in config.toml)", file=sys.stderr)
            return EXIT_NOT_CONFIGURED
        result = asyncio.run(run_check(config.update.check, float(config.command_timeout_seconds)))
        if result.error is not None:
            print(f"portico-gateway: {result.error}", file=sys.stderr)
            return EXIT_CHECK_FAILED
        if result.version is None:
            return 1
        print(result.version)
        return 0
    if not config.update.run:
        print("portico-gateway: no update command configured ([update] run in config.toml)", file=sys.stderr)
        return EXIT_NOT_CONFIGURED
    try:
        pid = stop_gateway(state, float(config.command_timeout_seconds) + 30.0)
    except TimeoutError as e:
        print(f"portico-gateway: {e}; not updating", file=sys.stderr)
        return 1
    if pid is not None:
        print(f"stopped the gateway (pid {pid})", flush=True)
    sys.stdout.flush()
    done = subprocess.run([SHELL, "-c", config.update.run], stdin=subprocess.DEVNULL, stderr=subprocess.STDOUT, check=False)
    return done.returncode


def cmd_message(args: argparse.Namespace) -> int:
    """v0.22: leave a message from the deployment for the app: one JSON file in ``<state dir>/messages/``.

    The running gateway delivers it within a few seconds (or on the app's next connect) and deletes
    the file; nothing here needs the gateway to be running.
    """
    from portico_gateway.deployment_messages import write_message
    from portico_gateway.state import StateDir

    if not args.text.strip():
        print("portico-gateway: message needs some text", file=sys.stderr)
        return 2
    state_path = Path(args.state).expanduser() if args.state else StateDir.default_path()
    try:
        path = write_message(state_path, args.text, title=args.title, notify=args.notify, space=args.space)
    except OSError as e:
        print(f"portico-gateway: {e}", file=sys.stderr)
        return 1
    print(path)
    return 0


def cmd_capture_prompt(args: argparse.Namespace) -> int:
    """v0.24: copy Claude Code's own system prompt to a file, the start of a custom prompt (one small model request)."""
    from portico_gateway.config import ConfigError, load_config
    from portico_gateway.prompt_capture import CaptureError, capture_prompt

    state, config_path = _state_and_config_path(args)
    try:
        config = load_config(config_path)
    except ConfigError as e:
        print(f"portico-gateway: {e}", file=sys.stderr)
        return 1
    out = Path(args.out).expanduser() if args.out else None
    try:
        path = asyncio.run(capture_prompt(state.path, list(config.setting_sources), out))
    except CaptureError as e:
        print(f"portico-gateway: {e}", file=sys.stderr)
        return 1
    print(f"wrote {path}")
    print('Use it with system_prompt = "custom" and system_prompt_file in config.local.toml; it applies to the next new or renewed session.')
    return 0


def cmd_export_schema(args: argparse.Namespace) -> int:
    out = Path(args.out) if args.out else PROTOCOL_DIR / "schema" / "portico.schema.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(canonical_json(export_schema()), encoding="utf-8")
    print(f"wrote {out}")
    return 0


def cmd_export_config_doc(args: argparse.Namespace) -> int:
    """v0.24 §6: write CONFIGURATION.md and config.example.toml (the repo root unless --out) from the key docs."""
    from portico_gateway.config_doc import render_example, render_markdown

    out_dir = Path(args.out) if args.out else REPO_ROOT
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "CONFIGURATION.md").write_text(render_markdown(), encoding="utf-8")
    (out_dir / "config.example.toml").write_text(render_example(), encoding="utf-8")
    print(f"wrote CONFIGURATION.md and config.example.toml to {out_dir}")
    return 0


def cmd_export_examples(args: argparse.Namespace) -> int:
    out_dir = Path(args.out) if args.out else PROTOCOL_DIR / "examples"
    out_dir.mkdir(parents=True, exist_ok=True)
    examples = {**example_messages(), **example_variants()}
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
    p.add_argument("--state", help="state directory (default: $PORTICO_HOME, the checkout's .portico-home, or ~/.portico)")
    p.add_argument("--config", help="config file (default: <state>/config.toml)")
    p.add_argument("--verbose", action="store_true", help="debug logging on stderr")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("doctor", help="check this machine, the state directory and the config; one line per check")
    p.add_argument("--state", help="state directory (default: $PORTICO_HOME, the checkout's .portico-home, or ~/.portico)")
    p.add_argument("--config", help="config file (default: <state>/config.toml)")
    p.set_defaults(func=cmd_doctor)

    p = sub.add_parser("check-env", help="exit 1 and print the line numbers when an env file has a line that is not KEY=value")
    p.add_argument("path", help="the env file to check; a missing file passes")
    p.set_defaults(func=cmd_check_env)

    p = sub.add_parser("stop", help="stop the gateway running on this state directory (exit 3 when none runs)")
    p.add_argument("--state", help="state directory (default: $PORTICO_HOME, the checkout's .portico-home, or ~/.portico)")
    p.add_argument("--config", help="config file (default: <state>/config.toml)")
    p.add_argument("--timeout", type=float, help="seconds to wait for it to stop (default: command_timeout_seconds + 30)")
    p.set_defaults(func=cmd_stop)

    p = sub.add_parser("status", help="whether a gateway runs here and its live session (exit 0 running, 3 not)")
    p.add_argument("--state", help="state directory (default: $PORTICO_HOME, the checkout's .portico-home, or ~/.portico)")
    p.add_argument("--json", action="store_true", help='one JSON object: {"version": 1, "running": ..., ...}')
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("sessions", help="list sessions with the prompt each started with (v0.24), or clear earlier ones")
    p.add_argument("--state", help="state directory (default: $PORTICO_HOME, the checkout's .portico-home, or ~/.portico)")
    p.add_argument("--json", action="store_true", help="one JSON list for programs")
    p.set_defaults(func=cmd_sessions_list)
    sessions_sub = p.add_subparsers(dest="sessions_command", required=False)
    # A subcommand's own --state/--json default to SUPPRESS, so an absent one never clobbers what
    # ``sessions --state X`` already parsed (argparse applies a subparser's defaults over the parent's).
    c = sessions_sub.add_parser("list", help="every session, newest first, with its prompt (mode, file, fingerprint)")
    c.add_argument("--state", default=argparse.SUPPRESS, help="state directory (default: $PORTICO_HOME, the checkout's .portico-home, or ~/.portico)")
    c.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="one JSON list for programs")
    c.set_defaults(func=cmd_sessions_list)
    c = sessions_sub.add_parser("clear", help="forget every earlier session (the gateway must be stopped; transcripts stay)")
    c.add_argument("--yes", action="store_true", help="do not ask first")
    c.add_argument("--state", default=argparse.SUPPRESS, help="state directory (default: $PORTICO_HOME, the checkout's .portico-home, or ~/.portico)")
    c.add_argument("--config", help="config file (default: <state>/config.toml)")
    c.set_defaults(func=cmd_sessions_clear)

    p = sub.add_parser("update", help="run the deployment's update (stops the gateway first); --check only asks")
    p.add_argument("--check", action="store_true", help="exit 0 and print the version when an update is available, 1 when none, 2 when not configured, 4 when the check failed")
    p.add_argument("--state", help="state directory (default: $PORTICO_HOME, the checkout's .portico-home, or ~/.portico)")
    p.add_argument("--config", help="config file (default: <state>/config.toml)")
    p.set_defaults(func=cmd_update)

    p = sub.add_parser("config-value", help="print one config value (e.g. brand.name, brand.app_icon), or nothing")
    p.add_argument("key", help="dotted key: brand.name, brand.app_icon, update.run, ...")
    p.add_argument("--state", help="state directory (default: $PORTICO_HOME, the checkout's .portico-home, or ~/.portico)")
    p.add_argument("--config", help="config file (default: <state>/config.toml)")
    p.set_defaults(func=cmd_config_value)

    p = sub.add_parser("config", help="config commands (v0.24): show")
    config_sub = p.add_subparsers(dest="config_command", required=True)
    c = config_sub.add_parser("show", help="every config key, its value in force and [default], [config.toml] or [config.local.toml]")
    c.add_argument("--changed", action="store_true", help="only the keys not at their defaults")
    c.add_argument("--json", action="store_true", help="the same rows as one JSON list, for agents")
    c.add_argument("--state", help="state directory (default: $PORTICO_HOME, the checkout's .portico-home, or ~/.portico)")
    c.add_argument("--config", help="config file (default: <state>/config.toml)")
    c.set_defaults(func=cmd_config_show)

    p = sub.add_parser("message", help="leave a message from the deployment for the open app (a file in <state>/messages/)")
    p.add_argument("text", help="the message (Markdown)")
    p.add_argument("--title", help="a short heading shown in bold")
    p.add_argument("--notify", action="store_true", help="also raise a system notification")
    p.add_argument("--space", help="the id of a space the app offers to open with the message")
    p.add_argument("--state", help="state directory (default: $PORTICO_HOME, the checkout's .portico-home, or ~/.portico)")
    p.set_defaults(func=cmd_message)

    p = sub.add_parser("capture-prompt", help="copy Claude Code's own system prompt to a file, to start a custom prompt (one small model request)")
    p.add_argument("--out", help="the file to write (default: <state>/prompts/claude-code-<version>.md); never inside the checkout")
    p.add_argument("--state", help="state directory (default: $PORTICO_HOME, the checkout's .portico-home, or ~/.portico)")
    p.add_argument("--config", help="config file (default: <state>/config.toml)")
    p.set_defaults(func=cmd_capture_prompt)

    p = sub.add_parser("export-schema", help="write protocol/schema/portico.schema.json from the models")
    p.add_argument("--out", help="write the schema to this path instead")
    p.set_defaults(func=cmd_export_schema)

    p = sub.add_parser("export-config-doc", help="write CONFIGURATION.md and config.example.toml from the key docs")
    p.add_argument("--out", help="write both into this directory instead of the repo root")
    p.set_defaults(func=cmd_export_config_doc)

    p = sub.add_parser("export-examples", help="write protocol/examples/<direction>.<type>.json from the models")
    p.add_argument("--out", help="write the examples into this directory instead")
    p.set_defaults(func=cmd_export_examples)

    return parser


def _load_env_file(args: argparse.Namespace) -> None:
    """Load ``<state>/env`` into this process's environment before ``run`` or ``doctor``.

    Values are literal (never sourced by a shell). Variables already set win,
    except PATH, whose entries from the file go first. A
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


def _env_file_path_first(args: argparse.Namespace) -> None:
    """After the login shell's PATH: the env file's PATH entries first again, so a deployment's explicit PATH wins."""
    import os

    from portico_gateway.doctor import ENV_FILE, EnvFileError, apply_env_file
    from portico_gateway.state import StateDir

    state_arg = getattr(args, "state", None)
    path = (Path(state_arg).expanduser() if state_arg else StateDir.default_path()) / ENV_FILE
    try:
        apply_env_file(path, os.environ)
    except (EnvFileError, OSError):
        pass  # already reported when the file first loaded


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command in ("run", "doctor", "capture-prompt"):
        _load_env_file(args)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
