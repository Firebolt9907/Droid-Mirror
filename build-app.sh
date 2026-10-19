#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/outputs/DroidMirror.app"

# Finish mirror-session cleanup before replacing either app's components.
/usr/bin/osascript <<'APPLESCRIPT'
if application id "app.droidmirror.mac" is running then
    tell application id "app.droidmirror.mac" to quit
    repeat 120 times
        if application id "app.droidmirror.mac" is not running then return
        delay 0.25
    end repeat
    error "DroidMirror did not quit; stop mirroring before rebuilding."
end if
APPLESCRIPT

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
# Build the customized client: upstream/Homebrew scrcpy lacks the ADB-free mode.
if [[ ! -f "$ROOT/scrcpy-5.0/build/build.ninja" ]]; then
  meson setup "$ROOT/scrcpy-5.0/build" "$ROOT/scrcpy-5.0" --buildtype=release -Dcompile_server=false -Dportable=true -Dvideotoolbox=true
fi
meson compile -C "$ROOT/scrcpy-5.0/build"
cp "$ROOT/scrcpy-5.0/build/app/scrcpy" "$APP/Contents/Helpers/scrcpy"
chmod +x "$APP/Contents/MacOS/DroidMirror"
codesign --force --deep --sign - "$APP" >/dev/null

# Update a connected phone in place, then resume its saved background bridge.
# Set ANDROID_SERIAL to select a phone, or skip for a Mac-only build.
if [[ "${DROIDMIRROR_SKIP_ANDROID_INSTALL:-0}" != 1 ]]; then
  export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  ADB="$ANDROID_HOME/platform-tools/adb"
  if [[ ! -x "$ADB" ]]; then ADB="$(command -v adb || true)"; fi
  if [[ -z "$ADB" ]]; then
    echo "Skipping Android install: adb unavailable; set ANDROID_HOME to your SDK."
  else
    DEVICES=()
    DEVICE_LIST="$("$ADB" devices)"
    while read -r SERIAL DEVICE_STATE REST; do
      if [[ "$DEVICE_STATE" == device ]]; then DEVICES+=("$SERIAL"); fi
    done <<< "$DEVICE_LIST"
    SERIAL="${ANDROID_SERIAL:-}"
    if [[ -n "$SERIAL" && ${DEVICES[(Ie)$SERIAL]} == 0 ]]; then
      echo "Android device $SERIAL is unavailable or unauthorized." >&2
      exit 1
    fi
    if [[ -z "$SERIAL" && ${#DEVICES} -gt 1 ]]; then
      echo "Multiple Android devices connected; set ANDROID_SERIAL." >&2
      exit 1
    fi
    if [[ -z "$SERIAL" && ${#DEVICES} == 1 ]]; then SERIAL="$DEVICES[1]"; fi
    if [[ -z "$SERIAL" ]]; then
      echo "Skipping Android install: no authorized phone connected."
    else
      export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}"
      (cd "$ROOT/BluetoothCompanion" && ./gradlew --no-daemon assembleDebug)
      "$ADB" -s "$SERIAL" install -r "$ROOT/BluetoothCompanion/build/outputs/apk/debug/BluetoothCompanion-debug.apk"
      START_RESULT="$("$ADB" -s "$SERIAL" shell am start -W \
        -a app.droidmirror.bluetooth.action.START_READY \
        -n app.droidmirror.bluetooth/.SilentStartActivity -f 0x10000000 2>&1)"
      echo "$START_RESULT"
      if [[ "$START_RESULT" == *"Error:"* || "$START_RESULT" == *"Status: timeout"* ]]; then
        echo "Android bridge startup failed." >&2
        exit 1
      fi
      "$ADB" -s "$SERIAL" shell am broadcast \
        -a app.droidmirror.bluetooth.action.START_READY \
        -n app.droidmirror.bluetooth/.AutomationReceiver -f 0x20
      echo "Bridge startup requested. If NOT_CONFIGURED or PERMISSION_REQUIRED appears, complete setup in the Android app."
    fi
  fi
fi
echo "$APP"
