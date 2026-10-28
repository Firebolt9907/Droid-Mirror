#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_build=$(mktemp -d /private/tmp/droidmirror-qr-tests.XXXXXX)
trap 'rm -rf "$task_build"' EXIT
task_java=${JAVA_HOME:-/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home}
"$task_java/bin/javac" -d "$task_build" \
    BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/QRKeyTransfer.java \
    BluetoothCompanion/tests/QRKeyTransferTest.java
"$task_java/bin/java" -cp "$task_build" app.droidmirror.bluetooth.QRKeyTransferTest "$task_build/vector"
swiftc -module-cache-path "$task_build/swift-cache" \
    Sources/DroidMirror/QRPairingProtocol.swift Native/QRPairingTests.swift -o "$task_build/qr-tests"
"$task_build/qr-tests" "$task_build/vector"
