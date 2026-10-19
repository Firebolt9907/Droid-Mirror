#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_work=$(mktemp -d /private/tmp/droidmirror-hotspot-tests.XXXXXX)
trap 'rm -rf "$task_work"' EXIT
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache -framework AppKit -framework Network \
  Native/PhoneHotspot.swift Native/PhoneHotspotTests.swift -o "$task_work/hotspot-tests"
"$task_work/hotspot-tests" | tee "$task_work/result.log"
# AppKit may exit early without a window-server connection; require completed assertions.
rg -q "^Phone hotspot toggle, .* tests passed$" "$task_work/result.log"
