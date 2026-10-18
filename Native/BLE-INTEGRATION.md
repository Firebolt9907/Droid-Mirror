# Integrated wireless ADB discovery

DroidMirror Android 0.19 now includes this bridge inside the companion app. See
[Android setup and migration](ANDROID-BRIDGE.md). The separate bridge APK is no
longer required with matching Mac and Android builds.

Android 0.37 sends separate sender-avatar and content-media fields. Messaging
notifications have a native communication-avatar path, gated on the signed
`com.apple.developer.usernotifications.communication` entitlement. The current
local development build lacks a matching provisioning profile, so macOS retains
the DroidMirror source icon. Adding the entitlement without that profile causes
AMFI to reject the app at launch (verified with a disposable probe). Unprovisioned
builds use ordinary presentation and do not donate communication interactions.
Only actual notification pictures or image-message attachments appear on the
trailing side. Ordinary app alerts keep the system-owned DroidMirror source icon.
Images come from notification metadata without Contacts access or remote avatar
downloads. The Mac validates format, byte size, and dimensions before decoding.
Media thumbnails preserve aspect ratio. Image budgeting reserves space for
AES-GCM, Base64, and the encrypted BLE envelope.
Android MessagingStyle conversations include up to 12 recent messages, with
sender names and timestamps in the supplied order, bounded to 2800 UTF-8 bytes
of JSON. Older messages are dropped first when the wire budget is reached.
The Mac creates a separate retained card for each incoming message, identified by
source notification, sender, timestamp, text and occurrence. Repeated snapshots and
action-token refreshes keep retained cards unchanged; new incoming messages create
new cards. The receiver still resolves actions against the latest Android token. Replies restore only the card that macOS dismissed after Send, with a
fresh delivery identifier, and create a separate “You” card showing the reply.
That outgoing card shows sending, accepted, failed or unconfirmed state. Android
outgoing echoes do not create duplicate cards. Older cards use the current source
notification's action tokens. Phone removal clears every card for that source;
closing an individual Mac card preserves its siblings, and closing the last one
sends the Android dismissal. Delayed restoration is canceled when its card is
removed. Message state is bounded in memory; visible cards carry their message
and reply state in macOS notification metadata so the receiver can adopt them on
restart. Reply restorations are coalesced so fast Android acknowledgments produce one
card with the latest status. No separate message-history file is written. macOS still closes the
expanded reply editor after Send.
Notification-click focus is requested once per click; retries never re-activate
the host or repeatedly raise its window.
Reconnect snapshots are sorted by Android posting time and delivered with passive
interruption level. Identical content updates are also passive; changed message
content is active. The receiver uses bounded in-memory content hashes for alert
deduplication and retains message-card state for reply restoration.

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
invalid messages. Frames are capped at 512 bytes even with MTU 517, so image-bearing
notifications survive the platform’s ATT attribute limit. Authentication has a deadline. A failing advertiser is temporarily
quarantined on Mac to avoid immediately selecting the same untrusted peer.

Android filters ongoing, non-clearable, foreground-service, group-summary, own-app
and SECRET notifications. An update that makes an existing item ineligible also
removes its Mac copy. Bridge 2.1 no longer adds its own blanket lock-screen redaction for PRIVATE notifications:
user-authorized forwarding uses only the content Android supplies to the listener,
preserving Android's own sensitive-content restrictions. This means readable
notification content can appear on Mac while the phone is locked. Content is not written to app logs,
but macOS stores delivered notifications in Notification Center. Existing delivered
content is not retroactively redacted when Android subsequently locks.
The last 16 eligible notifications are synchronized when connecting. New notification
content arrives immediately over the authenticated BLE connection, including while
scrcpy is running or minimized. Removals clean up Notification Center. Closing
scrcpy or Cmd+Q quits the mirroring host, locks the phone, and restores its settings
as before; the helper survives and continues notification delivery without a stream
or an awake phone screen. Clicking the notification body opens mirroring and sends
the open action after the first visible frame. Replies and other buttons send
directly over BLE without opening mirroring. Remote-use history stays on Android; the Mac
clears history banners from earlier releases on its next launch.

Mac notification categories request explicit dismissal callbacks, including for
notifications without action buttons. Closing a Mac notification sends an encrypted
`dismiss` command to the phone's notification listener without opening mirroring or
unlocking the phone. Dismissals are retried in memory for up to five minutes if the
Bluetooth link drops and are cleared on acknowledgment or phone-side removal.
Android checks the notification's version, posting time, eligibility, and clearable
state before cancellation, so an old Mac alert cannot intentionally dismiss a newer
phone update. A newly paired phone never receives the old phone's queued commands.
Automatic banner timeout and programmatic Mac removals do not trigger dismissal
commands. Clearing a notification does not delete the underlying chat message.

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
reject session updates needed to target notification actions. With
DroidMirror open, verify this regression outside the sandbox:

```sh
xcrun swiftc -module-cache-path /private/tmp/droidmirror-notification-module-cache Native/NotificationRuntime.swift Native/NotificationHostProbe.swift -o /private/tmp/droidmirror-host-tests
/private/tmp/droidmirror-host-tests
```

Mac notifications expose up to three Android actions, including a single free-form
RemoteInput reply where supported. Opaque notification ID/version pairs identify
in-memory PendingIntents held only on Android; arbitrary remote intents are never
accepted. Expired/replaced notifications reject actions. Actions queue for up to
45 seconds and remain pending until Android acknowledges them. Replies and other
buttons send directly over the authenticated notification connection; they do not
require ADB, a mirroring window, or a visible frame. Only opening the source app
starts/focuses the host-managed stream and waits for a visible frame. A minimized
stream is restored. Unacknowledged writes are not automatically resent, because
Android may already have sent the reply; an expired receipt asks the user to check
the conversation before retrying. Unsent actions instead report a connection error.
No phone unlocking or Android security restrictions are bypassed. App-specific
PendingIntent/background-launch restrictions may still prevent an action.

Reply regression checks:
```sh
xcrun swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache Native/NotificationActions.swift Native/NotificationActionTests.swift -o /private/tmp/droidmirror-notification-action-tests
/private/tmp/droidmirror-notification-action-tests
xcrun swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache Native/NotificationConversationState.swift Native/NotificationPresentationPolicy.swift Native/NotificationConversationTests.swift -o /private/tmp/droidmirror-notification-conversation-tests
/private/tmp/droidmirror-notification-conversation-tests
```
Verified on-device with a temporary notification app: a reply submitted in macOS
Notification Center arrived unchanged through Android RemoteInput while no
mirroring host was running. The test app recorded text locally and was removed.
The final retained-card layout was also verified with a local native probe using
the production bridge: Notification Center retained three distinct requests for
the restored original message, the acknowledged “You” reply, and a subsequent
incoming message. No real conversation was messaged. Full live-phone verification
of that final layout remains limited by a Bluetooth authentication reconnect stall.

The prior Mac bridge's `dev.bleadb.bridge.macos` / `tailscaleIP` preference is
imported on first use. DroidMirror stores its own copy under `DroidMirror.BLE.host`.
If no address is saved, it learns `ip` from Android. Use the DroidMirror menu's
**Background Bluetooth** submenu to change the address, check status, or
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

Build the integrated app after ending active mirror sessions and quitting the app
and its background helper. The build stages and signs the complete bundle:

```sh
./build-app.sh
```

Run the no-device subprocess tests:

```sh
xcrun swiftc -module-cache-path /private/tmp/droidmirror-swift-module-cache -target arm64-apple-macosx14.0 -framework AppKit -framework CoreBluetooth Native/NotificationRuntime.swift Native/BLESecurity.swift Native/BLESession.swift Native/BLEController.swift Native/BLEProcessTests.swift -o /private/tmp/droidmirror-ble-tests
/private/tmp/droidmirror-ble-tests
```

Android 0.37 clears per-client authentication and queued indications when the
notification subscription changes. The Mac toggles a cached subscription off
before enabling it again. This lets the UI-less receiver authenticate anew when
Android replaces its GATT server or the helper restarts while another Bluetooth
service keeps the physical link alive.

## Idle BLE session interface

Core Bluetooth may retain duplicate notification service UUIDs after Android
replaces a GATT server. On October 18, the Mac repeatedly wrote handle `0x00b2`
(ATT write-not-permitted), while Android's live characteristic was `0x00a8`.
Reconnecting selected the same cached service and never completed authentication.
The receiver now tries each distinct service object once before reconnecting,
clearing subscription state, fragment queues and security state for each attempt.
Callbacks for a previously selected characteristic or service are ignored. Every
replacement candidate must complete the existing authenticated handshake; queued
commands are not replayed across candidates. This addresses stale service selection
without assuming that Classic/LE coexistence itself proves a transport failure.

The **Background Bluetooth** menu controls the authenticated background session
used by notifications, clipboard, links, media, task continuation, and hotspot
commands. **Automatically connect Wireless ADB** is a separate, default-off
option; saving the phone address does not restart the BLE session. BLE connection
status and legacy ADB status are reported separately.

Companions advertising `sessionHealth: 1` in the encrypted `ready` message support
an encrypted `ping` / `pong` exchange, correlated by request UUID. Idle operation
requires neither an ADB endpoint nor an ADB process. Older companions retain the
endpoint-request health fallback, but endpoint errors do not mark BLE offline.
The existing 10-second maintenance tick enforces handshake, request and stalled
write deadlines. A 12-second heartbeat deadline is checked on that tick, so a
missing response is normally detected within roughly 12–24 seconds.

`BLEController.request(_:expecting:timeout:id:completion:)` reports a matching
application response, timeout, session loss, or queue rejection. ATT write
acknowledgments are not application success. Deadlines use monotonic uptime and
include queue time. Requests are not retried across sessions: callers must decide
whether retrying an operation is safe. Link sharing uses this API; existing
notification and hotspot policies keep their feature-specific correlation.

Both peers bound outbound queues and schedule plaintext messages before sealing.
Health probes/replies take priority over waiting messages.
Up to four control messages may pass waiting file chunks before a chunk gets a
turn. Each encrypted message's fragments finish before the next message starts,
keeping directional sequence and reassembly checks intact. Notification snapshots,
updates and removals retain FIFO order. Queued messages expire after 60 seconds
(or the request's earlier deadline on Mac). An already-started message cannot be
retracted; a timeout can mean that an action ran but its confirmation was lost.

Session reset invalidates outstanding requests and clears clipboard transfers,
media proxies, continuation UI and pending hotspot/link actions immediately.
After service invalidation, the controller discards GATT handles and security
state, rediscovers, mutually authenticates with fresh session keys, and restores
feature subscriptions. These changes do not make replacing the mirroring input
service during an active mirror seamless; updates must still end that session
gracefully before replacement.

Validation:

```sh
bash Native/test-ble-session.sh
# Build the companion first so these tests use current Android Kotlin classes.
bash Native/test-integrated-ble.sh
```

Physical-device checks remain necessary for a locked phone, Bluetooth off/on,
companion update/restart, and simultaneous mirroring/file/control traffic.
