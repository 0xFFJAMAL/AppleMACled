#!/bin/zsh
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_RUNNER="$SOURCE_DIR/applemacled.command"
SOURCE_PYTHON="$SOURCE_DIR/esp32_usb_serial.py"
FRESH_INSTALLER="$SOURCE_DIR/install_native_base.command"
REPAIR="$SOURCE_DIR/repair_accessibility.command"
SOURCE_AUDIO_WATCHDOG="$SOURCE_DIR/audio_watchdog.py"

APP_SUPPORT="$HOME/Library/Application Support/AppleMAC-LED"
APP_BUNDLE="$HOME/Applications/AppleMACLED Agent.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/AppleMACLEDAgent"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
LAUNCH_PLIST="$LAUNCH_DIR/com.applemacled.agent.plist"
LOG_DIR="$HOME/Library/Logs/AppleMAC-LED"
LABEL="com.applemacled.agent"
LEGACY_LABEL="com.applemacled.ble-agent"
LEGACY_PLIST="$LAUNCH_DIR/$LEGACY_LABEL.plist"
AUDIO_WATCHDOG_LABEL="com.applemacled.audio-watchdog"
AUDIO_WATCHDOG_PLIST="$LAUNCH_DIR/$AUDIO_WATCHDOG_LABEL.plist"
UID_VALUE="$(id -u)"
STATE="$APP_SUPPORT/native-ui-state.json"
VERSION_FILE="$APP_SUPPORT/agent-version.txt"

stop_agent() {
  launchctl bootout "gui/$UID_VALUE/$AUDIO_WATCHDOG_LABEL" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE" "$AUDIO_WATCHDOG_PLIST" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE" "$LAUNCH_PLIST" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE/$LEGACY_LABEL" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE" "$LEGACY_PLIST" >/dev/null 2>&1 || true
  rm -f "$LEGACY_PLIST"
  pkill -f "esp32_usb_serial.py.*daemon" >/dev/null 2>&1 || true
  pkill -f "audio_watchdog.py" >/dev/null 2>&1 || true
  pkill -f "AppleMACLEDAgent" >/dev/null 2>&1 || true
  sleep 1
}

if [[ ! -f "$SOURCE_RUNNER" || ! -f "$SOURCE_PYTHON" || ! -f "$SOURCE_AUDIO_WATCHDOG" ]]; then
  echo "Error: required agent files are missing next to install.command."
  exit 1
fi

stop_agent
mkdir -p "$APP_SUPPORT" "$LAUNCH_DIR" "$LOG_DIR"
chmod 700 "$APP_SUPPORT"

PRESERVE_NATIVE=0
if [[ -x "$APP_EXECUTABLE" ]] \
  && [[ -f "$INFO_PLIST" ]] \
  && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)" == "com.applemacled.agent" ]] \
  && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)" == "36.14" ]] \
  && /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
  PRESERVE_NATIVE=1
fi

if (( PRESERVE_NATIVE == 0 )); then
  echo "Installing the native system monitor…"
  "$FRESH_INSTALLER"
  stop_agent
else
  echo "Keeping the existing native AppleMACLED Agent without recompiling it."
  echo "This preserves the macOS Accessibility permission binding."
fi


cp "$SOURCE_RUNNER" "$APP_SUPPORT/applemacled.command"
cp "$SOURCE_PYTHON" "$APP_SUPPORT/esp32_usb_serial.py"
cp "$SOURCE_AUDIO_WATCHDOG" "$APP_SUPPORT/audio_watchdog.py"
chmod +x "$APP_SUPPORT/applemacled.command" "$APP_SUPPORT/audio_watchdog.py"
echo "36.14-lighting" > "$VERSION_FILE"

echo "Checking the agent Python environment before starting the LaunchAgent…"
(
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  "$APP_SUPPORT/applemacled.command" --help >/dev/null
) >> "$LOG_DIR/agent.log" 2>> "$LOG_DIR/agent-error.log"

cat > "$LAUNCH_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_EXECUTABLE</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>3</integer>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launcher.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launcher-error.log</string>
</dict>
</plist>
PLIST
plutil -lint "$LAUNCH_PLIST" >/dev/null

cat > "$AUDIO_WATCHDOG_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$AUDIO_WATCHDOG_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$APP_SUPPORT/audio_watchdog.py</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/audio-watchdog.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/audio-watchdog-error.log</string>
</dict>
</plist>
PLIST
plutil -lint "$AUDIO_WATCHDOG_PLIST" >/dev/null

launchctl enable "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_VALUE" "$LAUNCH_PLIST"
launchctl kickstart -k "gui/$UID_VALUE/$LABEL"
launchctl enable "gui/$UID_VALUE/$AUDIO_WATCHDOG_LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_VALUE" "$AUDIO_WATCHDOG_PLIST"
launchctl kickstart -k "gui/$UID_VALUE/$AUDIO_WATCHDOG_LABEL"
sleep 3

echo
if [[ -f "$STATE" ]] && /usr/bin/grep -Eq '"axTrusted"[[:space:]]*:[[:space:]]*true' "$STATE"; then
  echo "AppleMAC-LED agent installed. Accessibility permission is already active."
else
  echo "AppleMAC-LED agent installed, but macOS reports axTrusted=false."
  echo "Starting targeted permission repair…"
  "$REPAIR"
fi

echo "Music mode reads system audio through ScreenCaptureKit and sends the level over USB Serial."
echo "If macOS requests Screen Recording/system audio permission, allow AppleMACLED Agent."

echo "The audio watchdog detects a stalled ScreenCaptureKit monitor and restarts the agent after 3 failed checks with a 90-second cooldown."
