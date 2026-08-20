#!/bin/zsh
set -euo pipefail

LAUNCH_PLIST="$HOME/Library/LaunchAgents/com.applemacled.agent.plist"
LEGACY_LAUNCH_PLIST="$HOME/Library/LaunchAgents/com.applemacled.ble-agent.plist"
APP_BUNDLE="$HOME/Applications/AppleMACLED Agent.app"
APP_SUPPORT="$HOME/Library/Application Support/AppleMAC-LED"
LABEL="com.applemacled.agent"
LEGACY_LABEL="com.applemacled.ble-agent"
AUDIO_WATCHDOG_LABEL="com.applemacled.audio-watchdog"
AUDIO_WATCHDOG_PLIST="$HOME/Library/LaunchAgents/$AUDIO_WATCHDOG_LABEL.plist"
UID_VALUE="$(id -u)"

launchctl bootout "gui/$UID_VALUE/$AUDIO_WATCHDOG_LABEL" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_VALUE" "$AUDIO_WATCHDOG_PLIST" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_VALUE" "$LAUNCH_PLIST" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_VALUE/$LEGACY_LABEL" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_VALUE" "$LEGACY_LAUNCH_PLIST" >/dev/null 2>&1 || true
pkill -f "esp32_usb_serial.*daemon" >/dev/null 2>&1 || true
pkill -f "audio_watchdog.py" >/dev/null 2>&1 || true
pkill -f "AppleMACLEDAgent" >/dev/null 2>&1 || true
rm -f "$LAUNCH_PLIST" "$LEGACY_LAUNCH_PLIST" "$AUDIO_WATCHDOG_PLIST"
rm -rf "$APP_BUNDLE"

# Monitor state and logs are intentionally preserved.
# To remove all runtime data as well, run:
# rm -rf "$APP_SUPPORT"

echo "AppleMAC-LED autostart and application were removed."
