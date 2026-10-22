#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-media-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache -framework AppKit -framework MediaPlayer \
  Native/MediaSyncState.swift Native/AppleMusicQueue.swift Native/MusicCatalogArtwork.swift Native/AppleMusicSync.swift Native/MediaPlaybackSync.swift Native/MediaSyncTests.swift -o "$work/media-tests"
"$work/media-tests"
clang -fobjc-arc -fblocks -framework Foundation Native/MusicQueueHelperTests.m -o "$work/queue-helper-tests"
"$work/queue-helper-tests"
clang -dynamiclib -fobjc-arc -fblocks -framework Foundation Native/MusicQueueHelper.m -o "$work/libDroidMirrorMusicQueue.dylib"
plutil -lint Resources/Info.plist Resources/NotificationsInfo.plist
