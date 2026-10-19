#!/usr/bin/env python3
"""Publish signed Mac bundles by rename, never by overwriting executable files."""
import argparse
import ctypes
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def swap(source: Path, destination: Path):
    if source.is_symlink() or destination.is_symlink():
        raise ValueError("Refusing to replace a symlinked app bundle")
    if not source.is_dir():
        raise ValueError("Source app bundle is missing")
    if not destination.exists():
        source.rename(destination)
        return
    if not destination.is_dir():
        raise ValueError("Destination must be an app bundle directory")
    # macOS RENAME_SWAP atomically exchanges the directory entries on one volume.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000002):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def verify(app: Path):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def launch_check(app: Path):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if not info.get("DroidMirrorSupportsLaunchCheck"):
        raise ValueError("Rebuild DroidMirror first: this app lacks the safe launch check")
    environment = dict(os.environ)
    environment.pop("DYLD_INSERT_LIBRARIES", None)
    environment.pop("DROIDMIRROR_HOST_PID", None)
    result = subprocess.run([str(app / "Contents/MacOS/DroidMirror"), "--check-launch"],
                            env=environment, capture_output=True, text=True, timeout=15)
    if result.returncode or "DroidMirror launch check passed" not in result.stdout:
        raise RuntimeError(f"App launch check failed ({result.returncode}): {result.stderr.strip()}")
    print("Launcher, host shim and BLE library loaded successfully", flush=True)


def install(source: Path, destination: Path):
    # Stage beside the destination to guarantee an atomic, same-volume exchange.
    staging = Path(tempfile.mkdtemp(prefix=".droidmirror-install-", dir=destination.parent))
    candidate = staging / "DroidMirror.app"
    published = False
    had_previous = destination.exists()
    try:
        subprocess.run(["/usr/bin/ditto", str(source), str(candidate)], check=True)
        verify(candidate)
        launch_check(candidate)
        swap(candidate, destination)
        published = True
        try:
            verify(destination)
            launch_check(destination)
        except BaseException:
            # Put the original bundle back if verification at its final path fails.
            if had_previous:
                swap(candidate, destination)
            else:
                destination.rename(candidate)
            published = False
            raise
        print(f"Installed {destination}")
        if had_previous:
            print(f"Previous bundle preserved at {candidate}")
    finally:
        if not published or not had_previous:
            shutil.rmtree(staging)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["publish", "install", "check"])
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path, nargs="?")
    args = parser.parse_args()
    source = args.source.absolute()
    if args.mode == "check":
        verify(source)
        launch_check(source)
    else:
        if args.destination is None:
            parser.error("destination is required")
        destination = args.destination.absolute()
        if source == destination:
            parser.error("source and destination must differ")
        if args.mode == "install":
            install(source, destination)
        else:
            swap(source, destination)
