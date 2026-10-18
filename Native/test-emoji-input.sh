#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-emoji.XXXXXX)
trap 'rm -rf "$work"' EXIT
clang -Wall -Wextra -Werror Native/EmojiTextTests.c -o "$work/emoji-text"
"$work/emoji-text"
clang -fobjc-arc -fblocks -framework Cocoa Native/MirrorMenu.m Native/MirrorMenuTests.m -o "$work/emoji-menu"
"$work/emoji-menu"
