"""DroidMirror for Linux: GTK 4 / libadwaita application.

The application object owns every phone, mirror session and background
connection, so background features keep working with no window open:
it is started at login with `--background` (XDG autostart), closing the window
keeps it running, and launching it again just shows the window. Quit from the
window menu ends mirrors and background connections gracefully.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk  # noqa: E402

from . import config  # noqa: E402
from .background import PhoneBackground  # noqa: E402
from .session import MirrorSession  # noqa: E402

APP_ID = "app.droidmirror.linux"


def autostart_path() -> Path:
    return config.config_dir().parent / "autostart" / f"{APP_ID}.desktop"


def set_autostart(enabled: bool) -> None:
    path = autostart_path()
    if not enabled:
        path.unlink(missing_ok=True)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "[Desktop Entry]\nType=Application\nName=DroidMirror\n"
        "Comment=Keeps your phones' notifications, clipboard and media connected\n"
        f"Exec={config.launcher_command()} --background\nIcon={APP_ID}\nTerminal=false\nNoDisplay=true\n"
        "X-GNOME-Autostart-enabled=true\n"
    )


class PhoneRow(Adw.ActionRow):
    def __init__(self, app: "DroidMirrorApp", device: dict):
        super().__init__()
        self.app = app
        self.device = device
        self.address = device["address"]
        self.set_activatable(False)
        self.add_prefix(Gtk.Image.new_from_icon_name("phone-symbolic"))
        self.audio = Gtk.ToggleButton(valign=Gtk.Align.CENTER, tooltip_text="Play phone audio on this computer")
        self.audio.set_child(Gtk.Image.new_from_icon_name("audio-speakers-symbolic"))
        self.audio_handler = self.audio.connect("toggled", self._audio_toggled)
        self.add_suffix(self.audio)
        self.mirror = Gtk.Button(valign=Gtk.Align.CENTER)
        self.mirror.connect("clicked", self._mirror_clicked)
        self.add_suffix(self.mirror)
        menu = Gio.Menu()
        for label, action in (("Pair with QR code…", "qr-pair"), ("Enter pairing code…", "pair"), ("Send a link to this phone…", "send-link"),
                              ("Send files to this phone…", "send-files"),
                              ("Turn on phone hotspot", "hotspot-on"), ("Turn off phone hotspot", "hotspot-off"),
                              ("Rename…", "rename"), ("Open last log", "log"), ("Forget DroidMirror pairing", "forget")):
            menu.append(label, f"app.{action}::{self.address}")
        more = Gtk.MenuButton(icon_name="view-more-symbolic", menu_model=menu, valign=Gtk.Align.CENTER, tooltip_text="More")
        more.add_css_class("flat")
        self.add_suffix(more)
        # Drop files on a phone to save them in its Downloads folder.
        drop = Gtk.DropTarget.new(Gdk.FileList, Gdk.DragAction.COPY)
        drop.connect("drop", self._dropped)
        self.add_controller(drop)
        self.refresh()

    def _dropped(self, _target, value, _x, _y) -> bool:
        paths = [Path(f.get_path()) for f in value.get_files() if f.get_path()]
        self.app.send_files(self.address, paths)
        return bool(paths)

    @property
    def name(self) -> str:
        return self.app.phone_name(self.address, self.device)

    def refresh(self) -> None:
        session = self.app.sessions.get(self.address)
        background = self.app.backgrounds.get(self.address)
        self.set_title(GLib.markup_escape_text(self.name))
        paired = self.device.get("droidmirror", False)
        if session and session.state.running:
            subtitle = session.state.stage
            self.mirror.set_label("Stop")
            self.mirror.remove_css_class("suggested-action")
            self.mirror.add_css_class("destructive-action")
        else:
            if session and session.state.error:
                subtitle = session.state.error
            elif session and session.state.ended_on_phone:
                subtitle = session.state.stage
            elif not paired:
                subtitle = "Not set up · enter the pairing code from the phone"
            elif background and background.connected:
                subtitle = "Connected · lock the phone, then mirror"
            else:
                subtitle = "Ready · lock the phone, then mirror"
            self.mirror.set_label("Mirror" if paired else "Set up…")
            self.mirror.remove_css_class("destructive-action")
            self.mirror.add_css_class("suggested-action")
        self.set_subtitle(GLib.markup_escape_text(f"{self.address} · {subtitle}"))
        # Shown while media can play here, like the Mac's floating audio button.
        available = bool(session and session.state.running and (session.state.audio_available or session.state.audio_playing))
        self.audio.set_visible(available)
        self.audio.handler_block(self.audio_handler)
        self.audio.set_active(bool(session and session.state.audio_playing))
        self.audio.handler_unblock(self.audio_handler)

    def _audio_toggled(self, button) -> None:
        session = self.app.sessions.get(self.address)
        if session and session.state.running:
            session.set_audio(button.get_active())

    def _mirror_clicked(self, _button) -> None:
        session = self.app.sessions.get(self.address)
        if session and session.state.running:
            session.stop()
        elif not self.device.get("droidmirror"):
            self.app.pair_dialog(self.address)
        else:
            self.app.start_mirror(self.address)


class MainWindow(Adw.ApplicationWindow):
    def __init__(self, app: "DroidMirrorApp"):
        super().__init__(application=app, title="DroidMirror")
        self.app = app
        self.set_default_size(580, 720)
        self.toasts = Adw.ToastOverlay()
        view = Adw.ToolbarView()
        header = Adw.HeaderBar()
        refresh = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="Refresh paired phones")
        refresh.connect("clicked", lambda _b: app.reload())
        header.pack_start(refresh)
        menu = Gio.Menu()
        menu.append("Bluetooth Settings", "app.bluetooth-settings")
        menu.append("Quit DroidMirror", "app.quit")
        header.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu, tooltip_text="Main menu"))
        view.add_top_bar(header)

        page = Adw.PreferencesPage()
        self.phones = Adw.PreferencesGroup(
            title="Phones",
            description="Phones paired with this computer in system Bluetooth settings. Each phone keeps its own "
            "DroidMirror pairing code, and several phones can mirror at the same time.",
        )
        page.add(self.phones)
        self.handoff = Adw.PreferencesGroup(title="Continue from your phone")
        page.add(self.handoff)
        self.others = Adw.PreferencesGroup(title="Other Bluetooth devices")
        self.others_expander = Adw.ExpanderRow(title="Show other paired devices",
                                               subtitle="Use these if your phone isn't recognized as a phone")
        self.others.add(self.others_expander)
        page.add(self.others)
        page.add(self._background_group())
        page.add(self._mirroring_group())
        page.add(self._help_group())
        view.set_content(page)
        self.toasts.set_child(view)
        self.set_content(self.toasts)
        self.rows: dict[str, tuple[PhoneRow, Gtk.Widget]] = {}
        self.handoff_rows: list[Gtk.Widget] = []
        self.populate()

    def toast(self, message: str) -> None:
        self.toasts.add_toast(Adw.Toast(title=GLib.markup_escape_text(message), timeout=6))

    def populate(self) -> None:
        for row, container in list(self.rows.values()):
            container.remove(row)
        self.rows.clear()
        phones = others = 0
        for device in sorted(self.app.devices, key=lambda d: (not d.get("droidmirror"), d.get("name", ""))):
            row = PhoneRow(self.app, device)
            if device.get("droidmirror") or device.get("icon") == "phone":
                self.phones.add(row)
                self.rows[device["address"]] = (row, self.phones)
                phones += 1
            else:
                self.others_expander.add_row(row)
                self.rows[device["address"]] = (row, self.others_expander)
                others += 1
        self.others.set_visible(others > 0)
        if not phones:
            self.toast("Pair your phone in Bluetooth settings, then refresh.")
        self.refresh_handoff()

    def refresh_row(self, address: str) -> None:
        entry = self.rows.get(address)
        if entry:
            entry[0].refresh()
        self.refresh_handoff()

    def refresh_handoff(self) -> None:
        for widget in self.handoff_rows:
            self.handoff.remove(widget)
        self.handoff_rows.clear()
        for background in self.app.backgrounds.values():
            task = background.handoff
            if not task:
                continue
            url = task.get("url", "")
            row = Adw.ActionRow(title=GLib.markup_escape_text(task.get("title") or url),
                                subtitle=GLib.markup_escape_text(f"{background.name} · {url}"))
            button = Gtk.Button(label="Open", valign=Gtk.Align.CENTER)
            button.connect("clicked", lambda _b, u=url: Gio.AppInfo.launch_default_for_uri(u, None))
            row.add_suffix(button)
            self.handoff.add(row)
            self.handoff_rows.append(row)
        self.handoff.set_visible(bool(self.handoff_rows))

    # -- settings groups ------------------------------------------------------------

    def _switch(self, group, key: str, title: str, subtitle: str = "", after=None) -> None:
        row = Adw.SwitchRow(title=title, subtitle=subtitle)
        row.set_active(bool(config.load_settings().get(key, config.DEFAULTS.get(key, False))))

        def changed(r, _p):
            self.app.set_setting(key, r.get_active())
            if after:
                after(r.get_active())

        row.connect("notify::active", changed)
        group.add(row)

    def _background_group(self) -> Adw.PreferencesGroup:
        group = Adw.PreferencesGroup(title="Background features",
                                     description="These work while a phone is connected over Bluetooth, even with this window closed.")
        restart = lambda _v: self.app.restart_backgrounds()  # noqa: E731
        self._switch(group, "background", "Run in the background and start at login",
                     "Keeps phones connected for notifications, clipboard and media", self.app.background_changed)
        self._switch(group, "notifications", "Show phone notifications", "Closing one here clears it on the phone", restart)
        self._switch(group, "notification_sounds", "Play sounds for phone notifications")
        self._switch(group, "clipboard", "Share clipboard text", "Copy on one device, paste on the other", restart)
        self._switch(group, "media", "Phone media in desktop media controls", "", restart)
        self._switch(group, "handoff", "Continue phone browsing here", "Shows the phone's current web page above", restart)
        self._switch(group, "handoff_notifications", "Notify about new handoff pages")
        self._switch(group, "focus_from_phone", "Follow the phone's Focus / Do Not Disturb",
                     "Also enable Focus sync in the Android app", restart)
        self._switch(group, "focus_to_phone", "Send Do Not Disturb to the phone", "", restart)
        self._switch(group, "app_launchers", "Add phone apps to the application menu",
                     "Each app opens in a mirror of its phone", restart)
        self._switch(group, "wear", "Wear OS companion", "Shows this computer's battery on your watch and lets the watch ring it", restart)
        self._switch(group, "wireless_adb", "Connect wireless ADB automatically",
                     "Runs adb connect when the phone publishes its wireless debugging port")
        return group

    def _mirroring_group(self) -> Adw.PreferencesGroup:
        settings = config.load_settings()
        group = Adw.PreferencesGroup(title="Mirroring",
                                     description="Wi-Fi settings apply once video moves from Bluetooth to a direct network connection.")
        unlock = Adw.ComboRow(title="Unlock with the phone's saved PIN",
                              subtitle="Uses the PIN saved in the Android app's automatic unlock settings")
        choices = ["ask", "always", "never"]
        unlock.set_model(Gtk.StringList.new(["Ask each time", "Always", "Never (unlock manually)"]))
        unlock.set_selected(choices.index(settings.get("unlock", "ask")) if settings.get("unlock") in choices else 0)
        unlock.connect("notify::selected", lambda row, _p: self.app.set_setting("unlock", choices[row.get_selected()]))
        group.add(unlock)
        sizes = [0, 1280, 1600, 1920, 2400]
        size = Adw.ComboRow(title="Wi-Fi resolution (longest edge)")
        size.set_model(Gtk.StringList.new(["Native", "1280 px", "1600 px", "1920 px", "2400 px"]))
        current = int(settings.get("max_size", 1920))
        size.set_selected(sizes.index(current) if current in sizes else 3)
        size.connect("notify::selected", lambda row, _p: self.app.set_setting("max_size", sizes[row.get_selected()]))
        group.add(size)
        for key, title, low, high, step in (("max_fps", "Wi-Fi frame rate (fps)", 15, 120, 5),
                                             ("bit_rate_mbps", "Wi-Fi bitrate (Mbps)", 2, 40, 1),
                                             ("video_buffer_ms", "Wi-Fi playback buffer (ms)", 0, 200, 10)):
            row = Adw.SpinRow.new_with_range(low, high, step)
            row.set_title(title)
            row.set_value(float(settings.get(key, config.DEFAULTS[key])))
            row.connect("notify::value", lambda r, _p, k=key: self.app.set_setting(k, int(r.get_value())))
            group.add(row)
        from . import wifi_aware
        supported, reason = wifi_aware.support()
        self._switch(group, "wifi_aware", "Use Wi-Fi Aware video when available",
                     "Direct phone-to-computer Wi-Fi without a network. " + ("Available on this computer." if supported else reason))
        self._switch(group, "always_on_top", "Keep the mirror window on top")
        self._switch(group, "borderless", "Borderless mirror window")
        return group

    def _help_group(self) -> Adw.PreferencesGroup:
        group = Adw.PreferencesGroup(title="Setting up a phone")
        for text in (
            "1. Pair the phone with this computer in Bluetooth settings.",
            "2. On the phone, open DroidMirror, start and authorize Shizuku, and add this computer (up to two computers per phone).",
            "3. Tap Show pairing code on the phone, then choose Set up… here and paste it.",
            "4. Enable the background bridge on the phone, lock it, and press Mirror.",
        ):
            label = Gtk.Label(label=text, xalign=0, wrap=True, margin_top=4, margin_bottom=4)
            label.add_css_class("dim-label")
            group.add(label)
        return group


class DroidMirrorApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.add_main_option("background", 0, GLib.OptionFlags.NONE, GLib.OptionArg.NONE,
                             "Start without a window; keep phones connected in the background", None)
        self.sessions: dict[str, MirrorSession] = {}
        self.backgrounds: dict[str, PhoneBackground] = {}
        self.devices: list[dict] = []
        self.pending_open: dict[str, dict] = {}
        self.pending_launch: dict[str, str] = {}
        self.held = False

    # -- lifecycle --------------------------------------------------------------------

    def do_startup(self):
        Adw.Application.do_startup(self)
        for name, callback in (("pair", self.pair_dialog), ("forget", self.forget), ("log", self.open_log),
                               ("rename", self.rename_dialog), ("qr-pair", self.qr_pair_dialog), ("send-link", self.send_link_dialog),
                               ("hotspot-on", lambda a: self.hotspot(a, True)), ("hotspot-off", lambda a: self.hotspot(a, False)),
                               ("mirror", self.start_mirror), ("send-files", self.send_files_dialog),
                               ("launch-app", self.launch_app),
                               ("open-file", lambda p: Gio.AppInfo.launch_default_for_uri(Path(p).as_uri(), None)), ("open-link", lambda url: self.open_link_on_phone(url))):
            action = Gio.SimpleAction.new(name, GLib.VariantType.new("s"))
            action.connect("activate", lambda _a, value, cb=callback: cb(value.get_string()))
            self.add_action(action)
        for name, callback in (("quit", lambda *_: self.quit_gracefully()), ("show", lambda *_: self.present()),
                               ("bluetooth-settings", lambda *_: self.open_bluetooth_settings())):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", callback)
            self.add_action(action)
        self.set_accels_for_action("app.quit", ["<Control>q"])
        if config.load_settings().get("background", True):
            self.hold()
            self.held = True
            set_autostart(True)
        self.reload()

    def do_command_line(self, command_line):
        options = command_line.get_options_dict().end().unpack()
        if not options.get("background"):
            self.present()
        return 0

    def present(self) -> None:
        window = self.window or MainWindow(self)
        window.present()

    @property
    def window(self) -> MainWindow | None:
        for window in self.get_windows():
            if isinstance(window, MainWindow):
                return window
        return None

    def quit_gracefully(self) -> None:
        for session in self.sessions.values():
            if session.state.running:
                session.stop()
        for background in self.backgrounds.values():
            background.stop()
        self.backgrounds.clear()
        if self.held:
            self.release()
            self.held = False
        for window in self.get_windows():
            window.destroy()
        # Give helpers a moment to close Bluetooth links so phones restore their displays.
        GLib.timeout_add(400, lambda: (self.quit(), False)[1])

    def background_changed(self, enabled: bool) -> None:
        set_autostart(enabled)
        if enabled and not self.held:
            self.hold()
            self.held = True
        elif not enabled and self.held:
            self.release()
            self.held = False

    def set_setting(self, key: str, value) -> None:
        settings = config.load_settings()
        settings[key] = value
        config.save_settings(settings)

    def toast(self, message: str) -> None:
        if self.window:
            self.window.toast(message)
        else:
            notification = Gio.Notification.new("DroidMirror")
            notification.set_body(message)
            self.send_notification(None, notification)

    # -- phones -------------------------------------------------------------------------

    def phone_name(self, address: str, device: dict | None = None) -> str:
        custom = config.load_settings().get("names", {}).get(address)
        if custom:
            return custom
        if device is None:
            device = next((d for d in self.devices if d["address"] == address), {})
        return device.get("name") or "Android phone"

    def reload(self) -> None:
        try:
            self.devices = config.bluetooth_devices()
        except config.HelperError as error:
            self.devices = []
            print(f"DroidMirror: {error}")
        self.sync_backgrounds()
        if self.window:
            self.window.populate()

    def sync_backgrounds(self) -> None:
        """One background connection per phone set up with DroidMirror."""
        wanted = {d["address"]: d for d in self.devices if d.get("droidmirror")}
        for address in list(self.backgrounds):
            if address not in wanted:
                self.backgrounds.pop(address).stop()
        for address, device in wanted.items():
            if address not in self.backgrounds:
                background = PhoneBackground(address, self.phone_name(address, device), self)
                self.backgrounds[address] = background
                background.start()

    def restart_backgrounds(self) -> None:
        """Feature switches change subscriptions; reconnect so the phone sees the new set."""
        for background in self.backgrounds.values():
            background.stop()
        self.backgrounds.clear()
        self.sync_backgrounds()

    # Host interface used by PhoneBackground.
    def refresh_row(self, address: str) -> None:
        if self.window:
            self.window.refresh_row(address)

    def raise_window(self) -> None:
        self.present()

    def launch_app(self, target: str) -> None:
        """'ADDRESS COMPONENT' from a phone-app launcher: mirror the phone, then open the app."""
        address, _, component = target.partition(" ")
        background = self.backgrounds.get(address)
        if not background or not background.connected:
            self.toast("The phone is not connected. Keep it nearby with its background bridge enabled.")
            return
        self.pending_launch[address] = component
        session = self.sessions.get(address)
        if session and session.state.running and session.state.streaming:
            self._send_launch(address)
        elif not (session and session.state.running):
            self.start_mirror(address)

    def _send_launch(self, address: str) -> None:
        component = self.pending_launch.pop(address, None)
        background = self.backgrounds.get(address)
        if component and background:
            background.launch_app(component, lambda r: r.get("success") or self.toast("The phone could not open that app. Unlock it in the mirror and try again."))

    def open_on_phone(self, address: str, action: dict) -> None:
        """Notification click: open the app in a mirror, then send the open action once video starts."""
        session = self.sessions.get(address)
        background = self.backgrounds.get(address)
        if session and session.state.running and session.state.streaming:
            if background:
                background.send(action)
            return
        self.pending_open[address] = action
        if not (session and session.state.running):
            self.start_mirror(address)

    # -- mirroring ----------------------------------------------------------------------

    def start_mirror(self, address: str) -> None:
        existing = self.sessions.get(address)
        if existing and existing.state.running:
            return
        session = MirrorSession(address, self.phone_name(address), self.session_changed, self.ask_unlock)
        self.sessions[address] = session
        session.start()

    def session_changed(self, session: MirrorSession) -> None:
        if session.state.streaming and session.address in self.pending_open:
            background = self.backgrounds.get(session.address)
            action = self.pending_open.pop(session.address)
            if background:
                background.send(action)
        if session.state.streaming and session.address in self.pending_launch:
            self._send_launch(session.address)
        if not session.state.running:
            self.pending_open.pop(session.address, None)
            self.pending_launch.pop(session.address, None)
        self.refresh_row(session.address)
        if not session.state.running and session.state.error:
            self.toast(f"{session.name}: {session.state.error}")

    def ask_unlock(self, session: MirrorSession) -> None:
        self.present()
        dialog = Adw.AlertDialog(
            heading="Unlock your phone?",
            body=f"{session.name} is locked. DroidMirror can enter the PIN saved on the phone before video starts, "
            "or you can unlock it manually in the mirror window.",
        )
        dialog.add_response("manual", "Unlock manually")
        dialog.add_response("allow", "Use saved PIN")
        dialog.set_response_appearance("allow", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("allow")
        dialog.connect("response", lambda _d, response: session.send_unlock_decision(response == "allow"))
        dialog.present(self.window)

    # -- dialogs and actions ---------------------------------------------------------------

    def _entry_dialog(self, heading: str, body: str, entry: Gtk.Widget, label: str, done) -> None:
        self.present()
        dialog = Adw.AlertDialog(heading=heading, body=body)
        dialog.set_extra_child(entry)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("ok", label)
        dialog.set_response_appearance("ok", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("ok")
        dialog.connect("response", lambda _d, response: response == "ok" and done())
        dialog.present(self.window)

    def pair_dialog(self, address: str) -> None:
        entry = Gtk.PasswordEntry(show_peek_icon=True, placeholder_text="Private pairing code")

        def save():
            try:
                config.pair(address, entry.get_text())
                self.toast("Pairing code saved. It is verified on the first connection.")
            except config.HelperError as error:
                self.toast(str(error))
            background = self.backgrounds.pop(address, None)
            if background:
                background.stop()
            self.reload()

        self._entry_dialog(f"Set up {self.phone_name(address)}",
                           "On the phone, open DroidMirror, choose this computer, and tap Show pairing code. Paste the "
                           "private code here. It is separate from the short Bluetooth pairing code. Keep it private.",
                           entry, "Save pairing code", save)

    def qr_pair_dialog(self, address: str) -> None:
        """Show a QR invitation; the phone scans it and sends its pairing code over Bluetooth."""
        import os
        import shutil
        from gi.repository import Gdk
        helper = config.helper_path()
        if not helper:
            self.toast("The DroidMirror Bluetooth helper is missing.")
            return
        if not shutil.which("qrencode"):
            self.toast("Install qrencode to show pairing QR codes, or use Enter pairing code.")
            return
        self.present()
        picture = Gtk.Picture(content_fit=Gtk.ContentFit.CONTAIN, width_request=280, height_request=280)
        spinner = Adw.Spinner(width_request=48, height_request=48, halign=Gtk.Align.CENTER)
        stack = Gtk.Stack()
        stack.add_named(spinner, "wait")
        stack.add_named(picture, "code")
        dialog = Adw.AlertDialog(heading=f"Pair {self.phone_name(address)}",
                                 body="On the phone, open DroidMirror, choose this computer, and tap Scan Mac QR code. "
                                      "The code works once and expires in two minutes.")
        dialog.set_extra_child(stack)
        dialog.add_response("close", "Close")
        process = subprocess.Popen([helper, "--qr-pair", address], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        os.set_blocking(process.stdout.fileno(), False)
        buffer = bytearray()

        def readable(fd, _condition):
            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                return True
            if not chunk:
                return False
            buffer.extend(chunk)
            while b"\n" in buffer:
                index = buffer.index(b"\n")
                line = bytes(buffer[:index]).decode(errors="replace").strip()
                del buffer[: index + 1]
                if line.startswith("QR "):
                    png = subprocess.run(["qrencode", "-t", "PNG", "-s", "8", "-m", "2", "-o", "-", line[3:]],
                                         capture_output=True).stdout
                    picture.set_paintable(Gdk.Texture.new_from_bytes(GLib.Bytes.new(png)))
                    stack.set_visible_child_name("code")
                elif line == "SAVED":
                    dialog.close()
                    self.toast("Pairing code received from the phone.")
                    stale = self.backgrounds.pop(address, None)
                    if stale:
                        stale.stop()
                    self.reload()
                elif line.startswith("FAILED"):
                    dialog.set_body(line[7:] or "Pairing failed. Use Enter pairing code instead.")
                    stack.set_visible(False)
            return True

        GLib.io_add_watch(process.stdout.fileno(), GLib.PRIORITY_DEFAULT, GLib.IO_IN | GLib.IO_HUP, readable)
        dialog.connect("closed", lambda _d: process.poll() is None and process.terminate())
        dialog.present(self.window)

    def rename_dialog(self, address: str) -> None:
        entry = Gtk.Entry(text=self.phone_name(address))

        def save():
            settings = config.load_settings()
            names = dict(settings.get("names", {}))
            text = entry.get_text().strip()
            if text:
                names[address] = text
            else:
                names.pop(address, None)
            settings["names"] = names
            config.save_settings(settings)
            self.reload()

        self._entry_dialog("Rename phone", "", entry, "Rename", save)

    def send_link_dialog(self, address: str) -> None:
        entry = Gtk.Entry(placeholder_text="https://")
        self._entry_dialog(f"Open a link on {self.phone_name(address)}", "", entry, "Open on phone",
                           lambda: self.open_link_on_phone(entry.get_text().strip(), address))

    def open_link_on_phone(self, url: str, address: str | None = None) -> None:
        if not url.startswith(("http://", "https://")):
            self.toast("Enter an http or https link.")
            return
        candidates = [b for a, b in self.backgrounds.items() if b.connected and (address is None or a == address)]
        if not candidates:
            self.toast("No phone is connected. Keep the phone nearby with its background bridge enabled.")
            return
        phone = candidates[0]
        if not phone.open_link(url, lambda ok: self.toast(f"Opened on {phone.name}." if ok else f"{phone.name} could not open the link.")):
            self.toast(f"Could not reach {phone.name}.")

    def send_files(self, address: str, paths: list[Path]) -> None:
        background = self.backgrounds.get(address)
        if not background:
            self.toast("Set up this phone first.")
            return
        error = background.send_files(paths)
        self.toast(error or f"Sending {len(paths)} file{'s' if len(paths) != 1 else ''} to {background.name}…")

    def send_files_dialog(self, address: str) -> None:
        self.present()
        dialog = Gtk.FileDialog(title=f"Send files to {self.phone_name(address)}")

        def chosen(source, result):
            try:
                files = source.open_multiple_finish(result)
            except GLib.Error:
                return
            self.send_files(address, [Path(f.get_path()) for f in files if f.get_path()])

        dialog.open_multiple(self.window, None, chosen)

    def hotspot(self, address: str, enabled: bool) -> None:
        background = self.backgrounds.get(address)
        if not background or not background.connected:
            self.toast("The phone is not connected.")
            return

        def reply(result: dict) -> None:
            status = str(result.get("status") or ("done" if result.get("success") else "failed"))
            messages = {"on": "Phone hotspot is on. Connect to it in Wi-Fi settings.", "off": "Phone hotspot is off.",
                        "unsupported": "This phone can't control its hotspot from DroidMirror."}
            self.toast(messages.get(status, f"Hotspot: {status}"))

        background.hotspot(enabled, reply)

    def forget(self, address: str) -> None:
        session = self.sessions.get(address)
        if session and session.state.running:
            self.toast("Stop mirroring this phone first.")
            return
        try:
            config.forget(address)
            self.toast("DroidMirror pairing removed. The system Bluetooth pairing is unchanged.")
        except config.HelperError as error:
            self.toast(str(error))
        self.reload()

    def open_log(self, address: str) -> None:
        session = self.sessions.get(address)
        path = session.log_path if session else None
        if not path:
            logs = sorted((config.state_dir() / "logs").glob(f"DroidMirror-Bluetooth-{address.replace(':', '')}-*.log"))
            path = logs[-1] if logs else None
        if not path:
            self.toast("No connection log for this phone yet.")
            return
        Gio.AppInfo.launch_default_for_uri(path.as_uri(), None)

    def open_bluetooth_settings(self) -> None:
        for command in (["gnome-control-center", "bluetooth"], ["systemsettings", "kcm_bluetooth"], ["blueman-manager"]):
            try:
                subprocess.Popen(command)
                return
            except OSError:
                continue
        self.toast("Open your desktop's Bluetooth settings to pair a phone.")


def main(argv: list[str] | None = None) -> int:
    return DroidMirrorApp().run(argv if argv is not None else sys.argv)
