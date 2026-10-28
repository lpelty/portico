"""``portico-gateway`` command line.

Subcommands land task by task; so far: ``run``, ``export-schema``, ``export-examples``.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import signal
import sys
from pathlib import Path

from portico_gateway import REPO_ROOT, __version__
from portico_gateway.messages import canonical_json, example_messages, export_schema, to_json_obj

PROTOCOL_DIR = REPO_ROOT / "protocol"


def cmd_run(args: argparse.Namespace) -> int:
    """Run the gateway until SIGINT/SIGTERM. Refuses a second copy on the same state directory."""
    from portico_gateway.config import ConfigError, load_config
    from portico_gateway.state import StateDir, StateError

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    try:
        state = StateDir(Path(args.state).expanduser() if args.state else None)
        config = load_config(Path(args.config).expanduser() if args.config else state.config_path)
    except (ConfigError, StateError, OSError) as e:
        print(f"portico-gateway: {e}", file=sys.stderr)
        return 1
    if not state.acquire_lock():
        print(f"portico-gateway: another gateway is already running on {state.path}", file=sys.stderr)
        return 1
    try:
        return asyncio.run(_run_server(config, state, args.port))
    except StateError as e:
        print(f"portico-gateway: {e}", file=sys.stderr)
        return 1
    finally:
        state.release_lock()


async def _run_server(config, state, port: int) -> int:  # noqa: ANN001 - types live in the modules below
    from portico_gateway.chats import ChatRegistry
    from portico_gateway.engine import SDKEngine
    from portico_gateway.server import GatewayServer

    registry = ChatRegistry(index=state.load_index(), state=state, history_buffer=config.history_buffer)
    server = GatewayServer(config=config, state=state, registry=registry, engine_factory=SDKEngine, version=__version__)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    await server.serve(port)
    try:
        await stop.wait()
    finally:
        await server.shutdown()
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

    p = sub.add_parser("export-schema", help="write protocol/schema/portico.schema.json from the models")
    p.add_argument("--out", help="write the schema to this path instead")
    p.set_defaults(func=cmd_export_schema)

    p = sub.add_parser("export-examples", help="write protocol/examples/<direction>.<type>.json from the models")
    p.add_argument("--out", help="write the examples into this directory instead")
    p.set_defaults(func=cmd_export_examples)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
