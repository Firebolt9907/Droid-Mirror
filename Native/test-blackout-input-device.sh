#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
adb="${ADB:-$sdk/platform-tools/adb}"
classes=BluetoothCompanion/build/intermediates/javac/debug/compileDebugJavaWithJavac/classes
apk="${BLACKOUT_TEST_APK:-BluetoothCompanion/build/outputs/apk/debug/DroidMirrorBluetooth-debug.apk}"
# Build :assembleDebug first. End mirroring, unlock the phone, and show an ordinary
# app before running. This briefly displays a blackout and injects one test tap.
if ! "$adb" shell dumpsys power | grep -q 'mWakefulness=Awake'; then
    echo 'Unlock the phone and show an ordinary app before testing overlay input.' >&2
    exit 1
fi
if "$adb" shell dumpsys window policy | grep -q 'showing=true'; then
    echo 'The keyguard is showing; unlock the phone before testing overlay input.' >&2
    exit 1
fi
work=$(mktemp -d /private/tmp/droidmirror-blackout-input.XXXXXX)
remote="/data/local/tmp/droidmirror-blackout-input-$$"
cleanup() { "$adb" shell rm -f "$remote.apk" "$remote.dex" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/classes" "$work/dex"
javac --release 8 -cp "$sdk/platforms/android-36/android.jar:$classes" -d "$work/classes" \
    BluetoothCompanion/tests/BlackoutInputDeviceTest.java
"$sdk/build-tools/36.0.0/d8" --lib "$sdk/platforms/android-36/android.jar" \
    --classpath "$classes" --output "$work/dex" \
    "$work/classes/app/droidmirror/bluetooth/BlackoutInputDeviceTest.class"
"$adb" push "$apk" "$remote.apk" >/dev/null
"$adb" push "$work/dex/classes.dex" "$remote.dex" >/dev/null
"$adb" shell "CLASSPATH=$remote.apk:$remote.dex app_process /system/bin app.droidmirror.bluetooth.BlackoutInputDeviceTest"
