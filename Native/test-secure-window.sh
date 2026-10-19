#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
test_dir=$(mktemp -d /tmp/droidmirror-secure-window.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
server=scrcpy-5.0/server/src/main/java/com/genymobile/scrcpy
javac -d "$test_dir" "$server/control/SecureWindowState.java" "$server/control/DeviceMessage.java" \
  "$server/control/DeviceMessageWriter.java" "$server/control/ControlProtocolException.java" \
  "$server/util/StringUtils.java" "$server/control/SecureWindowMonitor.java" \
  Native/SecureWindowStateTests.java Native/SecureWindowMonitorTests.java
java -cp "$test_dir" SecureWindowStateTests "$@"
java -cp "$test_dir" com.genymobile.scrcpy.control.SecureWindowMonitorTests
clang -I"${DROIDMIRROR_CLIENT_BUILD:-$root/scrcpy-5.0/build}/app" \
  -Iscrcpy-5.0/app/src -I/opt/homebrew/include -L/opt/homebrew/lib -lSDL3 \
  Native/SecureWindowWireTests.c scrcpy-5.0/app/src/device_msg.c scrcpy-5.0/app/src/control_msg.c \
  scrcpy-5.0/app/src/util/str.c scrcpy-5.0/app/src/util/strbuf.c -o "$test_dir/wire"
"$test_dir/wire"

clang -I/opt/homebrew/include Native/SecureBlackFrameTests.c -o "$test_dir/black-frame"
"$test_dir/black-frame"
clang -fobjc-arc -framework Foundation Native/BleInputQueue.m Native/BleInputQueueTests.m -o "$test_dir/ble-queue"
"$test_dir/ble-queue"

clang -O2 -Wl,-dead_strip -I"${DROIDMIRROR_CLIENT_BUILD:-$root/scrcpy-5.0/build}/app" \
  -Iscrcpy-5.0/app/src -I/opt/homebrew/include -L/opt/homebrew/lib \
  -lSDL3 -lavutil -lavcodec -lavformat -framework CoreVideo \
  Native/HardwareBlackFrameTests.c -o "$test_dir/hardware-black-frame"
"$test_dir/hardware-black-frame"
