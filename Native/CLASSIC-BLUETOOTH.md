# Bluetooth Classic video transport

DroidMirror defaults to Bluetooth Classic RFCOMM, independent of LAN and ADB.
This is EDR-capable Classic Bluetooth, not BLE. EDR modulation and radio throughput
are negotiated by the operating systems; the app cannot guarantee an EDR mode or
1 Mbps sustained throughput on every Mac/phone combination.

The new path is **video only**. Android's public MediaProjection API requires a
user-approved capture session and a foreground service. It does not grant scrcpy's
shell privileges for input injection, locking, clipboard, UHID, or audio.
Optional physical-panel control is available through a separately authorized
Shizuku user service, as described below. Choose **USB / wireless ADB** in
Connection settings for the existing full-featured mode. The existing BLE notification bridge is separate.

## Build and use

A compiled, debug-signed Android APK is included at
`outputs/DroidMirror-Bluetooth-0.2-debug.apk`, alongside its SHA-256 checksum.
It uses the same test signing key as 0.1 and can be installed over that version.
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
installer. No USB or wireless debugging is required for normal Bluetooth capture. The companion has a new package identity and does
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

## Optional screen-off with Shizuku

1. Install and start Shizuku 13 or newer on the phone. Its initial setup may
   require wireless debugging or root; Bluetooth streaming itself still uses
   neither ADB nor LAN.
2. In **DroidMirror Bluetooth**, tap **Authorize Shizuku** and approve the system
   permission dialog. Enabling Nearby Devices alone does not authorize Shizuku.
3. Check **Turn phone panel off with Shizuku recovery**, start capture and approve
   MediaProjection, then connect the Mac. The panel stays on until an encoded
   media frame has actually been transmitted.
4. Stop capture to restore the panel. **Restore phone display** explicitly asks
   the shell service to turn the panel back on and cancels any active screen-off
   lease. Screen-off is opt-in each new activity/session, not an unattended default.

`DisplayGuardService` is a Shizuku **daemon user service**, running in a separate
shell/root process. It is not the companion's Android foreground Service and it
continues after the app process dies. It resolves physical display tokens and
uses the same hidden SurfaceControl/DisplayControl power APIs as scrcpy. It never
uses a power-key sleep command, locks the phone, changes screen brightness, or
writes persistent system settings. API differences/OEM restrictions can make
screen-off unavailable; the companion reports failure and continues video with
the display on. Normal screen timeout/lock can still stop MediaProjection.

Before OFF, the guard registers an app-owned Binder death recipient and calls
NORMAL to check that the restoration API can be invoked. It records recovery
intent before OFF, including partial failures across multiple physical displays.
App process death triggers a direct restoration attempt from the shell process.
An independent shell timer checks a **two-second lease** every 100 ms; the app
renews every 250 ms only while encoded video continues to transmit and Shizuku
permission remains available. Late heartbeats cannot revive an expired lease.
Stop, capture revocation, Bluetooth failure, missing video progress, app hangs,
manual recovery and normal guard shutdown also attempt restoration. Failed NORMAL
calls are retried by the shell timer; new OFF leases are refused until recovery
succeeds. The app detaches without terminating the daemon guard.

This is prompt best-effort recovery, **not an absolute guarantee of immediate
restoration**. Binder callbacks, scheduling and display-driver calls take time.
The two-second timeout applies while the guard is running and scheduled; Android
suspension or a blocked display API can delay it. Shell UID/process separation
protects against ordinary app lifecycle kills, not SIGKILL of the guard, a driver
hang, reboot or every OEM behavior. Shutdown hooks cannot handle SIGKILL. If the
guard itself is forcibly killed while the panel is off, restart Shizuku/the app
and use Restore phone display; a physical wake/power cycle or reboot is the final
fallback. No setting that persists across reboot is changed. Do not rely on this
as an unlock mechanism or a guarantee that capture survives panel-off on your OEM.

The portable `DisplayLeaseTest` verifies timeout, stop/death-path restoration,
foreign/stale owner rejection, late-heartbeat rejection, failed ON preflight,
partial OFF rollback, retrying failed restorations without app heartbeats and
manual recovery. These use simulated display power and clock, not a real Binder
or display driver. On-device verification still needs app crash/force-stop,
Bluetooth loss, permission revocation, screen lock and physical power-key tests.

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
zero lint errors (advisory warnings for localization, backup metadata, app
icon and newer AGP availability). The included APK passes `apksigner verify` using
APK Signature Scheme v2. The permission checks identified by lint were fixed;
revoking Bluetooth access causes capture to stop.

Also validated in the Linux workspace:

- Pure Java DisplayLease tests: restoration, two-second expiry, stale-owner and
  late-heartbeat rejection, partial OFF rollback, failed ON preflight and ON retries.
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
javac -d /tmp/droidmirror-wire-tests BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/DisplayLease.java BluetoothCompanion/tests/DisplayLeaseTest.java
java -cp /tmp/droidmirror-wire-tests DisplayLeaseTest
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
