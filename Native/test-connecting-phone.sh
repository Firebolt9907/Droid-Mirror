#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-connecting-phone.XXXXXX)
trap 'rm -rf "$work"' EXIT
# These SDL utilities need no generated scrcpy configuration.
touch "$work/config.h"
clang -I"$work" -Iscrcpy-5.0/app/src -I/opt/homebrew/include \
  -c scrcpy-5.0/app/src/util/sdl.c -o "$work/sdl.o"
clang -fobjc-arc -fblocks -I/opt/homebrew/include -L/opt/homebrew/lib -lSDL3 \
  -INative -I"$work" -Iscrcpy-5.0/app/src \
  -framework CoreImage -framework AppKit -framework QuartzCore Native/ConnectingPhone.m Native/DeviceCorners.m \
  Native/ConnectingPhoneTests.m "$work/sdl.o" -o "$work/connecting-phone"
"$work/connecting-phone"
