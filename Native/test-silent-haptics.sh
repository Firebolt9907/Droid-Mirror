#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_build=$(mktemp -d /private/tmp/droidmirror-haptics-tests.XXXXXX)
trap 'rm -rf "$task_build"' EXIT
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
javac -cp "$sdk/platforms/android-36/android.jar" -d "$task_build" \
  BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/HapticTraceParser.java \
  BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/HapticVibrationLease.java \
  BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/SilentHaptics.java \
  BluetoothCompanion/tests/HapticTraceParserTest.java \
  BluetoothCompanion/tests/HapticVibrationLeaseTest.java \
  BluetoothCompanion/tests/HapticRestoreWatchdogTest.java
java -cp "$task_build" app.droidmirror.bluetooth.HapticTraceParserTest
java -cp "$task_build" app.droidmirror.bluetooth.HapticVibrationLeaseTest
java -cp "$task_build" app.droidmirror.bluetooth.HapticRestoreWatchdogTest
