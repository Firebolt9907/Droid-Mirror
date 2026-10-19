#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
test_binary=$(mktemp /tmp/droidmirror-camera-tests.XXXXXX)
trap 'rm -f "$test_binary"' EXIT
clang -I"${DROIDMIRROR_CLIENT_BUILD:-$root/scrcpy-5.0/build}/app" \
  -Iscrcpy-5.0/app/src -I/opt/homebrew/include -L/opt/homebrew/lib -lSDL3 \
  Native/CameraCutoutTests.c scrcpy-5.0/app/src/camera_cutout.c \
  scrcpy-5.0/app/src/device_msg.c scrcpy-5.0/app/src/control_msg.c \
  scrcpy-5.0/app/src/util/str.c scrcpy-5.0/app/src/util/strbuf.c -o "$test_binary"
"$test_binary"
