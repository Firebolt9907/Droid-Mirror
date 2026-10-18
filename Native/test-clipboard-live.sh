#!/bin/bash
# Uses synthetic text on both real clipboards and restores them; keep the phone unlocked.
set -euo pipefail
cd "$(dirname "$0")/.."
serial=${1:?Pass the intended ADB device serial}
sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
task_java=${JAVA_HOME:-/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home}
if ! "$sdk/platform-tools/adb" -s "$serial" shell dumpsys trust | rg 'id=0.*deviceLocked=0' >/dev/null; then
  echo 'Unlock the phone before this clipboard test' >&2; exit 1
fi
work=$(mktemp -d /private/tmp/droidmirror-clipboard-live.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/classes" "$work/dex"
"$task_java/bin/javac" -source 8 -target 8 \
  -cp "$sdk/platforms/android-36/android.jar:BluetoothCompanion/build/intermediates/javac/debug/compileDebugJavaWithJavac/classes" \
  -d "$work/classes" Native/ClipboardDeviceProbe.java
"$sdk/build-tools/36.0.0/d8" --lib "$sdk/platforms/android-36/android.jar" \
  --output "$work/dex" "$work/classes/ClipboardDeviceProbe.class"
(cd "$work/dex" && zip -q "$work/probe.jar" classes.dex)
"$sdk/platform-tools/adb" -s "$serial" push "$work/probe.jar" /data/local/tmp/droidmirror-clipboard-probe.jar
apk=$("$sdk/platform-tools/adb" -s "$serial" shell pm path app.droidmirror.bluetooth | tr -d '\r' | sed -n 's/^package://p' | head -1)
[[ -n "$apk" ]] || { echo 'Companion APK not found' >&2; exit 1; }
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache -parse-as-library \
  Native/ClipboardLiveTests.swift -o "$work/live-test"
"$work/live-test" "$serial" "$apk" "$sdk/platform-tools/adb"
"$sdk/platform-tools/adb" -s "$serial" shell rm -f /data/local/tmp/droidmirror-clipboard-probe.jar
