"""Desktop clipboard access that keeps working while DroidMirror runs in the background.

GTK only lets a Wayland client read the clipboard while it has keyboard focus,
so background sync uses, in order:
  1. wl-clipboard (`wl-paste --watch` / `wl-copy`), which uses the Wayland
     data-control protocol (KDE Plasma, Sway, Hyprland, and others);
  2. KDE's Klipper D-Bus service;
  3. GTK's own clipboard (always works on X11; on Wayland only while a
     DroidMirror window is focused).
"""

from __future__ import annotations

import os
import shutil
import subprocess
from typing import Callable

from gi.repository import Gdk, Gio, GLib

MAX_TEXT = 64 * 1024


class DesktopClipboard:
    def __init__(self, on_change: Callable[[str], None]):
        self.on_change = on_change
        self.last = None  # last text seen or written, to suppress echoes
        self.backend = "none"
        self._watch = None
        self._klipper = None
        self._gdk = None
        if os.environ.get("WAYLAND_DISPLAY") and shutil.which("wl-paste") and shutil.which("wl-copy"):
            self._start_wl()
        elif self._start_klipper():
            pass
        else:
            self._start_gdk()

    # -- wl-clipboard ---------------------------------------------------------------

    def _start_wl(self) -> None:
        self.backend = "wl-clipboard"
        # One process prints each new selection, NUL-separated.
        try:
            self._watch = subprocess.Popen(
                ["wl-paste", "--type", "text/plain;charset=utf-8", "--watch", "sh", "-c", "cat; printf '\\0'"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            )
        except OSError:
            self._start_gdk()
            return
        os.set_blocking(self._watch.stdout.fileno(), False)
        buffer = bytearray()

        def readable(fd, _condition):
            try:
                chunk = os.read(fd, 65536)
            except BlockingIOError:
                return True
            if not chunk:
                return False
            buffer.extend(chunk)
            while b"\0" in buffer:
                index = buffer.index(b"\0")
                text = bytes(buffer[:index]).decode(errors="replace")
                del buffer[: index + 1]
                self._observed(text)
            if len(buffer) > MAX_TEXT * 4:
                buffer.clear()
            return True

        GLib.io_add_watch(self._watch.stdout.fileno(), GLib.PRIORITY_DEFAULT, GLib.IO_IN | GLib.IO_HUP, readable)

    # -- Klipper ------------------------------------------------------------------------

    def _start_klipper(self) -> bool:
        try:
            proxy = Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SESSION, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None,
                                                   "org.kde.klipper", "/klipper", "org.kde.klipper.klipper", None)
            if not proxy.get_name_owner():
                return False
        except GLib.Error:
            return False
        self._klipper = proxy
        self.backend = "klipper"

        def signal(_proxy, _sender, name, _parameters):
            if name == "clipboardHistoryUpdated":
                self._read_klipper()

        proxy.connect("g-signal", signal)
        return True

    def _read_klipper(self) -> None:
        try:
            text = self._klipper.call_sync("getClipboardContents", None, Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
        except GLib.Error:
            return
        self._observed(text)

    # -- GTK ----------------------------------------------------------------------------

    def _start_gdk(self) -> None:
        display = Gdk.Display.get_default()
        if not display:
            return
        self.backend = "gtk"
        self._gdk = display.get_clipboard()

        def changed(clipboard):
            def done(source, result):
                try:
                    text = source.read_text_finish(result)
                except GLib.Error:
                    return
                if text is not None:
                    self._observed(text)

            clipboard.read_text_async(None, done)

        self._gdk.connect("changed", changed)

    # -- common -------------------------------------------------------------------------

    def _observed(self, text: str) -> None:
        if not text or len(text) > MAX_TEXT or text == self.last:
            return
        self.last = text
        self.on_change(text)

    def set_text(self, text: str) -> None:
        if not text or len(text) > MAX_TEXT:
            return
        self.last = text
        if self.backend == "wl-clipboard":
            try:
                copy = subprocess.Popen(["wl-copy", "--type", "text/plain;charset=utf-8"], stdin=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL)
                copy.communicate(text.encode(), timeout=3)
            except (OSError, subprocess.SubprocessError):
                pass
        elif self.backend == "klipper":
            try:
                self._klipper.call_sync("setClipboardContents", GLib.Variant("(s)", (text,)), Gio.DBusCallFlags.NONE, 1000, None)
            except GLib.Error:
                pass
        elif self._gdk is not None:
            self._gdk.set_content(Gdk.ContentProvider.new_for_bytes("text/plain;charset=utf-8", GLib.Bytes.new(text.encode())))

    def close(self) -> None:
        if self._watch and self._watch.poll() is None:
            self._watch.terminate()
