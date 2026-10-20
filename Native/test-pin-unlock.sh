#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-pin-unlock.XXXXXX)
trap 'rm -rf "$work"' EXIT
javac -d "$work" \
    scrcpy-5.0/server/src/main/java/com/genymobile/scrcpy/control/PinUnlock.java \
    BluetoothCompanion/tests/PinUnlockTest.java
java -cp "$work" app.droidmirror.bluetooth.PinUnlockTest
javac -d "$work" scrcpy-5.0/server/src/main/java/com/genymobile/scrcpy/video/VideoStartGate.java BluetoothCompanion/tests/VideoStartGateTest.java
java -cp "$work" VideoStartGateTest
android_jar="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platforms/android-36/android.jar"
javac -cp "$android_jar:$work" -d "$work" \
    BluetoothCompanion/tests/stubs/android/content/Context.java \
    BluetoothCompanion/tests/stubs/android/content/SharedPreferences.java \
    BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/UnlockPinCooldown.java \
    BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/SavedUnlockPin.java \
    BluetoothCompanion/tests/SavedUnlockPinPausedTest.java
java -cp "$work:$android_jar" app.droidmirror.bluetooth.SavedUnlockPinPausedTest
javac -d "$work" BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/UnlockPinCooldown.java BluetoothCompanion/tests/UnlockPinCooldownTest.java
java -cp "$work" app.droidmirror.bluetooth.UnlockPinCooldownTest
clang -fsanitize=address,undefined Native/StartupRevealTests.c -o "$work/reveal"
"$work/reveal"
