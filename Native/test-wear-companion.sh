#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-wear-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache -framework AppKit -framework IOKit \
  Native/WearCompanionState.swift Native/WearCompanion.swift Native/WearCompanionTests.swift -o "$work/mac-tests"
"$work/mac-tests"
task_java=${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}
"$task_java/bin/javac" -d "$work" BluetoothCompanion/wear-shared/app/droidmirror/wearprotocol/*.java \
  BluetoothCompanion/tests/WearCommandPolicyTest.java
"$task_java/bin/java" -cp "$work" WearCommandPolicyTest

"$task_java/bin/javac" -d "$work" $(find BluetoothCompanion/tests/wear-stubs -name '*.java') \
  BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/WearSessionAccess.java
"$task_java/bin/java" -cp "$work" app.droidmirror.bluetooth.WearSessionAccessTest
