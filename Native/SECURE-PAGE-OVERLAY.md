# Secure-window placeholder

Black video is a fast candidate signal. It never shows the secure-page overlay by
itself: a WindowManager check must confirm a visible secure window first. YouTube's
ordinary black transition frames therefore do not show a secure-page message.

The shared Android scrcpy Controller starts a SecureWindowMonitor for screen capture.
It sleeps until the renderer detects a black-frame candidate. Then it runs
`/system/bin/dumpsys -t 1 window windows` as shell, inside the Shizuku user
service for Bluetooth/peer sessions and inside the shell server for direct ADB.
It requires no persistent desktop ADB connection for Shizuku sessions.

The monitor parses each window separately, matches the captured display, and checks
`fl=SECURE` (or FLAG_SECURE / numeric bit 0x2000), `mHasSurface=true`,
`isOnScreen=true` and `isVisible=true`. Fully obscured windows are excluded.
Hidden secure windows and secure windows on other displays do not trigger the UI.

The renderer checks black-frame candidates at most five times per second, supporting
software YUV420/NV12 and VideoToolbox IOSurfaces without full-frame downloads. It sends
control message 26 with a boolean and a four-byte generation when candidate state changes.
The worker wakes immediately for a black candidate and refreshes every 500 ms only
while that candidate remains active, including static screens with no new video frames.
Normal video immediately hides the warning, invalidates pending replies and sends a
cancel command that stops polling and kills an in-flight query. No commands run during
normal video. A cancelled query's late result cannot apply to a later black episode.

Each query has
Android's one-second dump timeout, a 1.5-second process-kill deadline, and a 2 MiB
output bound. It never holds the display-recovery watchdog or the controller input
thread. Stopping the controller interrupts the monitor and kills its current query.
No dump files or app/window titles are persisted or sent to the Mac.

Results are CLEAR=0, SECURE=1, UNKNOWN=2. Failed, timed-out or unsupported queries
produce UNKNOWN. Device message type 4 carries a state byte and a four-byte candidate generation
through the existing control channel; Bluetooth/peer sessions retain their BLE authentication and sequence
checks. Repeated samples recover from sender queue drops and late UI attachment.
The C receiver dispatches results to the main thread; only SECURE shows the existing
input-transparent overlay after a 350 ms debounce. CLEAR and UNKNOWN hide it.
The overlay also expires after three seconds without a secure-state refresh, and
session stop invalidates pending shows. Only matching responses for the current
black-screen generation can show the overlay.
Pixel detection alone never shows a warning.

The PIN-specific keyboard prompt check is still gated by secure state and must
independently confirm that Android is actually showing its PIN prompt.

Limitations: the candidate gate requires a fully black page (allowing the Android
navigation pill). Partially obscured/protected regions do not trigger a query.
The confirmation detects window FLAG_SECURE, not all possible capture restrictions.
Independently secured SurfaceViews, DRM buffers, device policy and sensitive-content
protection can block capture without exposing this flag. WindowManager visibility
and obscuration approximate actual composited visibility. Dump format differences
may produce UNKNOWN; that suppresses the message rather than guessing from black video.

Update both endpoints together. Stop an active mirror gracefully before APK/service
replacement. The Shizuku service version is bumped so a new session loads this code.

Validation:

```sh
sh Native/test-secure-window.sh
# Optionally validate the parser against connected-device metadata:
adb shell dumpsys window windows > /tmp/droidmirror-window-dump.txt
sh Native/test-secure-window.sh /tmp/droidmirror-window-dump.txt
```

`Native/SecureOverlayProbe.m` checks overlay attachment, debounce, repeated refresh,
recovery, stale-state expiry, session cleanup and input passthrough against the built
native style library. Black-frame candidate tests and monitor scheduling tests check that normal video causes
no shell queries, static black pages refresh, and cancelled/late results cannot reopen
a warning. Wire tests cover request/reply fragmentation and BLE command packing.
