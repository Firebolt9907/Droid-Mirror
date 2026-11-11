#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-touch-id.XXXXXX)
trap 'rm -rf "$work"' EXIT
javac -d "$work" BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/BleInputCrypto.java BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/UnlockSessionAuthorization.java BluetoothCompanion/tests/UnlockSessionAuthorizationTest.java
java -cp "$work" app.droidmirror.bluetooth.UnlockSessionAuthorizationTest
xcrun swiftc -typecheck -module-cache-path "$work/modules" Sources/DroidMirror/PhoneUnlockAuthentication.swift
clang -fsyntax-only -fobjc-arc -fblocks -mmacosx-version-min=14.0 Native/BleInputTransport.m
clang -fobjc-arc -fblocks -Wno-deprecated-declarations -framework Foundation -framework AVFoundation -framework IOBluetooth -framework CoreBluetooth -framework Security Native/ClassicBluetoothStartupTests.m Native/BleInputQueue.m Native/BleInputCrypto.c Native/ClassicBluetoothWire.c -o "$work/startup"
"$work/startup" --unlock-only
