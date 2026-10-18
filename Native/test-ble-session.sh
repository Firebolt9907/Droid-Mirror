#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-session-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
xcrun swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache \
  Native/BLESession.swift Native/BLESessionTests.swift -o "$work/session-tests"
"$work/session-tests"
# Check the actual controller and receiver together, rather than feature test doubles.
sources=$(sed -n '/^BLE_SOURCES=(/,/AndroidNotificationBridge.swift)/p' build-app.sh | sed 's/BLE_SOURCES=(//; s/)$//')
# Intentional word splitting of the source list (repository paths contain no spaces).
xcrun swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache \
  -target arm64-apple-macosx14.0 $sources Native/NotificationReceiver.swift -o "$work/receiver"
