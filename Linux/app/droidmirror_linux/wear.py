"""Wear OS companion parity (port of Native/WearCompanion*.swift).

While a phone is connected, this computer publishes its battery and name for
the watch (`watchMacState`) and can be found from the watch: `watchFindMac`
plays a sound, but only for a fresh ticket this computer issued on this
authenticated connection (same 35-second gate as macOS).
"""

from __future__ import annotations

import shutil
import socket
import subprocess
import time
import uuid
from pathlib import Path
from typing import Callable

from gi.repository import Gio, GLib

TICKET_LIFETIME = 35.0
SOUNDS = ("/usr/share/sounds/freedesktop/stereo/phone-incoming-call.oga",
          "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga",
          "/usr/share/sounds/freedesktop/stereo/complete.oga")


def battery() -> dict:
    try:
        proxy = Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SYSTEM, Gio.DBusProxyFlags.NONE, None, "org.freedesktop.UPower",
                                               "/org/freedesktop/UPower/devices/DisplayDevice", "org.freedesktop.UPower.Device", None)
        present = proxy.get_cached_property("IsPresent")
        percentage = proxy.get_cached_property("Percentage")
        state = proxy.get_cached_property("State")
        if present is not None and present.unpack() and percentage is not None:
            return {"level": int(round(percentage.unpack())), "charging": state is not None and state.unpack() in (1, 4)}
    except GLib.Error:
        pass
    return {"level": -1, "charging": False}


class WearCompanion:
    def __init__(self, send: Callable[[dict], bool]):
        self.send = send
        self.id = str(uuid.uuid4())
        self.tickets: dict[str, float] = {}
        self.requests: dict[str, float] = {}
        self.last_state: dict | None = None
        self.last_ring = 0.0
        self.phone_battery: dict | None = None
        self.timer = None

    def start(self) -> None:
        self.id = str(uuid.uuid4())
        self.tickets.clear()
        self.requests.clear()
        self.last_state = None
        self.tick()
        self.timer = GLib.timeout_add_seconds(10, self.tick)

    def stop(self) -> None:
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = None
        self.phone_battery = None

    def _ticket(self) -> str:
        now = time.monotonic()
        self.tickets = {k: v for k, v in self.tickets.items() if 0 <= now - v < TICKET_LIFETIME}
        value = str(uuid.uuid4())
        self.tickets[value] = now
        return value

    def tick(self) -> bool:
        state = dict(battery(), name=socket.gethostname())
        if state != self.last_state:
            event = dict(state, type="watchMacState", id=self.id, ticket=self._ticket(), changeOnly=True)
            if self.send(event):
                self.last_state = state
        return True

    def _accept(self, event: dict) -> bool:
        now = time.monotonic()
        self.requests = {k: v for k, v in self.requests.items() if 0 <= now - v < TICKET_LIFETIME}
        issued = self.tickets.get(event.get("ticket", ""))
        request = event.get("request", "")
        try:
            uuid.UUID(request)
        except (ValueError, TypeError, AttributeError):
            return False
        if event.get("id") != self.id or issued is None or not 0 <= now - issued < TICKET_LIFETIME:
            return False
        if request in self.requests or len(self.requests) >= 256:
            return False
        self.requests[request] = now
        return True

    def receive(self, event: dict) -> None:
        if event.get("id") != self.id:
            return
        kind = event.get("type")
        if kind == "watchTicketRequest":
            try:
                uuid.UUID(event.get("request", ""))
            except (ValueError, TypeError, AttributeError):
                return
            self.send({"type": "watchMacTicket", "id": self.id, "request": event["request"], "ticket": self._ticket()})
        elif kind == "watchPhoneBattery":
            level, charging = event.get("level"), event.get("charging")
            if isinstance(level, int) and -1 <= level <= 100 and isinstance(charging, bool):
                self.phone_battery = {"level": level, "charging": charging}
        elif kind == "watchFindMac":
            if not self._accept(event):
                return
            success = False
            if time.monotonic() - self.last_ring >= 5:
                self.last_ring = time.monotonic()
                success = self.ring()
            self.send({"type": "watchFindResult", "id": self.id, "request": event["request"], "success": success})

    @staticmethod
    def ring() -> bool:
        sound = next((s for s in SOUNDS if Path(s).exists()), None)
        player = shutil.which("pw-play") or shutil.which("paplay")
        if sound and player:
            # Three repetitions, like the Mac's find sound.
            subprocess.Popen(["sh", "-c", f'for i in 1 2 3; do "{player}" "{sound}"; done'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        if shutil.which("canberra-gtk-play"):
            subprocess.Popen(["canberra-gtk-play", "-i", "phone-incoming-call", "-l", "3"])
            return True
        return False
