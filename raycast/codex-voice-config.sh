#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Codex Voice Config
# @raycast.mode compact
# @raycast.packageName Codex Voice
# @raycast.icon ⚙️
# @raycast.argument1 { "type": "text", "placeholder": "Max minutes, e.g. 5" }

ROOT="${CODEX_VOICE_HOME:-$HOME/CodexVoice}"
ENV_NAME="${CODEX_VOICE_CONDA_ENV:-codex-voice}"
PYTHON_BIN="${CODEX_VOICE_PYTHON:-$HOME/anaconda3/envs/$ENV_NAME/bin/python}"

if [[ ! -x "$PYTHON_BIN" ]]; then
  for base in "$HOME/miniconda3" "$HOME/miniforge3" "/opt/homebrew"; do
    candidate="$base/envs/$ENV_NAME/bin/python"
    if [[ -x "$candidate" ]]; then
      PYTHON_BIN="$candidate"
      break
    fi
  done
fi

PYTHONNOUSERSITE=1 "$PYTHON_BIN" "$ROOT/bin/codex-voice-config.py" --set-max-minutes "$1"
