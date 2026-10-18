#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-injected-keys.XXXXXX)
trap 'rm -rf "$work"' EXIT
javac -d "$work" \
    scrcpy-5.0/server/src/main/java/com/genymobile/scrcpy/control/InjectedKeys.java \
    BluetoothCompanion/tests/InjectedKeysTest.java
java -cp "$work" InjectedKeysTest
