#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /tmp/droidmirror-handoff-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
src=BluetoothCompanion/src/main/java/app/droidmirror/bluetooth
javac -d "$work" "$src/PeerAddress.java" BluetoothCompanion/tests/PeerAddressTest.java
java -cp "$work" app.droidmirror.bluetooth.PeerAddressTest
javac -d "$work" "$src/BluetoothWire.java" "$src/VideoWindow.java" "$src/BluetoothVideoBudget.java" "$src/WriteDeadline.java" "$src/WirelessUpgradeAuth.java" "$src/WirelessVideoProfile.java" "$src/HevcCapturePolicy.java" "$src/VideoWire.java" scrcpy-5.0/server/src/main/java/com/genymobile/scrcpy/model/ExactAspectRatio.java BluetoothCompanion/tests/WirelessFallbackTest.java BluetoothCompanion/tests/ExactAspectRatioTest.java BluetoothCompanion/tests/BluetoothWireTest.java BluetoothCompanion/tests/WirelessUpgradeTest.java BluetoothCompanion/tests/VideoWindowTest.java BluetoothCompanion/tests/BluetoothVideoBudgetTest.java BluetoothCompanion/tests/BitrateRecoveryTest.java scrcpy-5.0/server/src/main/java/com/genymobile/scrcpy/video/BitrateRecovery.java BluetoothCompanion/tests/VideoWireTest.java
java -cp "$work" ExactAspectRatioTest
java -cp "$work" VideoWireTest
javac -cp "$work" -d "$work" "$src/SessionEndDelivery.java" BluetoothCompanion/tests/SessionEndDeliveryTest.java
java -cp "$work" app.droidmirror.bluetooth.SessionEndDeliveryTest
java -cp "$work" VideoWindowTest
java -cp "$work" BluetoothVideoBudgetTest
java -cp "$work" BitrateRecoveryTest
javac -cp "$work" -d "$work" scrcpy-5.0/server/src/main/java/com/genymobile/scrcpy/video/FrameFreshness.java BluetoothCompanion/tests/FrameFreshnessTest.java
java -cp "$work" FrameFreshnessTest
java -cp "$work" BluetoothWireTest
java -cp "$work" WirelessUpgradeTest "$work"
java -cp "$work" WirelessFallbackTest "$work"
javac -cp "$work" -d "$work" BluetoothCompanion/tests/stubs/android/system/*.java BluetoothCompanion/tests/stubs/android/net/*.java "$src/WirelessVideoUpgrade.java" BluetoothCompanion/tests/WirelessVideoUpgradeTest.java
java -cp "$work" app.droidmirror.bluetooth.WirelessVideoUpgradeTest
# Exercise the recovery state MAC across the actual Java and C implementations.
clang Native/BleInputCrypto.c Native/BleInputCryptoTests.c -o "$work/input-crypto"
"$work/input-crypto" "$work/input.bin"
javac -d "$work" "$src/BleInputCrypto.java" BluetoothCompanion/tests/BleInputCryptoTest.java
java -cp "$work" app.droidmirror.bluetooth.BleInputCryptoTest "$work/input.bin" "$work/return.bin"
"$work/input-crypto" unused "$work/return.bin"
clang -fsanitize=address,undefined -g Native/ClassicBluetoothWire.c Native/WirelessUpgradeTests.c -o "$work/handoff"
"$work/handoff" "$work/classic.bin" "$work/wifi.bin" "$work/expected.bin"
clang -fsanitize=address,undefined -g Native/ClassicBluetoothWire.c Native/WirelessFallbackTests.c -o "$work/fallback"
"$work/fallback" "$work/fallback-initial.bin" "$work/fallback-wifi.bin" "$work/fallback-resumed.bin" "$work/fallback-expected.bin"
clang -fobjc-arc -framework Foundation Native/BleInputQueue.m Native/BleInputQueueTests.m -o "$work/ble-queue"
"$work/ble-queue"
clang -fobjc-arc -fblocks -Wno-deprecated-declarations -framework Foundation -framework IOBluetooth -framework CoreBluetooth -framework Security Native/ClassicBluetoothStartupTests.m Native/BleInputQueue.m Native/BleInputCrypto.c Native/ClassicBluetoothWire.c -o "$work/bridge-tests"
"$work/bridge-tests" </dev/null
