#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-notification-apps.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache \
  Sources/DroidMirror/NotificationAppPreferences.swift Native/NotificationAppPreferencesTests.swift \
  -o "$work/preferences"
"$work/preferences"
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache \
  Native/NotificationRuntime.swift Native/NotificationDeliveryTests.swift -o "$work/delivery"
"$work/delivery"
