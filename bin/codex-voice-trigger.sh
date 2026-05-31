#!/bin/bash
set -euo pipefail

ROOT="${CODEX_VOICE_HOME:-$HOME/CodexVoice}"
MODE="${1:-normal}"
TRIGGER_DIR="$ROOT/state/triggers"

case "$MODE" in
  normal|copy-only|strict)
    ;;
  *)
    exit 2
    ;;
esac

mkdir -p "$TRIGGER_DIR"
tmp="$(mktemp "$TRIGGER_DIR/.$MODE.XXXXXX")"
printf '%s\n' "$MODE" >"$tmp"
mv "$tmp" "$TRIGGER_DIR/${tmp##*/.}"
