# Phone and Apple Music playback controls

Enable **Settings → Media playback → Sync phone and Apple Music playback**
(or the same toggle in the DroidMirror Bluetooth menu). Both devices need a
matching updated app, the Android background bridge, and an authenticated Bluetooth
pairing. The feature is off by default and works between mirror sessions.

- Phone players that expose an Android media session appear in the Mac's Now
  Playing controls. Supported controls are play, pause, next, previous and seek,
  according to the phone player's advertised capabilities.
- Apple Music on the Mac appears as **Apple Music on Mac** in Android's media
  controls and notification. Phone controls operate the current Music track.
  Other Mac apps are not inspected or controlled.
- Title, artist, album, duration, position and playback state are synchronized.
  This does not transfer audio, download music, or synchronize two audio streams.
  Artwork, volume control and queue editing are not included.
- Playing local media takes priority over the remote proxy on each device.
  The Android proxy is excluded from phone discovery to prevent feedback loops.

Grant Android notification access to DroidMirror so it can discover other players.
When Music is running and syncing is enabled, macOS requests permission for
**DroidMirror Notifications** to control **Music**. Allow it in **System Settings →
Privacy & Security → Automation**. Music is never launched just to poll metadata.
The Bluetooth menu and Settings show permission or connection status.
Music must have an available current track and persistent track ID; some radio
streams or unavailable tracks may not provide usable metadata or seeking.

Snapshots refresh about every two seconds and expire after eight seconds without
an update. Disconnecting, disabling sync, replacing the authenticated session, or
stopping the bridge clears proxy state. Controls use the existing encrypted,
sequence-checked BLE channel. Android binds its media subscription to one paired
Mac and a generation; delayed callbacks cannot send to a replacement subscription.
Commands target the last advertised session/track and are rejected if stale or
unsupported. Music rechecks the persistent track ID before executing a command.
The Music scripting queue also rejects canceled or expired work.

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

Tests cover metadata validation, action/target validation, lease expiry, opt-in,
authenticated routing, disconnect cleanup and local Music priority. They do not
confirm system UI presentation or Music Automation grants on a paired device.
For a live check: end any active mirror before updating both apps; enable syncing;
play a phone track and test Mac Now Playing; then pause phone playback, play Music
and test Android media controls. Try next/previous/seek, permission denial,
Bluetooth reconnect and disabling sync. Commands stop working at the eight-second lease deadline; visible proxies clear
on the next two-second cleanup tick (within about ten seconds of the last heartbeat).
