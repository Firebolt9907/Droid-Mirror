#!/usr/bin/env bash
set -euo pipefail
task_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=${1:?Usage: bash Native/run-key-release-tests.sh /path/to/meson/build}
build_dir=$(cd -- "$build_dir" && pwd)
cd "$task_root"
meson compile -C "$build_dir"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
objects=()
for object in "$build_dir"/app/scrcpy.p/*.o; do
    case "${object##*/}" in src_main.c.o) continue;; esac
    objects+=("$object")
done
read -ra dependency_flags <<< "$(pkg-config --cflags --libs sdl3 libavformat libavcodec libavutil libswresample libavdevice libusb-1.0)"
cc -D_GNU_SOURCE -I"$build_dir/app" -Iscrcpy-5.0/app/src \
    Native/ControllerFlushTests.c "${objects[@]}" "${dependency_flags[@]}" \
    -o "$test_dir/ControllerFlushTests"
input_objects=()
for object in "${objects[@]}"; do
    case "${object##*/}" in src_input_manager.c.o|src_keyboard_sdk.c.o) continue;; esac
    input_objects+=("$object")
done
cc -D_GNU_SOURCE -ffunction-sections -fdata-sections \
    -I"$build_dir/app" -Iscrcpy-5.0/app/src Native/KeyReleaseTests.c \
    "${input_objects[@]}" "${dependency_flags[@]}" -Wl,--gc-sections \
    -o "$test_dir/KeyReleaseTests"
"$test_dir/KeyReleaseTests"
"$test_dir/ControllerFlushTests"
