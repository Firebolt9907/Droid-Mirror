# Phone and Apple Music playback controls

Enable **Settings → Media playback → Sync phone and Apple Music playback**
(or the same toggle in the DroidMirror Bluetooth menu). Both devices need a
matching updated app, the Android background bridge, and an authenticated Bluetooth
pairing. The feature is off by default and works between mirror sessions.

- Phone players that expose an Android media session appear in the Mac's Now
  Playing controls. Supported controls are play, pause, next, previous and seek,
  according to the phone player's advertised capabilities.
- Apple Music on the Mac appears as **Apple Music on Mac** in Android's media
  controls and notification. Phone controls operate the current Music track,
  including shuffle and repeat (off → all → one). Both notification actions and
  media-session custom actions are provided; Android and watch software decide
  which controls to display. The notification uses a laptop icon.
  On Android 11 and later a public `MediaRoute2ProviderService` publishes and
  selects **Mac laptop** for this app's remote session, following the
  `music_server_android` implementation. The route is withdrawn on lease expiry,
  local playback priority, disconnect, or disabling sync. Output-chip rendering
  depends on the Android build. This describes playback already on the Mac;
  selecting it does not transfer a phone player's audio.
  Other Mac apps are not inspected or controlled.
- Title, artist, album, duration, position, playback state and available album
  artwork are synchronized. Covers are sent as compressed JPEGs over the
  same encrypted BLE connection and appear in both devices’ media controls.
  This does not transfer audio, download music, or synchronize two audio streams.
  Volume control and queue editing are not included. The actual Music playback
  queue is read through MediaRemote and published with Android's
  `MediaSession.setQueue()`, `ACTION_SKIP_TO_QUEUE_ITEM`, and active queue item ID.
  Compatible watch players can browse and select entries. Android's standard
  notification does not itself provide a scrolling queue; the media-session
  queue is available to controller clients that support one.
  Up to 32 entries (current plus upcoming) are requested, with the transmitted
  list shortened if needed to stay within the BLE message budget.
- Playing local media takes priority over the remote proxy on each device.
  The Android proxy is excluded from phone discovery to prevent feedback loops.

Grant Android notification access to DroidMirror so it can discover other players.
Music metadata and controls use the native MediaRemote adapter first. If that
interface is unavailable, a bounded AppleScript fallback may request permission
for **DroidMirror Notifications** to control **Music**. Allow that fallback in
**System Settings → Privacy & Security → Automation**. Music is never launched
just to poll metadata.
The Bluetooth menu and Settings show permission or connection status.
Music must have an available current track and persistent track ID; some radio
streams or unavailable tracks may not provide usable metadata or seeking.

Snapshots refresh about every two seconds and expire after eight seconds without
an update. Disconnecting, disabling sync, replacing the authenticated session, or
stopping the bridge clears proxy state. Controls use the existing encrypted,
sequence-checked BLE channel. Android binds its media subscription to one paired
Mac and a generation; delayed callbacks cannot send to a replacement subscription.
Commands target the last advertised session/track and are rejected if stale or
unsupported. Native controls recheck Music's process, current item, queue and
lease before dispatching to its resolved destination. The AppleScript fallback
rechecks the persistent track ID and rejects canceled or expired work.

Artwork is optional: players without an embedded cover retain the system fallback.
Covers are at most 512 pixels and 65,536 JPEG bytes, encoded at 85% quality
(with 384/256-pixel fallbacks for complex covers). Snapshots advertise a SHA-256
cover digest and Base64 length. Receivers pull 4,096-character chunks through the
same encrypted, sequence-checked, media-subscription-scoped channel. Only one
chunk is requested at a time, and the next snapshot retries a lost request.
Each message fits the existing BLE envelope; the full cover is not repeated with
every heartbeat. There is one bounded cover buffer per direction, discarded on
replacement or disconnect. Completion requires the advertised length and digest.
Oversized, malformed or missing artwork clears the previous cover without
interrupting playback controls. When native Music omits image data, the Mac uses
the track's numeric Apple catalog ID with Apple's lookup service and downloads a
512-pixel cover from Apple's HTTPS artwork CDN. This asynchronous fallback caches
the current cover; metadata and commands never wait for the network. Update both apps
for the new cover transfer and shuffle/repeat schema.

## Validation

```sh
bash Native/test-media-sync.sh
cd BluetoothCompanion
JAVA_HOME=$(/usr/libexec/java_home -v 21) ANDROID_HOME="$HOME/Library/Android/sdk" \
  ./gradlew --offline --no-daemon assembleDebug -x buildPeerTransport
cd ..
bash Native/test-media-protocol.sh
```

`-x buildPeerTransport` reuses an existing JNI transport build for this unrelated
media change; omit it when building a companion from a clean checkout.

The Swift test also compiles the Music AppleScript without executing it. This
requires LaunchServices access to the installed Music scripting dictionary; a
restricted shell may need permission to run the test outside its sandbox.

Tests cover high-quality artwork bounds, chunk framing, digest verification,
lost-request retry, replacement cleanup, metadata validation, action/target validation, lease expiry, opt-in,
authenticated routing, disconnect cleanup and local Music priority. They do not
confirm system UI presentation or Music Automation grants on a paired device.
For a live check: end any active mirror before updating both apps; enable syncing;
play a phone track and test Mac Now Playing; then pause phone playback, play Music
and test Android media controls. Try next/previous/seek/shuffle/repeat, check the laptop icon and output chip,
verify full-size covers on both sides, then test permission denial,
Bluetooth reconnect and disabling sync. Commands stop working at the eight-second lease deadline; visible proxies clear
on the next two-second cleanup tick (within about ten seconds of the last heartbeat).

## Battery reporting feasibility

Battery percentages can be exchanged as small authenticated status messages and
shown in DroidMirror on both devices with a modest implementation (roughly half
a day to a day including charging/unknown-state handling and tests).

Showing them in the operating systems' Bluetooth Settings is a different
integration. The standard BLE Battery Service is UUID `180F`, with Battery Level
`2A19`. Android could publish the phone battery beside the existing GATT service.
The Mac would also need a peripheral role to publish its battery in the reverse
direction. System Bluetooth pairing/identity, discovery, subscription and OS
battery-client support all need testing. Android's AOSP BAS client is gated by a
system configuration property and connection policy; advertising the service
alone does not guarantee Settings presentation. There is no public app API that
forces macOS Bluetooth Settings to display an arbitrary device's battery.

Estimate: a one-to-three-day device-tested prototype for standard BAS reporting
in both directions, followed by OS-specific investigation if Settings ignores
it; reliable native Settings display cannot be promised.

A phone BAS prototype (`180F`/`2A19`) with encrypted reads/notifications was tested:
the Mac successfully read the phone's real 99% battery, but its native Bluetooth
record still omitted the battery. The prototype was removed from the production
connection path because it did not provide the requested native Settings view.

An Android native-metadata prototype was also tested through Shizuku's privileged
shell identity (`BLUETOOTH_PRIVILEGED`). It successfully wrote the real Mac battery
(90% in the device test) to `METADATA_MAIN_BATTERY`, and a separate shell-side
35-second lease cleared the value to unknown after updates stopped. However,
Android's AdvancedBluetoothDetailsHeaderController hides the battery while
CachedBluetoothDevice.isConnected() is false or busy. That connection check requires
a connected LocalBluetoothProfile; the app's custom GATT/ACL connection does not
satisfy it. The native device-details page consequently still showed Connect and
no battery. The prototype was removed rather than shipping a misleading partial
integration or fabricating another profile's connection state.

The reverse standard BAS publisher is blocked on this Mac: Core Bluetooth rejected
`CBUUID("180F")` with `CBErrorDomain Code=8`, "The specified UUID is not allowed for
this operation." The Mac did not expose a built-in BAS when inspected from the
phone. Tested IOBluetooth paired-device setters did not populate its native battery
record. Do not claim native macOS Settings support based solely on a successful
GATT read; that OS integration remains unsupported on the tested system.

These results do not rule out implementing a recognized Bluetooth profile. A real
HID keyboard/mouse profile is a plausible fit for the app's existing input controls
and would address Android Settings' profile-connection gate. Today's idle UHID
keyboard is local to Android, and the proprietary BLE/Classic channels are not a
Bluetooth HID profile. A HID implementation needs real report descriptors, profile
registration, host/device role handling, bonded-peer restrictions and battery-report
tests in each direction. Classic HID is a separate path from the Core Bluetooth
peripheral UUID restriction; public examples include
[darwin-bt-remote](https://github.com/jqssun/darwin-bt-remote). Android provides
[BluetoothHidDevice](https://developer.android.com/reference/android/bluetooth/BluetoothHidDevice).
HID profile registration and actual native battery presentation have not been
validated for DroidMirror yet.

References: [Bluetooth assigned numbers](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Assigned_Numbers/out/en/index-en.html),
[AOSP BAS client](https://android.googlesource.com/platform/packages/modules/Bluetooth/+/refs/heads/main/android/app/src/com/android/bluetooth/bas/BatteryService.java),
[Android route providers](https://developer.android.com/reference/android/media/MediaRoute2ProviderService).

## Music queue adapter

Public Music scripting and macOS MusicKit do not expose the system Up Next queue.
`MusicQueueHelper.m` independently accesses MediaRemote's local route controller,
requests its real playback queue, and accepts only the `com.apple.Music` owner.
It resolves Music explicitly so phone playback in DroidMirror's Mac proxy cannot
hide Music behind the global Now Playing owner. The same snapshot supplies title,
artist, album, duration, position, playing state, shuffle/repeat modes, artwork when
available, and the controls Music currently advertises. AppleScript is a fallback
with a two-second timeout; its failure no longer clears a valid native player.
The helper runs as a small dylib loaded in a short-lived `/usr/bin/perl` process,
using the compatibility approach documented by
[mediaremote-adapter](https://github.com/ungive/mediaremote-adapter). No Droppy
binary or third-party implementation is bundled. The host and notification
receiver do not load MediaRemote. Input is bounded JSON on stdin, output is
bounded JSON on stdout, and the parent terminates a child exceeding four seconds.
Missing APIs, exceptions, mismatched metadata and unavailable queues remove queue
controls while leaving existing Music controls available. Private APIs may need
adjustment after macOS updates.

The Mac keeps native content IDs, process identity and queue identity locally.
Android receives a queue revision and numeric IDs scoped to that revision, so a
watch callback retained from an old queue cannot silently target a different row.
Queue payloads are separate `mediaQueue` messages, sent on revision changes through
the existing authenticated, encrypted, sequence-checked media subscription.
Android clears the queue on snapshot replacement and hides it when its lease
expires, local playback takes priority, or sync stops.

Selecting an entry requires a fresh track snapshot and matching queue revision.
The child re-reads Music's live owner, current item, queue identity and ordered
content IDs and checks the command deadline immediately before dispatch. It sends
the currently advertised PlayItemInPlaybackQueue command with the content ID and
validated queue offset to the resolved Music destination, never to a new global Now Playing
owner. Disabling sync cancels a pending child and discards its results.

Validation includes Swift wire-format/selection tests, Android queue parsing and
revision tests, and Objective-C owner/order/membership/expiry tests. Live queue
retrieval was checked on macOS 27; paired watch presentation and actual remote
song selection still require a device check.

Recovery check (2026-10-21): the installed receiver reported “Apple Music metadata
unavailable” while Android's proxy had `active=false` and empty metadata. A signed,
LaunchServices-launched probe reproduced Music AppleEvent timeout `-1712` even on
its player-state query. Native Music access remained responsive when explicitly
targeted. The repair prioritizes native playback data and controls and retains
AppleScript as a bounded fallback. After a graceful atomic Mac update, live checks
confirmed native Music connection and Android's active media session/notification.

Android device check (2026-10-21): the Pixel 8 received album artwork, a 14-item
queue, and the native shuffle/repeat state. The output selector showed “Mac laptop”
after the provider established a routing session and its controller ID was passed
to the remote VolumeProvider. Initial provider discovery can wait until the screen
is on and the app is foregrounded; Android restricts background route scans.
Active Material icons preserve the upstream SVG even-odd fill rule, and the route
declares TYPE_REMOTE_COMPUTER so System UI selects a computer device icon.

Transport regression check (2026-10-21): NextTrack must not include the current
item ID or playback-queue offset in its command options. Music interpreted those
queue-selection options as a request to restart the current item. Item selectors
are now restricted to explicit queue selection; transport and mode changes carry
only their own options. A live corrected Next command advanced from “Picture You”
to “After Midnight”. Music's AppleScript shuffle query separately timed out with
media sync disabled as well as enabled, so disabling DroidMirror did not resolve
the AppleEvent failure observed alongside Droppy's loading indicator.
After installation, Next invoked through Android's DroidMirror MediaSession also
advanced from “After Midnight” to “Naked In Manhattan”, confirming the Bluetooth
command path uses the corrected adapter.
