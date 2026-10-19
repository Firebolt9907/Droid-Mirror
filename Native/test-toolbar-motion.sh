#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-toolbar-motion.XXXXXX)
trap 'rm -rf "$work"' EXIT
for test in ToolbarMotion CameraCutoutWindow CameraCutoutCache BluetoothWindowStyle PhoneShadow; do
    clang -fobjc-arc -fblocks -I/opt/homebrew/include -L/opt/homebrew/lib \
        -lSDL3 -framework Cocoa -framework QuartzCore \
        "Native/${test}Tests.m" -o "$work/$test"
    "$work/$test"
done
