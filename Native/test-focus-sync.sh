#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-focus-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache Native/FocusSyncPolicy.swift Native/FocusSyncTests.swift -o "$work/focus-tests"
"$work/focus-tests"
