#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-task-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache -framework AppKit \
  Native/TaskContinuation.swift Native/TaskContinuationTests.swift -o "$work/task-tests"
"$work/task-tests"
javac -d "$work" BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/TaskUrlResolver.java \
  BluetoothCompanion/tests/TaskUrlResolverTest.java
java -cp "$work" TaskUrlResolverTest
