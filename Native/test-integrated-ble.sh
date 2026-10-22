#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
task_build=$(mktemp -d /private/tmp/droidmirror-ble-tests.XXXXXX)
trap 'rm -rf "$task_build"' EXIT
# Run assembleDebug first: exercise the actual APK's Kotlin classes.
classes="$root/BluetoothCompanion/build/tmp/kotlin-classes/debug"
task_java=${JAVA_HOME:-/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home}
task_cache=${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2/files-2.1
stdlib=$(find "$task_cache/org.jetbrains.kotlin/kotlin-stdlib/2.3.20" -name '*.jar' -print -quit)
json=$(find "$task_cache/org.json/json" -name '*.jar' -print -quit)
classpath="$task_build:$classes:$stdlib:$json"
"$task_java/bin/javac" -cp "$classpath" -d "$task_build" \
  "$root/Native/tests/android/os/SystemClock.java" \
  "$root/Native/tests/android/util/Base64.java" \
  "$root/BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/PairingKeys.java" \
  "$root/Native/tests/BLESecurityPeer.java"
"$task_java/bin/javac" -cp "$classpath" -d "$task_build" "$root/BluetoothCompanion/tests/ConversationPayloadTest.java"
"$task_java/bin/java" -cp "$classpath" ConversationPayloadTest
"$task_java/bin/javac" -cp "$classpath" -d "$task_build" "$root/BluetoothCompanion/tests/BleOutboundQueueTest.java"
"$task_java/bin/java" -cp "$classpath" BleOutboundQueueTest
"$task_java/bin/javac" -d "$task_build" \
  "$root/BluetoothCompanion/tests/stubs/android/content/Context.java" \
  "$root/BluetoothCompanion/tests/stubs/android/content/SharedPreferences.java" \
  "$root/BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/BackgroundBridgePreferences.java" \
  "$root/Native/tests/android/util/Base64.java" \
  "$root/BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/PairingKeys.java" \
  "$root/BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/BlePairing.java" \
  "$root/BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/QRKeyTransfer.java" \
  "$root/BluetoothCompanion/tests/BackgroundBridgePreferencesTest.java" \
  "$root/BluetoothCompanion/tests/SharedPairingTest.java"
"$task_java/bin/java" -cp "$task_build" BackgroundBridgePreferencesTest
"$task_java/bin/java" -cp "$task_build" SharedPairingTest
clang -I"$root/Native" "$root/Native/BleInputCrypto.c" "$root/Native/BleInputCryptoTests.c" -o "$task_build/input-crypto-tests"
"$task_build/input-crypto-tests"
xcrun swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache \
  "$root/Native/BLESession.swift" "$root/Native/BLESecurity.swift" "$root/Native/BLESecurityTests.swift" \
  -o "$task_build/security-tests"
"$task_build/security-tests" "$task_java/bin/java" "$classpath"
