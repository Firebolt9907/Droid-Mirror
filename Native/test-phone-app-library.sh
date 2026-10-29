#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-library-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache -framework AppKit \
  Native/LibraryIrohChannel.swift Native/ShortcutReveal.swift Native/PhoneAppLibrary.swift Native/PhoneAppLibraryTests.swift -o "$work/library-tests"
"$work/library-tests"
clang -fobjc-arc -fblocks -mmacosx-version-min=14.0 -framework AppKit Native/PhoneAppLauncher.m -o "$work/launcher"
