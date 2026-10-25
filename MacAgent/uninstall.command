#!/bin/zsh
set -euo pipefail

LAUNCH_PLIST="$HOME/Library/LaunchAgents/com.applemacled.agent.plist"
APP_BUNDLE="$HOME/Applications/AppleMACLED Agent.app"
APP_SUPPORT="$HOME/Library/Application Support/AppleMAC-LED"
LABEL="com.applemacled.agent"
AUDIO_WATCHDOG_LABEL="com.applemacled.audio-watchdog"
AUDIO_WATCHDOG_PLIST="$HOME/Library/LaunchAgents/$AUDIO_WATCHDOG_LABEL.plist"
UID_VALUE="$(id -u)"

launchctl bootout "gui/$UID_VALUE/$AUDIO_WATCHDOG_LABEL" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_VALUE" "$AUDIO_WATCHDOG_PLIST" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_VALUE" "$LAUNCH_PLIST" >/dev/null 2>&1 || true
pkill -f "applemacled_agent.*daemon" >/dev/null 2>&1 || true
pkill -f "audio_watchdog.py" >/dev/null 2>&1 || true
pkill -f "AppleMACLEDAgent" >/dev/null 2>&1 || true
rm -f "$LAUNCH_PLIST" "$AUDIO_WATCHDOG_PLIST"
rm -rf "$APP_BUNDLE"

echo "AppleMAC-LED autostart and application were removed."
