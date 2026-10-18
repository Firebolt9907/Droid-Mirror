#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
CONFIGURATION="${DROIDMIRROR_BUILD_CONFIGURATION:-debug}"
case "$CONFIGURATION" in
  debug) SWIFT_FLAGS=(); C_FLAGS=() ;;
  release) SWIFT_FLAGS=(-O); C_FLAGS=(-O2) ;;
  *) echo "DROIDMIRROR_BUILD_CONFIGURATION must be debug or release" >&2; exit 2 ;;
esac
FINAL_APP="$ROOT/outputs/DroidMirror.app"
mkdir -p "$ROOT/outputs"
BUILD_STAGE="$(mktemp -d "$ROOT/outputs/.droidmirror-build.XXXXXX")"
trap 'rm -rf "$BUILD_STAGE"' EXIT
APP="$BUILD_STAGE/DroidMirror.app"
# Never compile or sign over code the kernel may already have mapped.
if [[ -d "$FINAL_APP" ]]; then /usr/bin/ditto "$FINAL_APP" "$APP"; fi

cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="/tmp/droidmirror-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="/tmp/droidmirror-swift-cache"
swift build -c "$CONFIGURATION" --disable-sandbox --scratch-path /tmp/droidmirror-app-build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/Helpers"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp "$ROOT/Resources/app.droidmirror.background.plist" "$APP/Contents/Library/LaunchAgents/"
cargo build --locked --release --manifest-path "$ROOT/PeerTransport/Cargo.toml"
cp "$ROOT/PeerTransport/target/release/libdroidmirror_peer.dylib" "$APP/Contents/Frameworks/libdroidmirror_peer.dylib"
# The host and background receiver share the same pairing implementation.
BLE_SOURCES=(Sources/DroidMirror/NotificationAppPreferences.swift Native/BrowserURL.swift Native/LinkSharing.swift Native/MediaSyncState.swift Native/AppleMusicSync.swift Native/MediaPlaybackSync.swift Native/PhoneHotspot.swift Native/TaskContinuation.swift Native/ClipboardSync.swift Native/NotificationRuntime.swift Native/NotificationPresentationPolicy.swift Native/NotificationDismissal.swift Native/NotificationActions.swift Native/NotificationConversationState.swift
  Native/NotificationIconAttachment.swift Native/NotificationCommunicationContent.swift Native/BLESession.swift Native/BLEController.swift Native/BLEIntegration.swift
  Native/BLEMenu.swift Native/DiscoveryNotifications.swift Native/BLESecurity.swift
  Native/AndroidNotificationBridge.swift)
xcrun swiftc "${SWIFT_FLAGS[@]}" -module-cache-path /private/tmp/droidmirror-swift-module-cache \
  -emit-library -module-name DroidMirrorBLE -target arm64-apple-macosx14.0 \
  -framework AppKit -framework CoreBluetooth -framework UserNotifications -framework Security \
  "${BLE_SOURCES[@]}" -o "$APP/Contents/Frameworks/libDroidMirrorBLE.dylib"
BIN_DIR="$(swift build -c "$CONFIGURATION" --disable-sandbox --scratch-path /tmp/droidmirror-app-build --show-bin-path)"
cp "$BIN_DIR/DroidMirror" "$APP/Contents/MacOS/DroidMirrorHost"
# Preserve the launcher that loads the notification/session lifecycle hooks.
/usr/bin/clang "${C_FLAGS[@]}" -mmacosx-version-min=14.0 Native/DroidMirrorLauncher.c -o "$APP/Contents/MacOS/DroidMirror"
/usr/bin/clang "${C_FLAGS[@]}" -dynamiclib -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
  -framework Foundation -framework AppKit Native/DroidMirrorHostShim.m \
  -o "$APP/Contents/Frameworks/libDroidMirrorHostShim.dylib"
RECEIVER="$APP/Contents/Helpers/DroidMirror Notifications.app/Contents"
mkdir -p "$RECEIVER/MacOS" "$RECEIVER/Resources"
cp "$ROOT/Resources/NotificationsInfo.plist" "$RECEIVER/Info.plist"
xcrun swiftc "${SWIFT_FLAGS[@]}" -module-cache-path /private/tmp/droidmirror-swift-module-cache \
  -target arm64-apple-macosx14.0 -framework AppKit -framework CoreBluetooth \
  -framework UserNotifications -framework Security "${BLE_SOURCES[@]}" \
  Native/NotificationReceiver.swift -o "$RECEIVER/MacOS/DroidMirrorNotifications"
# A native Share extension receives web links from Safari and other apps.
SHARE="$APP/Contents/PlugIns/DroidMirrorShare.appex/Contents"
mkdir -p "$SHARE/MacOS"
cp "$ROOT/Resources/ShareExtensionInfo.plist" "$SHARE/Info.plist"
xcrun swiftc "${SWIFT_FLAGS[@]}" -module-cache-path /private/tmp/droidmirror-swift-module-cache \
  -parse-as-library -Xlinker -e -Xlinker _NSExtensionMain -module-name DroidMirrorShare -target arm64-apple-macosx14.0 \
  -framework AppKit -framework UniformTypeIdentifiers Native/BrowserURL.swift \
  Native/ShareExtension/ShareViewController.swift -o "$SHARE/MacOS/DroidMirrorShare"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/clang "${C_FLAGS[@]}" -dynamiclib -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
  -I/opt/homebrew/include -L/opt/homebrew/lib -lSDL3 \
  -framework CoreImage -framework Cocoa -framework QuartzCore \
  "$ROOT/Native/ScrcpyWindowStyle.m" \
  -o "$APP/Contents/Frameworks/libDroidMirrorStyleOriginal.dylib"
# Keep the device corners, resize handling, secure overlay and keyboard layer
# around the shared toolbar controller for every transport.
/usr/bin/clang "${C_FLAGS[@]}" -dynamiclib -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
  -framework CoreImage -framework Cocoa -framework QuartzCore \
  -I/opt/homebrew/include -L/opt/homebrew/lib -lSDL3 \
  "$ROOT/Native/ConnectingPhone.m" "$ROOT/Native/KeyboardPassthroughShim.m" "$ROOT/Native/DeviceCorners.m" \
  "$ROOT/Native/CornerResize.m" "$ROOT/Native/ScrollDirection.m" "$ROOT/Native/MirrorMenu.m" \
  -o "$APP/Contents/Frameworks/libDroidMirrorStyle.dylib"
/usr/bin/clang "${C_FLAGS[@]}" -mmacosx-version-min=14.0 -c "$ROOT/Native/ClassicBluetoothWire.c" -o /tmp/droidmirror-classic-wire.o
/usr/bin/clang "${C_FLAGS[@]}" -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
  -framework Foundation -framework IOBluetooth -framework CoreBluetooth -framework Security \
  "$ROOT/Native/ClassicBluetoothBridge.m" "$ROOT/Native/BleInputTransport.m" "$ROOT/Native/BleInputQueue.m" "$ROOT/Native/BleInputCrypto.c" /tmp/droidmirror-classic-wire.o -o "$APP/Contents/Helpers/DroidMirrorBluetooth"
# Runtime-loaded Wi-Fi Aware SPI stays isolated from the main app's deployment target.
/usr/bin/clang "${C_FLAGS[@]}" -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
  -framework Foundation -framework Security "$ROOT/Native/WiFiAwareBridge.m" -o "$APP/Contents/Helpers/DroidMirrorWiFiAware"
# Remove the retired experiment from existing app bundles before signing.
rm -f "$APP/Contents/Helpers/DroidMirrorWiFiAwareCatalyst"
# Build the shared Android controller too: gesture-pill shortcuts run on the phone
# for both ADB and the Bluetooth companion (which compiles these same sources).
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
SERVER_BUILD_DIR="$(mktemp -d /tmp/droidmirror-server.XXXXXX)"
BUILD_DIR="$SERVER_BUILD_DIR" bash "$ROOT/scrcpy-5.0/server/build_without_gradle.sh"
cp "$SERVER_BUILD_DIR/scrcpy-server" "$APP/Contents/Helpers/scrcpy-server"
rm -rf "$SERVER_BUILD_DIR"
# Build the customized client: upstream/Homebrew scrcpy lacks the ADB-free mode.
CLIENT_SOURCE="$ROOT/scrcpy-5.0"
CLIENT_BUILD="$CLIENT_SOURCE/build"
if [[ -f "$CLIENT_BUILD/meson-info/meson-info.json" ]]; then
  CONFIGURED_SOURCE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["directories"]["source"])' "$CLIENT_BUILD/meson-info/meson-info.json")"
  if [[ "${CONFIGURED_SOURCE:A}" != "${CLIENT_SOURCE:A}" ]]; then
    # A copied build cache otherwise silently compiles another checkout.
    meson setup --wipe "$CLIENT_BUILD" "$CLIENT_SOURCE" --buildtype=release -Dcompile_server=false -Dportable=true -Dvideotoolbox=true
  fi
fi
if [[ ! -f "$CLIENT_BUILD/build.ninja" ]]; then
  meson setup "$ROOT/scrcpy-5.0/build" "$ROOT/scrcpy-5.0" --buildtype=release -Dcompile_server=false -Dportable=true -Dvideotoolbox=true
fi
if [[ "$CONFIGURATION" == release ]]; then
  meson configure "$CLIENT_BUILD" --buildtype=release
fi
meson compile -C "$ROOT/scrcpy-5.0/build"
RENDERER="$APP/Contents/Helpers/DroidMirror Renderer.app/Contents"
mkdir -p "$RENDERER/MacOS" "$RENDERER/Resources"
cp "$ROOT/scrcpy-5.0/build/app/scrcpy" "$RENDERER/MacOS/DroidMirrorRenderer"
cp "$ROOT/Resources/RendererInfo.plist" "$RENDERER/Info.plist"
# The video engine is a private app helper, with DroidMirror identity and no Dock tile.
rm -f "$APP/Contents/Helpers/scrcpy"
cp "$ROOT/scrcpy-5.0/app/data/scrcpy.png" "$RENDERER/Resources/scrcpy.png"
cp "$ROOT/scrcpy-5.0/app/data/disconnected.png" "$RENDERER/Resources/disconnected.png"
chmod +x "$APP/Contents/MacOS/DroidMirror"
sh "$ROOT/Native/sign-droidmirror.sh" "$APP"
python3 "$ROOT/tools/app-bundle.py" check "$APP"
python3 "$ROOT/tools/app-bundle.py" publish "$APP" "$FINAL_APP"
echo "$FINAL_APP"
