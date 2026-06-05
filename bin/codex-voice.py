#!/usr/bin/env python3
"""Compatibility wrapper for the packaged Codex Voice CLI."""

from __future__ import annotations

import sys
from pathlib import Path


def _bootstrap_source_tree() -> None:
    root = Path(__file__).resolve().parents[1]
    src = root / "src"
    if src.exists():
        sys.path.insert(0, str(src))


def main() -> int:
    _bootstrap_source_tree()
    from codex_voice.voice import run

    return run()


if __name__ == "__main__":
    raise SystemExit(main())
