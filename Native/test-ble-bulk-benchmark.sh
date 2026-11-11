#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-ble-benchmark-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache Native/ClipboardBulkChannel.swift Native/ClipboardIrohChannel.swift Native/BLEBulkTest.swift Native/BLEBulkTestTests.swift -o "$work/benchmark-tests"
"$work/benchmark-tests"
