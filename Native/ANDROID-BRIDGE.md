# Android bridge inside DroidMirror

DroidMirror Android 0.20 incorporates BLE ADB Bridge 2.2's encrypted wireless ADB
endpoint discovery, notification forwarding (including app icons), notification
opening, actions, and free-form replies. The adapted Kotlin sources live under
`BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/bridge/`. They were
imported from the local project
`/Users/rishu/Documents/Codex/2026-09-18/referenced-chatgpt-conversation-this-is-an/android/`.
The bridge retains its v2 service UUIDs and wire protocol, alongside DroidMirror's
separate authenticated input service. The Android package remains
`app.droidmirror.bluetooth`, so existing capture setup survives an update.

## Setup / migration

1. Install `outputs/DroidMirror-Bluetooth-0.20-debug.apk` over DroidMirror.
2. Stop the separate **BLE ADB Bridge** app's background service. Disable its
   notification access to avoid duplicate forwarding. Uninstalling it is optional.
3. Open **DroidMirror → Notifications and wireless ADB**, grant Nearby Devices,
   and choose **Enable background bridge** (also available on the main setup
   screen). One service owns mirroring readiness, discovery and notification
   forwarding; closing a mirror session leaves that service ready.
4. Start Shizuku and tap **Authorize Shizuku** in DroidMirror. Once authorized,
   the existing Shizuku shell service grants only DroidMirror's
   `android.permission.WRITE_SECURE_SETTINGS`, for the calling app's Android user.
   The grant is checked in the app after the shell command completes. Setup and
   the running background bridge retry this when authorized Shizuku becomes
   available. **Grant secure settings with Shizuku** provides a manual retry;
   no computer or copied ADB command is needed. Granting this permission does
   not require or acquire a capture/display lease. The RPC has no configurable
   package, permission or command parameters, and the command has a five-second
   deadline. Android's trusted Wi-Fi requirement still applies; Wireless debugging
   can also be enabled manually.
5. Select your Mac in Android's main setup and tap **Pair Mac (mirroring and
   notifications)**. On the Mac choose **DroidMirror → Pair Bluetooth…**, select
   this phone, paste the displayed code and click **Pair Mac**. That one action
   saves input pairing and notification/discovery pairing. The notification
   setup screen links to this same Android pairing screen.
6. On Android, tap **Allow notification forwarding** and enable
   **DroidMirror notification forwarding**. Mac Bluetooth and notification
   permissions for **DroidMirror Notifications** are unchanged.

The separate app's pairing and notification access do not transfer between
Android packages. If upgrading from 0.18 or older, paste the existing mirroring
code once into the matching Mac build to configure notification pairing too.
No need to regenerate the code or use authorized ADB for BLE pairing. The old
60-second pairing window and exported pairing provider have been removed.
Android derives the notification credential from the selected Mac's existing
32-byte input pairing code with HMAC-SHA256 and the domain label
`DroidMirror notifications pairing v1`. The Mac saves the same derived credential
alongside its existing per-phone input key in Keychain and tells the notification
helper to reload its cached key. The input master is never sent over BLE.
Selecting a different Mac resets existing notification authentication; neither
missing selection nor a missing code creates credentials from a BLE request.
The old standalone notification credential is not a fallback. One selected Mac
and one notification phone identity are supported at a time. Notification-access
permission still needs the user's explicit approval in Android Settings.

The bridge is opt-in and remembers one enabled state. On upgrade from 0.17 or
older, it stays enabled if either previous background service was enabled. Both
setup screens control that same persisted state. It resumes on DroidMirror launch
or boot where Android permits foreground-service startup. **Stop background
bridge** stops mirroring readiness, any active Bluetooth mirror, discovery and
notification forwarding together, and persists across launches/reboot. Discovery
and notifications do not require Shizuku or a selected capture Mac. Once a Mac is
saved, the same service starts capture readiness too. `CaptureService` owns a
`BridgeRuntime`; there is no separate Android `BridgeService`, service binding,
or bridge foreground notification. The shared notification uses ID 1 and becomes
the stream Live Activity while capturing. Session audit (2) and active ADB
streaming (3) remain session-specific. Bluetooth off/on restarts discovery
advertising while the shared service is running.
ADB port changes publish on the existing connection instead of forcing a disconnect
that could disrupt BLE input. mDNS candidates are verified against a local ADB
listener so a different phone's announcement is not forwarded.

## Build and checks

From `BluetoothCompanion`, with JDK 17+ and Android SDK 36 configured:

```sh
./gradlew assembleDebug lintDebug
```

From the repository root after building Android:

```sh
bash Native/test-integrated-ble.sh
```

The cross-language test uses the actual APK's compiled Kotlin classes and JVM-only
Android clock/Base64 stubs. It checks mutual authentication, invalid proofs,
directional AES-GCM, tampering, replay, duplicate handshakes, and fragmentation
against the Mac Swift implementation using the shared derived pairing key.
Native C and Android Java also check an independently generated derivation vector.
Mac selection, absent/malformed codes, and removal of legacy trust fallback are
covered by JVM tests. The same script verifies legacy settings
migration, fresh installs, explicit stop/re-enable across simulated reboots, and
failed migration persistence using JVM preference stubs. `build-app.sh` rebuilds the Mac BLE library,
including the unified pairing menu and status. For an existing Mac bundle, rebuild
that library using the command in `BLE-INTEGRATION.md`, then sign with
`sh Native/sign-droidmirror.sh` to preserve Keychain access.

Build, lint, and protocol checks do not validate physical BLE radio coexistence.
Device validation should cover simultaneous mirroring/notification delivery,
notification click and reply after first frame, ADB port changes, Bluetooth
power cycling, service stop/start, reboot, and re-pairing with active sessions.
Android notification access remains explicitly user granted; see Android's
[notification listener documentation](https://developer.android.com/reference/android/service/notification/NotificationListenerService).
Long-running Bluetooth communication uses a connected-device foreground service,
following [Android background BLE guidance](https://developer.android.com/develop/connectivity/bluetooth/ble/background).

The Mac build also rebuilds the native launcher, host lifecycle shim and background
notification receiver. Keeping the launcher separate from the Swift host ensures
the receiver starts when DroidMirror launches and receives key-cache refreshes
after shared pairing. Signing uses the existing development identity.

The permission grant uses Shizuku's [documented user-service API](https://github.com/RikkaApps/Shizuku-API)
to run with the already authorized shell/root identity. The actual device grant
remains subject to Android/OEM permission policy.

Use `python3 tools/app-bundle.py install outputs/DroidMirror.app /Applications/DroidMirror.app`
to replace an installed Mac build. It stages a fresh bundle and preserves previous
files instead of copying over mapped signed code. See [Mac updates](MAC-APP-UPDATES.md).


The notification GATT server shares its physical link with mirroring input.
Notification authentication failure clears that protocol session without calling
`cancelConnection` on the shared link. Negotiated ATT MTUs are shared through
`BleLinkMtu`; input-server recreation does not reset a still-connected link to
23 bytes. Authenticated non-prepared writes provide a safe lower capacity bound
when joining a connection after its MTU callback.
