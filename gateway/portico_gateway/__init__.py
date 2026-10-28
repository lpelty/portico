"""Portico reference gateway."""

from pathlib import Path

__all__ = ["__version__", "REPO_ROOT"]

REPO_ROOT = Path(__file__).resolve().parents[2]


def _read_version() -> str:
    try:
        return (REPO_ROOT / "VERSION").read_text().strip()
    except OSError:
        return "0.0.0"


__version__ = _read_version()
