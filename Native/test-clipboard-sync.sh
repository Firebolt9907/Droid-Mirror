#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-clipboard-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache -framework AppKit \
  Native/ClipboardFilePolicy.swift Native/ClipboardSync.swift Native/ClipboardBulkChannel.swift Native/ClipboardTransferRace.swift Native/ClipboardSyncTests.swift -o "$work/clipboard-tests"
"$work/clipboard-tests"
javac -d "$work" BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/Clipboard{TextPolicy,FilePolicy,ChangeTracker}.java \
  BluetoothCompanion/tests/ClipboardSyncTest.java
java -cp "$work" app.droidmirror.bluetooth.ClipboardSyncTest

# Exercise the production Android transfer state machine with a fake clipboard bridge.
task_json=$(find "${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2/files-2.1/org.json/json" -name '*.jar' -print -quit)
task_java=${JAVA_HOME:-/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home}
mkdir -p "$work/stubs"
cat > "$work/stubs/PackageInstallClient.java" <<'JAVA'
package app.droidmirror.bluetooth;
final class PackageInstallClient {
    static boolean enabled = true;
    static boolean available() { return enabled; }
    static String packageName(android.content.Context context, java.io.File file) { return "example.app"; }
    static String install(android.content.Context context, java.io.File file, long size, java.util.function.BooleanSupplier cancelled) { return "Success"; }
}
JAVA
"$task_java/bin/javac" -cp "$task_json" -d "$work/files" \
  Native/tests/clipboard/android/content/{Context,Intent}.java \
  Native/tests/clipboard/android/net/Uri.java \
  Native/tests/clipboard/app/droidmirror/bluetooth/{ClipboardFileProvider,IClipboardBridge,DownloadsFileWriter}.java \
  Native/tests/android/{os/SystemClock,util/Base64}.java \
  "$work/stubs/PackageInstallClient.java" \
  BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/ApkInstallPolicy.java \
  BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/ClipboardFile{Policy,Transfer}.java \
  BluetoothCompanion/tests/ClipboardFileTransferTest.java
"$task_java/bin/java" -cp "$work/files:$task_json" app.droidmirror.bluetooth.ClipboardFileTransferTest
