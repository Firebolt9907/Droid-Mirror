#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
camera_test_dir=$(mktemp -d /private/tmp/droidmirror-camera-tests.XXXXXX)
trap 'rm -rf "$camera_test_dir"' EXIT HUP INT TERM
xcrun swiftc -module-cache-path /private/tmp/droidmirror-camera-cache Native/CameraFrameAssembler.swift Native/CameraFrameAssemblerTests.swift -o "$camera_test_dir/tests"
javac -d "$camera_test_dir" BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/CameraFrameWindow.java BluetoothCompanion/tests/CameraFrameWindowTest.java
java -cp "$camera_test_dir" CameraFrameWindowTest
javac -d "$camera_test_dir" BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/CameraVideoPacket.java BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/CameraVideoProfile.java BluetoothCompanion/tests/CameraVideoPacketTest.java
java -cp "$camera_test_dir" CameraVideoPacketTest "$camera_test_dir/packet.bin"
xcrun swiftc -module-cache-path /private/tmp/droidmirror-camera-cache Native/CameraVideoPacket.swift Native/CameraVideoPacketTests.swift -o "$camera_test_dir/packet-tests"
"$camera_test_dir/packet-tests" "$camera_test_dir/packet.bin"

"$camera_test_dir/tests"
xcrun swiftc -typecheck -target arm64-apple-macosx14.0 -module-cache-path /private/tmp/droidmirror-camera-cache Native/CameraIPC.swift Native/CameraExtension/main.swift

if [ "${1:-}" = "--integration" ]; then
    python3 - <<'PYTHON'
import re
import subprocess
from pathlib import Path
build = Path("build-app.sh").read_text()
paths = re.search(r"BLE_SOURCES=\((.*?)\)\nxcrun", build, re.S).group(1).split()
subprocess.run(["xcrun", "swiftc", "-typecheck", "-target", "arm64-apple-macosx14.0",
                "-module-cache-path", "/private/tmp/droidmirror-camera-cache", *paths], check=True)
print(f"Full BLE module typecheck passed ({len(paths)} source files)")
PYTHON
fi
