#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-notification-open.XXXXXX)
trap 'rm -rf "$work"' EXIT
task_java=${JAVA_HOME:-/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home}
"$task_java/bin/javac" -d "$work" \
    BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/bridge/NotificationOpenGate.java \
    BluetoothCompanion/tests/NotificationOpenGateTest.java
"$task_java/bin/java" -cp "$work" NotificationOpenGateTest
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache \
    Native/NotificationActions.swift Native/NotificationActionTests.swift -o "$work/actions"
"$work/actions"
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache \
    Native/NotificationRuntime.swift Native/NotificationDeliveryTests.swift -o "$work/delivery"
"$work/delivery"
