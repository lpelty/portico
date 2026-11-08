"""``portico-gateway capture-prompt`` (v0.24 §3): a starting copy of Claude Code's own system prompt.

One minimal engine request runs in a scratch folder with Claude Code's raw
request logging on (``OTEL_LOG_RAW_API_BODIES=file:<dir>``, one
``<id>.request.json`` per request). The ``system`` text of the logged
request is written to the output file with a header recording the Claude
Code version, the model and the date; lines naming this computer's folders
get a marker comment before them. The temporary logs are deleted.

The text is Anthropic's: the file is never written inside the checkout.
"""

from __future__ import annotations

import contextlib
import json
import tempfile
from collections.abc import Callable, Iterable
from datetime import date
from pathlib import Path
from typing import Any

from . import REPO_ROOT
from .engine import MARKER_PREFIX

# Tests replace these; ``None`` means the SDK's ``query`` and ``claude_code_version``.
DEFAULT_QUERY: Callable[..., Any] | None = None
DEFAULT_VERSION: Callable[[], str | None] | None = None

REQUEST = "Reply with OK."
NOTHING_LOGGED = (
    "Capture isn't possible: the engine logged no request (it may not support OTEL_LOG_RAW_API_BODIES). "
    "Nothing was written."
)
MARKER = f"{MARKER_PREFIX} the next line names this computer's folders; check it before using this prompt elsewhere -->"


class CaptureError(Exception):
    """The capture could not be made; the message says why, and nothing was written."""


def system_text(body: Any) -> str | None:
    """A logged request body's ``system`` text: a string, or its text blocks joined by blank lines."""
    if not isinstance(body, dict):
        return None
    system = body.get("system")
    if isinstance(system, str):
        return system or None
    if isinstance(system, list):
        texts = [b.get("text") for b in system if isinstance(b, dict) and isinstance(b.get("text"), str)]
        return "\n\n".join(texts) or None
    return None


def mark_machine_lines(text: str, places: Iterable[str]) -> str:
    """``text`` with ``MARKER`` before each line that names one of ``places`` (never removed silently)."""
    wanted = [p for p in places if p]
    out: list[str] = []
    for line in text.splitlines():
        if any(p in line for p in wanted):
            out.append(MARKER)
        out.append(line)
    return "\n".join(out)


def _inside(path: Path, folder: Path) -> bool:
    try:
        path.resolve().relative_to(folder.resolve())
    except ValueError:
        return False
    return True


def _longest_request(logdir: Path) -> tuple[str, str] | None:
    best: tuple[str, str] | None = None
    for file in sorted(logdir.rglob("*.request.json")) if logdir.is_dir() else []:
        try:
            body = json.loads(file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        text = system_text(body)
        if text and (best is None or len(text) > len(best[0])):
            best = (text, str(body.get("model") or "unknown"))
    return best


async def capture_prompt(
    state_path: Path,
    setting_sources: list[str],
    out: Path | None,
    *,
    query: Callable[..., Any] | None = None,
    version: Callable[[], str | None] | None = None,
    today: str | None = None,
) -> Path:
    """Run the capture and write the file; returns its path. Raises ``CaptureError`` and writes nothing on failure."""
    from claude_agent_sdk import ClaudeAgentOptions

    from .cc_version import claude_code_version
    from .titles import settings_env

    if out is not None and _inside(Path(out), REPO_ROOT):
        raise CaptureError("capture-prompt never writes inside the checkout; pick a path outside it")
    cc = (version or DEFAULT_VERSION or claude_code_version)() or "unknown"
    target = Path(out) if out is not None else Path(state_path) / "prompts" / f"claude-code-{cc}.md"
    if target.exists():
        raise CaptureError(f"{target} exists; pass --out with a new file name")
    run = query or DEFAULT_QUERY
    if run is None:
        from claude_agent_sdk import query as run
    with tempfile.TemporaryDirectory(prefix="prompt-capture-") as tmp:
        scratch = Path(tmp) / "scratch"
        logdir = Path(tmp) / "logs"
        scratch.mkdir()
        env = {**settings_env(setting_sources, None), "OTEL_LOG_RAW_API_BODIES": f"file:{logdir}"}
        options = ClaudeAgentOptions(
            cwd=str(scratch),
            system_prompt={"type": "preset", "preset": "claude_code"},
            max_turns=1,
            setting_sources=[],
            env=env,
        )
        try:
            async with contextlib.aclosing(run(prompt=REQUEST, options=options)) as messages:
                async for _ in messages:
                    pass
        except Exception as e:
            if _longest_request(logdir) is None:
                raise CaptureError(f"Capture isn't possible: the engine request failed ({type(e).__name__}: {e}). Nothing was written.") from e
        found = _longest_request(logdir)
        if found is None:
            raise CaptureError(NOTHING_LOGGED)
        text, model = found
        places = [str(scratch), str(Path(tmp)), str(Path(tmp).resolve()), str(scratch.resolve()), str(Path.home())]
        body = mark_machine_lines(text, places)
    header = f"<!-- captured from Claude Code {cc} · model {model} · {today or date.today().isoformat()} -->"
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + ".partial")
    partial.write_text(f"{header}\n{body}\n", encoding="utf-8")
    partial.replace(target)
    return target
