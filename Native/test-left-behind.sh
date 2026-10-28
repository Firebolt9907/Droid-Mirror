#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-left-behind.XXXXXX)
trap 'rm -rf "$work"' EXIT
javac -d "$work" BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/LeftBehindState.java BluetoothCompanion/tests/LeftBehindStateTest.java BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/LeftBehindExperiments.java BluetoothCompanion/tests/LeftBehindExperimentsTest.java BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/PresenceProtocol.java BluetoothCompanion/tests/PresenceProtocolTest.java BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/LeftBehindFeedbackEvent.java BluetoothCompanion/tests/LeftBehindFeedbackEventTest.java
java -cp "$work" LeftBehindStateTest
java -cp "$work" LeftBehindExperimentsTest
java -cp "$work" PresenceProtocolTest
java -cp "$work" LeftBehindFeedbackEventTest
xcrun swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache Native/ActivityClock.swift Native/BLESecurity.swift Native/PresenceRadioServer.swift Native/PresenceRadioTests.swift -o "$work/presence-radio-tests"
"$work/presence-radio-tests"
