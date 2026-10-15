#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/outputs/DroidMirror.app"

cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="/tmp/droidmirror-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="/tmp/droidmirror-swift-cache"
swift build --disable-sandbox --scratch-path /tmp/droidmirror-app-build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/Helpers"
BIN_DIR="$(swift build --disable-sandbox --scratch-path /tmp/droidmirror-app-build --show-bin-path)"
cp "$BIN_DIR/DroidMirror" "$APP/Contents/MacOS/DroidMirror"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/clang -dynamiclib -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
  -I/opt/homebrew/include -L/opt/homebrew/lib -lSDL3 \
  -framework Cocoa -framework QuartzCore \
  "$ROOT/Native/ScrcpyWindowStyle.m" \
  -o "$APP/Contents/Frameworks/libDroidMirrorStyle.dylib"
/usr/bin/clang -mmacosx-version-min=14.0 -c "$ROOT/Native/ClassicBluetoothWire.c" -o /tmp/droidmirror-classic-wire.o
/usr/bin/clang -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
  -framework Foundation -framework IOBluetooth \
  "$ROOT/Native/ClassicBluetoothBridge.m" /tmp/droidmirror-classic-wire.o -o "$APP/Contents/Helpers/DroidMirrorBluetooth"
# Runtime-loaded Wi-Fi Aware SPI stays isolated from the main app's deployment target.
/usr/bin/clang -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
  -framework Foundation "$ROOT/Native/WiFiAwareBridge.m" -o "$APP/Contents/Helpers/DroidMirrorWiFiAware"
# Build the customized client: upstream/Homebrew scrcpy lacks the ADB-free mode.
if [[ ! -f "$ROOT/scrcpy-5.0/build/build.ninja" ]]; then
  meson setup "$ROOT/scrcpy-5.0/build" "$ROOT/scrcpy-5.0" --buildtype=release -Dcompile_server=false -Dportable=true -Dvideotoolbox=true
fi
meson compile -C "$ROOT/scrcpy-5.0/build"
cp "$ROOT/scrcpy-5.0/build/app/scrcpy" "$APP/Contents/Helpers/scrcpy"
cp "$ROOT/scrcpy-5.0/app/data/scrcpy.png" "$APP/Contents/Helpers/scrcpy.png"
cp "$ROOT/scrcpy-5.0/app/data/disconnected.png" "$APP/Contents/Helpers/disconnected.png"
chmod +x "$APP/Contents/MacOS/DroidMirror"
codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
