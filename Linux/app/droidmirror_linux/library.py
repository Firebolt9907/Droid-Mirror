"""Phone apps in the desktop's application menu (Linux counterpart of the Mac's
phone app library).

When enabled, each connected phone's launchable apps become XDG desktop entries
("<app> — <phone>"). Launching one opens a mirror of that phone and starts the
app there (`appLaunch` waits for the mirror and the unlocked phone). The catalog
and 48 px icons travel over the authenticated BLE background session.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Callable

from gi.repository import GLib

from . import config


def _data_home() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")


def _slug(address: str, component: str) -> str:
    return "droidmirror-" + address.replace(":", "").lower() + "-" + hashlib.sha256(component.encode()).hexdigest()[:16]


class PhoneLibrary:
    def __init__(self, address: str, name: str, request: Callable[[dict, Callable[[dict], None]], bool]):
        self.address = address
        self.name = name
        self.request = request
        self.state_path = config.state_dir() / "apps" / (address.replace(":", "") + ".json")
        self.syncing = False
        self.snapshot = ""
        self.apps: list[dict] = []
        self.icon_queue: list[dict] = []
        self.icon_data = bytearray()

    # -- catalog ----------------------------------------------------------------------

    def start(self) -> None:
        if not config.load_settings().get("app_launchers", False):
            self.remove_all()
            return
        try:
            self.snapshot = json.loads(self.state_path.read_text()).get("snapshot", "")
        except (OSError, ValueError):
            self.snapshot = ""
        self.request({"type": "appCatalogSubscribe"}, lambda _r: self.sync())
        self.sync()

    def sync(self) -> None:
        if self.syncing:
            return
        self.syncing = True
        self.apps = []
        self._page(0, self.snapshot)

    def _page(self, offset: int, snapshot: str) -> None:
        command = {"type": "appCatalogRequest", "offset": offset}
        if snapshot:
            command["snapshot"] = snapshot
        if not self.request(command, lambda reply: self._catalog(reply, offset)):
            self.syncing = False

    def _catalog(self, reply: dict, offset: int) -> None:
        if not reply.get("success"):
            self.syncing = False
            return
        if reply.get("unchanged"):
            self.syncing = False
            return
        self.snapshot = reply.get("snapshot", "")
        page = [a for a in reply.get("apps", []) if isinstance(a, dict) and a.get("component") and a.get("label")]
        self.apps.extend(page)
        total = int(reply.get("total", 0))
        if page and len(self.apps) < total:
            self._page(offset + len(page), self.snapshot)
            return
        self._apply()

    # -- desktop entries --------------------------------------------------------------

    def _paths(self, app: dict) -> tuple[Path, Path]:
        slug = _slug(self.address, app["component"])
        return (_data_home() / "applications" / f"{slug}.desktop",
                _data_home() / "icons/hicolor/48x48/apps" / f"{slug}.png")

    def _apply(self) -> None:
        launcher = config.launcher_command()
        wanted = set()
        self.icon_queue = []
        for app in self.apps:
            desktop, icon = self._paths(app)
            wanted.add(desktop.name)
            desktop.parent.mkdir(parents=True, exist_ok=True)
            label = re.sub(r"[\r\n]", " ", app["label"])[:80]
            desktop.write_text(
                "[Desktop Entry]\nType=Application\n"
                f"Name={label}\nGenericName={label} on {self.name}\n"
                f"Comment=Open {label} on {self.name} with DroidMirror\n"
                f"Exec={launcher} launch-app {self.address} {app['component']}\n"
                f"Icon={icon.stem if icon.exists() else 'app.droidmirror.linux'}\n"
                "Terminal=false\nCategories=DroidMirror;\nX-DroidMirror-Phone=" + self.address + "\n"
                f"X-DroidMirror-Version={app.get('version', '')}\n"
            )
            if not icon.exists():
                self.icon_queue.append(app)
        directory = _data_home() / "applications"
        prefix = "droidmirror-" + self.address.replace(":", "").lower() + "-"
        for old in directory.glob(prefix + "*.desktop"):
            if old.name not in wanted:
                old.unlink(missing_ok=True)
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_path.write_text(json.dumps({"snapshot": self.snapshot, "count": len(self.apps)}))
        self._refresh_menu()
        self.syncing = False
        self._next_icon()

    def _next_icon(self) -> None:
        if not self.icon_queue:
            return
        self.icon_data = bytearray()
        self._icon_chunk(self.icon_queue[0], 0)

    def _icon_chunk(self, app: dict, offset: int) -> None:
        command = {"type": "appIconRequest", "component": app["component"], "version": app.get("version", ""),
                   "size": 48, "offset": offset}
        if not self.request(command, lambda reply: self._icon_reply(app, reply)):
            self.icon_queue.clear()

    def _icon_reply(self, app: dict, reply: dict) -> None:
        if not reply.get("success"):
            self.icon_queue.pop(0)
            self._next_icon()
            return
        try:
            self.icon_data += base64.b64decode(reply.get("data", ""))
        except ValueError:
            self.icon_queue.pop(0)
            self._next_icon()
            return
        total = int(reply.get("total", 0))
        if len(self.icon_data) < total:
            self._icon_chunk(app, len(self.icon_data))
            return
        self.icon_queue.pop(0)
        if hashlib.sha256(self.icon_data).hexdigest() == reply.get("hash") and self.icon_data.startswith(b"\x89PNG"):
            desktop, icon = self._paths(app)
            icon.parent.mkdir(parents=True, exist_ok=True)
            icon.write_bytes(bytes(self.icon_data))
            if desktop.exists():
                desktop.write_text(desktop.read_text().replace("Icon=app.droidmirror.linux", f"Icon={icon.stem}"))
        if not self.icon_queue:
            self._refresh_menu()
        # Pace icon traffic so it never competes with notifications or input.
        GLib.timeout_add(150, lambda: (self._next_icon(), False)[1])

    @staticmethod
    def _refresh_menu() -> None:
        try:
            subprocess.Popen(["update-desktop-database", str(_data_home() / "applications")],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass

    def remove_all(self) -> None:
        prefix = "droidmirror-" + self.address.replace(":", "").lower() + "-"
        for directory, pattern in ((_data_home() / "applications", prefix + "*.desktop"),
                                   (_data_home() / "icons/hicolor/48x48/apps", prefix + "*.png")):
            for path in directory.glob(pattern):
                path.unlink(missing_ok=True)
        self.state_path.unlink(missing_ok=True)
