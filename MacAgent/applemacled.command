#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV="$SCRIPT_DIR/.esp32-usb-venv"
PYTHON_SCRIPT="$SCRIPT_DIR/esp32_usb_serial.py"

[[ -f "$PYTHON_SCRIPT" ]] || { echo "Error: esp32_usb_serial.py was not found"; exit 1; }

PYTHON_BIN=""
for candidate in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  [[ -x "$candidate" ]] && { PYTHON_BIN="$candidate"; break; }
done
[[ -n "$PYTHON_BIN" ]] || PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
[[ -n "$PYTHON_BIN" ]] || { echo "Error: python3 was not found."; exit 1; }

PYTHON_VERSION="$("$PYTHON_BIN" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PYTHON_MAJOR="${PYTHON_VERSION%%.*}"
PYTHON_MINOR="${PYTHON_VERSION##*.}"
if (( PYTHON_MAJOR < 3 || (PYTHON_MAJOR == 3 && PYTHON_MINOR < 9) )); then
  echo "Error: Python 3.9 or newer is required. Current version: $PYTHON_VERSION"
  exit 1
fi

create_venv() {
  echo "Creating a local Python environment…"
  rm -rf "$VENV"
  "$PYTHON_BIN" -m venv "$VENV"
}

[[ -x "$VENV/bin/python" ]] || create_venv
VENV_VERSION="$("$VENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
[[ "$VENV_VERSION" == "$PYTHON_VERSION" ]] || create_venv
PY="$VENV/bin/python"

if ! "$PY" -c 'import serial, objc, AppKit, Foundation' >/dev/null 2>&1; then
  echo "Installing USB Serial and macOS dependencies for Python $PYTHON_VERSION…"
  create_venv
  PY="$VENV/bin/python"

  if (( PYTHON_MAJOR == 3 && PYTHON_MINOR == 9 )); then
    "$PY" -m pip install --upgrade "pip<26" setuptools wheel
    "$PY" -m pip install \
      "pyserial>=3.5" \
      "pyobjc-core==11.1" \
      "pyobjc-framework-Cocoa==11.1"
  else
    "$PY" -m pip install --upgrade pip setuptools wheel
    "$PY" -m pip install --upgrade \
      pyserial \
      pyobjc-framework-Cocoa
  fi
fi

if [[ $# -eq 0 ]]; then
  set -- status
fi

daemon_pid_is_live() {
  local pid="${1:-}"
  local command=""
  [[ "$pid" == <-> ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 || return 1
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command" == *"esp32_usb_serial.py daemon"* \
    || "$command" == *"applemacled.command daemon"* ]]
}

if [[ "${1:-}" == "daemon" && "${APPLEMACLED_DAEMON_CHILD:-0}" != "1" ]]; then
  LOG_DIR="$HOME/Library/Logs/AppleMAC-LED"
  PID_FILE="$SCRIPT_DIR/daemon.pid"
  mkdir -p "$LOG_DIR"

  rotate_log() {
    local path="$1"
    local max_bytes=$((8 * 1024 * 1024))
    local size="$(/usr/bin/stat -f '%z' "$path" 2>/dev/null || echo 0)"
    if [[ "$size" == <-> ]] && (( size > max_bytes )); then
      /bin/mv -f "$path" "$path.1"
    fi
  }
  rotate_log "$LOG_DIR/agent.log"
  rotate_log "$LOG_DIR/agent-error.log"

  daemon_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if ! daemon_pid_is_live "$daemon_pid"; then
    rm -f "$PID_FILE"
    nohup /usr/bin/env \
      APPLEMACLED_DAEMON_CHILD=1 \
      APPLEMACLED_DAEMON_PID_FILE="$PID_FILE" \
      "$0" "$@" \
      >> "$LOG_DIR/agent.log" \
      2>> "$LOG_DIR/agent-error.log" \
      </dev/null &
    bootstrap_pid=$!
    daemon_pid=""
    for attempt in {1..80}; do
      daemon_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
      daemon_pid_is_live "$daemon_pid" && break
      sleep 0.10
    done
    daemon_pid_is_live "$daemon_pid" || {
      echo "USB daemon supervisor: process failed to start ($bootstrap_pid)."
      exit 1
    }
    echo "USB daemon supervisor: started independent process $daemon_pid."
  else
    echo "USB daemon supervisor: keeping active process $daemon_pid."
  fi

  trap 'exit 0' TERM INT HUP
  while daemon_pid_is_live "$daemon_pid"; do sleep 1; done
  [[ "$(cat "$PID_FILE" 2>/dev/null || true)" != "$daemon_pid" ]] || rm -f "$PID_FILE"
  echo "USB daemon supervisor: process $daemon_pid exited; requesting restart."
  exit 1
fi

exec "$PY" "$PYTHON_SCRIPT" "$@"
