# DroidMirror for Wear OS

Implemented by Jeffrey Turkstra. The companion has exactly three features:

- **Privacy stop:** end the active phone mirror through the phone notification's existing session-scoped disconnect action. Bluetooth, direct Wi-Fi upgrades and ADB use their ordinary cleanup paths. A stop request is not treated as proof that capture has ended.
- **Battery glance:** phone and Mac battery percentages with charging state. Unknown readings and Macs without an internal battery show Unavailable. Battery exchange also works without a watch: the Mac's Background Bluetooth menu shows phone battery, and the phone's background-feature settings show Mac battery.
- **Find my Mac:** ring the selected, authenticated Mac for 12 seconds, with a visible Stop sound button on the Mac. Uses existing output volume; requires the Mac to be awake and connected. The watch reports missing acknowledgements rather than claiming the sound played.

## Galaxy Watch Now Bar

The watch uses the same AndroidX `OngoingActivity` notification pattern as
`~/Github/apple-tv-app/wear/.../NowBarPublisher.kt`. While mirroring is active,
the ongoing entry opens the watch app directly to its prominent End mirroring
button; the notification also has an explicit End mirroring action. The chip
itself opens the controls, so touching the chip does not accidentally disconnect.
Allow watch notifications when prompted. The entry clears when the phone reports
session completion and expires after 35 seconds without a fresh heartbeat.
Galaxy Watch software controls the precise Now Bar presentation. Physical Galaxy
Watch verification is still required; no watch/emulator was attached during development.

## Build and install

The module is `BluetoothCompanion/wear`. It targets Wear OS devices with API 30+
and requires a paired Android phone with Google Play services. Phone and watch
use the same application ID (`app.droidmirror.bluetooth`) and **must be signed
with the same certificate** for Data Layer communication.

```sh
cd BluetoothCompanion
JAVA_HOME=$(/usr/libexec/java_home -v 21) ANDROID_HOME="$HOME/Library/Android/sdk" \
  ./gradlew :assembleDebug :wear:assembleDebug
```

Debug outputs:

- Phone: `BluetoothCompanion/build/outputs/apk/debug/DroidMirrorBluetooth-debug.apk`
- Watch: `BluetoothCompanion/wear/build/outputs/apk/debug/wear-debug.apk`

Both debug modules use the same local Android debug key. For release builds,
`tools/build-release.py` now produces and signs `outputs/DroidMirror-WearOS-release.apk`
with the same configured keystore as the phone APK. The script still installs
only the phone and Mac; install the watch APK separately using its ADB serial.

End active mirroring before updating any companion component. Update the phone
in place to retain pairing, rebuild/update the matching Mac app using the normal
project workflow, and install the watch APK on the watch:

```sh
adb -s WATCH_SERIAL install -r outputs/DroidMirror-WearOS-release.apk
```

Open DroidMirror once on the watch and allow notifications. Keep the existing
phone background bridge enabled. Mac battery and Find my Mac require the updated
Mac receiver and phone bridge. Privacy stop can also operate on an active ADB
session when the phone's idle Bluetooth bridge is stopped.

## Automatic development installs

`./build-app.sh` detects the `android.hardware.type.watch` feature on authorized
ADB devices and attempts to build/install the watch APK on each connected watch.
It selects phones separately, so a phone and watch can both be connected without
triggering the multiple-phone error. Watch installation failures are reported and
the Mac update continues. Devices with unreadable feature lists are skipped.

- `ANDROID_SERIAL` selects the phone when multiple phones are connected.
- `DROIDMIRROR_WATCH_SERIAL` optionally selects one connected watch.
- `DROIDMIRROR_SKIP_WATCH_INSTALL=1` skips watch installation.
- `DROIDMIRROR_SKIP_ANDROID_INSTALL=1` skips both phone and watch installation.

All installs use `adb install -r` to retain data. Watch updates do not automatically
launch its UI; open it once to grant notifications. The build script still ends
active mirroring gracefully before replacing components.

## Transport and lifetime

Watch–phone traffic uses live `MessageClient` messages; no commands or stale
session DataItems are persisted. The watch discovers the phone's advertised
`droidmirror_phone` capability and rejects ambiguous phone targets. The phone
checks that commands originate from a connected Data Layer node. Data Layer
requires matching package/signature identities; the watch receives no Mac keys.

The phone sends bounded snapshots about every ten seconds and on session changes.
Each snapshot carries a short-lived lease scoped to its destination watch, mirror
session token and Mac connection ID. Commands require that lease plus the current
target; expired leases and superseded sessions are rejected. Requests are deduplicated.
The watch uses a monotonic 35-second status deadline and notification timeout.
Unavailable status does not imply that a mirror ended; stop is disabled until a
fresh status arrives.

Mac battery snapshots, reverse phone battery reports and Find commands use the
existing AES-GCM, sequence-checked BLE channel. Routing is restricted to the
phone's selected Mac and the exact authenticated BLE session that supplied the
snapshot. Mac commands additionally require a recently issued ticket (35-second
lifetime), connection ID and unique request ID; reconnecting invalidates tickets.
Sounds are rate limited and stop on disconnect. Mac status queued for BLE delivery
expires after five seconds. No new GATT services or authentication bypasses are added.

## Validation

```sh
bash Native/test-wear-companion.sh
cd BluetoothCompanion
JAVA_HOME=$(/usr/libexec/java_home -v 21) ANDROID_HOME="$HOME/Library/Android/sdk" \
  ./gradlew :assembleDebug :wear:assembleDebug :wear:lintDebug
```

Tests cover expired/future/unknown tickets, replay, reauthentication, stale watch
leases and targets, exact-session stop routing, canceled PendingIntents, late
completion from an earlier session, battery validation and disconnect cleanup.
The full Mac Bluetooth integration also compiles and links with the companion.

Device checklist: start/stop a Bluetooth mirror and a Wi-Fi-upgraded mirror;
repeat with ADB; confirm the phone panel restores and the Now Bar entry clears;
start another mirror and verify an old notification cannot stop it; check charging
and unknown battery states; ring and dismiss the Mac sound; disconnect either link
and confirm unavailable state, shortcut expiry and command failure feedback.

API references: [Ongoing Activity](https://developer.android.com/training/wearables/notifications/ongoing-activity),
[Data Layer and package/signature matching](https://developer.android.com/training/wearables/data/overview).
