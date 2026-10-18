#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-link-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache -framework AppKit \
  Native/BLESession.swift Native/BrowserURL.swift Native/LinkSharing.swift Native/LinkSharingTests.swift -o "$work/link-tests"
"$work/link-tests"
javac -d "$work" BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/TaskUrlResolver.java \
  BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/SharedLink.java BluetoothCompanion/tests/SharedLinkTest.java
java -cp "$work" SharedLinkTest
