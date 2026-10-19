#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_build=${1:-/tmp/droidmirror-sharpen-build}
task_objects="$task_build/app/scrcpy.p"
clang -fobjc-arc -fblocks -I"$task_build/app" \
  -I"$task_root/scrcpy-5.0/app/src" $(pkg-config --cflags sdl3 libavutil) \
  "$task_root/Native/VideoFilterTests.m" \
  "$task_objects/src_texture.c.o" "$task_objects/src_video_filter.m.o" \
  "$task_objects/src_interop_interop.c.o" \
  "$task_objects/src_interop_interop_software.c.o" \
  "$task_objects/src_interop_interop_videotoolbox.c.o" \
  "$task_objects/src_opengl.c.o" "$task_objects/src_util_log.c.o" \
  $(pkg-config --libs sdl3 libavutil) \
  -framework Cocoa -framework QuartzCore -framework CoreVideo \
  -framework Metal -framework MetalFX \
  -o /tmp/droidmirror-video-filter-tests
/tmp/droidmirror-video-filter-tests
