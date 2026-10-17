# Bluetooth startup timeouts

On October 16, 2026, the Mac unified log recorded four failed starts with
`API MISUSE: ... can only accept commands while in the connected state`
(10:48:10, 10:48:38, 10:49:02 and 10:49:20). The compatibility path called
`CBClassicPeer.openL2CAPChannel:` directly without establishing a baseband
connection. It could work when an existing connection happened to be available.
The helper now requests the baseband connection with the public asynchronous
`IOBluetoothDevice.openConnection:` API and opens L2CAP after completion.
An already connected device proceeds immediately; duplicate completion callbacks
cannot open a second channel. Each startup phase has its own 15-second deadline;
the Swift caller allows 50 seconds for all phases rather than killing the helper
after 20 seconds.

Other recorded starts opened L2CAP successfully and then expired during BLE
setup. Android logs show an existing Mac BLE connection when the per-session
GATT server is registered. The helper previously only scanned advertisements.
It now also retrieves peripherals already connected to the system that expose
the service UUID. These candidates still undergo the complete pairing proof and
clock authentication. This addresses a possible discovery failure; the historical
logs do not establish which BLE handshake step stalled. Every step now logs its
name, and timeout errors include the latest BLE stage. No keys, nonces, proofs or
screen contents are logged. Stale callbacks from other candidates are ignored,
and candidate changes clear the clock characteristic and authentication challenge.

Build and run the startup regression tests on macOS:

```sh
clang -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
  -framework Foundation -framework IOBluetooth -framework CoreBluetooth -framework Security \
  Native/ClassicBluetoothStartupTests.m Native/BleInputQueue.m \
  Native/BleInputCrypto.c Native/ClassicBluetoothWire.c \
  -o /tmp/droidmirror-bluetooth-startup-tests
/tmp/droidmirror-bluetooth-startup-tests
```

The tests exercise production startup methods with fake devices: disconnected
and already connected baseband startup, asynchronous and duplicate completions,
immediate connection failure, existing BLE connection reuse, rejected candidates,
and callbacks from old candidates. They do not exercise the radio or driver.
Repeated physical reconnects still need validation. A live session was left
running during these changes.

## Follow-up: discovery timeout reproduced

A subsequent six-attempt hardware run reproduced the exact `scanning for the
phone's BLE service` timeout once. The corresponding Android logs contained no
new accepted Classic session and no new BLE server/advertiser startup during
that attempt, despite macOS reporting the local L2CAP channel open. Five later
attempts completed BLE authentication (one-second video samples were too short
to reliably receive complete media frames).

The helper now waits for Android's complete, validated `DMBT0006` header before
starting BLE discovery. Until then it reports `waiting for Android to accept
the Classic session`. This distinguishes an unaccepted Classic session from a
BLE discovery failure and starts the BLE budget when Android is actually serving.

The helper also handles SIGTERM, explicitly closes its Classic channel and BLE
transport, and allows 250 ms for cancellation delivery before exiting. Previously
the app's `Process.terminate()` skipped all helper cleanup. A subsequent run using
the modified helper completed **6/6 reconnects**, each with authenticated BLE,
`STREAM_STARTED`, and complete HEVC media frames during a three-second sample.
Production-method regression tests also pass, including fragmented Android
header readiness. The built output app was updated and its signature verified.
These results support the cleanup change; six successes cannot establish a
long-term failure rate or exclude other radio/driver failures.


## Host injection leaking into the Bluetooth helper

The 16:18:19 report showed `DroidMirrorBluetooth` trying to load the BLE library
from `Contents/Helpers/Contents/Frameworks`. The native launcher injected the host
shim, and both the long-running Bluetooth helper and ProcessRunner commands
inherited that injection. The shim only excluded the notifications bundle; it
installed AppKit/task hooks in command-line children too.

The shim now requires both the actual `DroidMirrorHost` executable (from dyld,
not argv[0]) and the main app bundle identifier. It clears the injection variable
once loaded. Both Bluetooth helper launches and generic ProcessRunner commands
also explicitly remove `DYLD_INSERT_LIBRARIES` and the host PID environment entry.
The intended scrcpy UI injection remains explicitly configured by MirrorModel.

Run `bash Native/test-host-isolation.sh`. This builds a disposable app, launches
its host through the production native launcher, verifies host hooks are active,
then deliberately reinjects the shim into a helper and verifies it installs no
hooks. A real ProcessRunner child also verifies host injection is removed while
video configuration survives. Bluetooth startup fake-device regressions pass.

The reported `connecting to a BLE service candidate` deadline occurs before
pairing-proof verification. Android logs confirm that its input service was
registered and awaiting authentication. Fixing host isolation does not by itself
establish that the radio timeout is resolved; physical reconnects must be checked.

Two follow-up three-second hardware probes with host injection removed timed out
at the earlier `waiting for Android to accept the Classic session` stage. Android
readiness remained enabled with its foreground service running. No video frames
were saved. These runs verify neither recovery of the radio connection nor the
later BLE handshake; only the loader/isolation regression is confirmed fixed.
The rebuilt output Mac app was signed and verified. No Android APK change is
required for the host-isolation patch.


## Native channel streams replace the IOBluetooth wrapper

Following the persistent Classic acceptance timeout, the Android app's Java
thread stack showed `BluetoothReady` blocked in the shell listener's `accept()`.
Restarting the Android app recreated its listener but did not resolve the timeout.
macOS Bluetooth diagnostics reported successful PSM 0x1001 connections. A separate
public-IOBluetooth probe made Android accept but its pipe immediately broke while
the Mac never received its channel-open callback.

The successful diagnostic retained the CBL2CAPChannel returned by the existing
Classic-peer completion callback and opened its native NSInputStream/NSOutputStream
instead of converting it to IOBluetoothL2CAPChannel. The input stream now feeds the
unchanged wire parser; the output stream is kept open but never written. Stream
EOF/error ends the session, cleanup removes the stream delegate and run-loop
registration, and callbacks from closed streams are ignored. The old public API
remains the fallback on systems without Classic-peer selectors. No timeouts were
extended. Pairing and permissions are unchanged.

The first three-second physical probe authenticated BLE, received STREAM_STARTED,
and drained 32 HEVC frames at 468x1040 without storing screen content. Production
method tests also exercise native stream attachment, readiness only after the
Android header, delivered video bytes, zero reverse payload, cleanup and stale
stream events, alongside the existing baseband and BLE startup cases.


## PSM collision with Android system Bluetooth

The native-stream probe alone did not resolve repeated acceptance timeouts.
Android logs showed incoming connections on PSM 4097 routed to an existing
Bluetooth-system listener (`app_uid: 1002`), while the Shizuku listener
(`app_uid: 2000`) remained blocked in accept. Restarting only the shell listener
did not help. Even after restarting the Bluetooth stack, a system listener on
4097 appeared again. A later connection routed to the shell listener did stream
27 HEVC frames, confirming the routing difference mattered.

The coordinated Mac/Android update moves DroidMirror's fixed PSM from `0x1001`
to `0xD001`. Both endpoints must be updated together. The Shizuku user-service
version increases to 5 so an APK update replaces the old daemon instead of
retaining its old PSM. Pairing keys and user permissions are preserved.
The new PSM remains in the private range; another application explicitly using
that same PSM could still conflict. Dynamic negotiation is not implemented.


With the coordinated PSM update, the first physical attempt reached Android's
listener immediately, but then timed out connecting the BLE candidate. Three
subsequent attempts authenticated BLE, received STREAM_STARTED, and drained
41, 11 and 5 HEVC frames respectively in three-second samples. These results
separate the confirmed Classic routing problem from the remaining BLE issue.

The merged notification GATT server also had a link-wide authentication timeout:
it tracked every connected device, including mirroring clients that never used
notifications, and called cancelConnection. Notification rejection/revocation
now removes only its own subscription, queued messages, fragments and crypto
session. An idle mirroring peer is not required to authenticate to notifications.
Application pairing proof is still required before any notification data or
actions are accepted.


The Mac now also looks for existing links exposing the merged notification
service, since that link may predate discovery of the per-session input service.
A 20-second physical stream delivered 168 HEVC frames, exceeding the old
notification authentication timer. Its following reconnect authenticated but
failed with Android's `BLE return MTU too small`: a new input-server instance
started at MTU 23 on an existing link without a new MTU callback.
`BleLinkMtu` now shares negotiated MTUs between notification/input servers across
input-session recreation and clears them on physical disconnection. A valid,
non-prepared authenticated input write also supplies a conservative capacity
bound for a process that joined a link after its MTU callback. This avoids
assuming a larger size than the peer has demonstrated. The JVM regression covers
cross-service reuse, peer isolation, disconnect/reset, renegotiation, invalid
callbacks and the missing-callback fallback.


After the final APK installation, the phone's ADB endpoint changed from
pixel:39491 to pixel:34021. Validation was interrupted and the user reconnected
it. The installed GUI helper then logged PSM 0xD001 acceptance, complete BLE
pairing proof/clock authentication, STREAM_STARTED and WIFI_ACTIVE. Android
confirmed Streaming, successful return records, version 0.20, and the primary
user's WRITE_SECURE_SETTINGS grant. This active user session was left running.
The final sustained/repeated automated run did not complete, so this confirms
the current GUI session, not a measured long-term reconnect success rate.
