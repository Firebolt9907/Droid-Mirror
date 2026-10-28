#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
adb="${ADB:-$sdk/platform-tools/adb}"
classes=BluetoothCompanion/build/intermediates/javac/debug/compileDebugJavaWithJavac/classes
apk=BluetoothCompanion/build/outputs/apk/debug/DroidMirrorBluetooth-debug.apk
# Build :assembleDebug first, and end mirroring before running. The test briefly
# suppresses normal vibration and exercises independent crash restoration.
task_build=$(mktemp -d /private/tmp/droidmirror-haptics-device.XXXXXX)
remote="/data/local/tmp/droidmirror-haptics-test-$$"
cleanup() { "$adb" shell rm -f "$remote.apk" "$remote.dex" >/dev/null 2>&1 || true; rm -rf "$task_build"; }
trap cleanup EXIT
mkdir -p "$task_build/classes" "$task_build/dex"
javac --release 8 -cp "$sdk/platforms/android-36/android.jar:$classes" -d "$task_build/classes" BluetoothCompanion/tests/SilentHapticsDeviceTest.java
"$sdk/build-tools/36.0.0/d8" --lib "$sdk/platforms/android-36/android.jar" --classpath "$classes" --output "$task_build/dex" "$task_build/classes/app/droidmirror/bluetooth/SilentHapticsDeviceTest.class"
"$adb" push "$apk" "$remote.apk" >/dev/null
"$adb" push "$task_build/dex/classes.dex" "$remote.dex" >/dev/null
"$adb" shell "CLASSPATH=$remote.apk:$remote.dex app_process /system/bin app.droidmirror.bluetooth.SilentHapticsDeviceTest"
