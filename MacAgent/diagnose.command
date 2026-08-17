#!/bin/zsh
set -u

APP="$HOME/Applications/AppleMACLED Agent.app"
SUPPORT="$HOME/Library/Application Support/AppleMAC-LED"
STATE="$SUPPORT/native-ui-state.json"
AUDIO_STATE="$SUPPORT/native-audio-state.json"
LOG="$HOME/Library/Logs/AppleMAC-LED/agent.log"
ERR="$HOME/Library/Logs/AppleMAC-LED/agent-error.log"
LERR="$HOME/Library/Logs/AppleMAC-LED/launcher-error.log"

printf '\n=== Agent version ===\n'
cat "$SUPPORT/agent-version.txt" 2>/dev/null || echo 'not specified'

printf '\n=== Stable native app version ===\n'
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 'Application not found'

printf '\n=== Application signature ===\n'
if /usr/bin/codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  echo 'signature is valid'
else
  echo 'ERROR: signature is invalid'
fi

printf '\n=== LaunchAgent ===\n'
launchctl print "gui/$(id -u)/com.applemacled.agent" 2>&1 | head -35

printf '\n=== Processes ===\n'
pgrep -alf 'AppleMACLEDAgent|esp32_usb_serial.py.*daemon' || true

printf '\n=== Native Finder / Safari / App Store / ChatGPT / Trash / Bluetooth state ===\n'
if [[ -f "$STATE" ]]; then
  cat "$STATE"
  echo
  if /usr/bin/grep -Eq '"axTrusted"[[:space:]]*:[[:space:]]*false' "$STATE"; then
    echo 'IMPORTANT: macOS does not trust the current executable even if the toggle appears enabled.'
    echo 'Run: ./repair_accessibility.command'
  fi
else
  echo "File has not been created yet: $STATE"
fi

printf '\n=== Native system audio state ===\n'
if [[ -f "$AUDIO_STATE" ]]; then
  cat "$AUDIO_STATE"
  echo
else
  echo "File has not been created yet: $AUDIO_STATE"
fi

printf '\n=== Latest main log lines ===\n'
ls -lh "$LOG" "$ERR" 2>/dev/null || true
tail -n 40 "$LOG" 2>/dev/null || true

printf '\n=== Python errors ===\n'
tail -n 30 "$ERR" 2>/dev/null || true

printf '\n=== Native launcher errors ===\n'
tail -n 30 "$LERR" 2>/dev/null || true

printf '\n=== USB Serial ports ===\n'
"$SUPPORT/applemacled.command" ports 2>&1 || true

printf '\n=== ESP status over USB ===\n'
"$SUPPORT/applemacled.command" status 2>&1 || true
