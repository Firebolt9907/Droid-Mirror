#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-renderer-lifecycle.XXXXXX)
trap 'rm -rf "$work"' EXIT
app="$work/DroidMirrorLifecycleTests.app"
ditto outputs/DroidMirror.app "$app"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib,sys
path=sys.argv[1]
info=plistlib.load(open(path,'rb'))
info['CFBundleExecutable']='RendererLifecycleTests'
info['CFBundleIdentifier']='app.droidmirror.renderer-lifecycle-tests'
info['CFBundleName']='Renderer Lifecycle Tests'
plistlib.dump(info,open(path,'wb'))
PY
sources=()
for source in Sources/DroidMirror/*.swift; do
    [[ "$source" == */DroidMirrorApp.swift ]] || sources+=("$source")
done
swiftc -swift-version 6 -module-cache-path /private/tmp/droidmirror-swift-module-cache \
    "${sources[@]}" Native/RendererLifecycleTests.swift -o "$app/Contents/MacOS/RendererLifecycleTests"
ffmpeg -v error -f lavfi -i color=c=blue:s=360x800:r=1 -frames:v 1 -c:v libx264 -preset ultrafast -tune zerolatency -f h264 "$work/frame.h264"
python3 Native/renderer-stream-fixture.py "$work/frame.h264" "$work/port" &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true; rm -rf "$work"' EXIT
for attempt in {1..100}; do
    [[ -f "$work/port" ]] && break
    sleep 0.02
done
"$app/Contents/MacOS/RendererLifecycleTests" "$(cat "$work/port")"
wait "$fixture_pid"
