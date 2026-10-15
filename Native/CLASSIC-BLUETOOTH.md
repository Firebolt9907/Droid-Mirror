# Bluetooth Classic: Mac-initiated mirroring

Version 0.3 replaces the per-session MediaProjection workflow. After one-time
phone setup, pressing **Mirror on the Mac** opens the secure Bluetooth connection
and starts the embedded scrcpy 5 capture engine in a Shizuku shell user service.
There is no Android-managed screen-share prompt and no ADB or LAN connection in
the streaming path. Shizuku must be running and authorized; this is not a bypass
of Android's ordinary app permissions. Remote input and audio remain ADB-only.

## Install and set up once

The compiled Android test APK is `outputs/DroidMirror-Bluetooth-0.5-debug.apk`,
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
RFCOMM listener cannot accept the Mac's stream attempt. Use an independently
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

Rebuild the Mac for the 0.3 framed transport and events. The new helper also accepts
old raw 0.1/0.2 video streams, but those APKs retain their old capture prompts and
cannot report the new events. Checked-in Mac binaries are not updated here.
Use the documented development-signing workflow if preserving the existing BLE
notification helper's Keychain identity; the build script signs ad-hoc.

## Video and control events

The Bluetooth profile starts with H.264 at a 64,000 bit/s target, up to 8 fps and about a
480-pixel short edge, aligned down to 16 pixels while preserving aspect ratio.
The encoder uses constant bitrate without hard quantization limits, no B-frames,
and gradual intra refresh when supported. Repeated idle frames refine settled text
without forcing large periodic keyframes. Encoder constraints and
fallback may reduce the actual dimensions/rate. The
radio negotiates Classic/EDR itself; the app cannot force an EDR PHY rate.

The secure RFCOMM UUID is `c356a44e-6f2b-4da9-85e5-397991b8a603`. Android owns the
bonded-peer listener; the Shizuku daemon owns capture and recovery. A file-descriptor
pipe transfers scrcpy video from the shell service to the app's Bluetooth relay.
No screen content is saved. The matching wire format is dummy byte, 64-byte device
name, codec ID, then scrcpy 5 session/frame packets, preserving decoder/renderer
compatibility, rotation metadata, and protected-content restrictions.

The current stream begins with `DMBT0004`, followed by records comprising a
one-byte type, a four-byte big-endian length, and payload. Type 0 carries video
in chunks of at most 1 KiB. Type 1 is a one-byte event: PHONE_ON (1), SESSION_ENDED
(2), PHONE_LOCAL_USE (3), STREAM_STARTED (4), CAPTURE_FAILED (5), ALIVE (6).
Type 2 carries scrcpy control replies. The Mac parser routes video and control
to separate loopback sockets. Mac-to-Android records carry raw scrcpy control
bytes (type 0) or a heartbeat carrying an eight-byte cumulative video byte count
(type 1); Shizuku injects the controls. Acknowledgements run every 100 ms and
limit unacknowledged video to 12 KiB so radio queues cannot grow ahead of input.
The Android reader also recognizes the older empty heartbeat.
Heartbeat replies use a separate worker so video backpressure cannot block the
input reader. Malformed lengths/types/events close the connection.

The loopback listener accepts one client and is not authenticated local IPC; a
local process can race to connect. Radio access relies on secure system Bluetooth
bonding and the saved peer address, independent of the older BLE notification
bridge. The relay rejects encoded packets over 128 KiB and closes Bluetooth writes
blocked for five seconds when peer heartbeats have also expired. Live peer input
keeps ordinary radio backpressure from being mistaken for a dead connection.
The Mac bounds pending video to 128 KiB with a one-second
pending deadline. The encoder discards stale frames only with keyframe recovery, reducing bitrate when the stream falls behind. The capture pipe is capped at 4 KiB on Android 11 and newer.

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

Adaptive bitrate and static-screen resolution tiers remain follow-on work. Add
measured receive-rate/queue-delay feedback first, then adjust MediaCodec bitrate
with fast decreases and slow increases. Fixed higher resolution with fewer static
frames is less visually disruptive than toggling resolution after every scroll.
If resolution tiers are used, require sustained motion/stillness, preserve the
viewport, and send new session metadata/configuration/keyframes at each switch.
