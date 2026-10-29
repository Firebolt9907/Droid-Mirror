#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-synthetic-text.XXXXXX)
trap 'rm -rf "$work"' EXIT
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I/opt/homebrew/include \
    -L/opt/homebrew/lib -lSDL3 -framework Cocoa -framework Carbon \
    Native/SyntheticTextTests.m -o "$work/synthetic-text"
"$work/synthetic-text"
clang -O2 -Wl,-dead_strip -Wl,-undefined,dynamic_lookup -I"${DROIDMIRROR_CLIENT_BUILD:-scrcpy-5.0/build}/app" -Iscrcpy-5.0/app/src \
    -I/opt/homebrew/include -L/opt/homebrew/lib -lSDL3 -lavutil -lavcodec -lavformat \
    -framework CoreVideo Native/CommandControlInputTests.c \
    scrcpy-5.0/app/src/util/log.c scrcpy-5.0/app/src/util/tick.c \
    -o "$work/input"
"$work/input"
if [[ "${DROIDMIRROR_TEST_COCOA_QUEUE:-0}" == 1 ]]; then
    clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I/opt/homebrew/include \
        -L/opt/homebrew/lib -lSDL3 -framework Cocoa -framework Carbon \
        Native/SyntheticTextQueueTests.m -o "$work/cocoa-queue"
    "$work/cocoa-queue"
fi
