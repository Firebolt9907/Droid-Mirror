#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-media-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache -framework AppKit -framework MediaPlayer \
  Native/MediaSyncState.swift Native/AppleMusicSync.swift Native/MediaPlaybackSync.swift Native/MediaSyncTests.swift -o "$work/media-tests"
"$work/media-tests"
plutil -lint Resources/Info.plist Resources/NotificationsInfo.plist
