#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-mirror-requests.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -module-cache-path "$work/swift-cache" \
  Sources/DroidMirror/MirrorRequestHandler.swift Native/MirrorRequestTests.swift \
  -o "$work/mirror-request-tests"
"$work/mirror-request-tests"
