#!/bin/sh
# JVM test for the Android companion's multi-computer trust store.
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
javac -d "$work" $(find BluetoothCompanion/tests/stubs/android/content BluetoothCompanion/tests/stubs/android/bluetooth -name '*.java') \
  BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/ComputerPeers.java BluetoothCompanion/tests/ComputerPeersTest.java
java -cp "$work" ComputerPeersTest
