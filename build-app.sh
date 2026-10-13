#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/outputs/DroidMirror.app"

cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="/tmp/droidmirror-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="/tmp/droidmirror-swift-cache"
swift build --disable-sandbox --scratch-path /tmp/droidmirror-app-build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "/tmp/droidmirror-app-build/out/Products/Debug/DroidMirror" "$APP/Contents/MacOS/DroidMirror"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/clang -dynamiclib -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
  -I/opt/homebrew/include -L/opt/homebrew/lib -lSDL3 \
  -framework Cocoa -framework QuartzCore \
  "$ROOT/Native/ScrcpyWindowStyle.m" \
  -o "$APP/Contents/Frameworks/libDroidMirrorStyle.dylib"
chmod +x "$APP/Contents/MacOS/DroidMirror"
codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
