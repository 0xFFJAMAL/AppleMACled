#!/usr/bin/env python3
"""AppleMAC-LED public macOS agent.

Owns the ESP32-S3 USB Serial link, sends lighting commands for selected macOS activity, and streams system-audio levels for the music overlay."""
from __future__ import print_function
import argparse
import asyncio
import json
import math
import os
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set, Tuple

def detach_supervised_daemon() -> None:
    if os.environ.get('APPLEMACLED_DAEMON_CHILD') != '1':
        return
    if os.environ.get('APPLEMACLED_DAEMON_DETACHED') == '1':
        return
    first_child = os.fork()
    if first_child > 0:
        os._exit(0)
    os.setsid()
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    second_child = os.fork()
    if second_child > 0:
        os._exit(0)
    os.environ['APPLEMACLED_DAEMON_DETACHED'] = '1'
    pid_file = Path(os.environ.get('APPLEMACLED_DAEMON_PID_FILE', str(Path.home() / 'Library' / 'Application Support' / 'AppleMAC-LED' / 'daemon.pid')))
    pid_file.parent.mkdir(parents=True, exist_ok=True)
    temporary = pid_file.with_name('%s.%d.tmp' % (pid_file.name, os.getpid()))
    temporary.write_text('%d\n' % os.getpid(), encoding='ascii')
    os.replace(str(temporary), str(pid_file))
detach_supervised_daemon()
try:
    import serial
    from serial.tools import list_ports
except ModuleNotFoundError:
    print('The pyserial package is not installed.', file=sys.stderr)
    print('Run the agent through send_usb_to_esp.command.', file=sys.stderr)
    raise SystemExit(2)

class SerialAgentError(RuntimeError):
    pass
try:
    import AppKit
except ModuleNotFoundError:
    print('The macOS AppKit Python module is not installed.', file=sys.stderr)
    print('Run the agent through send_usb_to_esp.command.', file=sys.stderr)
    raise SystemExit(2)

def configure_background_appkit() -> None:
    """Keep the background Python process out of the Dock."""
    try:
        application = AppKit.NSApplication.sharedApplication()
        policy = getattr(AppKit, 'NSApplicationActivationPolicyProhibited', 2)
        application.setActivationPolicy_(policy)
    except Exception as error:
        print('Could not enable AppKit background mode: %s' % error, file=sys.stderr)
configure_background_appkit()
USB_PROTOCOL_ID = 'APPLEMAC_LED_USB'
USB_PROTOCOL_VERSION = '1'
DEFAULT_SERIAL_BAUD = 115200
SERIAL_ENV_PORT = 'APPLEMACLED_SERIAL_PORT'
SERIAL_PORT_PATTERNS = ('/dev/cu.usbmodem', '/dev/cu.usbserial', '/dev/cu.SLAB_USBtoUART', '/dev/cu.wchusbserial')
APP_DIR = Path.home() / 'Library' / 'Application Support' / 'AppleMAC-LED'
IPC_SOCKET = APP_DIR / 'agent.sock'
NATIVE_UI_STATE_FILE = APP_DIR / 'native-ui-state.json'
NATIVE_AUDIO_STATE_FILE = APP_DIR / 'native-audio-state.json'
CODEX_SESSION_DIR = Path.home() / '.codex' / 'sessions'

@dataclass
class NativeUIState:
    ax_trusted: bool = False
    front_bundle: str = ''
    front_name: str = ''
    bluetooth_event_counter: int = 0
    bluetooth_device_name: str = ''
    finder_copy_active: bool = False
    finder_foreground: bool = False
    finder_diagnostic: str = ''
    trash_event_counter: int = 0
    chatgpt_tab_active: bool = False
    chatgpt_busy: bool = False
    safari_foreground: bool = False
    safari_diagnostic: str = ''
    safari_download_active: bool = False
    safari_download_count: int = 0
    safari_download_diagnostic: str = ''
    appstore_download_active: bool = False
    appstore_diagnostic: str = ''
    openai_app_active: bool = False
    openai_app_busy: bool = False
    openai_app_foreground: bool = False
    openai_app_name: str = ''
    openai_app_diagnostic: str = ''
    error: str = ''
CHATGPT_AX_SCAN_ELEMENT_LIMIT = 3500

def chatgpt_ax_scan_hit_limit(diagnostic: str) -> bool:
    if 'stop=not-found' not in diagnostic:
        return False
    match = re.search('\\belements=(\\d+)\\b', diagnostic)
    return bool(match and int(match.group(1)) >= CHATGPT_AX_SCAN_ELEMENT_LIMIT)

class CodexSessionActivityMonitor:
    """Tracks Codex task lifecycle markers without reading conversation text."""
    SCAN_INTERVAL_SECONDS = 1.0
    STARTUP_LOOKBACK_SECONDS = 180.0
    SEARCH_CHUNK_BYTES = 1024 * 1024
    STALE_ACTIVE_SECONDS = 2 * 60 * 60

    def __init__(self, session_dir: Path=CODEX_SESSION_DIR) -> None:
        self.session_dir = session_dir
        self.files = {}
        self.next_scan_at = 0.0
        self.was_present = False
        self.was_active = False

    @staticmethod
    def _last_lifecycle_marker(data: bytes) -> Optional[bool]:
        marker: Optional[bool] = None
        for raw_line in data.splitlines():
            if b'"task_started"' not in raw_line and b'"task_complete"' not in raw_line:
                continue
            if len(raw_line) > 64 * 1024:
                continue
            try:
                event = json.loads(raw_line.decode('utf-8'))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if event.get('type') != 'event_msg':
                continue
            payload = event.get('payload')
            event_type = payload.get('type') if isinstance(payload, dict) else ''
            if event_type == 'task_started':
                marker = True
            elif event_type == 'task_complete':
                marker = False
        return marker

    def _last_lifecycle_marker_in_file(self, path: Path, size: int) -> Optional[bool]:
        position = size
        carry = b''
        with path.open('rb') as stream:
            while position > 0:
                start = max(0, position - self.SEARCH_CHUNK_BYTES)
                stream.seek(start)
                data = stream.read(position - start) + carry
                if start > 0:
                    first_break = data.find(b'\n')
                    if first_break < 0:
                        carry = data
                        position = start
                        continue
                    carry = data[:first_break]
                    complete = data[first_break + 1:]
                else:
                    complete = data
                    carry = b''
                marker = self._last_lifecycle_marker(complete)
                if marker is not None:
                    return marker
                position = start
        return None

    def reset(self) -> None:
        self.files.clear()
        self.next_scan_at = 0.0
        self.was_active = False

    def _add_file(self, path: Path, now_wall: float) -> None:
        try:
            stat = path.stat()
            size = int(stat.st_size)
            active = False
            if now_wall - float(stat.st_mtime) <= self.STARTUP_LOOKBACK_SECONDS:
                marker = self._last_lifecycle_marker_in_file(path, size)
                active = marker is True
            self.files[path] = {'offset': size, 'partial': b'', 'active': active, 'updated_at': float(stat.st_mtime)}
        except (FileNotFoundError, OSError):
            return

    def _update_file(self, path: Path, state: dict) -> None:
        try:
            stat = path.stat()
            size = int(stat.st_size)
            offset = int(state.get('offset', 0))
            if size < offset:
                self.files.pop(path, None)
                self._add_file(path, time.time())
                return
            if size == offset:
                return
            with path.open('rb') as stream:
                stream.seek(offset)
                appended = stream.read(size - offset)
            combined = bytes(state.get('partial', b'')) + appended
            if combined.endswith(b'\n'):
                complete = combined
                partial = b''
            else:
                complete, separator, tail = combined.rpartition(b'\n')
                partial = tail if separator else combined
            marker = self._last_lifecycle_marker(complete)
            if marker is not None:
                state['active'] = marker
            state['offset'] = size
            state['partial'] = partial
            state['updated_at'] = float(stat.st_mtime)
        except (FileNotFoundError, OSError):
            self.files.pop(path, None)

    def poll(self, now: float, present: bool) -> Tuple[bool, bool, bool, int]:
        if not present:
            stopped = self.was_active
            if self.was_present:
                self.reset()
            self.was_present = False
            return (False, False, stopped, 0)
        self.was_present = True
        if now >= self.next_scan_at:
            now_wall = time.time()
            try:
                paths = set(self.session_dir.glob('*/*/*/rollout-*.jsonl'))
            except OSError:
                paths = set()
            for path in paths:
                state = self.files.get(path)
                if state is None:
                    self._add_file(path, now_wall)
                else:
                    self._update_file(path, state)
            for path in set(self.files) - paths:
                self.files.pop(path, None)
            for state in self.files.values():
                if state.get('active') and now_wall - float(state.get('updated_at', 0.0)) >= self.STALE_ACTIVE_SECONDS:
                    state['active'] = False
            self.next_scan_at = now + self.SCAN_INTERVAL_SECONDS
        active_count = sum((1 for state in self.files.values() if state.get('active')))
        active = active_count > 0
        started = active and (not self.was_active)
        stopped = self.was_active and (not active)
        self.was_active = active
        return (active, started, stopped, active_count)

class NativeUIStateMonitor:
    """Read state produced by the native application launcher."""
    STALE_SECONDS = 30.0

    def __init__(self) -> None:
        self.last_good = NativeUIState(error='waiting for the native UI monitor')
        self.last_mtime_ns = -1

    def poll(self) -> NativeUIState:
        try:
            stat = NATIVE_UI_STATE_FILE.stat()
            mtime_ns = int(stat.st_mtime_ns)
            if mtime_ns != self.last_mtime_ns:
                payload = json.loads(NATIVE_UI_STATE_FILE.read_text(encoding='utf-8'))
                if not isinstance(payload, dict):
                    raise ValueError('invalid JSON')
                updated_at = float(payload.get('updatedAt', 0.0) or 0.0)
                age = max(0.0, time.time() - updated_at) if updated_at else 9999.0
                state = NativeUIState(ax_trusted=bool(payload.get('axTrusted', False)), front_bundle=str(payload.get('frontBundle', '') or ''), front_name=str(payload.get('frontName', '') or ''), bluetooth_event_counter=int(payload.get('bluetoothEventCounter', 0) or 0), bluetooth_device_name=str(payload.get('bluetoothDeviceName', '') or ''), finder_copy_active=bool(payload.get('finderCopyActive', False)), finder_foreground=bool(payload.get('finderForeground', False)), finder_diagnostic=str(payload.get('finderDiagnostic', '') or ''), trash_event_counter=int(payload.get('trashEventCounter', 0) or 0), chatgpt_tab_active=bool(payload.get('safariChatGPTTabActive', False)), chatgpt_busy=bool(payload.get('safariChatGPTBusy', False)), safari_foreground=bool(payload.get('safariForeground', False)), safari_diagnostic=str(payload.get('safariDiagnostic', '') or ''), safari_download_active=bool(payload.get('safariDownloadActive', False)), safari_download_count=int(payload.get('safariDownloadCount', 0) or 0), safari_download_diagnostic=str(payload.get('safariDownloadDiagnostic', '') or ''), appstore_download_active=bool(payload.get('appStoreDownloadActive', False)), appstore_diagnostic=str(payload.get('appStoreDiagnostic', '') or ''), openai_app_active=bool(payload.get('openAIAppActive', False)), openai_app_busy=bool(payload.get('openAIAppBusy', False)), openai_app_foreground=bool(payload.get('openAIAppForeground', False)), openai_app_name=str(payload.get('openAIAppName', '') or ''), openai_app_diagnostic=str(payload.get('openAIAppDiagnostic', '') or ''), error='' if age <= self.STALE_SECONDS else 'the native UI monitor is stale')
                self.last_good = state
                self.last_mtime_ns = mtime_ns
            else:
                updated_age = max(0.0, time.time() - stat.st_mtime)
                if updated_age > self.STALE_SECONDS:
                    self.last_good.error = 'the native UI monitor is not updating'
            return self.last_good
        except FileNotFoundError:
            self.last_good.error = 'the native UI state file has not been created yet'
            return self.last_good
        except Exception as error:
            self.last_good.error = 'native UI monitor read error: %s' % error
            return self.last_good

@dataclass
class NativeAudioState:
    active: bool = False
    level: float = 0.0
    peak: float = 0.0
    beat: bool = False
    updated_at: float = 0.0
    fresh: bool = False
    diagnostic: str = ''
    error: str = ''

def clamp_unit_float(value: object) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return 0.0
    if result < 0.0:
        return 0.0
    if result > 1.0:
        return 1.0
    return result

class NativeAudioStateMonitor:
    """Read low-latency system-audio levels from native ScreenCaptureKit."""
    STALE_SECONDS = 1.5

    def __init__(self) -> None:
        self.last_good = NativeAudioState(error='waiting for the audio monitor')
        self.last_mtime_ns = -1

    def poll(self) -> NativeAudioState:
        try:
            stat = NATIVE_AUDIO_STATE_FILE.stat()
            mtime_ns = int(stat.st_mtime_ns)
            if mtime_ns != self.last_mtime_ns:
                payload = json.loads(NATIVE_AUDIO_STATE_FILE.read_text(encoding='utf-8'))
                if not isinstance(payload, dict):
                    raise ValueError('invalid JSON')
                updated_at = float(payload.get('updatedAt', 0.0) or 0.0)
                age = max(0.0, time.time() - updated_at) if updated_at else 9999.0
                fresh = age <= self.STALE_SECONDS
                diagnostic = str(payload.get('diagnostic', '') or '')
                diagnostic_lower = diagnostic.lower()
                failure_markers = ('audio stopped', 'audio unavailable', 'audio output failed', 'audio start failed', 'no displays were found', 'no display')
                monitor_failed = any((marker in diagnostic_lower for marker in failure_markers))
                healthy = fresh and (not monitor_failed)
                state = NativeAudioState(active=bool(payload.get('active', False)) and healthy, level=clamp_unit_float(payload.get('level', 0.0)) if healthy else 0.0, peak=clamp_unit_float(payload.get('peak', 0.0)) if healthy else 0.0, beat=bool(payload.get('beat', False)) and healthy, updated_at=updated_at, fresh=fresh, diagnostic=diagnostic, error=diagnostic if monitor_failed else '' if fresh else 'the audio monitor is stale')
                self.last_good = state
                self.last_mtime_ns = mtime_ns
            else:
                updated_age = max(0.0, time.time() - stat.st_mtime)
                if updated_age > self.STALE_SECONDS:
                    self.last_good.active = False
                    self.last_good.level = 0.0
                    self.last_good.peak = 0.0
                    self.last_good.beat = False
                    self.last_good.fresh = False
                    self.last_good.error = 'the audio monitor is not updating'
            return self.last_good
        except FileNotFoundError:
            self.last_good.active = False
            self.last_good.level = 0.0
            self.last_good.peak = 0.0
            self.last_good.beat = False
            self.last_good.fresh = False
            self.last_good.error = 'the audio state file has not been created yet'
            return self.last_good
        except Exception as error:
            self.last_good.active = False
            self.last_good.level = 0.0
            self.last_good.peak = 0.0
            self.last_good.beat = False
            self.last_good.fresh = False
            self.last_good.error = 'audio monitor read error: %s' % error
            return self.last_good

def audio_byte(value: float, *, gain: float, gamma: float) -> int:
    compressed = math.pow(clamp_unit_float(value * gain), gamma)
    return max(0, min(255, int(round(compressed * 255.0))))

async def audio_serial_loop(provisioner) -> None:
    monitor = NativeAudioStateMonitor()
    sequence = secrets.randbits(31)
    was_active = False
    last_error = ''
    last_diagnostic = ''
    last_error_log_at = 0.0
    last_send_error_at = 0.0
    active_hold_until = 0.0
    candidate_active_since = 0.0
    latest_raw_active = False
    target_level = 0.0
    target_peak = 0.0
    smooth_level = 0.0
    smooth_peak = 0.0
    baseline_level = 0.0
    baseline_peak = 0.0
    previous_level = 0.0
    previous_peak = 0.0
    last_native_updated_at = 0.0
    last_audio_iteration_at = 0.0
    last_beat_at = 0.0
    derived_beats = 0
    max_native_gap = 0.0
    max_audio_loop_gap = 0.0
    max_send_seconds = 0.0
    last_stream_diagnostic_at = time.monotonic()
    start_confirm_seconds = 0.9
    active_hold_seconds = 1.15
    while True:
        now = time.monotonic()
        if last_audio_iteration_at > 0.0:
            max_audio_loop_gap = max(max_audio_loop_gap, now - last_audio_iteration_at)
        last_audio_iteration_at = now
        state = monitor.poll()
        sample_changed = bool(state.updated_at > 0.0 and state.updated_at != last_native_updated_at)
        beat = False
        if sample_changed:
            if last_native_updated_at > 0.0:
                native_gap = state.updated_at - last_native_updated_at
                if 0.0 < native_gap < 60.0:
                    max_native_gap = max(max_native_gap, native_gap)
            last_native_updated_at = state.updated_at
            latest_raw_active = bool(not state.error and state.fresh and state.active and (state.level >= 0.015 or state.peak >= 0.04))
            if latest_raw_active:
                target_level = state.level
                target_peak = state.peak
                if baseline_level > 0.0 and baseline_peak > 0.0:
                    level_rise = state.level - previous_level
                    peak_rise = state.peak - previous_peak
                    peak_ratio = state.peak / max(0.08, baseline_peak)
                    level_ratio = state.level / max(0.08, baseline_level)
                    derived_beat = bool(now - last_beat_at >= 0.18 and state.peak >= 0.14 and (peak_rise >= 0.055 and peak_ratio >= 1.05 or peak_ratio >= 1.3 or (level_rise >= 0.045 and level_ratio >= 1.06)))
                else:
                    derived_beat = False
                beat = bool(state.beat or derived_beat)
                if beat:
                    last_beat_at = now
                    derived_beats += 1
                baseline_alpha = 0.015 if beat else 0.06
                if baseline_level <= 0.0:
                    baseline_level = state.level
                    baseline_peak = state.peak
                else:
                    baseline_level += (state.level - baseline_level) * baseline_alpha
                    baseline_peak += (state.peak - baseline_peak) * baseline_alpha
                previous_level = state.level
                previous_peak = state.peak
            else:
                target_level = 0.0
                target_peak = 0.0
        elif state.error or not state.fresh:
            latest_raw_active = False
            target_level = 0.0
            target_peak = 0.0
        raw_active = latest_raw_active
        if raw_active:
            if candidate_active_since <= 0.0:
                candidate_active_since = now
            if was_active or now - candidate_active_since >= start_confirm_seconds:
                active_hold_until = now + active_hold_seconds
        else:
            candidate_active_since = 0.0
        level_follow = 0.46 if target_level > smooth_level else 0.16
        peak_follow = 0.64 if target_peak > smooth_peak else 0.24
        smooth_level += (target_level - smooth_level) * level_follow
        smooth_peak += (target_peak - smooth_peak) * peak_follow
        if smooth_level < 0.002:
            smooth_level = 0.0
        if smooth_peak < 0.004:
            smooth_peak = 0.0
        active = bool(now <= active_hold_until and (smooth_level >= 0.01 or smooth_peak >= 0.02))
        if state.diagnostic and state.diagnostic != last_diagnostic:
            if state.diagnostic not in {'ScreenCaptureKit audio active', 'ScreenCaptureKit audio idle'}:
                print('Audio: %s' % state.diagnostic)
            last_diagnostic = state.diagnostic
        if state.error:
            if state.error != last_error and now - last_error_log_at >= 20.0:
                print('Audio: %s.' % state.error)
                last_error_log_at = now
            last_error = state.error
        elif last_error:
            print('Audio: the system-audio monitor is ready.')
            last_error = ''
        if active or was_active:
            sequence = sequence + 1 & 4294967295
            output_level = audio_byte(smooth_level if active else 0.0, gain=0.95, gamma=0.85)
            output_peak = audio_byte(smooth_peak if active else 0.0, gain=1.35, gamma=0.75)
            try:
                send_started_at = time.monotonic()
                provisioner.send_audio_realtime(sequence, output_level, output_peak, bool(beat if raw_active and active else False), active)
                max_send_seconds = max(max_send_seconds, time.monotonic() - send_started_at)
            except Exception as error:
                if now - last_send_error_at >= 10.0 and (not provisioner.suspended):
                    print('Audio USB: could not send the level to the ESP: %s' % error)
                    last_send_error_at = now
            if active and now - last_stream_diagnostic_at >= 20.0:
                print('Audio stream: level=%d, peak=%d, beats=%d, native-gap-max=%.3fs, loop-gap-max=%.3fs, usb-send-max=%.3fs.' % (output_level, output_peak, derived_beats, max_native_gap, max_audio_loop_gap, max_send_seconds))
                derived_beats = 0
                max_native_gap = 0.0
                max_audio_loop_gap = 0.0
                max_send_seconds = 0.0
                last_stream_diagnostic_at = now
        if active and (not was_active):
            print('Audio: system audio is active; enabling the music overlay over USB Serial.')
        elif not active and was_active:
            print('Audio: system audio is idle; clearing the music overlay.')
        was_active = active
        await asyncio.sleep(0.025)

def audio_serial_thread_main(provisioner) -> None:
    """Run real-time audio outside the monitor/control asyncio event loop."""
    try:
        asyncio.run(audio_serial_loop(provisioner))
    except Exception as error:
        print('Audio thread: the music stream stopped unexpectedly: %s' % error)

class WiFiConnectionEventMonitor:
    """Emit an event only for a new Wi-Fi connection or SSID change."""
    POLL_SECONDS = 1.0

    def __init__(self) -> None:
        self.initialized = False
        self.last_ssid = ''
        self.next_poll_at = 0.0
        self.last_event_ssid = ''
        self.last_event_at = 0.0

    def poll(self, now: float) -> Optional[str]:
        if now < self.next_poll_at:
            return None
        self.next_poll_at = now + self.POLL_SECONDS
        try:
            ssid = get_current_ssid_fallback().strip()
        except Exception:
            ssid = ''
        if not self.initialized:
            self.initialized = True
            self.last_ssid = ssid
            return None
        previous = self.last_ssid
        self.last_ssid = ssid
        if not ssid:
            return None
        connected_now = not previous or previous != ssid
        if not connected_now:
            return None
        if ssid == self.last_event_ssid and now - self.last_event_at < 5.0:
            return None
        self.last_event_ssid = ssid
        self.last_event_at = now
        return ssid

class AppStoreProcessMonitor:
    """Conservative fallback monitor for App Store download processes."""
    POLL_SECONDS = 0.75
    HOLD_SECONDS = 8.0
    CPU_ACTIVE_THRESHOLD = 0.5
    PROCESS_PATTERNS = {'storedownloadd', 'appstoredownloadd', 'storeassetd'}

    def __init__(self) -> None:
        self.initialized = False
        self.next_poll_at = 0.0
        self.active_until = 0.0
        self.previous_names: Set[str] = set()
        self.last_diag = 'waiting for App Store processes'

    def poll(self, now: float) -> Tuple[bool, str]:
        if now < self.next_poll_at:
            return (now < self.active_until, self.last_diag)
        self.next_poll_at = now + self.POLL_SECONDS
        result = run_command(['/bin/ps', '-axo', 'comm=,%cpu='])
        if result.returncode != 0:
            self.last_diag = 'ps did not return App Store processes'
            return (now < self.active_until, self.last_diag)
        current: Set[str] = set()
        busy_names: Set[str] = set()
        for line in result.stdout.splitlines():
            raw = line.rstrip()
            if not raw:
                continue
            parts = raw.rsplit(None, 1)
            if len(parts) != 2:
                continue
            command, cpu_text = parts
            name = Path(command.strip()).name.lower()
            matched = next((pattern for pattern in self.PROCESS_PATTERNS if pattern in name), None)
            if matched is None:
                continue
            current.add(name)
            try:
                cpu = float(cpu_text.replace(',', '.'))
            except ValueError:
                cpu = 0.0
            threshold = 1.0 if 'storeasset' in name else self.CPU_ACTIVE_THRESHOLD
            if cpu >= threshold:
                busy_names.add(name)
        if busy_names:
            self.active_until = now + self.HOLD_SECONDS
        self.initialized = True
        self.previous_names = current
        details = sorted(busy_names or current)
        if details:
            self.last_diag = 'download-process=%s, hold=%s' % (','.join(details), 'yes' if now < self.active_until else 'no')
        else:
            self.last_diag = 'App Store download processes are inactive'
        return (now < self.active_until, self.last_diag)

class ArduinoIdeActivityMonitor:
    """Detect an actual compile or upload from Arduino IDE."""
    POLL_SECONDS = 0.2
    HOLD_SECONDS = 1.5
    COMPILE_PATTERNS = ('arduino-cli compile', 'arduino-builder', 'xtensa-esp32s3-elf-g++', 'xtensa-esp32s3-elf-gcc', 'xtensa-esp32s3-elf-ar', 'riscv32-esp-elf-g++', 'riscv32-esp-elf-gcc', 'riscv32-esp-elf-ar')
    UPLOAD_PATTERNS = ('arduino-cli upload', 'espota.py', '/avrdude ', '/bossac ', '/dfu-util ', '/openocd ', '/picotool ', '/rp2040load ', '/teensy_post_compile ')
    PACKAGE_COMPILE_PATTERNS = ('-elf-g++', '-elf-gcc', '-elf-ar', '-elf-ld', '/avr-g++', '/avr-gcc', '/avr-ar', '/avr-ld', '/cc1 ', '/cc1plus ', '/collect2 ', '/objcopy ', 'elf2bin', 'elf2image', 'gen_esp32part', 'merge_bin', 'merge-bin', 'mklittlefs', 'mkspiffs', '/ctags ')
    INDEXER_PATTERNS = ('arduino-language-server', '.libsdetect.d')

    def __init__(self) -> None:
        self.next_poll_at = 0.0
        self.active_until = 0.0
        self.last_mode = ''
        self.last_upload_uses_main_usb = False
        self.last_diag = 'Arduino IDE is waiting for compile or upload activity'

    @classmethod
    def classify_command(cls, command: str) -> str:
        normalized = command.casefold()
        padded = ' %s ' % normalized
        if any((pattern in normalized for pattern in cls.INDEXER_PATTERNS)):
            return ''
        if ' -e ' in padded and ' -o /dev/null ' in padded:
            return ''
        if any((pattern in normalized for pattern in cls.UPLOAD_PATTERNS)):
            return 'upload'
        is_esptool = 'esptool.py' in normalized or '/esptool ' in normalized
        if is_esptool and ('write_flash' in normalized or 'write-flash' in normalized):
            return 'upload'
        if is_esptool and ('merge_bin' in normalized or 'merge-bin' in normalized):
            return 'compile'
        if any((pattern in normalized for pattern in cls.COMPILE_PATTERNS)):
            return 'compile'
        if '/arduino15/packages/' in normalized:
            if any((pattern in normalized for pattern in cls.PACKAGE_COMPILE_PATTERNS)):
                return 'compile'
            if ' -c ' in padded and ' -o ' in padded:
                return 'compile'
        return ''

    @staticmethod
    def _serial_port_aliases(port_name: str) -> Set[str]:
        if not port_name.startswith(('/dev/cu.', '/dev/tty.')):
            return set()
        aliases = {port_name}
        if port_name.startswith('/dev/cu.'):
            aliases.add('/dev/tty.%s' % port_name[len('/dev/cu.'):])
        else:
            aliases.add('/dev/cu.%s' % port_name[len('/dev/tty.'):])
        return aliases

    @classmethod
    def upload_targets_main_usb(cls, command: str, main_usb_port: str) -> bool:
        """True only when an upload explicitly uses the main ESP USB port."""
        normalized = command.casefold()
        if 'espota.py' in normalized:
            return False
        main_aliases = cls._serial_port_aliases(main_usb_port)
        if not main_aliases:
            return False
        command_ports = set(re.findall('/dev/(?:cu|tty)\\.[a-zA-Z0-9._-]+', command))
        return bool(main_aliases.intersection(command_ports))

    def poll(self, now: float, main_usb_port: str='') -> Tuple[bool, str, str, bool]:
        if now < self.next_poll_at:
            active = now < self.active_until
            active_mode = self.last_mode if active else ''
            return (active, active_mode, self.last_diag, bool(active_mode == 'upload' and self.last_upload_uses_main_usb))
        self.next_poll_at = now + self.POLL_SECONDS
        result = run_command(['/bin/ps', '-axo', 'command='])
        if result.returncode != 0:
            active = now < self.active_until
            self.last_diag = 'ps did not return Arduino IDE processes'
            active_mode = self.last_mode if active else ''
            return (active, active_mode, self.last_diag, bool(active_mode == 'upload' and self.last_upload_uses_main_usb))
        classified_commands = [(self.classify_command(line), line) for line in result.stdout.splitlines() if line.strip()]
        modes = {mode for mode, _command in classified_commands}
        modes.discard('')
        if 'upload' in modes:
            mode = 'upload'
        elif 'compile' in modes:
            mode = 'compile'
        else:
            mode = ''
        if mode:
            self.last_mode = mode
            self.active_until = now + self.HOLD_SECONDS
            self.last_upload_uses_main_usb = bool(mode == 'upload' and any((command_mode == 'upload' and self.upload_targets_main_usb(command, main_usb_port) for command_mode, command in classified_commands)))
        active = now < self.active_until
        active_mode = self.last_mode if active else ''
        if active_mode == 'upload':
            if self.last_upload_uses_main_usb:
                self.last_diag = 'Arduino IDE is uploading to the main ESP over USB; releasing the port temporarily'
            else:
                self.last_diag = 'Arduino IDE is uploading to another board or OTA; keeping the main ESP USB connected'
        elif active_mode == 'compile':
            self.last_diag = 'Arduino IDE is compiling a sketch'
        else:
            self.last_diag = 'Arduino IDE is not compiling or uploading'
        return (active, active_mode, self.last_diag, bool(active_mode == 'upload' and self.last_upload_uses_main_usb))

def run_command(command: Sequence[str], *, inherit_stderr: bool=False) -> subprocess.CompletedProcess:
    return subprocess.run(list(command), stdout=subprocess.PIPE, stderr=None if inherit_stderr else subprocess.PIPE, text=True, check=False)

def list_system_interfaces() -> List[str]:
    """Return the network interface names reported by macOS."""
    result = run_command(['/sbin/ifconfig', '-l'])
    if result.returncode != 0:
        return []
    return [value for value in result.stdout.split() if value]

def ensure_app_dir() -> None:
    APP_DIR.mkdir(parents=True, exist_ok=True)
    try:
        APP_DIR.chmod(448)
    except OSError:
        pass

def find_wifi_interface() -> str:
    result = run_command(['/usr/sbin/networksetup', '-listallhardwareports'])
    if result.returncode != 0:
        raise RuntimeError((result.stderr or '').strip() or 'networksetup failed')
    blocks = re.split('\\n\\s*\\n', result.stdout)
    for block in blocks:
        if re.search('Hardware Port:\\s*(Wi-Fi|AirPort)\\s*$', block, re.MULTILINE):
            match = re.search('Device:\\s*(\\S+)', block)
            if match:
                return match.group(1)
    raise RuntimeError('The Mac Wi-Fi interface was not found')

def get_current_ssid_fallback() -> str:
    interface = find_wifi_interface()
    result = run_command(['/usr/sbin/networksetup', '-getairportnetwork', interface])
    output = (result.stdout + '\n' + (result.stderr or '')).strip()
    if result.returncode == 0 and output:
        lowered = output.lower()
        if 'not associated' not in lowered and 'not associated' not in lowered and ('<redacted>' not in lowered):
            match = re.search('Current (?:Wi-Fi|AirPort) Network:\\s*(.+)$', output, re.MULTILINE)
            if match and match.group(1).strip():
                return match.group(1).strip()
    summary = run_command(['/usr/sbin/ipconfig', 'getsummary', interface])
    match = re.search('^\\s*SSID\\s*:\\s*(.+?)\\s*$', summary.stdout, re.MULTILINE)
    if match and match.group(1).strip():
        return match.group(1).strip()
    raise RuntimeError('Could not determine the current Wi-Fi network')

def parse_decision(status: str) -> str:
    match = re.search('(?:^|\\|)DECISION:(NONE|OK|NC)(?:\\||$)', status)
    return match.group(1) if match else 'NONE'

def get_interface_io_bytes(interface: str) -> Tuple[int, int]:
    """Return interface receive and transmit byte counters."""
    result = run_command(['/usr/sbin/netstat', '-ibn', '-I', interface])
    if result.returncode == 0:
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        ibytes_index: Optional[int] = None
        obytes_index: Optional[int] = None
        values: List[Tuple[int, int]] = []
        for line in lines:
            columns = line.split()
            if 'Ibytes' in columns and 'Obytes' in columns:
                ibytes_index = columns.index('Ibytes')
                obytes_index = columns.index('Obytes')
                continue
            if ibytes_index is not None and obytes_index is not None and columns and (columns[0] == interface) and (len(columns) > max(ibytes_index, obytes_index)):
                try:
                    values.append((int(columns[ibytes_index]), int(columns[obytes_index])))
                except ValueError:
                    pass
        if values:
            return max(values, key=lambda item: item[0] + item[1])
    fallback = run_command(['/sbin/ifconfig', interface])
    input_match = re.search('input packets\\s+\\d+\\s+bytes\\s+(\\d+)', fallback.stdout)
    output_match = re.search('output packets\\s+\\d+\\s+bytes\\s+(\\d+)', fallback.stdout)
    if input_match and output_match:
        return (int(input_match.group(1)), int(output_match.group(1)))
    raise RuntimeError('Could not read traffic counters for %s' % interface)

class AirDropTrafficMonitor:
    """Detect both AirDrop receive and send activity quickly."""

    def __init__(self, threshold_kbps: float=24.0, sample_seconds: float=0.1) -> None:
        self.threshold_bytes = threshold_kbps * 1024.0
        self.sample_seconds = sample_seconds
        self.last_sample_at = 0.0
        self.previous: Optional[Tuple[int, int]] = None
        self.previous_time: Optional[float] = None
        self.last_activity_at = 0.0
        self.active = False
        self.last_rate = 0.0
        self.direction = 'AirDrop'
        self.connection_was_active = False
        self.last_connection_probe_at = 0.0
        self.cached_connection = False

    def _interfaces(self) -> List[str]:
        values = []
        for name in list_system_interfaces():
            if name.startswith(('awdl', 'llw')) and name not in values:
                values.append(name)
        for name in ('awdl0', 'llw0'):
            if name not in values:
                values.append(name)
        return values

    def _totals(self) -> Optional[Tuple[int, int]]:
        rx = 0
        tx = 0
        found = False
        for interface in self._interfaces():
            try:
                current_rx, current_tx = get_interface_io_bytes(interface)
                rx += current_rx
                tx += current_tx
                found = True
            except RuntimeError:
                continue
        return (rx, tx) if found else None

    def _sharingd_link_connection(self, now: float) -> bool:
        if now - self.last_connection_probe_at < 0.25:
            return self.cached_connection
        self.last_connection_probe_at = now
        lsof = Path('/usr/sbin/lsof')
        if not lsof.exists():
            self.cached_connection = False
            return False
        result = run_command([str(lsof), '-nP', '-a', '-c', 'sharingd', '-iTCP', '-sTCP:ESTABLISHED', '-Fn'])
        text = result.stdout.casefold()
        self.cached_connection = '%awdl' in text or '%llw' in text or '169.254.' in text
        return self.cached_connection

    def poll(self) -> Tuple[bool, float, str]:
        now = time.monotonic()
        if now - self.last_sample_at < self.sample_seconds:
            return (self.active, self.last_rate, self.direction)
        self.last_sample_at = now
        connection = self._sharingd_link_connection(now)
        connection_rising = connection and (not self.connection_was_active)
        self.connection_was_active = connection
        totals = self._totals()
        if totals is not None and self.previous is not None and (self.previous_time is not None):
            elapsed = max(now - self.previous_time, 0.001)
            delta_rx = max(0, totals[0] - self.previous[0])
            delta_tx = max(0, totals[1] - self.previous[1])
            rx_rate = delta_rx / elapsed
            tx_rate = delta_tx / elapsed
            self.last_rate = rx_rate + tx_rate
            if tx_rate > rx_rate * 1.2:
                self.direction = 'AirDrop send'
            elif rx_rate > tx_rate * 1.2:
                self.direction = 'AirDrop receive'
            else:
                self.direction = 'AirDrop'
            if self.last_rate >= self.threshold_bytes or (connection and self.last_rate >= 4.0 * 1024.0):
                self.last_activity_at = now
        if connection_rising:
            self.last_activity_at = now
        if totals is not None:
            self.previous = totals
            self.previous_time = now
        else:
            self.previous = None
            self.previous_time = None
            self.last_rate = 0.0
        should_be_active = now - self.last_activity_at < 0.75
        self.active = should_be_active
        return (self.active, self.last_rate, self.direction)

class SerialProvisioner:
    """Self-healing USB Serial transport for the ESP32-S3."""

    def __init__(self, port: Optional[str]=None, baud: int=DEFAULT_SERIAL_BAUD, timeout: float=12.0) -> None:
        self.explicit_port = port or os.environ.get(SERIAL_ENV_PORT, '').strip() or None
        self.baud = int(baud)
        self.timeout = float(timeout)
        self._serial = None
        self._port_name = ''
        self._lock = asyncio.Lock()
        self._write_lock = threading.RLock()
        self._disconnect_generation = 0
        self._suspended = False

    @property
    def disconnect_generation(self) -> int:
        return self._disconnect_generation

    @property
    def port_name(self) -> str:
        return self._port_name or 'not connected'

    @property
    def suspended(self) -> bool:
        return self._suspended

    def _candidate_ports(self) -> List[str]:
        if self.explicit_port:
            return [self.explicit_port]
        espressif = []
        fallback = []
        for item in list_ports.comports():
            device = str(getattr(item, 'device', '') or '')
            if not device.startswith('/dev/cu.'):
                continue
            description = str(getattr(item, 'description', '') or '').casefold()
            manufacturer = str(getattr(item, 'manufacturer', '') or '').casefold()
            vid = getattr(item, 'vid', None)
            pid = getattr(item, 'pid', None)
            if vid == 12346:
                score = 200
                if pid == 4097:
                    score += 30
                if device.startswith('/dev/cu.usbmodem'):
                    score += 20
                espressif.append((score, device))
                continue
            if device.startswith('/dev/cu.usbmodem') and ('esp' in description or 'espressif' in manufacturer):
                fallback.append((100, device))
        selected = espressif if espressif else fallback
        selected.sort(key=lambda item: (-item[0], item[1]))
        return [device for _score, device in selected]

    def list_ports_text(self) -> str:
        rows = []
        for item in list_ports.comports():
            rows.append('%s — %s%s' % (getattr(item, 'device', '?'), getattr(item, 'description', 'unknown device'), ' [VID:PID=%04X:%04X]' % (item.vid, item.pid) if getattr(item, 'vid', None) is not None and getattr(item, 'pid', None) is not None else ''))
        return '\n'.join(rows) if rows else 'No USB Serial ports found.'

    def _close_sync(self, *, disconnected: bool=True) -> None:
        with self._write_lock:
            handle = self._serial
            had_connection = handle is not None or bool(self._port_name)
            self._serial = None
            self._port_name = ''
            if handle is not None:
                try:
                    handle.close()
                except Exception:
                    pass
        if disconnected and had_connection:
            self._disconnect_generation += 1

    def _read_response_sync(self, prefixes: Sequence[str], timeout: float) -> Optional[str]:
        if self._serial is None:
            return None
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                raw = self._serial.readline()
            except (serial.SerialException, OSError) as error:
                self._close_sync()
                raise SerialAgentError('USB Serial read failed: %s' % error)
            if not raw:
                continue
            line = raw.decode('utf-8', errors='replace').strip()
            if not line:
                continue
            if line.startswith('RSP:'):
                message = line[4:]
                if not message.startswith(('AUDIO_',)):
                    print('ESP32:', message)
                if any((message.startswith(prefix) for prefix in prefixes)):
                    return message
            elif line.startswith('LOG:'):
                print('ESP32:', line[4:])
        return None

    def _write_line_sync(self, command: str, *, flush_output: bool=False) -> None:
        with self._write_lock:
            if self._serial is None:
                raise SerialAgentError('USB Serial is not connected')
            payload = ('CMD:%s\n' % command).encode('utf-8')
            try:
                self._serial.write(payload)
                if flush_output:
                    self._serial.flush()
            except (serial.SerialException, serial.SerialTimeoutException, OSError) as error:
                self._close_sync()
                raise SerialAgentError('USB Serial write failed: %s' % error)

    def _probe_port_sync(self, port_name: str):
        try:
            handle = serial.Serial(port=port_name, baudrate=self.baud, timeout=0.12, write_timeout=1.0, rtscts=False, dsrdtr=False, xonxoff=False)
        except (serial.SerialException, OSError) as error:
            raise SerialAgentError('%s: %s' % (port_name, error))
        try:
            native_usb_cdc = port_name.startswith('/dev/cu.usbmodem')
            try:
                handle.dtr = bool(native_usb_cdc)
                handle.rts = False
            except Exception:
                pass
            time.sleep(1.0 if native_usb_cdc else 0.2)
            handle.reset_input_buffer()
            handle.reset_output_buffer()
            probe_timeout = max(2.0, min(self.timeout, 4.0))
            deadline = time.monotonic() + probe_timeout
            next_hello = 0.0
            seen_lines = []
            while time.monotonic() < deadline:
                now = time.monotonic()
                if now >= next_hello:
                    handle.write(b'CMD:HELLO\n')
                    handle.flush()
                    next_hello = now + 0.65
                raw = handle.readline()
                if not raw:
                    continue
                line = raw.decode('utf-8', errors='replace').strip()
                if not line:
                    continue
                seen_lines.append(line)
                if len(seen_lines) > 8:
                    seen_lines.pop(0)
                if line == 'RSP:HELLO:%s:%s' % (USB_PROTOCOL_ID, USB_PROTOCOL_VERSION):
                    return handle
            detail = ''
            if seen_lines:
                detail = '; latest ESP lines: ' + ' | '.join(seen_lines)
            raise SerialAgentError('USB HELLO was not received' + detail)
        except Exception:
            try:
                handle.close()
            except Exception:
                pass
            raise

    def _ensure_serial_sync(self):
        if self._suspended:
            raise SerialAgentError('USB Serial is temporarily released for Arduino flashing')
        if self._serial is not None and self._serial.is_open:
            if self._port_name and os.path.exists(self._port_name):
                return self._serial
            self._close_sync()
        candidates = self._candidate_ports()
        if not candidates:
            raise SerialAgentError('ESP32-S3 USB Serial was not found. Check the cable and USB CDC On Boot.')
        errors = []
        for port_name in candidates:
            try:
                handle = self._probe_port_sync(port_name)
                self._serial = handle
                self._port_name = port_name
                print('Persistent USB Serial connection established with the ESP32: %s.' % port_name)
                return handle
            except Exception as error:
                errors.append('%s (%s)' % (port_name, error))
        raise SerialAgentError('The ESP32-S3 did not answer over USB Serial. Checked: %s' % '; '.join(errors))

    def _request_sync(self, command: str, prefixes: Sequence[str], timeout: float) -> str:
        self._ensure_serial_sync()
        self._write_line_sync(command)
        result = self._read_response_sync(prefixes, timeout)
        if result is None:
            self._close_sync()
            raise SerialAgentError('The ESP32 did not answer %s' % command)
        if result.startswith('ERROR:'):
            raise SerialAgentError('The ESP32 rejected %s: %s' % (command, result))
        return result

    async def _run(self, function, *, retries: int=2):
        async with self._lock:
            last_error = None
            for attempt in range(retries):
                try:
                    return await asyncio.to_thread(function)
                except (SerialAgentError, serial.SerialException, OSError) as error:
                    last_error = error
                    await asyncio.to_thread(self._close_sync)
                    if attempt + 1 < retries and (not self._suspended):
                        await asyncio.sleep(0.45)
                        continue
                    raise
            raise last_error or SerialAgentError('USB Serial operation failed')

    async def set_suspended(self, suspended: bool) -> None:
        suspended = bool(suspended)
        if suspended == self._suspended:
            return
        self._suspended = suspended
        if suspended:
            async with self._lock:
                await asyncio.to_thread(self._close_sync, disconnected=False)
            print('USB Serial was released for an Arduino upload.')
        else:
            print('The Arduino upload finished; USB Serial is available to the agent again.')
            self._disconnect_generation += 1

    async def force_reconnect(self) -> None:
        """Close even a nominally open descriptor and rediscover the ESP."""
        async with self._lock:
            await asyncio.to_thread(self._close_sync, disconnected=False)
        self._disconnect_generation += 1

    async def _command(self, command: str, expected: str, timeout: float=4.0) -> int:

        def operation():
            result = self._request_sync(command, [expected, 'ERROR:'], timeout)
            if result != expected:
                raise SerialAgentError('The ESP32 did not accept %s: %s' % (command, result))
            return 0
        return await self._run(operation)

    async def enter_waiting(self) -> int:
        return await self._command('WAIT', 'WAIT')

    async def send_ok(self) -> int:
        return await self._command('OK', 'OK')

    async def set_snake(self, enabled: bool) -> int:
        command = 'SNAKE_ON' if enabled else 'SNAKE_OFF'
        return await self._command(command, command)

    async def set_copy_snake(self, enabled: bool) -> int:
        command = 'COPY_ON' if enabled else 'COPY_OFF'
        return await self._command(command, command)

    async def set_chatgpt_snake(self, enabled: bool) -> int:
        command = 'CHATGPT_ON' if enabled else 'CHATGPT_OFF'
        return await self._command(command, command)

    async def set_appstore_snake(self, enabled: bool) -> int:
        command = 'APPSTORE_ON' if enabled else 'APPSTORE_OFF'
        return await self._command(command, command)

    async def flash_trash(self) -> int:
        return await self._command('TRASH_FLASH', 'TRASH_FLASH')

    async def system_blue(self) -> int:
        return await self._command('SYSTEM_BLUE', 'SYSTEM_BLUE')

    async def get_status_persistent(self) -> Tuple[str, None]:

        def operation():
            return self._request_sync('STATUS', ['USB:', 'ERROR:'], 6.0)
        status = await self._run(operation)
        return (status, None)

    async def get_status(self) -> Tuple[str, None]:
        return await self.get_status_persistent()

    async def reboot_persistent(self) -> int:
        result = await self._command('REBOOT', 'REBOOTING', timeout=6.0)
        async with self._lock:
            await asyncio.to_thread(self._close_sync)
        return result

    async def reboot(self) -> int:
        return await self.reboot_persistent()

    async def send_audio(self, sequence: int, level: int, peak: int, beat: bool, active: bool) -> None:
        await asyncio.to_thread(self.send_audio_realtime, sequence, level, peak, beat, active)

    def send_audio_realtime(self, sequence: int, level: int, peak: int, beat: bool, active: bool) -> None:
        command = 'AUDIO:%u:%u:%u:%u:%u' % (sequence & 4294967295, max(0, min(255, int(level))), max(0, min(255, int(peak))), 1 if beat else 0, 1 if active else 0)
        if self._suspended:
            raise SerialAgentError('USB Serial is temporarily released for Arduino flashing')
        if self._serial is None or not self._serial.is_open:
            raise SerialAgentError('USB Serial is not connected')
        if self._port_name and (not os.path.exists(self._port_name)):
            raise SerialAgentError('The USB Serial port disappeared')
        self._write_line_sync(command, flush_output=False)
async def send_command_to_running_agent(command: str, **payload) -> Optional[dict]:
    """Send a manual command through the already-running agent IPC socket."""
    if not IPC_SOCKET.exists():
        return None
    try:
        reader, writer = await asyncio.wait_for(asyncio.open_unix_connection(str(IPC_SOCKET)), timeout=1.0)
    except (OSError, asyncio.TimeoutError):
        try:
            IPC_SOCKET.unlink()
        except OSError:
            pass
        return None
    try:
        request = {'command': command}
        request.update(payload)
        writer.write((json.dumps(request) + '\n').encode('utf-8'))
        await writer.drain()
        try:
            ipc_timeout = 15.0
            raw = await asyncio.wait_for(reader.readline(), timeout=ipc_timeout)
        except asyncio.TimeoutError:
            return {'ok': False, 'message': 'The agent did not complete the command within %.0f seconds.' % 15.0}
        if not raw:
            raise RuntimeError('the agent closed IPC without a response')
        response = json.loads(raw.decode('utf-8', errors='replace'))
        if not isinstance(response, dict):
            raise RuntimeError('the agent returned an invalid IPC response')
        return response
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass

async def daemon_loop(provisioner: SerialProvisioner, *, health_interval: float, copy_poll_interval: float) -> int:
    print('AppleMAC-LED public agent 1.0 started.')
    print('The ESP USB link is checked at startup and every %.0f seconds.' % health_interval)
    print('Monitoring Finder, Trash, Safari, App Store, Arduino IDE, ChatGPT/Codex, AirDrop, Bluetooth, Wi-Fi, and system audio.')
    print('Desktop and Documents folder access is not required.')
    print('Safari and App Store downloads are persistent modes; AirDrop, Trash, and Bluetooth/Wi-Fi events have system priority.')
    keepalive_seconds = 5.0
    command_retry_seconds = 0.5
    await asyncio.sleep(3.0)
    ui_monitor = NativeUIStateMonitor()
    airdrop_monitor = AirDropTrafficMonitor()
    wifi_event_monitor = WiFiConnectionEventMonitor()
    appstore_process_monitor = AppStoreProcessMonitor()
    arduino_activity_monitor = ArduinoIdeActivityMonitor()
    codex_session_monitor = CodexSessionActivityMonitor()
    manual_chatgpt_until = 0.0
    manual_copy_until = 0.0
    manual_appstore_until = 0.0
    manual_usb_paused = False
    last_trash_event_counter: Optional[int] = None
    pending_trash_flashes = 0
    next_trash_command_at = 0.0
    last_bluetooth_event_counter: Optional[int] = None
    pending_system_blue_events = 0
    next_system_blue_command_at = 0.0
    copy_active = False
    desired_copy_active = False
    last_copy_keepalive_at = 0.0
    next_copy_command_at = 0.0
    last_copy_reason = ''
    finder_copy_was_active = False
    finder_copy_latched = False
    finder_copy_min_until = 0.0
    finder_copy_false_since = 0.0
    finder_copy_last_fresh_at = 0.0
    appstore_active = False
    desired_appstore_active = False
    last_appstore_keepalive_at = 0.0
    next_appstore_command_at = 0.0
    chatgpt_active = False
    desired_chatgpt_active = False
    last_chatgpt_keepalive_at = 0.0
    next_chatgpt_command_at = 0.0
    last_ui_error = ''
    last_ui_error_log_at = 0.0
    ui_error_started_at = 0.0
    ui_parent_restart_sent = False
    ui_parent_restart_seconds = 180.0
    chatgpt_tab_was_active = False
    openai_app_was_active = False
    last_safari_diag = ''
    last_safari_download_diag = ''
    last_openai_diag = ''
    last_finder_diag = ''
    last_appstore_diag = ''
    last_safari_download_count = 0
    appstore_was_active = False
    arduino_active = False
    arduino_mode = ''
    arduino_was_active = False
    last_arduino_mode = ''
    chatgpt_work_latched = False
    chatgpt_false_since = 0.0
    chatgpt_last_fresh_at = 0.0
    chatgpt_incomplete_since = 0.0
    chatgpt_latched_reason = ''
    chatgpt_false_confirm_seconds = 3.0
    chatgpt_incomplete_grace_seconds = 2.0
    last_focus_preference = 'chatgpt'
    displayed_mode = 'none'
    last_display_reason = ''
    next_health_at = 0.0
    startup_sync_pending = True
    startup_wait_sent = False

    async def handle_ipc(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        nonlocal chatgpt_active, copy_active, appstore_active
        nonlocal manual_chatgpt_until, manual_copy_until, manual_appstore_until
        nonlocal manual_usb_paused
        nonlocal pending_trash_flashes, pending_system_blue_events
        nonlocal next_health_at
        response = {'ok': False, 'message': 'unknown command'}
        try:
            raw = await asyncio.wait_for(reader.readline(), timeout=2.0)
            request = json.loads(raw.decode('utf-8', errors='replace'))
            command = str(request.get('command', '')).strip().lower()
            now = time.monotonic()
            if command == 'chatgpt-on':
                manual_chatgpt_until = now + 20.0
                await provisioner.set_chatgpt_snake(True)
                chatgpt_active = True
                response = {'ok': True, 'message': 'The orange snake is enabled for 20 seconds.'}
            elif command == 'chatgpt-off':
                manual_chatgpt_until = 0.0
                await provisioner.set_chatgpt_snake(False)
                chatgpt_active = False
                response = {'ok': True, 'message': 'The orange snake is disabled.'}
            elif command == 'copy-on':
                manual_copy_until = now + 20.0
                await provisioner.set_copy_snake(True)
                copy_active = True
                response = {'ok': True, 'message': 'The green snake is enabled for 20 seconds.'}
            elif command == 'copy-off':
                manual_copy_until = 0.0
                await provisioner.set_copy_snake(False)
                copy_active = False
                response = {'ok': True, 'message': 'The green snake is disabled.'}
            elif command == 'appstore-on':
                manual_appstore_until = now + 20.0
                await provisioner.set_appstore_snake(True)
                appstore_active = True
                response = {'ok': True, 'message': 'The App Store aurora snake is enabled for 20 seconds.'}
            elif command == 'appstore-off':
                manual_appstore_until = 0.0
                await provisioner.set_appstore_snake(False)
                appstore_active = False
                response = {'ok': True, 'message': 'The App Store aurora snake is disabled.'}
            elif command == 'trash-flash':
                await provisioner.flash_trash()
                response = {'ok': True, 'message': 'The red Trash flash was sent to the ESP32.'}
            elif command == 'system-blue':
                await provisioner.system_blue()
                response = {'ok': True, 'message': 'The blue system snake was sent to the ESP32.'}
            elif command == 'snake-on':
                await provisioner.set_snake(True)
                response = {'ok': True, 'message': 'The download snake is enabled.'}
            elif command == 'snake-off':
                await provisioner.set_snake(False)
                response = {'ok': True, 'message': 'The download snake is disabled.'}
            elif command == 'usb-pause':
                manual_usb_paused = True
                await provisioner.set_suspended(True)
                response = {'ok': True, 'message': 'The USB Serial port is released for flashing or Serial Monitor.'}
            elif command in {'usb-resume', 'usb-reconnect'}:
                manual_usb_paused = False
                await provisioner.set_suspended(False)
                await provisioner.force_reconnect()
                next_health_at = 0.0
                response = {'ok': True, 'message': 'The USB Serial descriptor was closed; the agent will rediscover the ESP32-S3 port.'}
            elif command == 'status':
                status, _unused = await provisioner.get_status_persistent()
                response = {'ok': True, 'message': 'Status: %s\nUSB port: %s' % (status, provisioner.port_name)}
            elif command == 'reboot':
                await provisioner.reboot_persistent()
                response = {'ok': True, 'message': 'The ESP32 is rebooting.'}
        except Exception as error:
            response = {'ok': False, 'message': str(error)}
        try:
            writer.write((json.dumps(response, ensure_ascii=False) + '\n').encode('utf-8'))
            await writer.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass
    ensure_app_dir()
    try:
        IPC_SOCKET.unlink()
    except FileNotFoundError:
        pass
    ipc_server = await asyncio.start_unix_server(handle_ipc, path=str(IPC_SOCKET))
    try:
        IPC_SOCKET.chmod(384)
    except OSError:
        pass
    print('Local agent command socket is ready: %s' % IPC_SOCKET)
    audio_thread = threading.Thread(target=audio_serial_thread_main, args=(provisioner,), name='AppleMACLED-Audio-Serial', daemon=True)
    audio_thread.start()
    print('Audio: the dedicated 40 Hz stream is running separately from system monitors.')
    last_usb_disconnect_generation = provisioner.disconnect_generation
    main_usb_port_hint = ''
    while True:
        loop_started = time.monotonic()
        current_port_name = provisioner.port_name
        if current_port_name.startswith(('/dev/cu.', '/dev/tty.')):
            main_usb_port_hint = current_port_name
        arduino_active, arduino_mode, arduino_diag, arduino_upload_uses_main_usb = await asyncio.to_thread(arduino_activity_monitor.poll, loop_started, main_usb_port_hint)
        arduino_upload_in_progress = bool(arduino_active and arduino_mode == 'upload')
        arduino_main_usb_upload_in_progress = bool(arduino_upload_in_progress and arduino_upload_uses_main_usb)
        usb_transport_paused = bool(manual_usb_paused or arduino_main_usb_upload_in_progress)
        await provisioner.set_suspended(usb_transport_paused)
        current_disconnect_generation = provisioner.disconnect_generation
        if current_disconnect_generation != last_usb_disconnect_generation:
            last_usb_disconnect_generation = current_disconnect_generation
            next_health_at = 0.0
            startup_sync_pending = True
            startup_wait_sent = False
            print('USB Serial: connection lost; the agent will rediscover the port automatically.')
        if usb_transport_paused and loop_started >= next_health_at:
            next_health_at = loop_started + health_interval
        elif loop_started >= next_health_at:
            retry_delay = health_interval
            try:
                if startup_sync_pending and (not startup_wait_sent):
                    await provisioner.enter_waiting()
                    startup_wait_sent = True
                    print('[%s] The ESP entered USB wait mode for the Mac.' % (time.strftime('%Y-%m-%d %H:%M:%S'),))
                status, _unused_ip = await provisioner.get_status_persistent()
                if parse_decision(status) != 'OK':
                    await provisioner.send_ok()
                    status, _unused_ip = await provisioner.get_status_persistent()
                startup_sync_pending = False
                if '|SNAKE:ON' in status:
                    await provisioner.set_snake(False)
                remote_copy_active = '|COPY:ON' in status
                copy_active = remote_copy_active
                command_now = time.monotonic()
                if copy_active != desired_copy_active:
                    await provisioner.set_copy_snake(desired_copy_active)
                    copy_active = desired_copy_active
                    last_copy_keepalive_at = command_now
                    next_copy_command_at = command_now + keepalive_seconds
                remote_appstore_active = '|APPSTORE:ON' in status
                appstore_active = remote_appstore_active
                if appstore_active != desired_appstore_active:
                    await provisioner.set_appstore_snake(desired_appstore_active)
                    appstore_active = desired_appstore_active
                    last_appstore_keepalive_at = command_now
                    next_appstore_command_at = command_now + keepalive_seconds
                remote_chatgpt_active = '|CHATGPT:ON' in status
                chatgpt_active = remote_chatgpt_active
                if chatgpt_active != desired_chatgpt_active:
                    await provisioner.set_chatgpt_snake(desired_chatgpt_active)
                    chatgpt_active = desired_chatgpt_active
                    last_chatgpt_keepalive_at = command_now
                    next_chatgpt_command_at = command_now + keepalive_seconds
            except (SerialAgentError, asyncio.TimeoutError) as error:
                if startup_sync_pending:
                    retry_delay = 2.0
                    startup_wait_sent = False
                print('[%s] ESP USB check: %s' % (time.strftime('%Y-%m-%d %H:%M:%S'), error))
            except Exception as error:
                if startup_sync_pending:
                    retry_delay = 2.0
                    startup_wait_sent = False
                print('[%s] ESP USB check error: %s' % (time.strftime('%Y-%m-%d %H:%M:%S'), error))
            next_health_at = time.monotonic() + retry_delay
        ui_state = ui_monitor.poll()
        now = time.monotonic()
        if ui_state.error:
            if not last_ui_error:
                ui_error_started_at = now
                ui_parent_restart_sent = False
            if ui_state.error != last_ui_error or now - last_ui_error_log_at >= 30.0:
                print('Native UI monitor: %s.' % ui_state.error)
                last_ui_error_log_at = now
            if not ui_parent_restart_sent and ui_error_started_at > 0.0 and (now - ui_error_started_at >= ui_parent_restart_seconds):
                ui_parent_restart_sent = True
                parent_pid = os.getppid()
                print('The native UI monitor has stalled for %.0f seconds; restarting AppleMACLED Agent.' % (now - ui_error_started_at))
                if parent_pid > 1:
                    try:
                        os.kill(parent_pid, signal.SIGKILL)
                    except OSError as error:
                        print('Could not stop the parent monitor: %s' % error)
                os._exit(75)
        elif last_ui_error:
            print('The native UI monitor is working again.')
            ui_error_started_at = 0.0
            ui_parent_restart_sent = False
        last_ui_error = ui_state.error
        if ui_state.safari_diagnostic and ui_state.safari_diagnostic != last_safari_diag:
            print('Safari UI: %s' % ui_state.safari_diagnostic)
            last_safari_diag = ui_state.safari_diagnostic
        if ui_state.safari_download_diagnostic and ui_state.safari_download_diagnostic != last_safari_download_diag:
            print('Safari downloads: %s' % ui_state.safari_download_diagnostic)
            last_safari_download_diag = ui_state.safari_download_diagnostic
        if ui_state.openai_app_diagnostic and ui_state.openai_app_diagnostic != last_openai_diag:
            print('ChatGPT app UI: %s' % ui_state.openai_app_diagnostic)
            last_openai_diag = ui_state.openai_app_diagnostic
        if ui_state.finder_diagnostic and ui_state.finder_diagnostic != last_finder_diag:
            print('Finder UI: %s' % ui_state.finder_diagnostic)
            last_finder_diag = ui_state.finder_diagnostic
        if ui_state.appstore_diagnostic and ui_state.appstore_diagnostic != last_appstore_diag:
            print('App Store: %s' % ui_state.appstore_diagnostic)
            last_appstore_diag = ui_state.appstore_diagnostic
        bluetooth_counter = max(0, int(ui_state.bluetooth_event_counter))
        if last_bluetooth_event_counter is None:
            last_bluetooth_event_counter = bluetooth_counter
        elif bluetooth_counter < last_bluetooth_event_counter:
            last_bluetooth_event_counter = bluetooth_counter
        elif bluetooth_counter > last_bluetooth_event_counter:
            added = min(4, bluetooth_counter - last_bluetooth_event_counter)
            pending_system_blue_events += added
            last_bluetooth_event_counter = bluetooth_counter
            device_name = ui_state.bluetooth_device_name or 'Bluetooth device'
            print('Bluetooth: %s connected; queueing the blue system indicator.' % device_name)
        wifi_ssid = await asyncio.to_thread(wifi_event_monitor.poll, now)
        if wifi_ssid:
            pending_system_blue_events += 1
            print('Wi-Fi: the Mac connected to %s; queueing the blue system indicator.' % wifi_ssid)
        ui_fresh = not ui_state.error
        chatgpt_tab_present = ui_state.chatgpt_tab_active and ui_fresh
        openai_app_present = ui_state.openai_app_active and ui_fresh
        raw_safari_busy = ui_state.chatgpt_busy and chatgpt_tab_present
        codex_session_busy, codex_session_started, codex_session_stopped, codex_active_count = await asyncio.to_thread(codex_session_monitor.poll, now=now, present=bool(ui_state.openai_app_active))
        if codex_session_started:
            print('Codex sessions: an active task was detected; enabling the indicator regardless of the selected chat.')
        elif codex_session_stopped:
            print('Codex sessions: all active tasks finished; disabling the app indicator immediately.')
        safari_chatgpt_scan_incomplete = chatgpt_tab_present and chatgpt_ax_scan_hit_limit(ui_state.safari_diagnostic)
        if ui_fresh:
            chatgpt_last_fresh_at = now
            if raw_safari_busy:
                chatgpt_work_latched = True
                chatgpt_false_since = 0.0
                chatgpt_incomplete_since = 0.0
                if ui_state.safari_foreground:
                    chatgpt_latched_reason = 'ChatGPT in Safari'
                else:
                    chatgpt_latched_reason = 'ChatGPT in Safari (background tab)'
            elif chatgpt_work_latched and safari_chatgpt_scan_incomplete:
                if chatgpt_incomplete_since <= 0.0:
                    chatgpt_incomplete_since = now
                if now - chatgpt_incomplete_since < chatgpt_incomplete_grace_seconds:
                    chatgpt_false_since = 0.0
                else:
                    if chatgpt_false_since <= 0.0:
                        chatgpt_false_since = now
                    if now - chatgpt_false_since >= chatgpt_false_confirm_seconds:
                        chatgpt_work_latched = False
                        chatgpt_false_since = 0.0
                        chatgpt_incomplete_since = 0.0
                        chatgpt_latched_reason = ''
            elif chatgpt_work_latched:
                chatgpt_incomplete_since = 0.0
                if chatgpt_false_since <= 0.0:
                    chatgpt_false_since = now
                if now - chatgpt_false_since >= chatgpt_false_confirm_seconds:
                    chatgpt_work_latched = False
                    chatgpt_false_since = 0.0
                    chatgpt_incomplete_since = 0.0
                    chatgpt_latched_reason = ''
        elif chatgpt_work_latched and now - chatgpt_last_fresh_at >= 45.0:
            chatgpt_work_latched = False
            chatgpt_false_since = 0.0
            chatgpt_incomplete_since = 0.0
            chatgpt_latched_reason = ''
        if chatgpt_tab_present and (not chatgpt_tab_was_active):
            print('Safari ChatGPT: the selected tab was detected; activity will also be tracked in the background.')
        elif not chatgpt_tab_present and chatgpt_tab_was_active:
            print('Safari ChatGPT: the selected tab is no longer detected.')
        chatgpt_tab_was_active = chatgpt_tab_present
        if openai_app_present and (not openai_app_was_active):
            app_name = ui_state.openai_app_name or 'ChatGPT'
            print('%s: a window was detected; ChatGPT/Codex activity will also be tracked in the background.' % app_name)
        elif not openai_app_present and openai_app_was_active:
            print('The ChatGPT/Codex application is no longer detected.')
        openai_app_was_active = openai_app_present
        raw_finder_copy = bool(ui_state.finder_copy_active)
        if ui_fresh:
            finder_copy_last_fresh_at = now
            if raw_finder_copy:
                finder_copy_latched = True
                finder_copy_min_until = max(finder_copy_min_until, now + 2.0)
                finder_copy_false_since = 0.0
            elif finder_copy_latched:
                if finder_copy_false_since <= 0.0:
                    finder_copy_false_since = now
                if now >= finder_copy_min_until and now - finder_copy_false_since >= 0.75:
                    finder_copy_latched = False
                    finder_copy_false_since = 0.0
        elif finder_copy_latched and now - finder_copy_last_fresh_at >= 10.0:
            finder_copy_latched = False
            finder_copy_false_since = 0.0
        finder_copy_active = finder_copy_latched
        if finder_copy_active and (not finder_copy_was_active):
            print('Finder: copy activity confirmed; holding the indicator for at least 2 seconds.')
        elif not finder_copy_active and finder_copy_was_active:
            print('Finder: copy activity ended after a stable OFF state.')
        finder_copy_was_active = finder_copy_active
        airdrop_active, airdrop_rate, airdrop_direction = await asyncio.to_thread(airdrop_monitor.poll)
        safari_download_count = max(0, int(ui_state.safari_download_count))
        safari_download_active = bool(ui_state.safari_download_active and ui_fresh)
        if safari_download_count <= 0 and safari_download_active:
            safari_download_count = 1
        if safari_download_count != last_safari_download_count:
            if safari_download_count > 0:
                print('Safari: %d active downloads; enabling the green system snake.' % safari_download_count)
            elif last_safari_download_count > 0:
                print('Safari: the final download finished; restoring the previous indicator.')
            last_safari_download_count = safari_download_count
        process_appstore_active, process_appstore_diag = await asyncio.to_thread(appstore_process_monitor.poll, now)
        appstore_download_source_active = bool(ui_state.appstore_download_active or process_appstore_active)
        if appstore_download_source_active and (not appstore_was_active):
            print('App Store: a download or update started; enabling the aurora snake.')
        elif not appstore_download_source_active and appstore_was_active:
            print('App Store: the final download/update finished; restoring the previous indicator.')
        appstore_was_active = appstore_download_source_active
        if process_appstore_diag != last_appstore_diag and (not ui_state.appstore_diagnostic):
            print('App Store process: %s' % process_appstore_diag)
            last_appstore_diag = process_appstore_diag
        if arduino_active and (not arduino_was_active):
            print('%s; enabling the aurora snake.' % arduino_diag)
        elif not arduino_active and arduino_was_active:
            print('Arduino IDE: compile/upload finished; restoring the previous indicator.')
        elif arduino_active and arduino_mode != last_arduino_mode:
            print('%s.' % arduino_diag)
        arduino_was_active = arduino_active
        last_arduino_mode = arduino_mode
        manual_chatgpt_active = now < manual_chatgpt_until
        manual_copy_active = now < manual_copy_until
        manual_appstore_active = now < manual_appstore_until
        appstore_source_active = bool(appstore_download_source_active or arduino_active or manual_appstore_active)
        if arduino_active:
            appstore_reason = 'Arduino IDE firmware upload' if arduino_mode == 'upload' else 'Arduino IDE compilation'
        elif appstore_download_source_active:
            appstore_reason = 'App Store download/update'
        else:
            appstore_reason = 'manual aurora snake test'
        chatgpt_source_active = codex_session_busy or chatgpt_work_latched or manual_chatgpt_active
        local_copy_source_active = finder_copy_active or manual_copy_active
        chatgpt_foreground = bool(ui_state.safari_foreground and chatgpt_tab_present or (ui_state.openai_app_foreground and openai_app_present))
        finder_foreground = bool(ui_state.finder_foreground or ui_state.front_bundle == 'com.apple.finder')
        if chatgpt_foreground:
            last_focus_preference = 'chatgpt'
        elif finder_foreground:
            last_focus_preference = 'copy'
        if codex_session_busy:
            chatgpt_reason = 'Codex active tasks: %d' % codex_active_count
        else:
            chatgpt_reason = chatgpt_latched_reason
        if manual_chatgpt_active and (not codex_session_busy):
            chatgpt_reason = 'manual ChatGPT test'
        if finder_copy_active:
            local_copy_reason = 'Finder copy'
        elif manual_copy_active:
            local_copy_reason = 'manual copy test'
        else:
            local_copy_reason = ''
        if airdrop_active:
            next_display_mode = 'copy'
            display_reason = '%s, %.0f KB/s' % (airdrop_direction, airdrop_rate / 1024.0)
        elif appstore_source_active:
            next_display_mode = 'appstore'
            display_reason = appstore_reason
        elif safari_download_active:
            next_display_mode = 'copy'
            display_reason = 'Safari download (%d)' % safari_download_count
        elif chatgpt_source_active and local_copy_source_active:
            if chatgpt_foreground:
                next_display_mode = 'chatgpt'
                display_reason = chatgpt_reason or 'ChatGPT/Codex — selected foreground window'
            elif finder_foreground:
                next_display_mode = 'copy'
                display_reason = local_copy_reason or 'Finder — selected foreground window'
            elif last_focus_preference == 'copy':
                next_display_mode = 'copy'
                display_reason = local_copy_reason or 'Finder copy'
            else:
                next_display_mode = 'chatgpt'
                display_reason = chatgpt_reason or 'ChatGPT/Codex is active in the background'
        elif chatgpt_source_active:
            next_display_mode = 'chatgpt'
            display_reason = chatgpt_reason or 'ChatGPT/Codex is active in the background'
        elif local_copy_source_active:
            next_display_mode = 'copy'
            display_reason = local_copy_reason or 'Finder copy'
        else:
            next_display_mode = 'none'
            display_reason = ''
        if next_display_mode != displayed_mode:
            previous_mode = displayed_mode
            displayed_mode = next_display_mode
            if displayed_mode == 'appstore':
                print('Indicator priority: aurora snake — %s.' % display_reason)
            elif displayed_mode == 'chatgpt':
                print('Indicator priority: orange snake — %s.' % display_reason)
            elif displayed_mode == 'copy':
                print('Indicator priority: green snake — %s.' % display_reason)
            elif previous_mode != 'none':
                print('Priority indicator finished; restoring the normal pulse.')
        elif display_reason and display_reason != last_display_reason:
            print('Current indicator source: %s.' % display_reason)
        last_display_reason = display_reason
        desired_appstore_active = displayed_mode == 'appstore'
        desired_chatgpt_active = chatgpt_active if arduino_main_usb_upload_in_progress else displayed_mode == 'chatgpt'
        desired_copy_active = copy_active if arduino_main_usb_upload_in_progress else displayed_mode == 'copy'
        command_now = time.monotonic()
        appstore_command_needed = desired_appstore_active != appstore_active or (desired_appstore_active and (not usb_transport_paused) and (command_now - last_appstore_keepalive_at >= keepalive_seconds))
        if appstore_command_needed and command_now >= next_appstore_command_at:
            previous_appstore = appstore_active
            try:
                await provisioner.set_appstore_snake(desired_appstore_active)
                appstore_active = desired_appstore_active
                last_appstore_keepalive_at = time.monotonic()
                next_appstore_command_at = last_appstore_keepalive_at + keepalive_seconds
                if appstore_active and (not previous_appstore):
                    print('Aurora snake enabled: %s.' % display_reason)
                elif not appstore_active and previous_appstore:
                    print('Aurora snake disabled; restoring the next active mode.')
            except Exception as error:
                next_appstore_command_at = time.monotonic() + command_retry_seconds
                print('Could not change the App Store snake: %s' % error)
        command_now = time.monotonic()
        chatgpt_command_needed = desired_chatgpt_active != chatgpt_active or (desired_chatgpt_active and (not usb_transport_paused) and (command_now - last_chatgpt_keepalive_at >= keepalive_seconds))
        if chatgpt_command_needed and command_now >= next_chatgpt_command_at:
            previous_chatgpt = chatgpt_active
            try:
                await provisioner.set_chatgpt_snake(desired_chatgpt_active)
                chatgpt_active = desired_chatgpt_active
                last_chatgpt_keepalive_at = time.monotonic()
                next_chatgpt_command_at = last_chatgpt_keepalive_at + keepalive_seconds
                if chatgpt_active and (not previous_chatgpt):
                    print('Orange snake enabled: %s.' % (display_reason or 'ChatGPT/Codex'))
                elif not chatgpt_active and previous_chatgpt:
                    print('The orange snake is temporarily disabled or the task finished.')
            except Exception as error:
                next_chatgpt_command_at = time.monotonic() + command_retry_seconds
                print('Could not change the ChatGPT snake: %s' % error)
        command_now = time.monotonic()
        copy_command_needed = desired_copy_active != copy_active or (desired_copy_active and (not usb_transport_paused) and (command_now - last_copy_keepalive_at >= keepalive_seconds))
        if copy_command_needed and command_now >= next_copy_command_at:
            previous_copy = copy_active
            try:
                await provisioner.set_copy_snake(desired_copy_active)
                copy_active = desired_copy_active
                last_copy_keepalive_at = time.monotonic()
                next_copy_command_at = last_copy_keepalive_at + keepalive_seconds
                if copy_active and (not previous_copy):
                    print('Green snake enabled: %s.' % (display_reason or 'file transfer'))
                elif not copy_active and previous_copy:
                    print('Green snake disabled; restoring the next active mode.')
            except Exception as error:
                next_copy_command_at = time.monotonic() + command_retry_seconds
                print('Could not change the file-transfer snake: %s' % error)
        trash_counter = max(0, int(ui_state.trash_event_counter))
        if last_trash_event_counter is None:
            last_trash_event_counter = trash_counter
        elif trash_counter < last_trash_event_counter:
            last_trash_event_counter = trash_counter
        elif trash_counter > last_trash_event_counter:
            pending_trash_flashes += min(3, trash_counter - last_trash_event_counter)
            last_trash_event_counter = trash_counter
            print('Finder: Trash was emptied; the red system indicator has priority.')
        if pending_trash_flashes > 0 and now >= next_trash_command_at:
            try:
                await provisioner.flash_trash()
                pending_trash_flashes -= 1
                next_trash_command_at = time.monotonic() + 1.3
                print('ESP32: the red Trash flash completed; restoring the previous indicator.')
            except Exception as error:
                next_trash_command_at = time.monotonic() + command_retry_seconds
                print('Could not send the Trash flash: %s' % error)
        if pending_system_blue_events > 0 and now >= next_system_blue_command_at:
            try:
                await provisioner.system_blue()
                pending_system_blue_events -= 1
                next_system_blue_command_at = time.monotonic() + 0.5
                print('ESP32: the blue system sequence completed; restoring the previous indicator.')
            except Exception as error:
                next_system_blue_command_at = time.monotonic() + command_retry_seconds
                print('Could not send the blue system indicator: %s' % error)
        if desired_copy_active and display_reason and (display_reason != last_copy_reason):
            print('Active file-transfer indicator: %s.' % display_reason)
        last_copy_reason = display_reason if desired_copy_active else ''
        spent = time.monotonic() - loop_started
        await asyncio.sleep(max(0.01, copy_poll_interval - spent))
    ipc_server.close()
    await ipc_server.wait_closed()
    return 0

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description='AppleMAC-LED USB Serial lighting and music agent')
    parser.add_argument('--port', default=os.environ.get(SERIAL_ENV_PORT), help='ESP USB Serial port, for example /dev/cu.usbmodem1101; auto-detected by default')
    parser.add_argument('--baud', type=int, default=DEFAULT_SERIAL_BAUD)
    parser.add_argument('--timeout', type=float, default=12.0)
    subparsers = parser.add_subparsers(dest='mode')
    subparsers.add_parser('status', help='Show ESP32 and USB status')
    subparsers.add_parser('ports', help='List detected Serial ports')
    subparsers.add_parser('reboot', help='Reboot the ESP32 through GPIO16')
    subparsers.add_parser('snake-on', help='Enable the download snake')
    subparsers.add_parser('snake-off', help='Disable the download snake')
    subparsers.add_parser('copy-on', help='Enable the copy snake')
    subparsers.add_parser('copy-off', help='Disable the copy snake')
    subparsers.add_parser('chatgpt-on', help='Enable the orange ChatGPT snake')
    subparsers.add_parser('chatgpt-off', help='Disable the orange ChatGPT snake')
    subparsers.add_parser('appstore-on', help='Enable the App Store aurora snake')
    subparsers.add_parser('appstore-off', help='Disable the App Store aurora snake')
    subparsers.add_parser('trash-flash', help='Run the red Trash flash')
    subparsers.add_parser('system-blue', help='Run one blue system snake pass')
    subparsers.add_parser('usb-pause', help='Release USB for flashing or Serial Monitor')
    subparsers.add_parser('usb-resume', help='Return USB to the background agent')
    subparsers.add_parser('usb-reconnect', help='Close a stale descriptor and rediscover the ESP')
    daemon = subparsers.add_parser('daemon', help='LaunchAgent background mode')
    daemon.add_argument('--interval', type=float, default=15.0)
    daemon.add_argument('--copy-poll-interval', type=float, default=0.1)
    return parser

async def async_main(args: argparse.Namespace) -> int:
    ipc_modes = {'status', 'reboot', 'snake-on', 'snake-off', 'copy-on', 'copy-off', 'chatgpt-on', 'chatgpt-off', 'appstore-on', 'appstore-off', 'trash-flash', 'system-blue', 'usb-pause', 'usb-resume', 'usb-reconnect'}
    if args.mode in ipc_modes:
        payload = {}
        response = await send_command_to_running_agent(args.mode, **payload)
        if response is not None:
            message = str(response.get('message', ''))
            if message:
                print(message)
            return 0 if response.get('ok') else 1
    provisioner = SerialProvisioner(port=args.port, baud=args.baud, timeout=args.timeout)
    if args.mode == 'ports':
        print(provisioner.list_ports_text())
        return 0
    if args.mode in {'usb-pause', 'usb-resume', 'usb-reconnect'}:
        raise SerialAgentError('This command requires the running background agent')
    if args.mode == 'status':
        status, _unused = await provisioner.get_status()
        print('Status:', status)
        print('USB port:', provisioner.port_name)
        return 0
    if args.mode == 'reboot':
        return await provisioner.reboot()
    if args.mode == 'snake-on':
        return await provisioner.set_snake(True)
    if args.mode == 'snake-off':
        return await provisioner.set_snake(False)
    if args.mode == 'copy-on':
        return await provisioner.set_copy_snake(True)
    if args.mode == 'copy-off':
        return await provisioner.set_copy_snake(False)
    if args.mode == 'chatgpt-on':
        return await provisioner.set_chatgpt_snake(True)
    if args.mode == 'chatgpt-off':
        return await provisioner.set_chatgpt_snake(False)
    if args.mode == 'appstore-on':
        return await provisioner.set_appstore_snake(True)
    if args.mode == 'appstore-off':
        return await provisioner.set_appstore_snake(False)
    if args.mode == 'trash-flash':
        return await provisioner.flash_trash()
    if args.mode == 'system-blue':
        return await provisioner.system_blue()
    if args.mode == 'daemon':
        return await daemon_loop(provisioner, health_interval=max(args.interval, 5.0), copy_poll_interval=min(max(args.copy_poll_interval, 0.02), 0.25))
    status, _unused = await provisioner.get_status()
    print('Status:', status)
    print('USB port:', provisioner.port_name)
    return 0

def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.mode is None:
        args.mode = 'status'
    try:
        return asyncio.run(async_main(args))
    except KeyboardInterrupt:
        print('Stopped.')
        return 130
    except (RuntimeError, ValueError, SerialAgentError, serial.SerialException) as error:
        text = str(error)
        print('Error: %s' % text, file=sys.stderr)
        lowered = text.lower()
        if 'permission' in lowered or 'not authorized' in lowered:
            print('Check AppleMACLED Agent permissions for Accessibility, Screen & System Audio Recording, and Downloads folder access.', file=sys.stderr)
        return 1
if __name__ == '__main__':
    raise SystemExit(main())
