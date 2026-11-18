"""Desktop Do Not Disturb, for two-way Focus sync with the phone.

GNOME: the `org.gnome.desktop.notifications show-banners` setting.
KDE Plasma (and other servers implementing it): the notification server's
`Inhibit`/`UnInhibit` methods and `Inhibited` property.
"""

from __future__ import annotations

from typing import Callable

from gi.repository import Gio, GLib


class DesktopFocus:
    def __init__(self, on_change: Callable[[bool], None]):
        self.on_change = on_change
        self.backend = "none"
        self.settings = None
        self.proxy = None
        self.cookie = 0
        self.applying = False
        source = Gio.SettingsSchemaSource.get_default()
        if source and source.lookup("org.gnome.desktop.notifications", True):
            self.settings = Gio.Settings.new("org.gnome.desktop.notifications")
            self.settings.connect("changed::show-banners", lambda *_: self._report())
            self.backend = "gnome"
            return
        try:
            proxy = Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, None,
                                                   "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                                                   "org.freedesktop.Notifications", None)
            if proxy.get_cached_property("Inhibited") is not None:
                self.proxy = proxy
                proxy.connect("g-properties-changed", lambda *_: self._report())
                self.backend = "inhibit"
        except GLib.Error:
            pass

    @property
    def available(self) -> bool:
        return self.backend != "none"

    def focused(self) -> bool:
        if self.settings:
            return not self.settings.get_boolean("show-banners")
        if self.proxy:
            value = self.proxy.get_cached_property("Inhibited")
            return bool(value.unpack()) if value is not None else False
        return False

    def _report(self) -> None:
        if not self.applying:
            self.on_change(self.focused())

    def set_focused(self, focused: bool) -> None:
        if focused == self.focused():
            return
        self.applying = True
        try:
            if self.settings:
                self.settings.set_boolean("show-banners", not focused)
            elif self.proxy:
                if focused and not self.cookie:
                    hints = GLib.Variant("a{sv}", {})
                    self.cookie = self.proxy.call_sync("Inhibit", GLib.Variant("(ssa{sv})", ("app.droidmirror.linux", "Phone Focus is on", {})),
                                                       Gio.DBusCallFlags.NONE, 2000, None).unpack()[0]
                    del hints
                elif not focused and self.cookie:
                    self.proxy.call_sync("UnInhibit", GLib.Variant("(u)", (self.cookie,)), Gio.DBusCallFlags.NONE, 2000, None)
                    self.cookie = 0
        except GLib.Error as error:
            print(f"Could not change Do Not Disturb: {error.message}")
        finally:
            GLib.timeout_add(500, self._done)

    def _done(self) -> bool:
        self.applying = False
        return False
