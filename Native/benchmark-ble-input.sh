#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_build=$(mktemp -d /private/tmp/droidmirror-ble-input-benchmark.XXXXXX)
trap 'rm -rf "$task_build"' EXIT
clang -O2 -fobjc-arc -fblocks -framework Foundation \
  Native/BleInputQueue.m Native/BleInputCrypto.c Native/BleInputBenchmark.m \
  -o "$task_build/benchmark"
"$task_build/benchmark"
