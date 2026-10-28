#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /tmp/droidmirror-usb-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
usb_prefix=$(pkg-config --variable=prefix libusb-1.0)
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
  -I"$usb_prefix/include" -L"$usb_prefix/lib" -lusb-1.0 Native/UsbAccessoryTransportTests.c -o "$work/usb"
"$work/usb"
