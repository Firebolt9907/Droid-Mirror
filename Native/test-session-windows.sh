#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-session-windows.XXXXXX)
trap 'rm -rf "$work"' EXIT
app="$work/SessionWindowTests.app/Contents"
mkdir -p "$app/MacOS"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.droidmirror.session-window-tests</string>
<key>CFBundleExecutable</key><string>SessionWindowTests</string>
</dict></plist>
PLIST
sources=()
for source in Sources/DroidMirror/*.swift; do
    [[ "$source" == */DroidMirrorApp.swift ]] || sources+=("$source")
done
swiftc -swift-version 6 -module-cache-path "$work/swift-cache" \
    "${sources[@]}" Native/SessionWindowTests.swift -o "$app/MacOS/SessionWindowTests"
"$app/MacOS/SessionWindowTests"
