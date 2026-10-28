#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_build=$(mktemp -d /private/tmp/droidmirror-ble-benchmark.XXXXXX)
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -O -module-cache-path "$task_build/cache" \
  Native/BLESession.swift Native/ActivityClock.swift Native/BLESecurity.swift Native/BLETransportBenchmark.swift \
  -o "$task_build/benchmark"
"$task_build/benchmark"
