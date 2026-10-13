# Bluetooth Classic video transport

DroidMirror defaults to Bluetooth Classic RFCOMM, independent of LAN and ADB.
This is EDR-capable Classic Bluetooth, not BLE. EDR modulation and radio throughput
are negotiated by the operating systems; the app cannot guarantee an EDR mode or
1 Mbps sustained throughput on every Mac/phone combination.

The new path is **video only**. Android's public MediaProjection API requires a
user-approved capture session and a foreground service. It does not grant scrcpy's
shell privileges for input injection, locking, screen-off capture, clipboard,
UHID, or audio. Choose **USB / wireless ADB** in Connection settings for the
existing full-featured mode. The existing BLE notification bridge is separate.

## Build and use

A compiled, debug-signed Android APK is included at
`outputs/DroidMirror-Bluetooth-0.1-debug.apk`, alongside its SHA-256 checksum.
Install it using the phone's package installer. This is a test build, not a store
release. Future APKs signed with a different debug key require uninstalling this
build before installation.

To rebuild the standalone companion, use JDK 17+ and Android SDK 35. The checked-in
Gradle wrapper pins and verifies Gradle 8.11.1:

```sh
cd BluetoothCompanion
./gradlew assembleDebug lintDebug
```

Install the APK produced in `build/outputs/apk/debug/` using the phone's package
installer. No USB or
wireless debugging is required. The companion has a new package identity and does
not replace BLE-ADB-Bridge or use its pairing secrets.

On macOS 14+, install the client build dependencies:

```sh
brew install meson ninja pkg-config sdl3 ffmpeg libusb
./build-app.sh
open outputs/DroidMirror.app
```

The build script compiles the customized scrcpy client and the IOBluetooth helper;
stock Homebrew scrcpy does not understand `--external-video-port`. The existing
bundled matching scrcpy 5 server is needed only for ADB mode. The new companion APK is included in `outputs/`; the checked-in Mac app binaries
remain unchanged until you rebuild on macOS. Signing uses the existing build
script's ad-hoc signature; use the documented development signing workflow if
maintaining the existing notification helper's Keychain identity.

1. Pair phone and Mac using their system Bluetooth settings.
2. Open **DroidMirror Bluetooth** on Android, grant Nearby Devices access, and
   select the paired Mac. Tap **Start Bluetooth capture** and approve capture.
   Android 14+ may let you choose one app or the entire screen.
3. Open DroidMirror on Mac, grant Bluetooth access, select the paired phone in
   Connection settings, and press **Mirror**. The list includes all bonded devices;
   choose the Android phone, not headphones or other peripherals.
4. Stop on either side. Start a fresh capture and approve it again to reconnect.
   Android's system capture indicator and the foreground notification can stop
   capture too. Protected content remains protected.

There is no automatic ADB fallback. The Bluetooth profile is fixed at a 480-pixel
short edge, aspect-preserving dimensions aligned down to 16 pixels, H.264 Baseline,
1,000,000 bit/s target and at most 30 fps. Portrait 1080×2400 becomes 480×1056;
landscape 1920×1080 becomes 848×480. Smaller displays are not upscaled.
Static screens request a repeat frame once per second. Rotation/content resizing
is fitted into the initial encoder surface; restart capture to change its shape.
Android encoder support and actual output frame rate require device validation.

## Transport and lifecycle

`CaptureService` advertises UUID `c356a44e-6f2b-4da9-85e5-397991b8a603` through a
secure RFCOMM server socket. It accepts only the phone-selected, system-bonded Mac.
It closes the listening socket after accepting a session. Capture consent expires
if no accepted Mac connects within 60 seconds. Video relies on system Bluetooth
bonding/encryption; it does not reuse the BLE bridge's application-layer protocol.

The Mac helper discovers the RFCOMM channel through SDP and forwards the video to
an ephemeral IPv4 loopback listener. Only one local client is accepted. The local
bridge is process-local plumbing over TCP; no LAN connection or ADB tunnel is
involved. As with other loopback IPC, another local process could race to connect;
this is not an authenticated local IPC boundary.

The stream uses the scrcpy 5 wire format: dummy byte, 64-byte device name, H.264
codec ID, session dimensions, then 12-byte frame headers and encoded payloads.
The client reads it through `--external-video-port`, skipping ADB initialization,
device selection, server push/launch, tunnels, and process cleanup. It retains the
normal decoder, rendering, recording options, and hardware-decoding fallback.
The Mac host removes injected ADB shims and shell environment from this launch.

The Android sender permits four bounded packets, rejects packets over 128 KiB,
refuses to send a packet queued for over 500 ms, and closes a blocked Bluetooth
write after one second. The Mac has a 128 KiB pending byte limit and a one-second
pending-data deadline. Slow links stop instead of dropping arbitrary H.264
reference frames or growing an unbounded queue. These are stall safeguards, not
a measured end-to-end latency guarantee. Disconnecting stops the projection and
requires new capture consent. The sender and Mac bridge do not save screen data.

## Validation status

The Android companion was compiled successfully in this workspace using JDK 17,
Android SDK 35, AGP 8.9.1 and Gradle 8.11.1. `assembleDebug lintDebug` passed with
zero lint errors (nine advisory warnings for localization, backup metadata, app
icon and newer AGP availability). The included APK passes `apksigner verify` using
APK Signature Scheme v2. The permission checks identified by lint were fixed;
revoking Bluetooth access causes capture to stop.

Also validated in the Linux workspace:

- Pure Java VideoWire tests: scrcpy 5 headers, timestamps/config/keyframe flags,
  packet boundaries and bounds, and portrait/landscape/no-upscale dimensions.
- Existing scrcpy CLI tests plus external mode cases: valid/invalid ports,
  audio/input suppression, and conflicting ADB options.
- C syntax check of `server.c`; XML/plist parse; clean whitespace diff.

The CLI tests and C syntax check used temporary dependency header/logging shims
because SDL/FFmpeg development headers were unavailable. They are not a full
client build. macOS Swift/Objective-C compilation and real radio throughput remain **unvalidated**.
The Android SDK and full JDK were downloaded with the executor's explicit network
permission. No physical phone or Mac is attached.

Before calling this production-ready, build on Mac and Android SDK hosts, then
verify TCC permissions, secure pairing/SDP, no running ADB dependency, start/stop
and capture revocation, device rotation, static screens, scrolling, frame rate,
throughput, and latency under interference. The checked-in Mac app still runs the previous implementation until rebuilt;
install the new companion APK for the Android side.

Run the portable Java tests:

```sh
javac -d /tmp/droidmirror-wire-tests BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/VideoWire.java BluetoothCompanion/tests/VideoWireTest.java
java -cp /tmp/droidmirror-wire-tests VideoWireTest
```

## Adaptive quality follow-on

Adaptive bitrate and higher-resolution still frames are feasible but are not
implemented in this baseline. Add framed reverse-channel feedback first: measured
receive throughput, queued bytes and delay, plus a session/sequence identifier.
Treat 1 Mbps as a video target, not as proof of available radio capacity. Apply
`MediaCodec.setParameters(PARAMETER_KEY_VIDEO_BITRATE)` with conservative headroom,
a fast decrease on growing queue delay, and a slow increase after sustained
stability. Check support on target encoders; frame rate and resolution may still
need changing when bitrate alone cannot maintain latency.

For readability, first test a fixed higher resolution with adaptive bitrate and
fewer frames while static. Motion prediction and unchanged blocks already help
H.264 encode scrolling/typing; portable text-field-specific region-of-interest
encoding is not available across Android encoders. A high-quality refresh/keyframe
after 300–500 ms of stillness may improve text without resizing. A keyframe itself
can create a bandwidth burst, so budget and pace it.

If two resolution tiers are needed, require sustained motion/stillness and a
minimum dwell time, preserve the viewport, and use scrcpy 5 session packets plus
fresh codec configuration/keyframes at each switch. Reconfigure the encoder and
resize the existing VirtualDisplay/change its surface rather than asking the
same MediaProjection token to create a second display on Android 14+. Avoid
immediate sharp/blurry transitions after every scroll; visual quality and switch
thresholds need testing with users and actual phones.
