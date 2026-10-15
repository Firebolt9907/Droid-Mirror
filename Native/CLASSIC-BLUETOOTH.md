# Bluetooth Classic: Mac-initiated mirroring

Version 0.3 replaces the per-session MediaProjection workflow. After one-time
phone setup, pressing **Mirror on the Mac** opens the secure Bluetooth connection
and starts the embedded scrcpy 5 capture engine in a Shizuku shell user service.
There is no Android-managed screen-share prompt and no ADB or LAN connection in
the streaming path. Shizuku must be running and authorized; this is not a bypass
of Android's ordinary app permissions. Remote mouse, keyboard and navigation input use the same Bluetooth connection;
audio remains ADB-only.

Bluetooth uses the same native rounded mirror window, floating draggable toolbar,
manual PIN keypad, keyboard shortcuts and optional touch-style scrolling as ADB.
Toolbar power/navigation and scroll gestures enter scrcpy's existing input path
and travel over BLE; they do not invoke ADB. Automatic PIN-prompt detection remains
ADB-only, so open the keypad with the toolbar's lock button when needed.
The Mac build includes both the shared toolbar controller and the device-corner
styling layer. The 0.7 APK also scales the full phone image through GL
when encoder alignment changes the aspect ratio, avoiding virtual-display black
bands at the top/bottom (or sides after rotation). Install both refreshed builds
for the corner and padding fixes; the APK retains the existing signing certificate.
Version 0.7 also increments the Shizuku capture-service version. The daemon is
deliberately persistent and can survive APK replacement; keeping its old version
would reuse old capture code even after installing the corrected APK. A new
session now replaces that daemon automatically. The internal capture surface is
the phone's full display size when alignment needs correction (1080×2400 on Pixel
8), while the video sent over Bluetooth remains at the low-resolution profile.

## Install and set up once

The compiled Android test APK is `outputs/DroidMirror-Bluetooth-0.8-debug.apk`,
with a SHA-256 checksum beside it. It uses the same signing certificate as 0.1/0.2/0.3/0.4
and can be installed over them. It is a debug build, not a store release.

1. Pair the phone and Mac in their system Bluetooth settings.
2. Install/start Shizuku 13 or newer. Its startup may require wireless debugging
   or root. Grant Shizuku access in **DroidMirror Bluetooth**.
3. Grant Nearby Devices and notification access. Select the paired Mac, choose
   whether to turn the phone panel off, and tap **Enable Mac connections** once.
   Only that bonded Mac is accepted. The ongoing notification shows readiness.
4. Pull/rebuild the Mac app as below. Allow its Bluetooth and notifications
   permissions, select the phone and press **Mirror**. Close the mirror to stop.
   The phone listener returns to ready state; the next session starts from Mac.

Configuration and selected peer are saved on Android. The listener is a
`connectedDevice` foreground service with `START_STICKY` and a boot receiver;
it does not use the `mediaProjection` foreground-service type. Closing the phone
setup activity does not end readiness or capture. **Disable Mac connections**
turns off background readiness. Shizuku permissions/startup have no fixed weekly
schedule: reboots, revocation and Shizuku itself determine when attention is
needed. Android force-stop prevents automatic restart until an explicit launch;
OEM battery restrictions can also delay/stop the listener. These are lifecycle
limits, not per-session capture approvals.

A sleeping phone is made logically awake through Android's normal power policy.
The configured keyguard is never dismissed, bypassed or reconfigured. This implementation is video-only,
so unlocking/input from Mac still requires the existing ADB mode.

## Silent Tasker restart (Android 0.4)

Complete phone setup once and leave **Enable Mac connections** enabled. Create a
Tasker **Bluetooth Connected** profile for your Mac with a **Send Intent** entry task:

| Field | Value |
| --- | --- |
| Action | `app.droidmirror.bluetooth.action.START_READY` |
| Package | `app.droidmirror.bluetooth` |
| Class | `app.droidmirror.bluetooth.SilentStartActivity` |
| Target | Activity |

Leave data, MIME type and extras empty. This transparent activity resumes the
saved listener and immediately finishes, without opening setup, requesting
permissions or starting capture. It can briefly take foreground focus; it has
no preview, animation or recent-task entry. Tasker must be permitted to launch
activities from the background on your Android/OEM version (Tasker's setup may
require “Display over other apps”). It does not unlock the phone.

For an activity-free attempt, change Class to
`app.droidmirror.bluetooth.AutomationReceiver` and Target to **Broadcast Receiver**.
Keep the same action/package. Android 12+ may reject this path with
`BACKGROUND_RESTRICTED` when the sender has no foreground-service exemption;
use the activity entry above if that happens. The receiver does not automatically
open an activity. Ordered broadcasts return code -1 with `START_REQUESTED`, or
code 0 with a refusal reason in result data. This acknowledges the startup request,
not Bluetooth/Shizuku readiness. Diagnostics use log tag `DroidMirrorReady`.

Equivalent commands for a shell-capable automation runner:

```sh
am start -a app.droidmirror.bluetooth.action.START_READY -n app.droidmirror.bluetooth/.SilentStartActivity -f 0x10000000
am broadcast -a app.droidmirror.bluetooth.action.START_READY -n app.droidmirror.bluetooth/.AutomationReceiver -f 0x20
```

The broadcast's `0x20` includes stopped packages; a real force-stop differs from
Android killing the process, and background restrictions still apply. Explicit
activity launch is preferred for force-stop recovery. Ordinary Bluetooth events
alone do not restart a force-stopped package. Tasker needs an actual Bluetooth
connection/profile event: pairing and discovery are not connections, and a dead
Classic L2CAP listener cannot accept the Mac's stream attempt. Use an independently
available Bluetooth connection event or another Tasker trigger if the Mac profile
does not fire.

Both entries are idempotent and only reuse saved settings. They cannot enable a
previously disabled listener, select a peer, grant Shizuku permission or dismiss
keyguard. An active stream stays active. Android still requires the existing
low-importance foreground-service notification; silent means no setup screen or
new alert. The entry points are public for Tasker, but only the configured bonded
Mac can connect and initiate capture. Compilation/lint do not validate Android/OEM
background launch policies; test the Tasker profile on your phone.

## Stream live update (Android 0.5)

Once an actual video frame has reached the Mac, the readiness notification
becomes **Screen sharing**, showing the bonded Mac's Bluetooth name, elapsed
session time, and **Disconnect**. The system chronometer counts up without
reposting every second. Tapping the notification opens a compact details dialog
with the same name, duration and action. Ending the stream closes an open dialog
and returns the notification to Bluetooth readiness; capture startup failures do
not create a live stream notification.

On Android 16 systems supporting the 36.1 live-update APIs, the app requests
promotion to a persistent status-bar chip. Tap the system chip to expand its
notification details. The app declares `POST_PROMOTED_NOTIFICATIONS` and uses the
documented `android.requestPromotedOngoing` extra, a standard BigText notification,
ongoing flag and low-importance channel. Base Android 16 and older phones fall
back to the ongoing notification; user notification/live-update settings and OEM
eligibility rules can also prevent the chip. Grant notification access during
setup, and enable Live Updates for DroidMirror in system app notification settings
where that control exists. The app does not repeatedly re-promote a dismissed
update during the same session. System placement/visibility is not app-controlled.

**Disconnect** releases the normal Shizuku session and restores the physical
panel without invoking the power-button/local-use path. macOS receives the normal
`SESSION_ENDED` event, closes the mirror, and posts the existing remote-use audit;
it does not show the “phone turned on” / “phone was used” takeover popup. A slow
or failed link can lose the final event, but cannot turn Disconnect into a
local-use event. Cleanup is bounded if the encoder fails to close, with shell
watchdog recovery still active. Readiness remains enabled for the next Mac start.
Each action is immutable and carries a unique session token; stale actions cannot
stop a subsequent stream. Both the action service and details activity are private.

The pill is usable while the phone panel is on. With the panel-off option enabled,
pressing the hardware power button to regain phone access still follows the
previously requested takeover flow and ends the session with its separate Mac
popup. The live update does not bypass keyguard or change power-button behavior.
Rebuild the Mac from this commit to suppress generic stream-failure messages after
an intentional normal end. Actual chip presentation and notification interaction
still require phone/OEM testing.

## Build

Android requires JDK 17+ and Android SDK 36. Gradle 8.11.1 is pinned and checksum
verified by the checked-in wrapper:

```sh
cd BluetoothCompanion
./gradlew assembleDebug lintDebug
```

The companion compiles the actual capture sources and AIDL from
`scrcpy-5.0/server/`; it does not launch scrcpy's ADB server entry point or push
anything through ADB. The embedded `com.genymobile.scrcpy.BuildConfig` pins the
engine version to 5.0. SDK/OEM incompatibilities can still reject privileged
capture at runtime, in which case the connection closes and Mac reports failure.

On macOS 14+ with Xcode command-line tools:

```sh
git pull origin main
brew install meson ninja pkg-config sdl3 ffmpeg libusb
./build-app.sh
open outputs/DroidMirror.app
```

Build and install both matching 0.8 endpoints. Open **Show BLE pairing code** on
Android, then paste that private code into **Settings → Connection → Pair BLE**
on the selected Mac once. Older endpoints cannot use the video-only protocol. The parser retains legacy
fixtures for protocol tests; the current app requires the matching transport.
Use the documented development-signing workflow if preserving the existing BLE
notification helper's Keychain identity; the build script signs ad-hoc.

## Video and control events

The Bluetooth profile starts with H.264 at a 256,000 bit/s target, up to 16 fps and about a
480-pixel short edge, aligned down to 16 pixels while preserving aspect ratio.
The encoder uses constant bitrate without hard quantization limits, no B-frames,
and gradual intra refresh when supported. Repeated idle frames refine settled text
without forcing large periodic keyframes. The actual frame rate may be lower
on a constrained link. Automatic downsizing on encoder errors is
disabled so recovery cannot lower the configured resolution. The
radio negotiates Classic/EDR itself; the app cannot force an EDR PHY rate.

Direct Classic BR/EDR L2CAP uses fixed private PSM `0x1001`. The Mac opens it
without SDP discovery. `ClassicL2capService` owns Android's authenticated,
encrypted socket through the hidden `BluetoothAdapter.listenUsingL2capOn(int)`
API, invoked in the Shizuku shell process. The public `listenUsingL2capChannel()`
API is LE-only and is not used. Only the selected bonded Mac is accepted.
The app's Binder death closes the listener and active socket; normal session
shutdown closes the connection while retaining the listener for the next session.
If the hidden API is unavailable, readiness reports the failure rather than
falling back to RFCOMM. The Shizuku display daemon still owns capture and recovery.
A one-way pipe bridges the app to the shell-owned L2CAP video writer. A reverse
Classic payload closes the connection; there is no Classic input/control relay. A file-descriptor
pipe transfers scrcpy video from the shell service to the app's Bluetooth relay.
No screen content is saved. The matching wire format is dummy byte, 64-byte device
name, codec ID, then scrcpy 5 session/frame packets, preserving decoder/renderer
compatibility, rotation metadata, and protected-content restrictions.

The Classic stream begins with `DMBT0006`, then type-0 records (one-byte type,
four-byte big-endian length, video payload), with payload chunks sized to four negotiated transmit MTUs minus the five-byte
envelope header (2683 bytes at MTU 672), bounded by the video window. Small frames
and final tails are sent immediately. The shell relay reads up to six MTUs at a
time without waiting to fill its buffer. The MTU is fetched once per connection
over Binder, never per video packet. The live
Mac receiver requires this version and rejects all other record types, including
control, events and session keys. Legacy formats remain only for parser fixtures.
Bluetooth's own connection signalling and link acknowledgements still run in both
directions under OS control; the one-way rule concerns application payloads.

BLE service `c356a44e-6f2b-4da9-85e5-397991b8a610` carries every non-video message:

- `...a611`: acknowledged GATT writes for input, cumulative video ACKs and heartbeats.
- `...a612`: a random 16-byte Mac challenge and phone HMAC proof.
- `...a613`: encrypted control replies and status events, pulled with GATT reads
  and fragmented to ATT size.
- `...a614`: a public 32-byte random per-session nonce, never a pairing/session key.

A private 32-byte pairing code is stored per selected bonded Mac in Android's
app-private preferences (backup disabled), and per phone in the Mac helper's
Keychain. It is provisioned once through the setup UI. Session keys are HMAC-SHA256
of `DroidMirror BLE session v1` plus the nonce using this pairing key. Mac verifies
the phone's proof before sending input. The server also requires the selected,
bonded Mac's resolved Bluetooth address. Classic and BLE CoreBluetooth identifiers
are different on the tested Mac, so they are not used as interchangeable identities.
The pairing code is never exchanged over Classic, BLE advertising, or logs.

Input encryption/authentication keys use the labels `DroidMirror BLE encryption v1`
and `DroidMirror BLE authentication v1`; return keys use `DroidMirror BLE return
encryption v1` and `DroidMirror BLE return authentication v1`. Separate directions
have independent sequence counters, preventing reflection and IV/key reuse. The
phone proof is HMAC of `DroidMirror BLE proof v1` plus the challenge. Each record
contains an eight-byte big-endian sequence, AES-256-CTR ciphertext, and a 16-byte
truncated HMAC-SHA256. The CTR IV is `DMINPUT1` plus the sequence. Authentication
precedes decryption; missing/replayed/reordered records terminate the session.

Mac-to-phone plaintext records are type 0 (raw scrcpy control) or type 1 (eight-byte
cumulative video count; legacy empty heartbeat also recognized). Return records
are type 1 (one-byte PHONE_ON=1, SESSION_ENDED=2, PHONE_LOCAL_USE=3, STREAM_STARTED=4,
CAPTURE_FAILED=5, ALIVE=6) or type 2 (scrcpy control replies), with four-byte lengths.
The Mac keeps video and control on separate local sockets. Heartbeats/ACKs run at
250 ms with a 24 KiB video window. Unsent cumulative ACKs coalesce to the newest
count under CoreBluetooth backpressure; input bytes retain their exact order.
Mac BLE callbacks and GATT operations run on a dedicated serial queue, separate
from the Classic receive loop. Return reads use a bounded worker queue and poll at 500 ms when idle, then drain
queued records immediately. Empty reads contain no application record. A return
packet is retired after its GATT response is submitted; missing/reordered packets
fail authentication/sequence checks. This avoids absent notification callbacks on
the tested macOS path. Phone heartbeat echoes run at one second, reducing BLE
airtime. Waiting for a video ACK never holds the BLE control writer. BLE failure closes
the Classic session and invokes the existing recovery path. Both transports share
the same radio, so extra BLE traffic is not free bandwidth.

macOS 26's legacy IOBluetooth opening shim loses its pending channel on this
machine. The helper uses runtime-checked Classic-peer completion selectors to
retain the actual CBL2CAPChannel and wrap it for the existing stream delegate;
older implementations retain the public IOBluetooth path. This is an experimental
compatibility dependency, alongside Android's hidden Classic listener API.

The loopback listener accepts one client and is not authenticated local IPC; a
local process can race to connect. Radio access relies on secure system Bluetooth
bonding and the saved peer address, independent of the older BLE notification
bridge. The relay rejects encoded packets over 128 KiB and closes Bluetooth writes
blocked for five seconds when peer heartbeats have also expired. Live peer input
keeps ordinary radio backpressure from being mistaken for a dead connection.
The Mac bounds pending video to 128 KiB with a one-second
pending deadline. The encoder discards frames more than two seconds old only with keyframe recovery,
reducing bitrate when the stream falls behind. After ten seconds of continuous
healthy output, bitrate grows by 25% toward the configured target; idle gaps do
not count as healthy throughput. `DroidMirrorPerformance` logs relay FPS, encoded
kbps and time spent sending every five seconds, without saving video.
This is a recovery threshold, not
an end-to-end latency guarantee: transport and decoder time are additional. The capture pipe is capped at 4 KiB on Android 11 and newer.

## Panel-off and recovery

The Shizuku daemon registers the app's Binder death callback before capture or OFF.
Panel-off is applied only after a media frame is transmitted. It uses scrcpy-style
physical SurfaceControl/DisplayControl APIs, not brightness changes, sleep-key
commands, or persistent system settings. It tests NORMAL before OFF and records
recovery intent before partial multi-display OFF operations.

App death, session stop, Bluetooth/encoder failure, manual recovery, and normal
guard shutdown lock the phone before restoring the panel. Lock failures are
logged; panel restoration still runs so recovery cannot leave it inaccessible.
A shell watchdog checks every 100 ms. Startup
has a ten-second grace period; after video starts, the app renews a two-second
session/display lease every 250 ms after the first media frame while Mac control
heartbeats remain current. Bluetooth congestion has a five-second peer grace
period; loss of Shizuku authorization ends the lease immediately. Failed NORMAL
operations are retried; new OFF requests are refused while recovery is pending.
Retired/folded display tokens are refreshed after restoration failures.

Recovery is prompt best effort, not guaranteed instantaneous. Scheduling,
suspension, or blocked display APIs can delay it. Shell UID protects against
ordinary app lifecycle kills but not SIGKILL of the guard, every OEM restriction,
or driver hangs. Shutdown hooks cannot handle SIGKILL. **Restore phone display**
is available in setup; a physical power cycle/reboot is the final fallback if the
guard itself is forcibly killed. No display setting persists across reboot.

## Local phone use and notifications

A short physical power press produces a logical SCREEN_OFF/sleep transition.
The app's protected SCREEN_OFF broadcast receiver requests local takeover, and
the shell service independently polls display interactivity every 100 ms. During
healthy streaming it sends NO_CHANGE_LIGHTS user-activity updates once per second
so ordinary idle timeout does not interrupt mirroring or relight the physical panel.
If that OEM API is unavailable, timeout can still interrupt capture. Another local
screen-lock/sleep action also produces this transition: an ordinary app
cannot distinguish raw hardware power presses from all other screen-off causes.
Long-press menus or presses which produce no screen transition are not detected.

Local takeover invalidates the remote session, requests `IWindowManager.lockNow`,
checks keyguard lock for up to 500 ms, restores physical panel power, and wakes the
phone through `IPowerManager`. It never wakes deliberately without confirming the
lock. A confirmed transition sends PHONE_ON to Mac. Mac shows a separate popup
headed **phone was used**, with **phone turned on** and the lock/restore result.
If confirmation fails, PHONE_LOCAL_USE reports that failure without claiming
success. Streaming ends in both cases; readiness remains available for the next
Mac-initiated session. Events are best effort if the radio link fails at that moment.

At session end, Mac posts **Phone was used remotely** through UserNotifications,
deduplicating stream-close/quit/disconnect callbacks. The phone's shell watchdog
posts the same audit title through Android's shell notification command, surviving
capture-app crash/force-stop while Shizuku remains alive. The app falls back to its
own notification if that command fails and the app is still running. The end policy
commits an end once per session; stop, EOF, local takeover and Binder death cannot
post repeated shell audits for that session. The notification replaces the prior
phone audit entry rather than storing a screen recording or a full activity history.

Notifications are subject to OS permissions, Focus/channel settings and process
availability. Older Android versions lacking the shell notification command cannot
post a crash notification from a dead app. No implementation can guarantee a Mac
popup over a disconnected radio or deliver immediately when all relevant processes
are killed. Reconnection/status notifications are not evidence of an unlock.

## Validation

`assembleDebug lintDebug` succeeds with zero lint errors in the Linux workspace,
using JDK 17, SDK 36, AGP 8.9.1 and Gradle 8.11.1. The signed APK verifies and uses
the same certificate as the previous test builds. Portable checks include:

- DisplayLease: stop/death-path recovery, expiry, stale owners, late heartbeats,
  failed ON preflight, partial OFF rollback and retrying restoration.
- RemoteSession: one end event, local-use precedence, crash/stop/timeout, stale
  owners, ordinary disconnect followed by screen-off, and startup grace becoming the short active-stream timeout.
- VideoWire and BluetoothWire: scrcpy headers/flags, dimensions, chunking and events.
- Native C parser under address/undefined-behavior sanitizers: every fragment size,
  event/video isolation, legacy input, malformed records and truncation.
- A real Java-generated envelope fixture decoded by the C receiver.
- Earlier scrcpy CLI tests and C syntax checks (with dependency header shims).

These are compile/state/protocol tests, not physical Binder/driver/radio tests.
Mac Swift/Objective-C compilation and the actual phone's capture, power, lock,
notification delivery and restart behavior still need hardware validation. Test
repeated Mac-only starts, foreground/background readiness, phone power press,
normal timeout, Bluetooth loss, app kill/force-stop, Shizuku stop, rotation and
sleeping/locked startup before relying on unattended mirroring.

## Adaptive quality

Capture dimensions stay fixed. When an encoded frame is more than 400 ms old,
MediaCodec bitrate decreases by 25%, at most once a second, with a floor of half
the configured target (128 kbps for this profile). Ten seconds of continuous
healthy output raises it by 25% toward the target. Idle gaps do not count as healthy
throughput. Frames older than two seconds trigger safe keyframe recovery instead
of forwarding a stale inter-frame chain. Repeated recovery also respects the
quality floor. These bounds prevent the earlier repeated collapse to 32 kbps;
they cannot guarantee latency when available live throughput is below the floor.

## Encoder-independent Classic throughput test

With the matching debug APK installed and wireless debugging or USB connected:

```sh
python3 tools/benchmark-classic.py PHONE_CLASSIC_ADDRESS
```

This explicitly starts a shell-only generated-data listener on separate PSM
`0x1003`, accepting only the saved bonded Mac. It runs three ten-second samples:
672-byte direct writes, 256-byte direct writes, and 672-byte producer writes through
a persistent pipe with a 4 KiB relay buffer. There is no encoder, decoder, BLE
application window or per-packet Binder call. The diagnostic payload is a checked
byte sequence, never screen content. It is available only via the explicit shell
benchmark entry point; ordinary mirrors still require video-only records on `0x1001`.
The Mac checks the full sequence, reports actual received bytes/rate, and the script
rejects a result unless sender and receiver byte totals agree. An interrupted
connection is an invalid sample. The receiver duration spans first to last data,
including queue drain, while sender timing includes any blocked writes.

These measurements characterize transport capacity without concurrent BLE input;
leave headroom for BLE, retransmissions and encoded keyframe bursts before choosing
a video bitrate. A configured 64 kbps encoder target is not a measured radio limit.
