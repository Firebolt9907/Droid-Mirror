#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-clipboard-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache -framework AppKit \
  Native/ClipboardSync.swift Native/ClipboardSyncTests.swift -o "$work/clipboard-tests"
"$work/clipboard-tests"
javac -d "$work" BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/Clipboard{TextPolicy,ChangeTracker}.java \
  BluetoothCompanion/tests/ClipboardSyncTest.java
java -cp "$work" app.droidmirror.bluetooth.ClipboardSyncTest
