"""Entry point: `python3 -m droidmirror_linux [list | pair ADDRESS | forget ADDRESS | mirror ADDRESS]`.

Without arguments the GTK app opens. The subcommands work headless (SSH, scripts).
"""

from __future__ import annotations

import argparse
import getpass
import sys


def _cli(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="droidmirror", description="Mirror and control Android phones from Linux.")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list", help="list paired Bluetooth devices and their DroidMirror setup")
    pair = sub.add_parser("pair", help="save a phone's private DroidMirror pairing code")
    pair.add_argument("address")
    forget = sub.add_parser("forget", help="remove a phone's DroidMirror pairing code")
    forget.add_argument("address")
    mirror = sub.add_parser("mirror", help="mirror one phone (several can run at once)")
    mirror.add_argument("address")
    mirror.add_argument("--unlock", choices=["ask", "always", "never"], help="saved-PIN unlock policy for this session")
    link = sub.add_parser("open-on-phone", help="open a web link on a connected phone (via the running app)")
    link.add_argument("url")
    launch = sub.add_parser("launch-app", help="open a phone app in a mirror (used by phone-app launchers)")
    launch.add_argument("address")
    launch.add_argument("component")
    args = parser.parse_args(argv)

    from . import config

    if args.command == "list":
        for device in config.bluetooth_devices():
            state = "paired with DroidMirror" if device.get("droidmirror") else "not set up"
            print(f"{device['address']}  {device.get('name', ''):<28} {state}")
        return 0
    if args.command == "pair":
        code = sys.stdin.read() if not sys.stdin.isatty() else getpass.getpass("Private pairing code from the phone: ")
        config.pair(args.address, code)
        print("Pairing code saved. It is verified on the first mirror.")
        return 0
    if args.command in ("open-on-phone", "launch-app"):
        from gi.repository import Gio, GLib
        remote = Gio.Application(application_id="app.droidmirror.linux", flags=Gio.ApplicationFlags.IS_LAUNCHER)
        remote.register(None)
        if not remote.get_is_remote():
            print("DroidMirror is not running. Start it (it runs in the background) and try again.", file=sys.stderr)
            return 1
        if args.command == "open-on-phone":
            remote.activate_action("open-link", GLib.Variant("s", args.url))
        else:
            remote.activate_action("launch-app", GLib.Variant("s", f"{args.address} {args.component}"))
        return 0
    if args.command == "forget":
        config.forget(args.address)
        return 0

    from gi.repository import GLib

    from .session import MirrorSession

    if args.unlock:
        settings = config.load_settings()
        settings["unlock"] = args.unlock
        config.save_settings(settings)
    loop = GLib.MainLoop()
    last = {"stage": None}

    def changed(session: MirrorSession) -> None:
        if session.state.stage != last["stage"]:
            last["stage"] = session.state.stage
            print(f"[{session.name}] {session.state.stage}", flush=True)
        if not session.state.running:
            if session.state.error:
                print(f"[{session.name}] {session.state.error}", file=sys.stderr, flush=True)
            if session.log_path:
                print(f"[{session.name}] log: {session.log_path}", flush=True)
            loop.quit()

    def ask(session: MirrorSession) -> None:
        answer = input("Unlock with the PIN saved on the phone? [y/N] ").strip().lower()
        session.send_unlock_decision(answer in ("y", "yes"))

    session = MirrorSession(args.address, args.address, changed, ask)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, 2, lambda: (session.stop(), True)[1])
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, 15, lambda: (session.stop(), True)[1])
    session.start()
    if session.state.running:
        loop.run()
    return 0 if not session.state.error else 1


def main() -> int:
    argv = sys.argv[1:]
    if argv and argv[0] in ("list", "pair", "forget", "mirror", "open-on-phone", "launch-app", "-h", "--help"):
        return _cli(argv)
    from .app import main as gui

    return gui([sys.argv[0], *argv])


if __name__ == "__main__":
    sys.exit(main())
