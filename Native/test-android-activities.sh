#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-activities.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache \
  Native/ActivityClock.swift Native/AndroidActivityRenderer.swift Native/AndroidActivityMenu.swift Native/AndroidActivityMenuTests.swift -o "$work/activities"
result=$("$work/activities")
printf '%s\n' "$result"
if [[ "$result" != *"Android activity menu and timer synchronization tests passed"* ]]; then
  echo "Menu tests did not complete; run with access to the macOS window server." >&2
  exit 1
fi
task_java=${JAVA_HOME:-/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home}
task_sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
"$task_java/bin/javac" -cp "$task_sdk/platforms/android-36/android.jar" -d "$work" \
  BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/bridge/NotificationForwardingPolicy.java \
  BluetoothCompanion/tests/NotificationForwardingPolicyTest.java
"$task_java/bin/java" -cp "$work:$task_sdk/platforms/android-36/android.jar" NotificationForwardingPolicyTest

"$task_java/bin/javac" -d "$work" \
  BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/bridge/NotificationClock.java \
  BluetoothCompanion/tests/NotificationClockTest.java
"$task_java/bin/java" -cp "$work" NotificationClockTest

"$task_java/bin/javac" -d "$work" \
  BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/bridge/EmbeddedTimer.java \
  BluetoothCompanion/tests/EmbeddedTimerTest.java
"$task_java/bin/java" -cp "$work" EmbeddedTimerTest
