#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
adb="${ADB:-$sdk/platform-tools/adb}"
d8="$sdk/build-tools/36.0.0/d8"
work=$(mktemp -d /private/tmp/droidmirror-blackout-text.XXXXXX)
remote="/data/local/tmp/droidmirror-blackout-text-$$.dex"
cleanup() { "$adb" shell rm -f "$remote" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/classes" "$work/dex"
javac --release 8 -cp "$sdk/platforms/android-36/android.jar" -d "$work/classes" \
    BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/BlackoutText.java \
    BluetoothCompanion/tests/BlackoutTextDeviceTest.java
"$d8" --lib "$sdk/platforms/android-36/android.jar" --output "$work/dex" \
    "$work/classes/app/droidmirror/bluetooth/BlackoutText.class" \
    "$work/classes/app/droidmirror/bluetooth/BlackoutTextDeviceTest.class"
"$adb" push "$work/dex/classes.dex" "$remote" >/dev/null
# No app installation, overlay, wake, capture or mirroring session is involved.
"$adb" shell "CLASSPATH=$remote app_process /system/bin app.droidmirror.bluetooth.BlackoutTextDeviceTest"
