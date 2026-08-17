#!/bin/zsh
set -u

APP_BUNDLE="$HOME/Applications/AppleMACLED Agent.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/AppleMACLEDAgent"
LABEL="com.applemacled.agent"
LEGACY_LABEL="com.applemacled.ble-agent"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/Library/Application Support/AppleMAC-LED/native-ui-state.json"
UID_VALUE="$(id -u)"

stop_agent() {
  launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE" "$LAUNCH_PLIST" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE/$LEGACY_LABEL" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE" "$LEGACY_PLIST" >/dev/null 2>&1 || true
  rm -f "$LEGACY_PLIST"
  pkill -f "esp32_usb_serial.py.*daemon" >/dev/null 2>&1 || true
  pkill -f "AppleMACLEDAgent" >/dev/null 2>&1 || true
  sleep 1
}

start_agent() {
  launchctl enable "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
  if [[ -f "$LAUNCH_PLIST" ]]; then
    launchctl bootstrap "gui/$UID_VALUE" "$LAUNCH_PLIST" >/dev/null 2>&1 || true
    launchctl kickstart -k "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
  fi
}

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  echo "Error: application not found:"
  echo "  $APP_BUNDLE"
  exit 1
fi

if ! /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
  echo "Error: the AppleMACLED Agent signature is invalid."
  echo "Run ./install.command from the MacAgent folder first."
  exit 1
fi

echo "Stopping the agent…"
stop_agent


echo "Resetting the stale Accessibility entry…"
/usr/bin/tccutil reset Accessibility com.applemacled.agent >/dev/null 2>&1 || \
  /usr/bin/tccutil reset Accessibility >/dev/null 2>&1 || true

rm -f "$STATE"
killall "System Settings" >/dev/null 2>&1 || true
sleep 1

echo "Launching the same signed application instance…"
open -n "$APP_BUNDLE"
sleep 2
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true

cat <<'TXT'

In the Accessibility settings page that opens:

1. Wait for AppleMACLED Agent to appear.
2. Enable the toggle.
3. If the entry does not appear, click "+" and select:
   ~/Applications/AppleMACLED Agent.app

Do not run install.command again after granting permission.
This command will continue automatically once macOS actually confirms access.
TXT

echo
printf "Waiting for axTrusted=true"
TRUSTED=0
for _ in {1..180}; do
  if [[ -f "$STATE" ]] && /usr/bin/grep -Eq '"axTrusted"[[:space:]]*:[[:space:]]*true' "$STATE"; then
    TRUSTED=1
    break
  fi
  printf "."
  sleep 1
done
printf "\n"

stop_agent

if (( TRUSTED == 1 )); then
  echo "Accessibility permission confirmed by the system: axTrusted=true."
  start_agent
  sleep 2
  echo
  echo "The agent has been started again. Verification:"
  echo "  ./diagnose.command"
  exit 0
fi

echo "macOS still reports axTrusted=false."
echo "Current state:"
cat "$STATE" 2>/dev/null || true
start_agent
exit 2
