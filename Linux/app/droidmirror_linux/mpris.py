"""The phone's current media session as an MPRIS player.

Desktop media controls, keyboard media keys and widgets (GNOME, KDE, others)
show "<phone> (DroidMirror)" and control the phone over the authenticated BLE
background session (`mediaSubscribe` / `mediaState` / `mediaCommand`).
"""

from __future__ import annotations

import base64
import hashlib
import time
from typing import Callable

from gi.repository import Gio, GLib

from . import config

XML = """
<node>
  <interface name="org.mpris.MediaPlayer2">
    <method name="Raise"/>
    <method name="Quit"/>
    <property name="CanQuit" type="b" access="read"/>
    <property name="CanRaise" type="b" access="read"/>
    <property name="HasTrackList" type="b" access="read"/>
    <property name="Identity" type="s" access="read"/>
    <property name="DesktopEntry" type="s" access="read"/>
    <property name="SupportedUriSchemes" type="as" access="read"/>
    <property name="SupportedMimeTypes" type="as" access="read"/>
  </interface>
  <interface name="org.mpris.MediaPlayer2.Player">
    <method name="Next"/>
    <method name="Previous"/>
    <method name="Pause"/>
    <method name="PlayPause"/>
    <method name="Stop"/>
    <method name="Play"/>
    <method name="Seek"><arg direction="in" type="x" name="Offset"/></method>
    <method name="SetPosition"><arg direction="in" type="o" name="TrackId"/><arg direction="in" type="x" name="Position"/></method>
    <method name="OpenUri"><arg direction="in" type="s" name="Uri"/></method>
    <signal name="Seeked"><arg type="x" name="Position"/></signal>
    <property name="PlaybackStatus" type="s" access="read"/>
    <property name="Rate" type="d" access="read"/>
    <property name="Metadata" type="a{sv}" access="read"/>
    <property name="Volume" type="d" access="read"/>
    <property name="Position" type="x" access="read"/>
    <property name="MinimumRate" type="d" access="read"/>
    <property name="MaximumRate" type="d" access="read"/>
    <property name="CanGoNext" type="b" access="read"/>
    <property name="CanGoPrevious" type="b" access="read"/>
    <property name="CanPlay" type="b" access="read"/>
    <property name="CanPause" type="b" access="read"/>
    <property name="CanSeek" type="b" access="read"/>
    <property name="CanControl" type="b" access="read"/>
  </interface>
</node>
"""
PATH = "/org/mpris/MediaPlayer2"


class PhonePlayer:
    def __init__(self, address: str, name: str, send: Callable[[dict], None], raise_window: Callable[[], None]):
        self.address = address
        self.name = name
        self.send = send
        self.raise_window = raise_window
        self.state: dict | None = None
        self.sampled = 0.0
        self.art_url = ""
        self.bus = None
        self.registrations: list[int] = []
        self.owner = 0

    # -- bus lifecycle --------------------------------------------------------------

    def _publish(self) -> None:
        if self.owner:
            return
        node = Gio.DBusNodeInfo.new_for_xml(XML)
        well_known = "org.mpris.MediaPlayer2.droidmirror_" + self.address.replace(":", "").lower()

        def acquired(connection, _name):
            self.bus = connection
            for interface in node.interfaces:
                self.registrations.append(connection.register_object(PATH, interface, self._call, self._get, None))

        self.owner = Gio.bus_own_name(Gio.BusType.SESSION, well_known, Gio.BusNameOwnerFlags.NONE, acquired, None, None)

    def _unpublish(self) -> None:
        if self.bus:
            for registration in self.registrations:
                self.bus.unregister_object(registration)
        self.registrations.clear()
        if self.owner:
            Gio.bus_unown_name(self.owner)
        self.owner = 0
        self.bus = None

    def close(self) -> None:
        self._unpublish()

    # -- phone state ----------------------------------------------------------------

    def receive(self, message: dict) -> None:
        kind = message.get("type")
        if kind != "mediaState":
            return
        if message.get("unchanged") and self.state:
            if "position" in message:
                self.state["position"] = message["position"]
                self.sampled = time.monotonic()
            return
        if not message.get("active"):
            self.state = None
            self._unpublish()
            return
        artwork = message.get("artwork")
        if isinstance(artwork, str) and artwork:
            self._store_artwork(artwork)
        self.state = message
        self.sampled = time.monotonic()
        self._publish()
        self._changed(["PlaybackStatus", "Metadata", "Position", "Rate", "CanGoNext", "CanGoPrevious", "CanPlay", "CanPause", "CanSeek"])

    def _store_artwork(self, encoded: str) -> None:
        try:
            data = base64.b64decode(encoded, validate=False)
        except ValueError:
            return
        if not data or len(data) > 512 * 1024:
            return
        directory = config.cache_dir() / "artwork"
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / (hashlib.sha256(data).hexdigest()[:24] + ".img")
        if not path.exists():
            path.write_bytes(data)
        for old in directory.glob("*.img"):
            if old != path and time.time() - old.stat().st_mtime > 3600:
                old.unlink(missing_ok=True)
        self.art_url = path.as_uri()

    def _position_us(self) -> int:
        if not self.state:
            return 0
        position = float(self.state.get("position", 0.0))
        if self.state.get("playing"):
            position += (time.monotonic() - self.sampled) * float(self.state.get("playbackRate", 1.0) or 1.0)
        duration = float(self.state.get("duration", 0.0))
        if duration > 0:
            position = min(position, duration)
        return int(max(0.0, position) * 1_000_000)

    def _actions(self) -> set[str]:
        return set(self.state.get("actions", [])) if self.state else set()

    def _metadata(self) -> GLib.Variant:
        s = self.state or {}
        values = {
            "mpris:trackid": GLib.Variant("o", "/app/droidmirror/track/" + hashlib.sha1(str(s.get("id", "none")).encode()).hexdigest()[:16]),
            "xesam:title": GLib.Variant("s", s.get("title") or "Phone media"),
            "xesam:album": GLib.Variant("s", s.get("album") or ""),
            "xesam:artist": GLib.Variant("as", [s.get("artist")] if s.get("artist") else []),
            "mpris:length": GLib.Variant("x", int(float(s.get("duration", 0.0)) * 1_000_000)),
        }
        if self.art_url:
            values["mpris:artUrl"] = GLib.Variant("s", self.art_url)
        return GLib.Variant("a{sv}", values)

    def _get(self, _connection, _sender, _path, interface, prop):
        a = self._actions()
        s = self.state or {}
        values = {
            "CanQuit": GLib.Variant("b", False), "CanRaise": GLib.Variant("b", True), "HasTrackList": GLib.Variant("b", False),
            "Identity": GLib.Variant("s", f"{self.name} (DroidMirror)"), "DesktopEntry": GLib.Variant("s", "app.droidmirror.linux"),
            "SupportedUriSchemes": GLib.Variant("as", []), "SupportedMimeTypes": GLib.Variant("as", []),
            "PlaybackStatus": GLib.Variant("s", "Playing" if s.get("playing") else ("Paused" if self.state else "Stopped")),
            "Rate": GLib.Variant("d", 1.0), "MinimumRate": GLib.Variant("d", 1.0), "MaximumRate": GLib.Variant("d", 1.0),
            "Metadata": self._metadata(), "Volume": GLib.Variant("d", 1.0), "Position": GLib.Variant("x", self._position_us()),
            "CanGoNext": GLib.Variant("b", "next" in a), "CanGoPrevious": GLib.Variant("b", "previous" in a),
            "CanPlay": GLib.Variant("b", "play" in a), "CanPause": GLib.Variant("b", "pause" in a),
            "CanSeek": GLib.Variant("b", "seek" in a), "CanControl": GLib.Variant("b", True),
        }
        return values.get(prop)

    def _changed(self, names: list[str]) -> None:
        if not self.bus:
            return
        changed = {name: self._get(None, None, None, None, name) for name in names}
        self.bus.emit_signal(None, PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                             GLib.Variant("(sa{sv}as)", ("org.mpris.MediaPlayer2.Player", changed, [])))

    # -- commands to the phone ----------------------------------------------------------

    def _command(self, action: str, **extra) -> None:
        if self.state and action in self._actions():
            self.send({"type": "mediaCommand", "id": self.state.get("id"), "action": action, **extra})

    def _call(self, _connection, _sender, _path, _interface, method, parameters, invocation):
        playing = bool(self.state and self.state.get("playing"))
        if method == "Raise":
            self.raise_window()
        elif method in ("Play",):
            self._command("play")
        elif method in ("Pause", "Stop"):
            self._command("pause")
        elif method == "PlayPause":
            self._command("pause" if playing else "play")
        elif method == "Next":
            self._command("next")
        elif method == "Previous":
            self._command("previous")
        elif method == "Seek":
            target = max(0, self._position_us() + parameters.unpack()[0]) / 1_000_000
            self._command("seek", position=target)
        elif method == "SetPosition":
            self._command("seek", position=max(0, parameters.unpack()[1]) / 1_000_000)
        invocation.return_value(None)
