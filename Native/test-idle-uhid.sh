#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-idle-uhid.XXXXXX)
trap 'rm -rf "$work"' EXIT
src=scrcpy-5.0/server/src/main/java/com/genymobile/scrcpy
javac -d "$work" \
    BluetoothCompanion/tests/stubs/android/system/*.java \
    BluetoothCompanion/tests/stubs/android/net/*.java \
    BluetoothCompanion/tests/stubs/android/util/Log.java \
    "$src/util/Ln.java" "$src/control/IdleUhidKeyboard.java" \
    BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/DisplayLease.java \
    BluetoothCompanion/tests/IdleUhidKeyboardTest.java
java -cp "$work" IdleUhidKeyboardTest
