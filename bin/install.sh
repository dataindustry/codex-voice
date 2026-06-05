#!/bin/bash
set -euo pipefail

ROOT="${CODEX_VOICE_HOME:-$HOME/CodexVoice}"
CONDA_ENV_NAME="${CODEX_VOICE_CONDA_ENV:-codex-voice}"
SKIP_DEPS=0

for arg in "$@"; do
  case "$arg" in
    --skip-deps)
      SKIP_DEPS=1
      ;;
    -h|--help)
      echo "Usage: bash ~/CodexVoice/bin/install.sh [--skip-deps]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

log() {
  printf '[CodexVoice] %s\n' "$*"
}

warn() {
  printf '[CodexVoice] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[CodexVoice] ERROR: %s\n' "$*" >&2
  exit 1
}

ensure_layout() {
  mkdir -p \
    "$ROOT/bin" \
    "$ROOT/config" \
    "$ROOT/recordings" \
    "$ROOT/transcripts" \
    "$ROOT/logs" \
    "$ROOT/state"
}

ensure_required_files() {
  local missing=0
  for file in \
    "$ROOT/bin/codex-voice.py" \
    "$ROOT/config/config.json" \
    "$ROOT/config/terms.json" \
    "$ROOT/config/correction_prompt.txt" \
    "$ROOT/bin/install-launch-agents.sh" \
    "$ROOT/bin/codex-voice-config.py" \
    "$ROOT/Sources/Agent/main.swift" \
    "$ROOT/pyproject.toml" \
    "$ROOT/bin/codex-voice-recording-indicator.swift" \
    "$ROOT/environment.yml" \
    "$ROOT/requirements.txt"; do
    if [[ ! -f "$file" ]]; then
      warn "Missing required file: $file"
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    die "CodexVoice files are incomplete. Restore the bundle, then rerun install.sh."
  fi
}

find_conda() {
  if [[ -n "${CONDA_EXE:-}" && -x "$CONDA_EXE" ]]; then
    echo "$CONDA_EXE"
    return
  fi
  if command -v conda >/dev/null 2>&1; then
    command -v conda
    return
  fi
  for candidate in \
    "$HOME/anaconda3/bin/conda" \
    "$HOME/miniconda3/bin/conda" \
    "$HOME/miniforge3/bin/conda" \
    "/opt/homebrew/bin/conda"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done
  return 1
}

conda_env_exists() {
  local conda_bin="$1"
  "$conda_bin" env list | awk '{print $1}' | grep -Fxq "$CONDA_ENV_NAME"
}

conda_python() {
  local conda_bin="$1"
  "$conda_bin" run -n "$CONDA_ENV_NAME" python -c 'import sys; print(sys.executable)'
}

check_homebrew_tools() {
  if ! command -v brew >/dev/null 2>&1; then
    warn "Homebrew not found. Install ffmpeg and portaudio manually before running voice input."
    return
  fi

  if ! command -v ffmpeg >/dev/null 2>&1; then
    warn "ffmpeg not found. Recommended: brew install ffmpeg"
  else
    log "ffmpeg found: $(command -v ffmpeg)"
  fi

  if ! brew list portaudio >/dev/null 2>&1; then
    warn "portaudio not found. sounddevice often needs it: brew install portaudio"
  else
    log "portaudio is installed."
  fi
}

check_ollama() {
  if ! command -v ollama >/dev/null 2>&1; then
    warn "Ollama not found. Install from https://ollama.com/ if you want local LLM correction."
    return
  fi

  log "Ollama found: $(command -v ollama)"
  local models
  models="$(ollama list 2>/dev/null || true)"
  if [[ "$models" != *"qwen3.6:35b-a3b"* ]]; then
    warn "Default model qwen3.6:35b-a3b is not installed."
    warn "Either edit $ROOT/config/config.json or run: ollama pull qwen3.6:35b-a3b"
  fi
}

install_conda_deps() {
  if [[ "$SKIP_DEPS" -eq 1 ]]; then
    warn "Skipping Conda environment install/update because --skip-deps was provided."
    return
  fi

  local conda_bin="$1"
  if conda_env_exists "$conda_bin"; then
    log "Using existing Conda environment: $CONDA_ENV_NAME"
  else
    log "Creating Conda environment: $CONDA_ENV_NAME"
    "$conda_bin" env create -f "$ROOT/environment.yml"
  fi

  local python_bin
  python_bin="$(conda_python "$conda_bin")"
  log "Codex Voice Conda Python: $python_bin"
  PYTHONNOUSERSITE=1 "$python_bin" -m pip install --upgrade pip wheel "setuptools<82"
  PYTHONNOUSERSITE=1 "$python_bin" -m pip install -e "$ROOT[dev]"
}

set_permissions() {
  chmod +x "$ROOT/bin/codex-voice.py"
  chmod +x "$ROOT/bin/install.sh"
  chmod +x "$ROOT/bin/install-launch-agents.sh"
  chmod +x "$ROOT/bin/codex-voice-config.py"
  [[ ! -f "$ROOT/Codex Voice Agent.app/Contents/MacOS/CodexVoiceAgent" ]] || chmod +x "$ROOT/Codex Voice Agent.app/Contents/MacOS/CodexVoiceAgent"
  [[ ! -f "$ROOT/bin/codex-voice-recording-indicator" ]] || chmod +x "$ROOT/bin/codex-voice-recording-indicator"
}

cleanup_legacy_artifacts() {
  rm -f "$ROOT/bin/codex-voice-trigger.sh"
  rm -rf "$ROOT/raycast" "$ROOT/state/triggers"
}

main() {
  log "Installing Codex Voice under $ROOT"
  ensure_layout
  ensure_required_files
  check_homebrew_tools
  check_ollama

  local conda_bin
  conda_bin="$(find_conda)" || die "Conda not found. Install Anaconda/Miniconda/Miniforge or set CONDA_EXE."
  log "Using Conda: $conda_bin"

  install_conda_deps "$conda_bin"
  set_permissions
  cleanup_legacy_artifacts
  CODEX_VOICE_CONDA_ENV="$CONDA_ENV_NAME" "$ROOT/bin/install-launch-agents.sh"

  log "Install steps completed."
  log "Next: open the menu bar panel to grant permissions or record a different native hotkey."
  log "Default native hotkey: Option+Space."
  log "macOS may ask for Microphone permission and Accessibility permission."
}

main "$@"
