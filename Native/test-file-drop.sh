#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-drop-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
clang -fobjc-arc -fblocks -framework Cocoa -framework QuartzCore Native/FileDropDestinationTests.m -o "$work/drop-tests"
"$work/drop-tests"
