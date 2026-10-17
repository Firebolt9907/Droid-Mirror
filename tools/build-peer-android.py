#!/usr/bin/env python3
"""Build the session-owned Iroh JNI library with the installed Android NDK."""
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
sdk = Path(os.environ.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk")))
ndk_root = sdk / "ndk"
versions = sorted(ndk_root.glob("*"), key=lambda p: tuple(int(v) for v in p.name.split(".")))
if not versions:
    sys.exit("Install Android NDK 28+ through sdkmanager before building the Iroh transport")
ndk = Path(os.environ.get("ANDROID_NDK_HOME", str(versions[-1])))
host = "darwin-x86_64" if platform.system() == "Darwin" else "linux-x86_64"
toolchain = ndk / "toolchains/llvm/prebuilt" / host / "bin"
targets = {
    "arm64-v8a": ("aarch64-linux-android", "aarch64-linux-android"),
    "armeabi-v7a": ("armv7-linux-androideabi", "armv7a-linux-androideabi"),
    "x86_64": ("x86_64-linux-android", "x86_64-linux-android"),
}
output = Path(sys.argv[1] if len(sys.argv) > 1 else root / "BluetoothCompanion/build/iroh-jni")
abis = os.environ.get("DROIDMIRROR_ANDROID_ABIS", "arm64-v8a").split(",")
for abi in abis:
    if abi not in targets:
        sys.exit(f"Unsupported Iroh ABI: {abi}")
    target, clang_target = targets[abi]
    env = os.environ.copy()
    env[f"CARGO_TARGET_{target.upper().replace('-', '_')}_LINKER"] = str(toolchain / f"{clang_target}26-clang")
    env[f"CC_{target.replace('-', '_')}"] = str(toolchain / f"{clang_target}26-clang")
    env[f"AR_{target.replace('-', '_')}"] = str(toolchain / "llvm-ar")
    # Keep build artifacts in the repo's ignored target directory for reproducible reuse.
    subprocess.run(["cargo", "build", "--locked", "--release", "--manifest-path",
                    str(root / "PeerTransport/Cargo.toml"), "--target", target], env=env, check=True)
    destination = output / abi
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / f"PeerTransport/target/{target}/release/libdroidmirror_peer.so", destination)
