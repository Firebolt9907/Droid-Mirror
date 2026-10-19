#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_build=${1:-/private/tmp/droidmirror-rotation-build}
task_test=$(mktemp /private/tmp/droidmirror-rotation-test.XXXXXX)
trap 'rm -f "$task_test"' EXIT
# Use a release client build; AutomaticRotationTests matches its struct layout.
set --
for object in "$task_build"/app/scrcpy.p/*.o; do
    case "$object" in */src_main.c.o) ;; *) set -- "$@" "$object" ;; esac
done
clang -fobjc-arc -fblocks -I"$task_build/app" -I"$task_root/scrcpy-5.0/app/src" \
  $(pkg-config --cflags sdl3 libavformat libavcodec libavutil libswresample libusb-1.0) \
  "$task_root/Native/AutomaticRotationTests.m" "$task_root/Native/DeviceCorners.m" "$task_root/Native/RotationPresentation.m" "$@" \
  $(pkg-config --libs sdl3 libavformat libavcodec libavutil libswresample libusb-1.0) \
  -framework Cocoa -framework QuartzCore -framework CoreVideo -framework Metal -framework MetalFX \
  -o "$task_test"
"$task_test"
