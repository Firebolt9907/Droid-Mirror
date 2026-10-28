#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
work=$(mktemp -d /tmp/droidmirror-scroll.XXXXXX)
trap 'rm -rf "$work"' EXIT
clang -fsanitize=address,undefined Native/WheelDeltaTests.c -o "$work/deltas"
"$work/deltas"
javac -d "$work" scrcpy-5.0/server/src/main/java/com/genymobile/scrcpy/control/WheelScroll.java \
  BluetoothCompanion/tests/WheelScrollTest.java
java -cp "$work" WheelScrollTest
clang -fobjc-arc -fblocks -I/opt/homebrew/include -L/opt/homebrew/lib -lSDL3 \
  -framework Cocoa -framework QuartzCore Native/BluetoothWindowStyleTests.m -o "$work/window"
"$work/window"
