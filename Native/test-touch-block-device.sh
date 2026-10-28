#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
adb="${ADB:-$sdk/platform-tools/adb}"
work=$(mktemp -d /private/tmp/droidmirror-touch-block.XXXXXX)
remote="/data/local/tmp/droidmirror-touch-block-$$.dex"
cleanup() { "$adb" shell rm -f "$remote" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/classes" "$work/dex"
javac --release 8 -cp "$sdk/platforms/android-36/android.jar" -d "$work/classes" \
    BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/TouchDevicePaths.java \
    BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/TouchBlocker.java \
    BluetoothCompanion/tests/TouchBlockRecoveryDeviceTest.java
"$sdk/build-tools/36.0.0/d8" --min-api 31 --lib "$sdk/platforms/android-36/android.jar" --output "$work/dex" \
    "$work/classes/app/droidmirror/bluetooth/TouchDevicePaths.class" \
    "$work/classes/app/droidmirror/bluetooth/TouchBlocker.class" \
    "$work/classes/app/droidmirror/bluetooth/TouchBlockRecoveryDeviceTest.class"
"$adb" push "$work/dex/classes.dex" "$remote" >/dev/null
"$adb" shell "CLASSPATH=$remote app_process /system/bin app.droidmirror.bluetooth.TouchBlockRecoveryDeviceTest"
