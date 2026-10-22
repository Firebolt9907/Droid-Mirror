#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-audio.XXXXXX)
trap 'rm -rf "$work"' EXIT
clang -fsanitize=address,undefined -g Native/ClassicBluetoothWire.c Native/WirelessAudioWireTests.c -o "$work/wire"
"$work/wire"
clang -fsanitize=address,undefined -g Native/WirelessAudioRingTests.c -o "$work/ring"
"$work/ring"
clang -fobjc-arc -fblocks -Wno-deprecated-declarations -framework Foundation -framework AVFoundation \
    Native/WirelessAudioPlaybackTests.m -o "$work/playback"
"$work/playback"
clang -fobjc-arc -fblocks -I/opt/homebrew/include -L/opt/homebrew/lib \
    -lSDL3 -framework Cocoa -framework QuartzCore Native/WirelessAudioButtonTests.m -o "$work/button"
button_output=$("$work/button")
printf '%s\n' "$button_output"
# AppKit can exit a standalone test process before returning from a UI call.
# Require its completion marker as well as a successful exit status.
[[ "$button_output" == *"timeout casting indicator, resume/stop, teardown and focus preservation passed"* ]]
