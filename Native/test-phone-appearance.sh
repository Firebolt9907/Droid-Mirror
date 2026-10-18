#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-appearance.XXXXXX)
trap 'rm -rf "$work"' EXIT
clang -fsanitize=address,undefined Native/ClassicBluetoothWire.c Native/ClassicBluetoothWireTests.c -o "$work/wire"
"$work/wire"
clang -fobjc-arc -fblocks -framework AppKit -framework QuartzCore \
    Native/DeviceCorners.m Native/DeviceCornersTests.m -o "$work/corners"
"$work/corners"
swiftc -swift-version 6 -module-cache-path "$work/swift-cache" \
    Sources/DroidMirror/Models.swift Sources/DroidMirror/PhoneAppearanceCache.swift \
    Native/PhoneAppearanceTests.swift -o "$work/fallback"
"$work/fallback"
bash Native/test-connecting-phone.sh
