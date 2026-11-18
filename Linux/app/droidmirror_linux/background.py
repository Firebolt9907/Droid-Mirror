"""Per-phone background session and its features (Linux counterpart of the Mac's
BLEController-based helpers).

`PhoneBackground` keeps `droidmirror-bluetooth --notifications ADDRESS`
running. That helper holds the authenticated, encrypted BLE session with the
phone's background bridge and relays one JSON message per line. Everything is
gated on that live connection: features subscribe when the session reports
`connected` and stop as soon as it drops.

Features: notifications (actions, replies, dismissal, open in mirror),
clipboard text both ways, link sharing both ways, phone media as an MPRIS
player, Focus / Do Not Disturb both ways, phone hotspot, browser handoff
("continue on this computer"), the phone's wireless-ADB endpoint, and the
presence beacon used by the phone's left-behind alerts, and the Wear OS
companion (this computer's battery on the watch, find-my-computer sound).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import uuid
from typing import Callable

from gi.repository import GLib

from . import config
from .clipboard import DesktopClipboard
from .files import FileTransfers
from .focus import DesktopFocus
from .library import PhoneLibrary
from .mpris import PhonePlayer
from .notifications import DesktopNotifications, PhoneNotifications
from .wear import WearCompanion

_clipboard: DesktopClipboard | None = None
_focus: DesktopFocus | None = None
_phones: list["PhoneBackground"] = []


def _shared_clipboard() -> DesktopClipboard:
    global _clipboard
    if _clipboard is None:
        _clipboard = DesktopClipboard(lambda text: [p.desktop_clipboard(text) for p in list(_phones)])
    return _clipboard


def _shared_focus() -> DesktopFocus:
    global _focus
    if _focus is None:
        _focus = DesktopFocus(lambda focused: [p.desktop_focus(focused) for p in list(_phones)])
    return _focus


class PhoneBackground:
    def __init__(self, address: str, name: str, host):
        """host provides: refresh_row(address), open_on_phone(address, action), raise_window(), toast(text)."""
        self.address = address
        self.name = name
        self.host = host
        self.process: subprocess.Popen | None = None
        self.buffer = b""
        self.status = "Starting"
        self.connected = False
        self.capabilities: dict = {}
        self._restart = None
        self._poll = None
        self._stopped = False
        self.handoff: dict | None = None
        self.adb_endpoint: dict | None = None
        self.phone_focus: dict | None = None
        self.pending: dict[str, Callable[[dict], None]] = {}
        self.notifications = PhoneNotifications(address, name, self.send, lambda action: host.open_on_phone(address, action))
        self.player = PhonePlayer(address, name, self.send, host.raise_window)
        self.wear = WearCompanion(self.send)
        self.files = FileTransfers(self.send, self._file_notice)
        self.library = PhoneLibrary(address, name, self.request)
        _phones.append(self)

    # -- process ----------------------------------------------------------------------

    def start(self) -> None:
        helper = config.helper_path()
        if not helper or self.process:
            return
        self._stopped = False
        logs = config.state_dir() / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        log = open(logs / f"background-{self.address.replace(':', '')}.log", "ab", buffering=0)
        self.process = subprocess.Popen([helper, "--notifications", self.address], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=log, start_new_session=True)
        log.close()
        os.set_blocking(self.process.stdout.fileno(), False)
        GLib.io_add_watch(self.process.stdout.fileno(), GLib.PRIORITY_DEFAULT, GLib.IO_IN | GLib.IO_HUP, self._readable)
        GLib.child_watch_add(GLib.PRIORITY_DEFAULT, self.process.pid, self._exited)

    def stop(self) -> None:
        self._stopped = True
        if self._restart:
            GLib.source_remove(self._restart)
            self._restart = None
        if self.process and self.process.poll() is None:
            try:
                self.process.stdin.close()
            except OSError:
                pass
            self.process.terminate()
        self._disconnected()
        if self in _phones:
            _phones.remove(self)

    def _exited(self, _pid, _status) -> None:
        self.process = None
        self._disconnected()
        self._set_status("Background connection stopped")
        if not self._stopped:
            self._restart = GLib.timeout_add_seconds(15, self._retry)

    def _retry(self) -> bool:
        self._restart = None
        self.start()
        return False

    def send(self, command: dict) -> bool:
        if not self.connected or not self.process or self.process.poll() is not None:
            return False
        try:
            self.process.stdin.write((json.dumps(command) + "\n").encode())
            self.process.stdin.flush()
            return True
        except OSError:
            return False

    def request(self, command: dict, reply: Callable[[dict], None]) -> bool:
        identifier = str(uuid.uuid4())
        command["request"] = identifier
        self.pending[identifier] = reply
        if not self.send(command):
            self.pending.pop(identifier, None)
            return False
        GLib.timeout_add_seconds(20, lambda: (self.pending.pop(identifier, None) and reply({"success": False, "timeout": True})) and False)
        return True

    def _readable(self, fd, _condition) -> bool:
        try:
            chunk = os.read(fd, 1 << 20)
        except BlockingIOError:
            return True
        except OSError:
            chunk = b""
        if not chunk:
            return False
        self.buffer += chunk
        while b"\n" in self.buffer:
            line, self.buffer = self.buffer.split(b"\n", 1)
            try:
                self._message(json.loads(line))
            except (ValueError, KeyError, TypeError, AttributeError) as error:
                print(f"Ignoring invalid phone message: {error}")
        return True

    def _set_status(self, text: str) -> None:
        self.status = text
        self.host.refresh_row(self.address)

    # -- connection gate -----------------------------------------------------------

    def _connected(self) -> None:
        settings = config.load_settings()
        self.connected = True
        if settings.get("notifications", True):
            self.send({"type": "subscribe", "activityDeltas": 0})
        if settings.get("clipboard", True):
            _shared_clipboard()
            # bulk 0: files use the authenticated BLE lane (no L2CAP/Iroh side channel).
            self.send({"type": "clipboardSubscribe", "enabled": True, "files": bool(settings.get("files", True)), "bulk": 0, "race": 0})
        self.send({"type": "linkSubscribe"})
        if settings.get("media", True):
            self.send({"type": "mediaSubscribe", "enabled": True})
        if settings.get("handoff", True):
            self.send({"type": "taskSubscribe", "enabled": True, "changeOnly": True})
        if settings.get("focus_from_phone", False) or settings.get("focus_to_phone", False):
            _shared_focus()
            self.send({"type": "focusQuery"})
            self._poll = GLib.timeout_add_seconds(10, self._poll_focus)
        self.send({"type": "get", "request": 1})
        if settings.get("wear", True):
            self.wear.start()
        self.library.start()

    def _disconnected(self) -> None:
        self.connected = False
        self.notifications.clear()
        self.player.close()
        self.wear.stop()
        self.files.reset()
        self.handoff = None
        if self._poll:
            GLib.source_remove(self._poll)
            self._poll = None
        for reply in list(self.pending.values()):
            reply({"success": False})
        self.pending.clear()

    # -- phone → computer ------------------------------------------------------------

    def _message(self, message: dict) -> None:
        kind = message.get("type")
        request = message.get("request")
        if isinstance(request, str) and request in self.pending and kind not in ("shareLink", "openLink"):
            self.pending.pop(request)(message)
        if kind == "_status":
            was = self.connected
            if message.get("connected") and not was:
                self._connected()
            elif not message.get("connected") and was:
                self._disconnected()
            self._set_status(message.get("status", ""))
        elif kind in ("notification", "removed", "actionResult", "dismissResult", "activitiesReset"):
            self.notifications.receive(message)
        elif kind == "clipboard":
            text = message.get("text")
            if isinstance(text, str) and config.load_settings().get("clipboard", True):
                _shared_clipboard().set_text(text)
        elif kind == "appCatalogChanged" and not (isinstance(request, str) and request in self.pending):
            self.library.sync()
        elif isinstance(kind, str) and kind.startswith("clipboardFile"):
            self.files.receive(message)
        elif kind == "shareLink":
            self._share_link(message)
        elif kind in ("mediaState",):
            self.player.receive(message)
        elif kind == "taskContinuation":
            self._handoff(message)
        elif isinstance(kind, str) and kind.startswith("watch"):
            self.wear.receive(message)
        elif kind == "focusState":
            self._phone_focus(message)
        elif kind is None and ("port" in message or "error" in message):
            self._adb_endpoint(message)
        self.host.refresh_row(self.address)

    def _share_link(self, message: dict) -> None:
        url = message.get("url", "")
        success = isinstance(url, str) and url.startswith(("http://", "https://"))
        if success:
            try:
                from gi.repository import Gio
                Gio.AppInfo.launch_default_for_uri(url, None)
            except GLib.Error:
                success = False
        self.send({"type": "shareLinkResult", "request": message.get("request", ""), "success": success})

    def _handoff(self, message: dict) -> None:
        url = message.get("url", "")
        if not isinstance(url, str) or not url.startswith(("http://", "https://")):
            self.handoff = None
            return
        if self.handoff and self.handoff.get("url") == url:
            return
        self.handoff = message
        if config.load_settings().get("handoff_notifications", False):
            DesktopNotifications.shared().notify(self.notifications, 0, f"Handoff · {self.name}",
                                                 "Continue on this computer", GLib.markup_escape_text(url), [], {}, 8000)

    def _phone_focus(self, message: dict) -> None:
        self.phone_focus = message
        if config.load_settings().get("focus_from_phone", False) and message.get("available") and message.get("origin") != "linux":
            _shared_focus().set_focused(bool(message.get("focused")))

    def _poll_focus(self) -> bool:
        if not self.connected:
            self._poll = None
            return False
        self.send({"type": "focusQuery"})
        return True

    def _adb_endpoint(self, message: dict) -> None:
        self.adb_endpoint = message if "port" in message else None
        if not self.adb_endpoint or not config.load_settings().get("wireless_adb", False):
            return
        host = message.get("ip")
        adb = shutil.which("adb") or config.android_tool("adb")
        if host and adb:
            subprocess.Popen([adb, "connect", f"{host}:{int(message['port'])}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # -- computer → phone --------------------------------------------------------------

    def _file_notice(self, title: str, body: str, path) -> None:
        from gi.repository import Gio
        notification = Gio.Notification.new(title)
        notification.set_body(body)
        if path is not None:
            notification.set_default_action_and_target("app.open-file", GLib.Variant("s", str(path)))
        application = Gio.Application.get_default()
        if application:
            application.send_notification(None, notification)

    def send_files(self, paths) -> str | None:
        if not self.connected:
            return "The phone is not connected."
        for path in paths:
            error = self.files.send_file(path)
            if error:
                return error
        return None

    def desktop_clipboard(self, text: str) -> None:
        if self.connected and config.load_settings().get("clipboard", True):
            self.send({"type": "clipboardSet", "text": text})

    def desktop_focus(self, focused: bool) -> None:
        if self.connected and config.load_settings().get("focus_to_phone", False):
            self.send({"type": "focusSet", "focused": focused, "origin": "linux"})

    def open_link(self, url: str, reply: Callable[[bool], None]) -> bool:
        return self.request({"type": "openLink", "url": url}, lambda r: reply(bool(r.get("success"))))

    def launch_app(self, component: str, reply: Callable[[dict], None]) -> bool:
        return self.request({"type": "appLaunch", "component": component}, reply)

    def hotspot(self, enabled: bool, reply: Callable[[dict], None]) -> bool:
        return self.request({"type": "hotspotStart" if enabled else "hotspotStop"}, reply)
