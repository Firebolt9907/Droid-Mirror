#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
test_binary=$(mktemp /tmp/droidmirror-phone-gestures.XXXXXX)
trap 'rm -f "$test_binary"' EXIT
clang -fobjc-arc -fblocks -I/opt/homebrew/include -L/opt/homebrew/lib -lSDL3 \
  -framework Cocoa -framework QuartzCore Native/PhoneGestureTests.m -o "$test_binary"
"$test_binary"
