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

The compiled Android test APK is `outputs/DroidMirror-Bluetooth-0.10-debug.apk`,
with a SHA-256 checksum beside it. It uses the same signing certificate as 0.1/0.2/0.3/0.4
and can be installed over them. It is a debug build, not a store release.

1. Pair the phone and Mac in their system Bluetooth settings.
2. Install/start Shizuku 13 or newer. Its startup may require wireless debugging
   or root. Grant Shizuku access in **DroidMirror Bluetooth**.
3. Grant Nearby Devices and notification access. Select the paired Mac, choose
   whether to turn the phone panel off, and tap **Enable background bridge** once.
   Only that bonded Mac is accepted. The ongoing notification shows readiness.
4. Pull/rebuild the Mac app as below. Allow its Bluetooth and notifications
   permissions, select the phone and press **Mirror**. Close the mirror to stop.
   The phone listener returns to ready state; the next session starts from Mac.

Configuration and selected peer are saved on Android. The listener is a
`connectedDevice` foreground service with `START_STICKY` and a boot receiver;
it does not use the `mediaProjection` foreground-service type. Closing the phone
setup activity does not end readiness or capture. **Stop background bridge**
turns off background readiness. Shizuku permissions/startup have no fixed weekly
schedule: reboots, revocation and Shizuku itself determine when attention is
needed. Android force-stop prevents automatic restart until an explicit launch;
OEM battery restrictions can also delay/stop the listener. These are lifecycle
limits, not per-session capture approvals.

A sleeping phone is made logically awake through Android's normal power policy.
The configured keyguard is never dismissed, bypassed or reconfigured. This implementation is video-only,
so unlocking/input from Mac still requires the existing ADB mode.

## Silent Tasker restart (Android 0.4)

Complete phone setup once and leave **Enable background bridge** enabled. Create a
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

Build and install both matching 0.10 endpoints. Open **Show BLE pairing code** on
Android, then paste that private code into **Settings → Connection → Pair BLE**
on the selected Mac once. Older endpoints cannot use the video-only protocol. The parser retains legacy
fixtures for protocol tests; the current app requires the matching transport.
Use the documented development-signing workflow if preserving the existing BLE
notification helper's Keychain identity; the build script signs ad-hoc.

## Video and control events

The hybrid Bluetooth profile requires regular HEVC (H.265 Main, 8-bit), starting at
160,000 bit/s and probing up to a 192,000 bit/s ceiling, up to 15 fps and about a
320-pixel short-edge limit. It chooses an exact-ratio size compatible with the
encoder alignment instead of rounding width and height separately (306×680
on the Pixel 8).
The encoder requests constant bitrate where advertised (otherwise VBR), without
hard quantization limits or B-frames, and gradual intra refresh only when advertised.
The bitrate is a target: the Pixel 8 driver reports VBR despite its CBR capability.
Companion 0.15 and the matching Mac build are required; HEVC is retained after the
Wi-Fi handoff, while input stays on BLE. Direct ADB mode retains its own codec
selection and ADB input. See [HEVC handoff validation](WIRELESS-HANDOFF.md). Repeated idle frames refine settled text
without forcing large periodic keyframes. The actual frame rate may be lower
on a constrained link. Automatic downsizing on encoder errors is
disabled so recovery cannot lower the configured resolution. The
radio negotiates Classic/EDR itself; the app cannot force an EDR PHY rate.

Direct Classic BR/EDR L2CAP uses fixed private PSM `0xD001`. The Mac opens it
without SDP discovery. Both apps must use this PSM; the old `0x1001` can already
belong to Android system Bluetooth and route sessions away from DroidMirror.
`ClassicL2capService` owns Android's authenticated,
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
- `...a615`: one authenticated Android uptime sample during connection setup.

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
The Mac keeps video and control on separate local sockets. During active Classic
video, cumulative ACKs run at 40 ms (on the 20 ms bridge timer). The video window
starts at 8 KiB and adapts up to 64 KiB using delivered payload bytes and observed
ACK spacing. Every 500 ms of active delivery, it budgets 150 ms of payload plus
ACK feedback headroom and a 25% margin. Upward estimates are smoothed and window
growth is capped at 8 KiB per sample; reduced throughput contracts the window
without smoothing the drop. Idle heartbeats do not count as bandwidth samples,
and Wi-Fi fallback resets the estimate. This permits higher bitrate without a
fixed small window starving the radio. It measures delivered traffic, not unused
link capacity; encoder probes supply the additional traffic to discover headroom.
Idle heartbeats remain at 250 ms. Moving Wi-Fi video also uses 40 ms ACKs,
with a 128 KiB outstanding window to bound the bytes that must replay over Classic.
Use matching Mac and companion builds. The preview APK is `outputs/DroidMirror-Bluetooth-low-latency-debug.apk`;
use it with `outputs/DroidMirror.app`. The portable regression suite
(`bash Native/test-wireless-upgrade.sh`) checks delivery estimates, bandwidth
probing, ACK timing, window backpressure and handoff/fallback accounting. Actual
radio throughput and end-to-end latency still require a connected phone test.
Unsent cumulative ACKs coalesce to the newest
count under CoreBluetooth backpressure. The newest ACK is prioritized between
complete input envelopes, so sustained mouse traffic cannot keep it behind the
whole input backlog. Mouse hover forwarding is disabled at client launch; motion
without a held button sends no control input. Sustained mouse drag MOVE positions are limited to 60 Hz, keeping the newest unsent
position in each 16.7 ms source-time bucket for the same pointer and button state.
Earlier buckets remain queued during radio backpressure, preserving the motion
history Android needs for fling velocity; only samples within a bucket coalesce. Clicks, releases, keys, scrolling
and pointer/state changes are ordering barriers; a final position flushes before
a barrier. Other input retains its exact order. Complete scrcpy messages are
reassembled across arbitrary TCP fragments before applying this policy. Ready
envelopes share full ATT payloads, without a timer that waits to fill a packet.
Mac BLE callbacks and GATT operations run on a dedicated serial queue, separate
from the Classic receive loop. Only one acknowledged GATT read or write is in
flight at a time; due return reads get a turn during sustained input. Return
reads use a bounded worker queue and poll at 500 ms when idle, then drain
queued records immediately. Empty reads contain no application record. A return
packet is retired after its GATT response is submitted; missing/reordered packets
fail authentication/sequence checks. This avoids absent notification callbacks on
the tested macOS path. Phone heartbeat echoes run at one second, reducing BLE
airtime. Waiting for a video ACK never holds the BLE control writer. BLE failure closes
the Classic session and invokes the existing recovery path. Both transports share
the same radio, so extra BLE traffic is not free bandwidth.

Bluetooth touch messages use private scrcpy type 23: the standard 32-byte touch
record followed by the original 64-bit event time in milliseconds. The client
captures SDL event time before its controller queue. The authenticated uptime
read maps Mac CLOCK_MONOTONIC to Android uptime once per connection using the
Mac receive time, so mapping is conservatively in the past. The helper converts
source times before BLE transmission; Android uses them for MotionEvent eventTime
and downTime. Coalescing retains the newest sample's timestamp. Thus network
queueing changes delivery latency, not the gesture's measured duration/velocity.
No fast-swipe-to-Home classifier or phone-side smoothing is used. Standard ADB
type-2 touch messages retain their existing behavior. Matching endpoints are
required. Invalid future or over-ten-second-old timestamps are rejected.


macOS 26's legacy IOBluetooth opening shim loses its pending channel on this
machine. The helper uses runtime-checked Classic-peer completion selectors to
retain the actual CBL2CAPChannel, opens its native input/output streams, and feeds
the existing video parser directly. Re-wrapping the returned channel in
IOBluetoothL2CAPChannel caused acceptance timeouts or a closed Android pipe on
macOS 27; that adapter is removed. The reverse stream stays open without writing
application payload. Older implementations retain the public IOBluetooth path. This is an experimental
compatibility dependency, alongside Android's hidden Classic listener API.

The loopback listener accepts one client and is not authenticated local IPC; a
local process can race to connect. Radio access relies on secure system Bluetooth
bonding and the saved peer address, independent of the older BLE notification
bridge. The relay rejects encoded packets over 128 KiB and closes Bluetooth writes
blocked for five seconds when peer heartbeats have also expired. Live peer input
keeps ordinary radio backpressure from being mistaken for a dead connection.
The Mac bounds pending video to 128 KiB with a one-second
pending deadline. The encoder discards frames more than 500 ms old only with keyframe recovery,
reducing bitrate when the stream falls behind. After ten seconds of continuous
healthy Bluetooth output, bitrate recovers by 25% toward the 128 kbps ceiling; idle gaps do
not count as healthy throughput. `DroidMirrorPerformance` logs relay FPS, encoded
kbps and time spent sending every five seconds, without saving video.
This is a recovery threshold, not
an end-to-end latency guarantee: transport and decoder time are additional. The capture pipe is capped at 4 KiB on Android 11 and newer.

## Panel-off and recovery

The Shizuku daemon registers the app's Binder death callback before capture or OFF.
When panel-off is enabled, the guard acquires a bounded startup lease and blanks
before logically waking Android, then reapplies OFF immediately after wake and
through the first second of capture startup. Recovery APIs are resolved without
a visible NORMAL preflight. Android wake/driver scheduling may still produce a
brief transition; the panel no longer waits for encoder startup or a media frame.
SurfaceControl/DisplayControl restores OFF, DOZE, or DOZE_SUSPEND according to
Android's display state instead of forcing NORMAL. No brightness or persistent
system setting is changed.

App death, session stop, Bluetooth/encoder failure, manual recovery, and normal
guard shutdown lock the phone, stop capture, and confirm logical sleep before
restoring the panel to Android's requested OFF/doze/AOD policy. Local phone takeover
still deliberately wakes the lock screen. Lock failures are
logged; panel restoration still runs so recovery cannot leave it inaccessible.
A shell watchdog checks every 100 ms. Startup
has a ten-second grace period; after video starts, the app renews a two-second
session/display lease every 250 ms after the first media frame while Mac control
heartbeats remain current. Bluetooth congestion has a five-second peer grace
period; loss of Shizuku authorization ends the lease immediately. Failed restoration
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
checks keyguard lock for up to 500 ms, waits 500 ms before restoring physical panel
power, and wakes the phone through `IPowerManager`. It never wakes deliberately
without confirming the lock. A confirmed transition sends PHONE_ON to Mac. Mac shows a separate popup
headed **phone was used**, with **phone turned on** and the lock/restore result.
If confirmation fails, PHONE_LOCAL_USE reports that failure without claiming
success. Streaming ends in both cases; readiness remains available for the next
Mac-initiated session. Events are best effort if the radio link fails at that moment.

At session end, Mac posts **Phone was used remotely** through UserNotifications,
deduplicating stream-close/quit/disconnect callbacks. The phone's shell watchdog
starts a separate shell touch monitor and the companion's remote-use warning service,
including after capture-app death while Shizuku remains alive. The warning requests
Android Live Update promotion and stays visible until five seconds after the first
physical touch, including lock-screen touches. Later touches do not reset the timer.
The helper reads contact starts through `getevent -lt`, without injecting or consuming
input, and exits when the warning is dismissed, replaced, or its app process dies.
Starting a new stream clears an older warning. On devices without raw touch access,
unlocking or tapping the warning starts the timer instead. The warning service
also checks for an already awake, unlocked phone, so an unlock that precedes service
startup is not lost. Screen-on behind the keyguard alone never starts this timer.
The streaming card returns to background readiness before transport cleanup, so
blocked socket/guard cleanup cannot leave the ended stream promoted.
Readiness and streaming use separate notification IDs. Foreground ownership moves
back to readiness before the streaming card is cancelled, including when the user
has muted the readiness channel (Android can ignore updates to a blocked channel).
If launching the companion
fails, the companion attempts to start the same warning service directly; no separate
shell notification is posted. Android controls
Live Update eligibility and ordering; promotion is a request, not a visibility guarantee.
The end policy
commits an end once per session; stop, EOF, local takeover and Binder death cannot
post repeated audits for that session. The notification replaces the prior
phone audit entry rather than storing a screen recording or a full activity history.

Notifications are subject to OS permissions, Focus/channel settings and process
availability. A crash warning requires the companion warning service to start.
No implementation can guarantee a Mac
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

Bluetooth captures at roughly a 320-pixel short edge with up to 15 FPS, starting
at 128 kbps. The encoder recovers bitrate by 25% after each ten seconds of
continuous current output, capped at the same 128 kbps startup rate. When an encoded frame is more
than 250 ms old, bitrate decreases by 25%, at most once a second, down to an
64 kbps floor. Frames older than 500 ms trigger safe keyframe recovery and
halve bitrate without crossing that floor. Idle gaps do not count as healthy
throughput. The same profile is restored after Wi-Fi fallback. Wi-Fi retains
its explicit profile, and ordinary ADB encoding does not enable this controller.

The relay logs `window`, `inFlight`, `deliveredKbps`, `ackWaitMs` and encoded kbps
so a physical test can distinguish an ACK-limited sender from an overloaded
encoder. These are control policies, not end-to-end latency guarantees: transport
and decoding add delay, and links below the quality floor may still fall behind.

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
benchmark entry point; ordinary mirrors still require video-only records on `0xD001`.
The Mac checks the full sequence, reports actual received bytes/rate, and the script
rejects a result unless sender and receiver byte totals agree. An interrupted
connection is an invalid sample. The receiver duration spans first to last data,
including queue drain, while sender timing includes any blocked writes.

These measurements characterize transport capacity without concurrent BLE input;
leave headroom for BLE, retransmissions and encoded keyframe bursts before choosing
a video bitrate. A configured 64 kbps encoder target is not a measured radio limit.

## Recovery during an active transport change

Wi-Fi changes can invalidate the Mac's cached BLE input service even when the
Android capture session remains alive. The Mac now pauses BLE operations, rediscovers
the service and completes a fresh pairing proof within four seconds. The original
session nonce must match; an app replacement or restarted capture cannot inherit
an existing mirror. Classic video and the renderer sockets remain open.

Recovery characteristics `…a616` and `…a617` reconcile an ATT write or return read
whose callback CoreBluetooth discarded. The first reports the phone's next input
sequence with an HMAC bound to the fresh authentication challenge. The Mac retries
only the exact saved ciphertext when the phone proves that packet was not accepted;
otherwise it continues at the existing sequence. The second returns the last read
return packet, verified with its original MAC and sequence and delivered at most
once. Neither direction resets its counters or relaxes ordinary sequence validation.
Unsent commands stay queued until proof, recovery state and clock validation finish.
The Android return sender allows six seconds for this bounded rediscovery.

Video fallback retains the authenticated handoff nonce and exact received byte
offset. Wi-Fi's unacknowledged window is capped at 128 KiB rather than 2 MiB: the
larger window could leave over a megabyte to replay over Classic before another
upgrade was possible. The 40 ms moving-video ACK cadence provides credit for the
default 12 Mbps profile without that backlog. A silent network loss still requires
stall detection and replay, so a brief video pause is possible during a switch.

Validation by Jeffrey Turkstra on 2026-10-18: the paired phone completed
Wi-Fi → Classic → Wi-Fi with the same installed Mac helper and rendering process,
including real VideoToolbox playback and BLE service invalidation during Wi-Fi loss.
A separate session replayed 129,789 bytes, within the 128 KiB budget, and successfully
upgraded again. Phone Wi-Fi was restored after both tests. The portable handoff
suite passes, including Java/C recovery proof vectors, exact-ciphertext retry,
already-accepted input suppression, return replay, and unchanged decoder bytes.
