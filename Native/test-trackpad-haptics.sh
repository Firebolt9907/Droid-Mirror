#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_build=$(mktemp -d /private/tmp/droidmirror-trackpad-tests.XXXXXX)
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache \
  -framework AppKit -framework IOKit Native/TrackpadHaptics.swift Native/TrackpadHapticsTests.swift \
  -o "$task_build/haptics-tests"
"$task_build/haptics-tests" "$@"
