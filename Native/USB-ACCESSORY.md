# Automatic USB video without ADB

Automatic mode starts the existing authenticated Bluetooth session and checks for
an Android Open Accessory (AOA) USB bulk interface. It prefers that interface for
video over LAN / wireless ADB. Plugging USB in during wireless mirroring first
performs the bounded Bluetooth recovery, then authenticates the USB candidate.
The authenticated receiver confirmation identifies network (1) versus USB (2).
The phone Live Update shows USB, Wi-Fi or BT in its compact chip and names the
video transport in its notification body. The indicator changes after confirmation
and returns to Bluetooth on fallback; merely plugging in USB does not label a
Wi-Fi session as USB.

Unplugging USB uses the same live recovery: discard queued video, restore the
Bluetooth encoder and resume at its new session/configuration/keyframe.

USB carries the existing video and negotiated audio envelope. Input and cumulative
video acknowledgements remain on the authenticated BLE side channel. Shizuku and
Bluetooth are still required for capture/control; USB debugging and ADB are not.
The initial Android accessory chooser must be approved (and can remember the app).
A charge-only cable or a phone without AOA support cannot carry this stream.

The Mac probes known Android USB vendor IDs and only negotiates with a single
attached Android candidate. Multiple phones are left alone to avoid switching
an arbitrary phone's USB mode. AOA can replace the phone's current USB mode, so
file transfer / tethering may be interrupted when accessory mode starts.
Only the accessory bulk interface is claimed; its adjacent ADB interface is not.
AOA identifiers never authenticate a phone: the existing pairing key, fresh nonce,
profile proof and cumulative handoff cutoff must verify before accepting video.
No kernel driver is detached to seize a device already owned by another process.

The Mac bridge buffers one complete codec packet so a truncated packet can be
discarded without corrupting the renderer stream. A Classic-only reset envelope
(type 8, eight-byte cumulative cutoff) retires Wi-Fi/USB backlog; sequence checking
and delayed ACK validation continue across the gap. Initial startup retains the
legacy exact replay until the first complete frame, preserving device headers.
Update both Mac and Android together for the reset envelope.

Session flag bit 1 (byte 3, value 2) is a local renderer extension indicating USB.
The video regulator bypasses its configured jitter delay during those sessions,
then restores normal buffering for the next non-USB session. This removes added
playback delay; USB transfer, capture, encoding, decoding and presentation are
not instantaneous. No end-to-end latency measurement is implied.

Builds bundle libusb with the Mac helper. `bash Native/test-usb-accessory.sh` uses
mock USB devices (never changes attached hardware) to test AOA setup, ambiguity,
unsupported devices, ADB-interface isolation and partial bulk writes. Run
`bash Native/test-wireless-upgrade.sh` for authenticated handoff, live backlog
retirement, fragmented reset records and decoder continuity. Real-device testing
still needs an approved AOA-capable phone with USB debugging disabled, hot-plug,
cable removal during motion, and comparison of USB versus Wi-Fi latency.

Protocol references:
- https://source.android.com/docs/core/interaction/accessories/aoa
- https://developer.android.com/develop/connectivity/usb/accessory
