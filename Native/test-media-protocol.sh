#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-media-protocol.XXXXXX)
trap 'rm -rf "$work"' EXIT
# Compile the companion's debug Kotlin classes first.
task_cache=${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2/files-2.1
stdlib=$(find "$task_cache/org.jetbrains.kotlin/kotlin-stdlib/2.3.20" -name '*.jar' -print -quit)
json=$(find "$task_cache/org.json/json" -name '*.jar' -print -quit)
classpath="BluetoothCompanion/build/tmp/kotlin-classes/debug:$stdlib:$json"
javac -cp "$classpath" -d "$work" BluetoothCompanion/tests/MediaSyncProtocolTest.java
java -cp "$work:$classpath" MediaSyncProtocolTest
