#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-display.XXXXXX)
trap 'rm -rf "$work"' EXIT
android_jar="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platforms/android-36/android.jar"
src=BluetoothCompanion/src/main/java/app/droidmirror/bluetooth
javac -cp "$android_jar" -d "$work" \
    "$src/DisplayLease.java" "$src/RemoteSession.java" "$src/PhysicalDisplayPower.java" \
    BluetoothCompanion/tests/DisplayLeaseTest.java \
    BluetoothCompanion/tests/RemoteSessionTest.java \
    BluetoothCompanion/tests/PhysicalDisplayPowerTest.java
java -cp "$work:$android_jar" DisplayLeaseTest
java -cp "$work:$android_jar" RemoteSessionTest
java -cp "$work:$android_jar" app.droidmirror.bluetooth.PhysicalDisplayPowerTest
