"""Paths, settings and helper invocation for the Linux host."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

DEFAULTS = {
    "unlock": "ask",  # ask | always | never: saved-PIN unlock policy for each session
    "max_size": 1920,  # Wi-Fi picture: longest edge in px, 0 = native
    "max_fps": 60,
    "bit_rate_mbps": 12,
    "video_buffer_ms": 50,
    "audio_buffer_ms": 120,
    "always_on_top": False,
    "borderless": False,
    "background": True,  # run at login without a window, keep phones connected
    "notifications": True,  # phone notifications as desktop notifications
    "notification_sounds": True,
    "clipboard": True,  # clipboard text both ways
    "files": True,  # copied files and drag-and-drop over the BLE file lane
    "media": True,  # phone media as an MPRIS player
    "handoff": True,  # phone's current web page offered here
    "handoff_notifications": False,
    "focus_from_phone": False,
    "focus_to_phone": False,
    "wireless_adb": False,
    "app_launchers": False,  # phone apps as desktop launchers (opt-in)
    "wear": True,  # share battery with the watch; let the watch ring this computer
    "wifi_aware": True,  # use Wi-Fi Aware video when the adapter supports NAN
    "names": {},  # address -> custom display name
}


def _xdg(name: str, fallback: str) -> Path:
    value = os.environ.get(name)
    return Path(value) if value else Path.home() / fallback


def config_dir() -> Path:
    return _xdg("XDG_CONFIG_HOME", ".config") / "droidmirror"


def state_dir() -> Path:
    return _xdg("XDG_STATE_HOME", ".local/state") / "droidmirror"


def cache_dir() -> Path:
    return _xdg("XDG_CACHE_HOME", ".cache") / "droidmirror"


def install_dir() -> Path:
    """Directory holding the built helper and renderer (see build-linux.sh)."""
    env = os.environ.get("DROIDMIRROR_HOME")
    if env:
        return Path(env)
    here = Path(__file__).resolve().parent
    # Source checkout: Linux/app/droidmirror_linux -> Linux/build
    checkout = here.parent.parent / "build"
    if checkout.exists():
        return checkout
    return _xdg("XDG_DATA_HOME", ".local/share") / "droidmirror"


def _executable(*candidates: Path | str | None) -> str | None:
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def helper_path() -> str | None:
    return _executable(os.environ.get("DROIDMIRROR_HELPER"), install_dir() / "droidmirror-bluetooth")


def scrcpy_path() -> str | None:
    return _executable(os.environ.get("DROIDMIRROR_SCRCPY"), install_dir() / "droidmirror-renderer")


def resource_dir() -> Path | None:
    path = install_dir() / "resources"
    return path if path.is_dir() else None


def android_tool(name: str) -> str | None:
    for root in (os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"), str(Path.home() / "Android/Sdk")):
        if root:
            found = _executable(Path(root) / "platform-tools" / name)
            if found:
                return found
    return shutil.which(name)


def launcher_command() -> str:
    """Command that starts this app (installed wrapper, else the checkout)."""
    installed = Path.home() / ".local/bin/droidmirror"
    if installed.exists():
        return str(installed)
    package = Path(__file__).resolve().parent.parent
    return f"env PYTHONPATH={package} python3 -m droidmirror_linux"


def load_settings() -> dict:
    settings = dict(DEFAULTS)
    try:
        settings.update(json.loads((config_dir() / "settings.json").read_text()))
    except (OSError, ValueError):
        pass
    return settings


def save_settings(settings: dict) -> None:
    directory = config_dir()
    directory.mkdir(parents=True, exist_ok=True)
    temporary = directory / "settings.json.tmp"
    temporary.write_text(json.dumps(settings, indent=2, sort_keys=True))
    temporary.replace(directory / "settings.json")


def prune_logs(directory: Path, keep: int = 30) -> None:
    logs = sorted(directory.glob("DroidMirror-Bluetooth-*.log"), key=lambda p: p.stat().st_mtime, reverse=True)
    for old in logs[keep:]:
        try:
            old.unlink()
        except OSError:
            pass


# -- helper commands -------------------------------------------------------------


class HelperError(Exception):
    pass


def _helper(args: list[str], stdin: bytes | None = None, timeout: float = 10) -> str:
    helper = helper_path()
    if not helper:
        raise HelperError("The DroidMirror Bluetooth helper is missing. Run Linux/build-linux.sh.")
    try:
        result = subprocess.run([helper, *args], input=stdin, capture_output=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as error:
        raise HelperError(str(error)) from error
    if result.returncode != 0:
        raise HelperError(result.stderr.decode(errors="replace").strip() or "Bluetooth helper failed")
    return result.stdout.decode(errors="replace")


def pairing_key(address: str) -> bytes | None:
    """The phone's private pairing code (owner-only file written by the helper)."""
    import base64
    path = config_dir() / "phones" / (address.upper().replace(":", "_") + ".key")
    try:
        key = base64.b64decode(path.read_text().strip())
    except (OSError, ValueError):
        return None
    return key if len(key) == 32 else None


def bluetooth_devices() -> list[dict]:
    """BlueZ-paired devices, each with `droidmirror: bool` (a saved pairing code)."""
    return json.loads(_helper(["--list"]) or "[]")


def pair(address: str, code: str) -> None:
    _helper(["--pair", address], stdin=code.strip().encode())


def forget(address: str) -> None:
    _helper(["--forget", address])
