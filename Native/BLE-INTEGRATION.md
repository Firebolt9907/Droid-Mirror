# Integrated wireless ADB discovery

DroidMirror Android 0.19 now includes this bridge inside the companion app. See
[Android setup and migration](ANDROID-BRIDGE.md). The separate bridge APK is no
longer required with matching Mac and Android builds.

Bridge 2.2 includes a bounded launcher-icon PNG in each encrypted notification.
Mac validates its PNG format/dimensions and adds it as a UserNotifications image
attachment beside the text. The OS-owned source icon/grouping remains DroidMirror.
Unavailable/invalid/oversized icons fall back to text without blocking delivery.
Notification-click focus is requested once per click; retries never re-activate
the host or repeatedly raise its window.
Reconnect snapshots are sorted by Android posting time and delivered with passive
interruption level. Identical content updates are also passive; changed message
content is active. The receiver retains only bounded in-memory content hashes for
deduplication, not raw message text.

DroidMirror runs its BLE client in a bundled, UI-less **DroidMirror Notifications**
helper. The mirroring host keeps the pairing/settings menu but does not open a second
BLE connection. It uses the
BLE ADB Bridge v2.0 protocol now included in `BluetoothCompanion`. Install the
matching DroidMirror Android APK:
v1.9's plaintext protocol is intentionally not accepted by this build.

Launch DroidMirror and approve its Bluetooth permission once. The Android DroidMirror
background bridge must be enabled, and the Mac must already be paired for Wireless
Debugging. Pair encrypted BLE once using the steps below. The bridge sends the changing port; DroidMirror runs `adb connect`
using its saved phone address. The existing device refresh/auto-start flow then
launches scrcpy. BLE carries encrypted discovery, notifications and notification
actions, but not video or keyboard input.

## Pairing and notification setup

1. Install `outputs/DroidMirror-Bluetooth-0.19-debug.apk` on Android and enable
   **Notifications and wireless ADB → Enable background bridge**. Stop the old bridge.
2. On Android, select your paired Mac and tap **Pair Mac (mirroring and notifications)**.
3. On Mac, choose **DroidMirror → Pair Bluetooth…**, select this phone, paste the
   Android code and click **Pair Mac**. One action provisions both input and
   notification/discovery credentials; no ADB provisioning or pairing window is needed.
4. On Android, tap **Allow notification forwarding** and explicitly enable its
   notification-listener access in Settings. Allow DroidMirror notifications on Mac.
5. Authorize Shizuku in the Android app. DroidMirror uses its shell service to grant
   its own secure-settings permission and checks the result before reporting success.

The shared 256-bit pairing code stays in the existing per-Mac Android input pairing
store and per-phone Mac Keychain item. Notification credentials are derived with
HMAC-SHA256 and the label `DroidMirror notifications pairing v1`, and the Mac stores
that derived credential for its background notification helper. Re-pair once when
upgrading from the separate provisioning flow. Old independent notification trust
is ignored on Android, and the exported ADB pairing provider has been removed.
One notification phone identity is supported at a time. Granting Android notification
access remains a separate explicit OS permission.

## Security and actions

No notification content, endpoint or action is processed before mutual HMAC-SHA256
challenge authentication. Per-session HKDF-SHA256 keys are directional. Messages
use AES-256-GCM with authenticated directional sequence nonces and replay checks.
Only random nonces and authentication proofs are unencrypted. There is no v1
plaintext fallback. This is application-layer protection independent of BLE bonding.
Radio metadata and availability are not protected; this is not a formal security audit.

Confirmed-indication/write queues serialize fragments, bound memory, and reject
invalid messages. Authentication has a deadline. A failing advertiser is temporarily
quarantined on Mac to avoid immediately selecting the same untrusted peer.

Android filters ongoing, group-summary, own-app and SECRET notifications. Bridge
2.1 no longer adds its own blanket lock-screen redaction for PRIVATE notifications:
user-authorized forwarding uses only the content Android supplies to the listener,
preserving Android's own sensitive-content restrictions. This means readable
notification content can appear on Mac while the phone is locked. Content is not written to app logs,
but macOS stores delivered notifications in Notification Center. Existing delivered
content is not retroactively redacted when Android subsequently locks.
The last 16 eligible notifications are synchronized when connecting. New notification
deliveries are suppressed while a scrcpy session is running (including minimized
sessions); suppressed updates are not queued for replay. Removals still clean up
Notification Center. Closing scrcpy or Cmd+Q quits the mirroring host, locks the phone,
and restores its settings as before; the helper survives and resumes notification
delivery without a stream or an awake phone screen. Clicking a notification opens
mirroring and sends its action after the first visible frame.

The helper starts on the next DroidMirror launch and stays alive until logout/reboot
or until explicitly quit. It is not yet registered for automatic login startup.
Allow **DroidMirror Notifications** Bluetooth and notifications on Mac; this is a
separate macOS permission identity from the main app. The Bluetooth receiver menu
toggle disables the helper's BLE connection too.

Sign updates with `sh Native/sign-droidmirror.sh`, using the existing Apple
Development identity, not ad-hoc signing. Ad-hoc rebuilds change the Keychain access
requirement and cause repeated Always Allow prompts. The receiver caches its key
in memory, including failed reads, so reconnects do not repeatedly request access.
Explicit receiver configuration/re-pairing invalidates that cache.

The notification receiver checks both the notification and input services for
phones already connected to macOS before scanning advertisements. It rediscovers
the notification service when Android invalidates GATT handles, ignores callbacks
for retired characteristics, and temporarily skips candidates whose service setup
fails or times out. This avoids repeatedly selecting a stale input connection.

Session and window-visible events validate their actual sender PID through
`NSRunningApplication(processIdentifier:)`. The launcher can leave the host's
LaunchServices listing at PID -1; comparing heartbeats with that listing would
reject all session updates and keep notification delivery suppressed. With
DroidMirror open, verify this regression outside the sandbox:

```sh
xcrun swiftc -module-cache-path /private/tmp/droidmirror-notification-module-cache Native/NotificationRuntime.swift Native/NotificationHostProbe.swift -o /private/tmp/droidmirror-host-tests
/private/tmp/droidmirror-host-tests
```

Mac notifications expose up to three Android actions, including a single free-form
RemoteInput reply where supported. Opaque notification ID/version pairs identify
in-memory PendingIntents held only on Android; arbitrary remote intents are never
accepted. Expired/replaced notifications reject actions. Clicking queues an action
for up to 45 seconds, starts/focuses the host-managed stream, and waits for an actual
rendered frame in a visible window before sending. A minimized stream is restored.
No phone unlocking or Android security restrictions are bypassed. App-specific
PendingIntent/background-launch restrictions may still prevent an action.

The prior Mac bridge's `dev.bleadb.bridge.macos` / `tailscaleIP` preference is
imported on first use. DroidMirror stores its own copy under `DroidMirror.BLE.host`.
If no address is saved, it learns `ip` from Android. Use the DroidMirror menu's
**Wireless ADB over Bluetooth** submenu to change the address, check status, or
disable discovery. Quit the separate BLEADBBridge Mac app to avoid competing
Bluetooth clients. Discovery continues in the helper when the mirroring host quits.

If no mirroring process starts within 30 seconds of notification authorization,
DroidMirror sends one macOS notification per launch and continues discovery.
Successful connection removes the warning; quitting cancels a pending warning.
Allow notifications when macOS asks (or in System Settings > Notifications).

ADB connect attempts have a ten-second deadline; health checks have a five-second
deadline. Endpoint requests, reconnection watchdogs and connection acknowledgements
are retained from the original client. No Accessibility permission is used.

The Android companion's stock-Android Wi-Fi and ADB authorization requirements
remain unchanged. This integration does not bypass pairing or enable cellular-only
Wireless Debugging.

Build the integrated library:

```sh
xcrun swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache -emit-library -module-name DroidMirrorBLE -target arm64-apple-macosx14.0 -framework AppKit -framework CoreBluetooth -framework UserNotifications -framework Security Native/NotificationRuntime.swift Native/NotificationPresentationPolicy.swift Native/NotificationIconAttachment.swift Native/BLEController.swift Native/BLEIntegration.swift Native/BLEMenu.swift Native/DiscoveryNotifications.swift Native/BLESecurity.swift Native/AndroidNotificationBridge.swift -o outputs/DroidMirror.app/Contents/Frameworks/libDroidMirrorBLE.dylib
```

Run the no-device subprocess tests:

```sh
xcrun swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache -target arm64-apple-macosx14.0 -framework AppKit -framework CoreBluetooth Native/NotificationRuntime.swift Native/BLESecurity.swift Native/BLEController.swift Native/BLEProcessTests.swift -o /private/tmp/droidmirror-ble-tests
/private/tmp/droidmirror-ble-tests
```
