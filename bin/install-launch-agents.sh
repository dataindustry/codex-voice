#!/bin/bash
set -euo pipefail

ROOT="${CODEX_VOICE_HOME:-$HOME/CodexVoice}"
AGENT_DIR="$HOME/Library/LaunchAgents"
UID_VALUE="$(id -u)"

AGENT_LABEL="com.codexvoice.agent"
AGENT_PLIST="$AGENT_DIR/$AGENT_LABEL.plist"
AGENT_SOURCE="$ROOT/bin/codex-voice-agent.swift"
AGENT_APP="$ROOT/Codex Voice Agent.app"
AGENT_CONTENTS="$AGENT_APP/Contents"
AGENT_MACOS="$AGENT_CONTENTS/MacOS"
AGENT_BINARY="$AGENT_MACOS/CodexVoiceAgent"
INDICATOR_SOURCE="$ROOT/bin/codex-voice-recording-indicator.swift"
INDICATOR_BINARY="$ROOT/bin/codex-voice-recording-indicator"
CONDA_ENV_NAME="${CODEX_VOICE_CONDA_ENV:-codex-voice}"

mkdir -p "$AGENT_DIR" "$ROOT/logs" "$ROOT/state/triggers"

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

resolve_python() {
  if [[ -n "${CODEX_VOICE_PYTHON:-}" && -x "$CODEX_VOICE_PYTHON" ]]; then
    echo "$CODEX_VOICE_PYTHON"
    return
  fi

  local conda_bin
  conda_bin="$(find_conda)" || {
    echo "Conda was not found. Run ~/CodexVoice/bin/install.sh first." >&2
    return 1
  }

  "$conda_bin" run -n "$CONDA_ENV_NAME" python -c 'import sys; print(sys.executable)'
}

compile_agent() {
  if [[ ! -f "$AGENT_SOURCE" ]]; then
    echo "Codex Voice agent source is missing: $AGENT_SOURCE" >&2
    return 1
  fi
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc was not found; cannot build Codex Voice agent." >&2
    return 1
  fi
  mkdir -p "$AGENT_MACOS"
  cat >"$AGENT_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>CodexVoiceAgent</string>
  <key>CFBundleIdentifier</key>
  <string>$AGENT_LABEL</string>
  <key>CFBundleName</key>
  <string>Codex Voice Agent</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Codex Voice needs microphone access to record local voice input.</string>
</dict>
</plist>
PLIST
  if [[ ! -x "$AGENT_BINARY" || "$AGENT_SOURCE" -nt "$AGENT_BINARY" ]]; then
    swiftc "$AGENT_SOURCE" -o "$AGENT_BINARY" -framework Cocoa -framework AVFoundation
    chmod +x "$AGENT_BINARY"
  fi
  codesign --force --sign - --identifier "$AGENT_LABEL" "$AGENT_APP" >/dev/null
}

compile_recording_indicator() {
  if [[ ! -f "$INDICATOR_SOURCE" ]]; then
    echo "Codex Voice recording indicator source is missing: $INDICATOR_SOURCE" >&2
    return 1
  fi
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc was not found; cannot build Codex Voice recording indicator." >&2
    return 1
  fi
  if [[ ! -x "$INDICATOR_BINARY" || "$INDICATOR_SOURCE" -nt "$INDICATOR_BINARY" ]]; then
    swiftc "$INDICATOR_SOURCE" -o "$INDICATOR_BINARY" -framework Cocoa
    chmod +x "$INDICATOR_BINARY"
  fi
}

PYTHON_BIN="$(resolve_python)"
compile_agent
compile_recording_indicator

cat >"$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$AGENT_BINARY</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>WorkingDirectory</key>
  <string>$ROOT</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/anaconda3/bin:$HOME/miniconda3/bin:$HOME/miniforge3/bin</string>
    <key>CODEX_VOICE_HOME</key>
    <string>$ROOT</string>
    <key>CODEX_VOICE_CONDA_ENV</key>
    <string>$CONDA_ENV_NAME</string>
    <key>CODEX_VOICE_PYTHON</key>
    <string>$PYTHON_BIN</string>
    <key>PYTHONNOUSERSITE</key>
    <string>1</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$ROOT/logs/$AGENT_LABEL.out.log</string>
  <key>StandardErrorPath</key>
  <string>$ROOT/logs/$AGENT_LABEL.err.log</string>
</dict>
</plist>
PLIST

plutil -lint "$AGENT_PLIST" >/dev/null
launchctl bootout "gui/$UID_VALUE" "$AGENT_PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_VALUE" "$AGENT_PLIST"

echo "Installed and started Codex Voice single LaunchAgent: $AGENT_LABEL"
echo "Codex Voice Python: $PYTHON_BIN"
