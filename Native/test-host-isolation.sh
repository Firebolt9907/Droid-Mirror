#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
task_build=$(mktemp -d /private/tmp/droidmirror-isolation.XXXXXX)
trap 'rm -rf "$task_build"' EXIT
app="$task_build/DroidMirror.app/Contents"
mkdir -p "$app/MacOS" "$app/Helpers" "$app/Frameworks"
cp "$root/Resources/Info.plist" "$app/Info.plist"
cat > "$task_build/BLEStub.c" <<'STUB'
void DroidMirrorStartBLE(void) {}
void DroidMirrorStopBLE(void) {}
void DroidMirrorRefreshBLEMenu(void) {}
STUB
clang -dynamiclib "$task_build/BLEStub.c" -o "$app/Frameworks/libDroidMirrorBLE.dylib"
clang -fobjc-arc -fblocks -dynamiclib -framework Foundation -framework AppKit \
  "$root/Native/DroidMirrorHostShim.m" -o "$app/Frameworks/libDroidMirrorHostShim.dylib"
clang -fobjc-arc -fblocks -framework Foundation -framework AppKit \
  "$root/Native/HostIsolationProbe.m" -o "$app/MacOS/DroidMirrorHost"
cp "$app/MacOS/DroidMirrorHost" "$app/Helpers/DroidMirrorBluetooth"
clang "$root/Native/DroidMirrorLauncher.c" -o "$app/MacOS/DroidMirror"
"$app/MacOS/DroidMirror" host
xcrun swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache \
  "$root/Sources/DroidMirror/Models.swift" "$root/Sources/DroidMirror/ProcessRunner.swift" \
  "$root/Native/ToolEnvironmentTests.swift" -o "$task_build/environment-tests"
"$task_build/environment-tests"
