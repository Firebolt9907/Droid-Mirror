#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-clipboard-activity.XXXXXX)
trap 'rm -rf "$work"' EXIT
cache="${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2/files-2.1"
stdlib=$(find "$cache/org.jetbrains.kotlin/kotlin-stdlib/2.3.20" -name '*.jar' -print -quit)
json=$(find "$cache/org.json/json" -name '*.jar' -print -quit)
task_java=${JAVA_HOME:-/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home}
classpath="$work:BluetoothCompanion/build/tmp/kotlin-classes/debug:$stdlib:$json"
"$task_java/bin/javac" -cp "$classpath" -d "$work" BluetoothCompanion/tests/ClipboardSyncProgressTest.java
"$task_java/bin/java" -cp "$classpath" ClipboardSyncProgressTest
