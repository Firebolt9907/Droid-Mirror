"""Mirror-session orchestration for Linux (port of ClassicBluetoothTransport.swift
and the Bluetooth branch of MirrorModel.swift).

One `MirrorSession` owns one `droidmirror-bluetooth` helper and one scrcpy
renderer for one phone. Sessions are independent, so several phones can be
mirrored at the same time from one laptop.

The helper speaks the same line protocol as the macOS helper:
  stdout  LISTENING <video> <control> | READY <video> <control> | EVENT <NAME>
  stdin   UPGRADE_PEER | UPGRADE <port> | UNLOCK_DECISION 0|1
"""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from gi.repository import GLib

from . import config

EVENTS_ENDING = {"SESSION_ENDED", "PHONE_ON", "PHONE_LOCAL_USE", "CAPTURE_FAILED", "PIN_FAILED", "PHONE_IN_USE"}

PHONE_IN_USE = "Phone is in use. Lock your phone, then try mirroring again."


@dataclass
class SessionState:
    stage: str = "Connecting over Bluetooth…"
    transport: str = "bluetooth"
    error: str | None = None
    running: bool = False
    ended_on_phone: bool = False
    streaming: bool = False
    audio_available: bool = False  # phone media can play here (Wi-Fi video active)
    audio_playing: bool = False
    events: list[str] = field(default_factory=list)


class MirrorSession:
    """Runs helper + renderer for one phone. All callbacks run on the GLib main loop."""

    def __init__(
        self,
        address: str,
        name: str,
        on_change: Callable[["MirrorSession"], None],
        ask_unlock: Callable[["MirrorSession"], None] | None = None,
    ):
        self.address = address
        self.name = name
        self.on_change = on_change
        self.ask_unlock = ask_unlock
        self.state = SessionState()
        self.helper: subprocess.Popen | None = None
        self.renderer: subprocess.Popen | None = None
        self.log_path: Path | None = None
        self._log = None
        self._buffer = b""
        self._watches: list[int] = []
        self._upgrade_timer: int | None = None
        self._lan_probe_pending = False
        self._wireless_active = False
        self._forwards: dict[str, int] = {}
        self._audio_forwards: dict[str, int] = {}
        self._stopping = False
        self._aware = None

    # -- lifecycle -----------------------------------------------------------------

    def start(self) -> None:
        settings = config.load_settings()
        helper = config.helper_path()
        if not helper:
            self._fail("The DroidMirror Bluetooth helper is missing. Run Linux/build-linux.sh.")
            return
        if not config.scrcpy_path():
            self._fail("The DroidMirror renderer (patched scrcpy) is missing. Run Linux/build-linux.sh.")
            return
        logs = config.state_dir() / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        self.log_path = logs / f"DroidMirror-Bluetooth-{self.address.replace(':', '')}-{stamp}.log"
        self._log = open(self.log_path, "ab", buffering=0)
        config.prune_logs(logs)
        env = os.environ.copy()
        unlock = settings.get("unlock", "ask")
        env["DROIDMIRROR_ALLOW_UNLOCK"] = {"always": "1", "never": "0"}.get(unlock, "defer")
        env["DROIDMIRROR_WIFI_MAX_SIZE"] = str(settings.get("max_size", 1920))
        env["DROIDMIRROR_WIFI_FPS"] = str(settings.get("max_fps", 60))
        env["DROIDMIRROR_WIFI_BIT_RATE"] = str(int(settings.get("bit_rate_mbps", 12)) * 1_000_000)
        env["DROIDMIRROR_AUDIO_BUFFER_MS"] = str(int(settings.get("audio_buffer_ms", 120)))
        env["DROIDMIRROR_APPEARANCE_CACHE"] = str(config.cache_dir() / f"appearance-{self.address.replace(':', '')}.json")
        (config.cache_dir()).mkdir(parents=True, exist_ok=True)
        try:
            self.helper = subprocess.Popen(
                [helper, self.address],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=self._log,
                env=env,
                start_new_session=True,
            )
        except OSError as error:
            self._fail(f"Could not start the Bluetooth helper: {error}")
            return
        os.set_blocking(self.helper.stdout.fileno(), False)
        self._watches.append(
            GLib.io_add_watch(self.helper.stdout.fileno(), GLib.PRIORITY_DEFAULT, GLib.IO_IN | GLib.IO_HUP, self._on_helper_output)
        )
        self._watches.append(GLib.child_watch_add(GLib.PRIORITY_DEFAULT, self.helper.pid, self._on_helper_exit))
        self.state.running = True
        self.state.stage = "Connecting over Bluetooth…"
        self._changed()

    def stop(self) -> None:
        """Ends the session gracefully: the helper closes BLE/L2CAP before exiting,
        so the phone restores its display and ends capture."""
        self._stopping = True
        if self._upgrade_timer:
            GLib.source_remove(self._upgrade_timer)
            self._upgrade_timer = None
        if self.renderer and self.renderer.poll() is None:
            self.renderer.terminate()
        if self.helper and self.helper.poll() is None:
            try:
                self.helper.stdin.close()
            except OSError:
                pass
            self.helper.send_signal(signal.SIGTERM)
        self._remove_forwards()
        self._close_wifi_aware()

    def set_audio(self, playing: bool) -> None:
        """Play the phone's media on this computer (or return it to the phone)."""
        self._command("AUDIO_START" if playing else "AUDIO_STOP")

    def send_unlock_decision(self, allowed: bool) -> None:
        self._command(f"UNLOCK_DECISION {1 if allowed else 0}")

    # -- helper protocol -----------------------------------------------------------

    def _command(self, line: str) -> None:
        if self.helper and self.helper.poll() is None:
            try:
                self.helper.stdin.write((line + "\n").encode())
                self.helper.stdin.flush()
            except (BrokenPipeError, OSError):
                pass

    def _on_helper_output(self, fd, condition) -> bool:
        try:
            chunk = os.read(fd, 65536)
        except BlockingIOError:
            return True
        except OSError:
            chunk = b""
        if not chunk:
            return False
        if self._log:
            self._log.write(chunk)
        self._buffer += chunk
        while b"\n" in self._buffer:
            line, self._buffer = self._buffer.split(b"\n", 1)
            self._line(line.decode(errors="replace").strip())
        return True

    def _line(self, line: str) -> None:
        if line.startswith("LISTENING "):
            fields = line.split()
            if len(fields) == 3:
                self._start_renderer(int(fields[1]), int(fields[2]))
        elif line.startswith("READY "):
            self.state.stage = "Authenticated · starting video"
            self._changed()
        elif line.startswith("EVENT "):
            self._event(line[6:])

    def _event(self, event: str) -> None:
        self.state.events.append(event)
        if event == "LAN_UNAVAILABLE":
            self._lan_probe_pending = False
            return
        if event == "STREAM_STARTED":
            self.state.streaming = True
            self._start_wifi_aware()
            self.state.stage = "Bluetooth · up to 15 fps · 128 kbps"
            self._schedule_upgrades()
        elif event == "WIFI_ACTIVE":
            self._wireless_active = True
            s = config.load_settings()
            size = "native resolution" if int(s.get("max_size", 1920)) == 0 else f"{s.get('max_size', 1920)} px"
            self.state.stage = f"Wi-Fi video · {size} · up to {s.get('max_fps', 60)} fps"
            self.state.transport = "wifi"
        elif event == "USB_ACTIVE":
            self._wireless_active = True
            self.state.stage = "USB video · no added playback buffer · Bluetooth controls"
            self.state.transport = "usb"
        elif event == "WIFI_RECOVERING":
            self._wireless_active = False
            self.state.audio_available = self.state.audio_playing = False
            self.state.stage = "Wi-Fi video dropped · resuming Bluetooth…"
        elif event == "BLUETOOTH_ACTIVE":
            self._wireless_active = False
            self.state.transport = "bluetooth"
            self.state.stage = "Bluetooth · up to 15 fps · 128 kbps"
            self._schedule_upgrades()
        elif event == "UNLOCK_DECISION_NEEDED":
            if self.ask_unlock:
                self.ask_unlock(self)
            else:
                self.send_unlock_decision(False)
        elif event == "PHONE_IN_USE":
            self.state.error = PHONE_IN_USE
        elif event == "PIN_PAUSED":
            self.state.stage = "PIN cooling down · unlock manually or reconnect after 15 seconds"
        elif event == "PIN_FAILED":
            self.state.error = "Automatic unlock failed. Unlock the phone manually."
        elif event == "CAPTURE_FAILED":
            self.state.error = "The phone could not start capture. Check that Shizuku is running."
        elif event in ("SESSION_ENDED", "PHONE_ON", "PHONE_LOCAL_USE"):
            self.state.ended_on_phone = True
            self.state.stage = "Mirroring ended on the phone"
        elif event.startswith("AUDIO_STATE "):
            value = int(event.split()[1])
            self.state.audio_available = bool(value & 1) and not value & 4
            if not self.state.audio_available:
                self.state.audio_playing = False
        elif event == "AUDIO_PLAYING":
            self.state.audio_playing = True
        elif event in ("AUDIO_STOPPED", "AUDIO_FAILED"):
            self.state.audio_playing = False
        elif event == "MINIMIZE_WINDOW":
            pass  # No portable "minimize this SDL window" request on Wayland.
        self._changed()

    def _start_wifi_aware(self) -> None:
        """Offer the phone's Wi-Fi Aware data path as one more upgrade candidate."""
        if self._aware or not config.load_settings().get("wifi_aware", True):
            return
        from . import wifi_aware
        supported, _reason = wifi_aware.support()
        key = config.pairing_key(self.address)
        if not supported or not key:
            return
        link = wifi_aware.WifiAwareLink(key, lambda port: self._command(f"UPGRADE {port}"), lambda text: None)
        if link.start():
            self._aware = link

    def _close_wifi_aware(self) -> None:
        if self._aware:
            self._aware.close()
            self._aware = None

    def _schedule_upgrades(self) -> None:
        if self._upgrade_timer is None:
            self._attempt_upgrade()
            self._upgrade_timer = GLib.timeout_add_seconds(10, self._attempt_upgrade)

    def _attempt_upgrade(self) -> bool:
        if self._wireless_active or not self.helper or self.helper.poll() is not None:
            self._upgrade_timer = None
            return False
        if not self._lan_probe_pending:
            self._lan_probe_pending = True
            self._command("UPGRADE_PEER")
        self._adb_upgrade()
        return True

    def _adb_upgrade(self) -> None:
        """Optional fallback: an already-connected wireless ADB device."""
        adb = shutil.which("adb") or config.android_tool("adb")
        if not adb:
            return
        try:
            devices = subprocess.run([adb, "devices"], capture_output=True, text=True, timeout=3).stdout
        except (OSError, subprocess.SubprocessError):
            return
        for line in devices.splitlines()[1:]:
            fields = line.split()
            if len(fields) < 2 or fields[1] != "device":
                continue
            serial = fields[0]
            if ":" not in serial and not serial.endswith("._adb-tls-connect._tcp"):
                continue
            port = self._forwards.get(serial)
            if port is None and len(self._forwards) < 32:
                try:
                    out = subprocess.run(
                        [adb, "-s", serial, "forward", "tcp:0", "localabstract:droidmirror_video_upgrade"],
                        capture_output=True, text=True, timeout=3,
                    ).stdout.strip()
                    port = int(out)
                    self._forwards[serial] = port
                except (OSError, subprocess.SubprocessError, ValueError):
                    continue
            if port:
                audio = self._audio_forwards.get(serial)
                if audio is None:
                    try:
                        audio = int(subprocess.run(
                            [adb, "-s", serial, "forward", "tcp:0", "localabstract:droidmirror_audio_upgrade"],
                            capture_output=True, text=True, timeout=3).stdout.strip())
                        self._audio_forwards[serial] = audio
                    except (OSError, subprocess.SubprocessError, ValueError):
                        audio = None
                if audio:
                    self._command(f"AUDIO_FORWARD {port} {audio}")
                self._command(f"UPGRADE {port}")

    def _remove_forwards(self) -> None:
        adb = shutil.which("adb") or config.android_tool("adb")
        for serial, port in list(self._forwards.items()) + list(self._audio_forwards.items()):
            if adb:
                subprocess.run([adb, "-s", serial, "forward", "--remove", f"tcp:{port}"], capture_output=True, timeout=3)
        self._forwards.clear()
        self._audio_forwards.clear()

    # -- renderer ------------------------------------------------------------------

    def _start_renderer(self, video: int, control: int) -> None:
        settings = config.load_settings()
        args = [
            config.scrcpy_path(),
            f"--external-video-port={video}",
            f"--external-control-port={control}",
            f"--window-title=DroidMirror — {self.name}",
            "--window-width=430",
            f"--video-buffer={int(settings.get('video_buffer_ms', 50))}",
            "--no-mouse-hover",
            "--mouse-bind=-hsn:-+++",
            "--no-audio",
            "--pause-on-exit=false",
        ]
        if settings.get("borderless", False):
            args.append("--window-borderless")
        if settings.get("always_on_top", False):
            args.append("--always-on-top")
        env = os.environ.copy()
        for key in ("ADB", "ANDROID_SERIAL"):
            env.pop(key, None)
        env["DROIDMIRROR_TRANSPORT"] = "bluetooth-classic"
        env["DROIDMIRROR_CONNECTION_LABEL"] = "Bluetooth controls"
        env.setdefault("SDL_APP_ID", "app.droidmirror.linux")
        env.setdefault("SDL_APP_NAME", "DroidMirror")
        icons = config.resource_dir()
        if icons:
            env["SCRCPY_ICON_DIR"] = str(icons)
        try:
            self.renderer = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=self._log, stderr=self._log, env=env)
        except OSError as error:
            self._fail(f"Could not start the renderer: {error}")
            self.stop()
            return
        self._watches.append(GLib.child_watch_add(GLib.PRIORITY_DEFAULT, self.renderer.pid, self._on_renderer_exit))

    def _on_renderer_exit(self, pid, status) -> None:
        # Closing the mirror window ends the session gracefully.
        if not self._stopping:
            self.stop()

    def _on_helper_exit(self, pid, status) -> None:
        code = os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else status
        self.state.running = False
        self.state.streaming = False
        if self.renderer and self.renderer.poll() is None:
            self.renderer.terminate()
        if self._upgrade_timer:
            GLib.source_remove(self._upgrade_timer)
            self._upgrade_timer = None
        if code != 0 and not self._stopping and not self.state.ended_on_phone and not self.state.error:
            self.state.error = self._diagnose()
        self.state.stage = self.state.stage if self.state.ended_on_phone else "Mirror disconnected"
        self._remove_forwards()
        self._close_wifi_aware()
        if self._log:
            self._log.close()
            self._log = None
        self._changed()

    def _diagnose(self) -> str:
        text = ""
        if self.log_path and self.log_path.exists():
            text = self.log_path.read_text(errors="replace")
        lines = [l for l in text.splitlines() if l and not l.startswith(("BLE setup:", "LISTENING", "READY", "EVENT"))]
        last = lines[-1] if lines else "Bluetooth connection failed."
        if "PAIRING_CODE_MISMATCH" in text:
            return "The pairing code is wrong. Copy the code for this computer from the Android app and save it again."
        if "Could not open Classic L2CAP" in text:
            return (
                "The phone did not accept the Bluetooth connection. On the phone, make sure this computer is trusted in "
                "DroidMirror, the background bridge is enabled and Shizuku is running."
            )
        return last

    def _fail(self, message: str) -> None:
        self.state.error = message
        self.state.running = False
        self._changed()

    def _changed(self) -> None:
        try:
            self.on_change(self)
        except Exception as error:  # UI errors must not kill the session
            print(f"DroidMirror UI update failed: {error}")
