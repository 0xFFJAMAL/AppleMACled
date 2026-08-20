#!/bin/zsh
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_RUNNER="$SOURCE_DIR/send_usb_to_esp.command"
SOURCE_PYTHON="$SOURCE_DIR/esp32_usb_serial.py"
SOURCE_AUDIO_WATCHDOG="$SOURCE_DIR/audio_watchdog.py"
NATIVE_INSTALLER="$SOURCE_DIR/install_native_base.command"

APP_SUPPORT="$HOME/Library/Application Support/AppleMAC-LED"
APP_BUNDLE="$HOME/Applications/AppleMACLED Agent.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/AppleMACLEDAgent"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
LAUNCH_PLIST="$LAUNCH_DIR/com.applemacled.agent.plist"
LEGACY_LAUNCH_PLIST="$LAUNCH_DIR/com.applemacled.ble-agent.plist"
LOG_DIR="$HOME/Library/Logs/AppleMAC-LED"
LABEL="com.applemacled.agent"
LEGACY_LABEL="com.applemacled.ble-agent"
AUDIO_WATCHDOG_LABEL="com.applemacled.audio-watchdog"
AUDIO_WATCHDOG_PLIST="$LAUNCH_DIR/$AUDIO_WATCHDOG_LABEL.plist"
UID_VALUE="$(id -u)"
NATIVE_STATE="$APP_SUPPORT/native-ui-state.json"
NATIVE_AUDIO_STATE="$APP_SUPPORT/native-audio-state.json"
VERSION_FILE="$APP_SUPPORT/agent-version.txt"
STAGE_PID=""

required_files=(
  "$SOURCE_RUNNER"
  "$SOURCE_PYTHON"
  "$SOURCE_AUDIO_WATCHDOG"
  "$NATIVE_INSTALLER"
)
for required_file in "${required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Error: required installer file is missing: $required_file" >&2
    exit 1
  fi
done

stop_agents() {
  launchctl bootout "gui/$UID_VALUE/$AUDIO_WATCHDOG_LABEL" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE" "$AUDIO_WATCHDOG_PLIST" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE" "$LAUNCH_PLIST" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE/$LEGACY_LABEL" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE" "$LEGACY_LAUNCH_PLIST" >/dev/null 2>&1 || true
  pkill -f "esp32_usb_serial.py.*daemon" >/dev/null 2>&1 || true
  pkill -f "audio_watchdog.py" >/dev/null 2>&1 || true
  pkill -f "AppleMACLEDAgent" >/dev/null 2>&1 || true
}

stop_permission_stage() {
  if [[ "$STAGE_PID" == <-> ]]; then
    kill "$STAGE_PID" >/dev/null 2>&1 || true
    wait "$STAGE_PID" >/dev/null 2>&1 || true
  fi
  STAGE_PID=""
  pkill -f "esp32_usb_serial.py.*daemon" >/dev/null 2>&1 || true
  pkill -f "AppleMACLEDAgent" >/dev/null 2>&1 || true
  sleep 2
}

cleanup_on_exit() {
  stop_permission_stage
}

state_is_true() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] && /usr/bin/grep -Eq "\"$key\"[[:space:]]*:[[:space:]]*true" "$file"
}

start_permission_stage() {
  local stage="$1"
  stop_permission_stage
  rm -f "$NATIVE_STATE" "$NATIVE_AUDIO_STATE"
  /usr/bin/open \
    -W -n -g \
    --env "APPLEMACLED_PERMISSION_STAGE=$stage" \
    --stdout "$LOG_DIR/permission-setup.log" \
    --stderr "$LOG_DIR/permission-setup-error.log" \
    "$APP_BUNDLE" &
  STAGE_PID="$!"
}

wait_for_permission() {
  local state_file="$1"
  local key="$2"
  local label="$3"
  local settings_url="$4"

  echo
  echo "$label"
  open "$settings_url" >/dev/null 2>&1 || true
  printf "Waiting for macOS to confirm permission"
  while ! state_is_true "$state_file" "$key"; do
    if [[ "$STAGE_PID" != <-> ]] || ! kill -0 "$STAGE_PID" >/dev/null 2>&1; then
      printf "\nPermission helper stopped unexpectedly. Check:\n  %s\n" \
        "$LOG_DIR/permission-setup-error.log" >&2
      exit 1
    fi
    printf "."
    sleep 1
  done
  printf " confirmed.\n"
  stop_permission_stage
}

wait_for_audio_permission() {
  local settings_url="x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

  echo
  echo "3/4 — Allow Screen & System Audio Recording for music-reactive lighting. No screen image is stored."
  /usr/bin/open "$settings_url" >/dev/null 2>&1 || true
  echo "After enabling AppleMACLED Agent, macOS may ask to restart it."
  echo "Choose Later if that option is shown; this installer will perform the required restart safely."
  printf "Press Return here after the permission switch is enabled: "
  if ! read -r _audio_permission_ready; then
    echo "Error: interactive confirmation is required for the Screen Recording restart." >&2
    exit 1
  fi

  echo "Restarting only the permission helper…"
  stop_permission_stage
  start_permission_stage audio
  wait_for_permission \
    "$NATIVE_STATE" \
    screenCaptureGranted \
    "Verifying Screen & System Audio Recording after the helper restart." \
    "$settings_url"
}

echo "Stopping any installed AppleMAC-LED agent…"
stop_agents
sleep 2

mkdir -p "$APP_SUPPORT" "$LAUNCH_DIR" "$LOG_DIR"
chmod 700 "$APP_SUPPORT"

echo "Building and signing a fresh native agent…"
"$NATIVE_INSTALLER"
stop_agents
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

cp "$SOURCE_RUNNER" "$APP_SUPPORT/send_usb_to_esp.command"
cp "$SOURCE_RUNNER" "$APP_SUPPORT/applemacled.command"
cp "$SOURCE_PYTHON" "$APP_SUPPORT/esp32_usb_serial.py"
cp "$SOURCE_AUDIO_WATCHDOG" "$APP_SUPPORT/audio_watchdog.py"
chmod +x \
  "$APP_SUPPORT/send_usb_to_esp.command" \
  "$APP_SUPPORT/applemacled.command" \
  "$APP_SUPPORT/audio_watchdog.py"
echo "public-1.0" > "$VERSION_FILE"

echo "Checking the private Python environment before permission setup…"
(
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  "$APP_SUPPORT/send_usb_to_esp.command" --help >/dev/null
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

plutil -lint "$LAUNCH_PLIST" >/dev/null
plutil -lint "$AUDIO_WATCHDOG_PLIST" >/dev/null

echo "Resetting AppleMACLED Agent privacy permissions…"
for service in Accessibility SystemPolicyDownloadsFolder ScreenCapture Bluetooth BluetoothAlways; do
  /usr/bin/tccutil reset "$service" com.applemacled.agent >/dev/null 2>&1 || true
  sleep 1
done

trap cleanup_on_exit EXIT INT TERM

start_permission_stage accessibility
wait_for_permission \
  "$NATIVE_STATE" \
  axTrusted \
  "1/4 — Enable AppleMACLED Agent under Accessibility." \
  "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

start_permission_stage downloads
wait_for_permission \
  "$NATIVE_STATE" \
  downloadsAccessGranted \
  "2/4 — Allow Downloads folder access for Safari download lighting." \
  "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"

start_permission_stage audio
wait_for_audio_permission

start_permission_stage bluetooth
wait_for_permission \
  "$NATIVE_STATE" \
  bluetoothGranted \
  "4/4 — Allow Bluetooth access for the blue connection notification." \
  "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"

trap - EXIT INT TERM
stop_permission_stage

echo "Starting the installed background agent…"
launchctl enable "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_VALUE" "$LAUNCH_PLIST"
launchctl kickstart -k "gui/$UID_VALUE/$LABEL"
launchctl enable "gui/$UID_VALUE/$AUDIO_WATCHDOG_LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_VALUE" "$AUDIO_WATCHDOG_PLIST"
launchctl kickstart -k "gui/$UID_VALUE/$AUDIO_WATCHDOG_LABEL"
sleep 3

echo
echo "AppleMAC-LED public agent 1.0 is installed."
echo "All required permissions were reset, requested one at a time, and verified."
echo "Run ./diagnose.command or follow the log with:"
echo "  tail -f \"$LOG_DIR/agent.log\""
