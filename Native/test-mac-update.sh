#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-mac-update.XXXXXX)
trap 'rm -rf "$work"' EXIT
zsh -n build-app.sh
clang -fobjc-arc -fblocks -framework AppKit Native/UpdateMacAppsTests.m -o "$work/lifecycle"
"$work/lifecycle"
PYTHONDONTWRITEBYTECODE=1 python3 Native/test-bundle-publish.py
javac -d "$work/java" BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/AudioVolumeLease.java BluetoothCompanion/tests/AudioVolumeLeaseTest.java
java -cp "$work/java" app.droidmirror.bluetooth.AudioVolumeLeaseTest
