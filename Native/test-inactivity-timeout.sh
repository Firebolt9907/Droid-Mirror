#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_binary=$(mktemp /private/tmp/droidmirror-inactivity.XXXXXX)
trap 'rm -f "$test_binary"' EXIT
clang -fobjc-arc -fblocks -I/opt/homebrew/include -L/opt/homebrew/lib -lSDL3 \
  -framework Cocoa -framework QuartzCore Native/InactivityTimeoutTests.m -o "$test_binary"
DROIDMIRROR_HOST_PID="inactivity-test-$$" "$test_binary"
