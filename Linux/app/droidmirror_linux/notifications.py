"""Phone notification forwarding for Linux.

Each phone's PhoneBackground (background.py) keeps an authenticated,
encrypted BLE session with the phone's background bridge and hands
notification messages to PhoneNotifications. Phone notifications become desktop
notifications (org.freedesktop.Notifications). Closing one on the desktop
dismisses it on the phone; action buttons run the phone's action.
"""

from __future__ import annotations

import uuid
from typing import Callable

from gi.repository import Gio, GLib

BUS_NAME = "org.freedesktop.Notifications"
OBJECT = "/org/freedesktop/Notifications"
CLOSED_BY_USER = 2


class DesktopNotifications:
    """Thin client for the freedesktop notification service, shared by all phones."""

    _instance: "DesktopNotifications | None" = None

    @classmethod
    def shared(cls) -> "DesktopNotifications":
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    def __init__(self):
        self.handlers: dict[int, "PhoneNotifications"] = {}
        self.proxy = None
        self.capabilities: list[str] = []
        try:
            self.proxy = Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, None, BUS_NAME, OBJECT, BUS_NAME, None)
            self.proxy.connect("g-signal", self._signal)
            self.capabilities = list(self.proxy.call_sync("GetCapabilities", None, Gio.DBusCallFlags.NONE, 2000, None).unpack()[0])
        except GLib.Error as error:
            print(f"Desktop notifications unavailable: {error.message}")
            self.proxy = None

    def notify(self, owner: "PhoneNotifications", replaces: int, app: str, title: str, body: str,
               actions: list[str], hints: dict, timeout_ms: int = -1) -> int:
        if not self.proxy:
            return 0
        try:
            result = self.proxy.call_sync(
                "Notify",
                GLib.Variant("(susssasa{sv}i)", (app, replaces, "app.droidmirror.linux", title, body, actions, hints, timeout_ms)),
                Gio.DBusCallFlags.NONE, 2000, None,
            )
        except GLib.Error as error:
            print(f"Could not show notification: {error.message}")
            return 0
        identifier = result.unpack()[0]
        self.handlers[identifier] = owner
        return identifier

    def close(self, identifier: int) -> None:
        if self.proxy and identifier:
            try:
                self.proxy.call_sync("CloseNotification", GLib.Variant("(u)", (identifier,)), Gio.DBusCallFlags.NONE, 2000, None)
            except GLib.Error:
                pass

    def _signal(self, _proxy, _sender, signal, parameters) -> None:
        values = parameters.unpack()
        owner = self.handlers.get(values[0])
        if not owner:
            return
        if signal == "ActionInvoked":
            owner.desktop_action(values[0], values[1])
        elif signal == "NotificationReplied":  # KDE inline replies
            owner.desktop_reply(values[0], values[1])
        elif signal == "NotificationClosed":
            self.handlers.pop(values[0], None)
            owner.desktop_closed(values[0], values[1])


class PhoneNotifications:
    """Desktop cards for one phone's notifications. Its PhoneBackground owns the
    encrypted session and calls `receive` / provides `send`."""

    def __init__(self, address: str, name: str, send: Callable[[dict], None], open_on_phone: Callable[[dict], None]):
        self.address = address
        self.name = name
        self._send = send
        self.open_on_phone = open_on_phone
        self.cards: dict[str, dict] = {}  # phone id -> {"desktop": int, "version": int, "actions": [...]}
        self.by_desktop: dict[int, str] = {}
        self.closing: set[int] = set()

    def clear(self) -> None:
        desktop = DesktopNotifications.shared()
        for card in list(self.cards.values()):
            self.closing.add(card["desktop"])
            desktop.close(card["desktop"])
        self.cards.clear()

    def receive(self, message: dict) -> None:
        if message.get("type") == "activitiesReset":
            # The phone resends current activities right after a reset.
            desktop = DesktopNotifications.shared()
            for phone_id, card in list(self.cards.items()):
                if card.get("activity"):
                    self.cards.pop(phone_id)
                    self.closing.add(card["desktop"])
                    desktop.close(card["desktop"])
            return
        self._message(message)

    # -- phone → desktop -----------------------------------------------------------

    def _message(self, message: dict) -> None:
        kind = message.get("type")
        if kind == "notification":
            self._show(message)
        elif kind == "removed":
            card = self.cards.pop(str(message.get("id")), None)
            if card:
                self.closing.add(card["desktop"])
                DesktopNotifications.shared().close(card["desktop"])
        elif kind == "actionResult" and message.get("success") is False:
            DesktopNotifications.shared().notify(self, 0, self.name, "Action failed",
                                                 "The phone could not run that notification action.", [], {}, 5000)

    def _show(self, message: dict) -> None:
        if message.get("activity"):
            self._show_activity(message)
            return
        # Other ongoing/persistent items (media, downloads, services) stay on the phone.
        if message.get("ongoing") or message.get("persistent"):
            return
        phone_id = str(message["id"])
        desktop = DesktopNotifications.shared()
        card = self.cards.get(phone_id)
        app = message.get("app") or "Android"
        title = message.get("title") or app
        if message.get("isMessage") and message.get("conversation"):
            title = f"{message['conversation']}: {title}"
        body = GLib.markup_escape_text(message.get("body") or "")
        actions: list[str] = ["default", "Open on phone"]
        specs = []
        reply = None
        for action in message.get("actions", [])[:3]:
            specs.append(action)
            if action.get("opensApp"):
                continue  # opening an app needs the mirror; "Open on phone" covers it
            if action.get("reply") and "inline-reply" in desktop.capabilities and reply is None:
                reply = action
                actions += ["inline-reply", action.get("title", "Reply")]
            elif not action.get("reply"):
                actions += [f"action:{action['id']}", action.get("title", "Action")]
        hints = {
            "desktop-entry": GLib.Variant("s", "app.droidmirror.linux"),
            "x-droidmirror-phone": GLib.Variant("s", self.name),
        }
        from . import config
        if message.get("silent") or message.get("snapshot") or not config.load_settings().get("notification_sounds", True):
            hints["suppress-sound"] = GLib.Variant("b", True)
            hints["urgency"] = GLib.Variant("y", 0)
        identifier = desktop.notify(self, card["desktop"] if card else 0, f"{app} · {self.name}", title, body, actions, hints)
        if not identifier:
            return
        self.cards[phone_id] = {"desktop": identifier, "version": message.get("version", 0), "actions": specs,
                                "reply": reply["id"] if reply else None, "message": message}
        self.by_desktop[identifier] = phone_id

    def _show_activity(self, message: dict) -> None:
        """Live Activities (rides, timers, scores) as one resident notification
        per activity, updated in place silently; progress uses the standard
        `value` hint."""
        phone_id = str(message["id"])
        desktop = DesktopNotifications.shared()
        card = self.cards.get(phone_id)
        app = message.get("app") or "Android"
        lines = [message.get("status"), message.get("subtitle"), message.get("body")]
        body = "\n".join(GLib.markup_escape_text(str(line)) for line in lines if line)
        hints = {
            "desktop-entry": GLib.Variant("s", "app.droidmirror.linux"),
            "resident": GLib.Variant("b", True),
            "suppress-sound": GLib.Variant("b", True),
            "urgency": GLib.Variant("y", 0 if card else 1),
            "category": GLib.Variant("s", "x-droidmirror.activity"),
        }
        fraction = message.get("fraction")
        if isinstance(fraction, (int, float)) and 0 <= fraction <= 1:
            hints["value"] = GLib.Variant("i", int(round(fraction * 100)))
        actions = ["default", "Open on phone"] if message.get("canOpen", True) else []
        identifier = desktop.notify(self, card["desktop"] if card else 0, f"{app} · {self.name}",
                                    message.get("title") or app, body, actions, hints, 0)
        if identifier:
            self.cards[phone_id] = {"desktop": identifier, "version": message.get("version", 0), "actions": [],
                                    "reply": None, "message": message, "activity": True}
            self.by_desktop[identifier] = phone_id

    # -- desktop → phone -----------------------------------------------------------

    def desktop_action(self, identifier: int, key: str) -> None:
        phone_id = self.by_desktop.get(identifier)
        card = self.cards.get(phone_id) if phone_id else None
        if not card:
            return
        if key.startswith("action:"):
            action = key.split(":", 1)[1]
            opens = any(a.get("id") == action and a.get("opensApp") for a in card["actions"])
            self._send({"type": "action", "id": phone_id, "version": card["version"], "action": action,
                        "request": str(uuid.uuid4()), "opensApp": opens})
        elif key == "default":
            # Opens the source app in a mirror, like clicking a Mac notification.
            self.open_on_phone({"type": "action", "id": phone_id, "version": card["version"], "action": "open",
                                "request": str(uuid.uuid4())})

    def desktop_reply(self, identifier: int, text: str) -> None:
        phone_id = self.by_desktop.get(identifier)
        card = self.cards.get(phone_id) if phone_id else None
        if not card or not card.get("reply") or not text.strip():
            return
        self._send({"type": "action", "id": phone_id, "version": card["version"], "action": card["reply"],
                    "request": str(uuid.uuid4()), "text": text[:1024], "opensApp": False})

    def desktop_closed(self, identifier: int, reason: int) -> None:
        phone_id = self.by_desktop.pop(identifier, None)
        if identifier in self.closing:
            self.closing.discard(identifier)
            return
        card = self.cards.get(phone_id) if phone_id else None
        # Only an explicit user dismissal clears the phone's notification;
        # expiry and programmatic closes do not (same as macOS).
        if card and card.get("activity"):
            self.cards.pop(phone_id, None)  # ongoing on the phone; closing only hides it here
            return
        if card and reason == CLOSED_BY_USER:
            self.cards.pop(phone_id, None)
            self._send({"type": "dismiss", "id": phone_id, "version": card["version"], "request": str(uuid.uuid4())})
