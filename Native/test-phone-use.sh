#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-phone-use.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path "$work/swift-cache" Sources/DroidMirror/PhoneUsePolicy.swift Native/PhoneUsePolicyTests.swift -o "$work/policy"
"$work/policy"
src=BluetoothCompanion/src/main/java/app/droidmirror/bluetooth
javac -d "$work/java" "$src/PhoneUsePolicy.java" "$src/BluetoothWire.java" "$src/VideoWindow.java" "$src/WriteDeadline.java" "$src/BluetoothVideoBudget.java" "$src/WirelessUpgradeAuth.java" BluetoothCompanion/tests/PhoneUsePolicyTest.java
java -cp "$work/java" app.droidmirror.bluetooth.PhoneUsePolicyTest
clang -fsanitize=address,undefined -g Native/ClassicBluetoothWire.c Native/ClassicBluetoothWireTests.c -o "$work/wire"
"$work/wire"
