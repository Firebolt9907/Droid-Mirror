# Phone Camera for macOS

DroidMirror exposes **DroidMirror Phone Camera** through a CoreMediaIO Camera
Extension on macOS 14+. The persistent notification receiver publishes the device
when its BLE session authenticates and removes it on disconnect. A screen mirror
is not required. Merely listing/selecting the device does not open the phone
camera: capture starts with the extension stream's `startStream()` callback and
stops after the last `stopStream()` callback.

## Setup and signing

**Default builds omit the camera extension.** The System Extension entitlement
requires a paid Apple Developer Program team; free Personal Teams cannot provision
it. When `DROIDMIRROR_TEAM_ID` is unset, `Native/sign-droidmirror.sh` removes the
extension from the signed bundle, signs everything else as before, and Settings
disables **Enable Mac Camera Extension…**. Set the variables below to include it.

1. Use an Apple Developer team with registered identifiers `app.droidmirror.mac`,
   `app.droidmirror.notifications`, `app.droidmirror.camera`, and the app group
   `TEAMID.app.droidmirror.camera` (replace TEAMID with your team identifier). Enable System Extension installation for the
   host, and authorize the application group for the host, receiver and camera
   extension. Proper signing/provisioning is required; ad-hoc signing cannot
   validate this feature.
2. Set `DROIDMIRROR_SIGNING_IDENTITY` and `DROIDMIRROR_TEAM_ID`. Supply matching
   provisioning profiles through `DROIDMIRROR_HOST_PROFILE`,
   `DROIDMIRROR_RECEIVER_PROFILE` and `DROIDMIRROR_CAMERA_PROFILE` when required by
   your signing/distribution setup. The signing script expands the extension's
   Mach service team prefix and signs nested components before the host.
   Developer ID distribution also requires the usual notarization workflow.
3. Build/install using the normal project workflow **after ending active mirror
   and camera sessions**. The extension is embedded under
   `Contents/Library/SystemExtensions`. Building alone does not activate it.
4. In Mac Settings → Phone Camera, click **Enable Mac Camera Extension**. Approve
   the system request in System Settings → General → Login Items & Extensions →
   Camera Extensions (location/wording varies with macOS). Install the host under
   `/Applications` before activation. A restart can be required for replacement.
5. On Android, open Bridge Settings → **Arm Phone Camera for Mac apps** and grant
   Camera permission. This user action starts the camera foreground service while
   the activity is visible, satisfying Android's background camera restrictions.
   The persistent notification initially says **Phone camera ready for Mac**;
   Camera2 and the encoder remain closed until a Mac client starts streaming.
6. Keep DroidMirror running and BLE connected, then choose the device in FaceTime,
   Zoom, Photo Booth, or another camera client. Set front/back in Mac Settings. Changing the camera restarts capture only if
   a client is currently using it. Resolution and frame rate follow the active
   transport automatically. No screen mirror is needed.

Use **Stop sharing** in the Android camera notification to disarm. Arm again after
service/process restart. Android's camera privacy toggle, another app holding the
camera, or missing permission can prevent capture. Errors are logged by the Mac
receiver; it retries at most once every five seconds while demand remains.

## Architecture and security

- The extension runs an anonymous NSXPCListener, publishing its securely archived
  listener endpoint atomically inside the application group container. The group and CMIO Mach service share the same
  team-prefixed name, as required by CMIO validation. Both sides
  require the peer's Apple signing anchor, their own signing team, and the exact
  receiver/extension signing identifier. Distributed notifications cannot inject
  demand or video. The host UI only requests OS activation; the persistent BLE
  receiver owns camera control and decoding.
- Every 500 ms the receiver renews BLE presence over XPC and reads whether the
  extension has stream users. `startStream`/`stopStream` maintain a reference count;
  multiple Mac clients share a single phone capture. BLE connection alone only
  publishes the device. Missing receiver presence removes it within four seconds.
- Start, stop, lease renewal and frame ACKs use the existing authenticated BLE
  JSON channel, after `BleSecureSession.open`; its authentication, directional
  nonce and replay/sequence validation remain unchanged. Camera control records
  have a one-second outbound scheduling deadline so queued leases cannot keep
  capture alive behind an unrelated file transfer. A new authentication
  handshake revokes camera ownership. Replies are pinned to the original BLE
  session object and device, never broadcast to another Mac.
- Phone capture uses Camera2 → surface-input MediaCodec H.264/AVC with no B frames
  and independent keyframes. The camera is owned by an ordinary camera foreground
  service, not a daemonized Shizuku service. No Shizuku service code/version changes
  are needed for this feature.
- A dedicated Iroh camera endpoint uses `phone-camera`/`mac-camera` identity labels,
  its own `droidmirror_camera` local socket, and the existing reliable bulk ALPN.
  It inherits the existing direct-IP, paired-identity, no-relay discovery policy.
  A fresh random 32-byte capability and exact camera-session UUID travel only over
  authenticated BLE. The QUIC application handshake proves both; strictly
  increasing application sequence numbers protect binary frame records. This lane does
  not borrow the active mirror or clipboard connection.
- If Iroh is missing, cannot connect, or fails, low-rate video uses authenticated
  BLE. Frames are split into 2048-byte payloads, bounded to 128 KiB and three
  outstanding access units, with a three-second assembly/ACK recovery bound. Camera
  Bluetooth chunks yield to control traffic and are rejected before saturating the BLE
  queue. The next independently decodable frame recovers from a path failure.
- VideoToolbox decodes on the Mac. Core Image orients and letterboxes into a stable
  1280×720 BGRA output at 30 fps (repeating frames only when necessary); bounded XPC frame delivery feeds IOSurface-backed pixel
  buffers into CMIO sample buffers using the host-time clock. No frames are saved
  to disk. The endpoint archive contains no frame data or pairing credentials.

## Protocol additions

JSON type names avoid allocating/colliding with binary input message IDs:

| Type | Direction | Fields |
| --- | --- | --- |
| `cameraStart` | Mac → phone BLE | `session` UUID, `facing` front/back; legacy `width` hint is ignored by automatic profiles |
| `cameraLease` | Mac → phone BLE | `session` |
| `cameraStop` | Mac → phone BLE | `session` |
| `cameraFrameAck` | Mac → phone BLE | `session`, `frame`, `epoch` |
| `cameraKeyframe` | Mac → phone BLE | `session`, active encoder `epoch` |
| `cameraIrohOffer` | phone → Mac BLE | `session`, `token`, bounded `addresses`, `videoVersion: 2` |
| `cameraState` | phone → Mac BLE | `session`, encoder `epoch`, `transport`, `width`, `height`, `fps`, `rotation` or `error` |
| `cameraFrame` | phone → Mac BLE only | `session`, encoder `epoch`, `frame`, zero-based `chunk`, `last`, base64 `data` |

After the Iroh JSON **handshake only**, video uses raw binary records. The hello
proves the BLE-delivered token and session and requires `version: 2`; the ready
reply confirms version 2. Each access unit is a four-byte unsigned length followed
by this network-byte-order record (no JSON or base64 video):

| Offset | Bytes | Field |
| --- | --- | --- |
| 0 | 8 | ASCII `DMCV0001` |
| 8 | 4 | Positive encoder epoch |
| 12 | 8 | Strictly increasing connection sequence, starts at 1 |
| 20 | 8 | Presentation timestamp, microseconds |
| 28 | 4 | Flags: bit 0 is keyframe; all other bits must be zero |
| 32 | 4 | Payload length, 1…2 MiB |
| 36 | payload length | Raw Annex-B H.264 access unit; keyframes include SPS/PPS |

The record length, payload length, flags and sequence are checked before decode.
The authenticated QUIC connection and session capability bind every record to the
current camera session. Binary video has no per-frame BLE ACK requirement. The
phone writer queue is bounded to four records/1 MiB, and Mac delivery and decode
queues each allow at most three frames.

The phone accepts lease/stop/ACK only for the active camera-session UUID. An old
stop cannot release a newer session's camera. The phone checks BLE validity and a
four-second monotonic lease every 200 ms. Stop closes the capture session, camera,
encoder and Iroh lane; disconnect and BLE reauthentication do the same. Receiver
shutdown sends stop before closing BLE; a host-app quit also ends capture on the
next demand poll. A receiver crash, Mac sleep, lost XPC, or Bluetooth loss is
covered by the phone watchdog. A readiness foreground service can remain armed
without owning the camera.

## Current limits and validation

The active authenticated video path selects the encoder:

| Path | Capture | AVC bitrate | Keyframes |
| --- | --- | --- | --- |
| Iroh/direct IP (Wi-Fi/LAN/VPN) | 1280×720 at 30 fps | 3 Mbps | Every second, plus an explicit request after reconfiguration |
| Bluetooth | 320×240 at 15 fps | 128 kbps | Every frame, allowing safe frame drops and bounded ACK recovery |

Iroh readiness is polled every 200 ms. Upgrading or falling back increments the
encoder epoch, closes/recreates only the capture-session/encoder resources (keeping
the camera device open along with the BLE session, lease and foreground service), and requests a fresh keyframe after
Camera2 configures. Frame sequence/authentication checks remain active. The Mac
resets VideoToolbox on a newer epoch, rejects delayed older epochs and waits for a
keyframe before accepting dependent frames. Decoder errors/overload request a
fresh keyframe over authenticated BLE. A fixed 720p CMIO device avoids renegotiating
the Mac call's format; BLE frames are scaled and letterboxed into that format.

A failed/stalled IP writer is closed rather than sending high-resolution frames
over BLE or silently dropping dependent Wi-Fi frames. A stalled queue is detected
after 1.5 seconds without write progress. BLE capture resumes with its own fresh
encoder/keyframe. IP offers retry after a five-second cooldown; an unanswered
opening attempt has a ten-second bound. Unsupported 720p camera/encoder setup
falls back to BLE and waits 30 seconds before trying IP again. No mirror session
or service restart is needed for these changes. Actual frame rates still depend
on camera hardware, exposure, CPU and link throughput. IP is preferred once ready;
there is no measured IP-versus-BLE latency comparison.

There is no audio/microphone,
HEVC negotiation, dynamic device-rotation tracking, lens zoom, or automatic
rearming after Android kills the service. Sensor orientation is applied; test
front/back orientation on the target hardware. Some applications cache their
camera lists and need to reopen the picker after BLE reconnection. The host must
stay running; the camera device may still be listed while BLE remains connected
after host quit, but capture is stopped.

`sh Native/test-continuity-camera.sh` tests capture profiles, bounded ACK windows,
Java-to-Swift binary fixtures, malformed/replayed packet rejection, epoch/keyframe
recovery, bounded frame reassembly and typechecks
the CMIO extension. Add `--integration` to typecheck the complete BLE receiver
module (SwiftUI macro plugins need permission to run). Also compile the full BLE source list from `build-app.sh`,
Swift host, Android Kotlin/Java and Rust native transport. Do not use build-app.sh
as a compile-only check: it can quit apps and install components.

Signing/provisioning, anonymous XPC under the real sandbox, OS activation and
actual camera-client behavior require a properly signed installed build. On-device
acceptance must cover: BLE-only availability with no mirror; enumeration without
opening Camera2; first/last client and overlapping clients; front/back settings;
IP and forced BLE paths; last-client stop; host quit; receiver crash; phone camera
privacy/revocation; BLE disconnect/reauthentication; watchdog timeout; Android
Stop sharing; and extension replacement after gracefully ending active sessions.
Check that phone camera privacy indicators clear and another Android app can
immediately acquire the camera after every stop path. No install, activation or
service restart is part of the compile-only validation.

Apple references: [Camera extension setup](https://developer.apple.com/documentation/CoreMediaIO/creating-a-camera-extension-with-core-media-i-o) and [Core Media IO camera extensions](https://developer.apple.com/videos/play/wwdc2022/10022/).

## Implementation verification

Completed without installing an APK, activating the extension, running a bundle
update script, or restarting a service:

- `sh Native/test-continuity-camera.sh`: frame assembly assertions and final
  extension typecheck passed.
- Complete `BLE_SOURCES` list parsed from `build-app.sh`, passed to
  `xcrun swiftc -typecheck -target arm64-apple-macosx14.0 -module-cache-path /private/tmp/droidmirror-camera-cache`:
  passed (47 source files). The optional `--integration` script mode reproduces it.
- `env CLANG_MODULE_CACHE_PATH=/private/tmp/droidmirror-camera-clang SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/droidmirror-camera-swift swift build --disable-sandbox --scratch-path /private/tmp/droidmirror-camera-host-build`:
  passed.
- In `BluetoothCompanion`, `env ANDROID_HOME=/Users/rishu/Library/Android/sdk JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home ./gradlew compileDebugKotlin compileDebugJavaWithJavac`:
  passed, including Android native transport compilation. A second compile with
  `-x buildPeerTransport --max-workers=2 --console=plain` also passed. Warnings
  include the compatible deprecated Camera2 capture-session API.
- `cargo check --locked --manifest-path PeerTransport/Cargo.toml`: passed with an
  existing unused `endpoint_mode` warning.
- `cargo test --locked --manifest-path PeerTransport/Cargo.toml tests::camera_lane_is_separate_and_progresses_with_blocked_video -- --exact --nocapture`:
  one test passed, including distinct camera/clipboard identities and data
  delivery while video is blocked.
- `sh -n Native/sign-droidmirror.sh`, `zsh -n build-app.sh`, new/changed plist
  validation with `plutil -lint`, and `git diff --check`: passed.

The sandbox initially blocked Gradle cache access, SwiftUI macro subprocesses,
and synthetic QUIC sockets. Approved compile/test-only reruns succeeded. No
signing or on-device behavior is claimed by these checks.

## Files for this feature

New files:

- `Native/CameraExtension/main.swift`
- `Native/CameraIPC.swift`, `Native/ContinuityCamera.swift`, `Native/CameraIrohChannel.swift`
- `Native/CameraVideoPacket.swift`, `Native/CameraVideoPacketTests.swift`
- `Native/CameraFrameAssembler.swift`, `Native/CameraFrameAssemblerTests.swift`, `Native/test-continuity-camera.sh`
- `Sources/DroidMirror/CameraExtensionActivation.swift`
- `BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/CameraVideoPacket.java`, `BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/CameraVideoProfile.java`, `BluetoothCompanion/tests/CameraVideoPacketTest.java`
- `BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/CameraFrameWindow.java`, `BluetoothCompanion/tests/CameraFrameWindowTest.java`
- `BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/PeerCameraEndpoint.java`
- `BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/bridge/CameraIrohChannel.kt`
- `BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/bridge/ContinuityCameraService.kt` (also contains the foreground-consent activity)
- `Resources/CameraExtensionInfo.plist`, `Resources/CameraExtension.entitlements`, `Resources/CameraHost.entitlements`, `Resources/CameraReceiver.entitlements`
- This document.

Targeted integration edits (other agents/user edits in these files were preserved):

- `Native/BLEController.swift`, `Native/BLEIntegration.swift`
- `Sources/DroidMirror/SettingsView.swift`
- `BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/bridge/BlePeripheral.kt`
- `BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/bridge/BridgeSettingsActivity.kt`
- `BluetoothCompanion/src/main/AndroidManifest.xml`
- `PeerTransport/src/lib.rs`
- `Resources/Info.plist`, `build-app.sh`, `Native/sign-droidmirror.sh`, `README.md`
