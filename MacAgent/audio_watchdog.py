#!/usr/bin/env python3
"""AppleMAC-LED ScreenCaptureKit audio watchdog.

Restarts the main LaunchAgent only when the native audio state remains failed or
stale for several consecutive checks. A cooldown prevents restart loops.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

LABEL = "com.applemacled.agent"
UID = os.getuid()
DOMAIN = f"gui/{UID}"
AUDIO_STATE = Path.home() / "Library/Application Support/AppleMAC-LED/native-audio-state.json"
POLL_SECONDS = 5.0
START_GRACE_SECONDS = 35.0
STALE_SECONDS = 6.0
FAILURE_CHECKS_BEFORE_RESTART = 3
RESTART_COOLDOWN_SECONDS = 90.0
POST_RESTART_GRACE_SECONDS = 20.0

TRANSIENT_FAILURE_MARKERS = (
    "audio stopped",
    "audio unavailable",
    "audio output failed",
    "audio start failed",
    "не удалось найти дисплеи",
    "no display",
)
PERMANENT_FAILURE_MARKERS = (
    "not authorized",
    "permission denied",
    "requires macos",
    "не разреш",
    "нет разреш",
)


def log(message: str) -> None:
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{stamp}] {message}", flush=True)


def console_user_is_current() -> bool:
    try:
        result = subprocess.run(
            ["/usr/bin/stat", "-f", "%Su", "/dev/console"],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
        return result.stdout.strip() == os.environ.get("USER", "")
    except Exception:
        return True


def read_audio_health() -> tuple[bool, bool, str]:
    """Returns (healthy, permanent_failure, diagnostic)."""
    try:
        payload = json.loads(AUDIO_STATE.read_text(encoding="utf-8"))
        updated_at = float(payload.get("updatedAt", 0.0) or 0.0)
        age = max(0.0, time.time() - updated_at) if updated_at else 9999.0
        diagnostic = str(payload.get("diagnostic", "") or "").strip()
        lower = diagnostic.lower()

        if any(marker in lower for marker in PERMANENT_FAILURE_MARKERS):
            return False, True, diagnostic or "permanent audio permission error"
        if any(marker in lower for marker in TRANSIENT_FAILURE_MARKERS):
            return False, False, diagnostic or "ScreenCaptureKit transient failure"
        if age > STALE_SECONDS:
            return False, False, f"native-audio-state stale: {age:.1f}s; {diagnostic}"
        return True, False, diagnostic or "audio state fresh"
    except FileNotFoundError:
        return False, False, "native-audio-state.json is missing"
    except Exception as exc:
        return False, False, f"failed to read audio state: {exc}"


def restart_main_agent() -> bool:
    command = ["/bin/launchctl", "kickstart", "-k", f"{DOMAIN}/{LABEL}"]
    try:
        result = subprocess.run(command, check=False, capture_output=True, text=True, timeout=20)
        if result.returncode == 0:
            log("ScreenCaptureKit did not recover; the main AppleMAC-LED agent was restarted.")
            return True
        detail = (result.stderr or result.stdout or "unknown launchctl error").strip()
        log(f"Failed to restart the agent: {detail}")
    except Exception as exc:
        log(f"launchctl kickstart failed: {exc}")
    return False


def main() -> int:
    log("Audio watchdog 36.1 started.")
    time.sleep(START_GRACE_SECONDS)

    consecutive_failures = 0
    last_restart_at = 0.0
    last_diagnostic = ""
    last_permanent_log_at = 0.0

    while True:
        if not console_user_is_current():
            consecutive_failures = 0
            time.sleep(POLL_SECONDS)
            continue

        healthy, permanent, diagnostic = read_audio_health()
        now = time.monotonic()

        if healthy:
            if consecutive_failures:
                log(f"Audio monitor recovered: {diagnostic}")
            consecutive_failures = 0
            last_diagnostic = diagnostic
            time.sleep(POLL_SECONDS)
            continue

        if permanent:
            consecutive_failures = 0
            if now - last_permanent_log_at >= 60.0:
                log(f"Audio monitor requires permission; automatic restart is disabled: {diagnostic}")
                last_permanent_log_at = now
            time.sleep(POLL_SECONDS)
            continue

        consecutive_failures += 1
        if diagnostic != last_diagnostic:
            log(f"Audio monitor unavailable ({consecutive_failures}/{FAILURE_CHECKS_BEFORE_RESTART}): {diagnostic}")
            last_diagnostic = diagnostic

        cooldown_ready = now - last_restart_at >= RESTART_COOLDOWN_SECONDS
        if consecutive_failures >= FAILURE_CHECKS_BEFORE_RESTART and cooldown_ready:
            if restart_main_agent():
                last_restart_at = time.monotonic()
                consecutive_failures = 0
                time.sleep(POST_RESTART_GRACE_SECONDS)
                continue

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        log("Audio watchdog stopped.")
        raise SystemExit(0)
