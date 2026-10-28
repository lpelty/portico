"""``portico-gateway`` command line.

Subcommands land task by task; for now: ``export-schema`` and ``export-examples``.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from portico_gateway import REPO_ROOT, __version__
from portico_gateway.messages import canonical_json, example_messages, export_schema, to_json_obj

PROTOCOL_DIR = REPO_ROOT / "protocol"


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
