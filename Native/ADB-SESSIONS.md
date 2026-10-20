# ADB session recovery and phone Live Activity

DroidMirror's ADB client passes `droidmirror_session=true` to the bundled server.
This enables recovery for a video stream of the main phone display. Standalone
scrcpy invocations and the Bluetooth companion's embedded controller retain their
own lifecycles.

The server checks Android's logical interactive state every 50 ms, after first
observing it awake. Physical panel-off does not count as sleep. A power/screen-lock
action stops capture and closes stream sockets, confirms keyguard, restores the
physical panel, and wakes the phone. The cleanup subprocess preserves this wake
even with `--power-off-on-close`; the Mac recognizes the successful local-use
marker and restores settings without injecting another Sleep key.

While streaming, user activity with NO_CHANGE_LIGHTS prevents an ordinary idle
timeout without lighting the panel or changing the user's timeout settings.

Before capture begins, the shell server starts the companion's
`AdbStreamService` and allows up to eight seconds for a phone-local Binder handshake while the
encoder warms in parallel. Codec metadata may pass during preparation; captured
frames stay gated until successful preparation and a fresh keyframe.
The service decrypts an optional saved screen-lock PIN and sends it only to that
shell process for one pre-video unlock attempt. A failure or interrupted attempt
starts a 15-second automatic-entry cooldown. During that cooldown the normal
streaming path remains available for manual unlock. A new connection after the
cooldown may retry the PIN; there are no automatic background retries. The PIN never travels
over the ADB connection to the Mac. Older companions attach without a PIN;
without a companion, mirroring retains its manual unlock behavior.
The foreground stream notification now appears during this preparation step. Version 0.12 or newer of the companion is required for the phone
Live Activity; power-button recovery works without it. The service reuses the
Bluetooth notification's promoted status, details, dismissal and Stop Mirroring
action. Companion 0.22 adds **Minimize** to the notification and stream
details. For ADB streams it sends an encrypted `minimizeMirror` event over the
existing paired background BLE bridge. Companion 0.24 instead uses the already
authenticated capture BLE return channel (event 7) for Bluetooth/hybrid streams,
so a disconnected background discovery receiver does not drop the command.
The Mac routes commands using the owning helper's parent PID or a fresh session
heartbeat rather than LaunchServices, which can report PID -1 after the launcher
execs the host. The mirror window remains borderless and supports Dock minimization;
capture continues. For USB/ADB streams the background bridge and authenticated BLE
connection must already be available. Stale session actions are
ignored and action tokens are canceled when a stream ends.
Android's promotion support and user notification settings still apply.
No Bluetooth readiness or Shizuku authorization is needed for ADB sessions.

The exported service requires Android's DUMP permission (available to ADB shell).
A per-session Binder tracks server death, removes stale notifications and handles
Stop Mirroring. Notification action tokens and callback generations prevent old
sessions from stopping a newer one. The service is not sticky and removes its
foreground notification on server exit or death.

After building the client/server and installing the companion, run:

```sh
python3 Native/test-adb-session.py --server /path/to/built/scrcpy-server
```

The device test exercises disconnect, stale and current notification actions,
promoted notification cleanup, and a synthetic Power press. It records only to a
temporary directory, deletes recordings afterward, and finishes at awake keyguard.
