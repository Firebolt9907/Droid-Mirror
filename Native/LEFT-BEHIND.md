# Mac left-behind reminders: selected beacon detector

The selected implementation is the former **#2 passive BLE beacon**. Experiments
#1 (link loss), #3 (reverse GATT challenge), and #4 (Classic RFCOMM challenge) have
been removed from the runtime, Mac endpoints, and selection UI. Normal mirror
Bluetooth authentication and sequence checks remain unchanged.

## Final selection, 2026-10-29

The read-only phone snapshot showed #2 with 5 correct, zero incorrect, and 2
unanswered feedback events. #3 had 7 recorded correct, 6 recorded incorrect, and
2 unanswered; allowing for the user's one known accidental incorrect vote gives
8 correct and 5 incorrect (about 62% precision among answered alerts). #4 had no
successful probes and never armed. #1 was already rejected as too noisy.
These results favor #2 for this user's hardware and usage; they do not establish
recall or reliability across all sleep/power settings. Historical votes are not
rewritten because the accidental event is unidentified.

## Operation

Enable **Mac left-behind alerts** and **Show left-behind reminders** in Android's
background features settings. Allow Nearby Devices/scanning and notifications.
On Android 11 or earlier, scanning also needs Location permission and Location
enabled. The bridge and the paired Mac's DroidMirror receiver must be running.
Significant-motion sensor support is required.

The Mac advertises a pairing-specific service UUID. The phone only scans for
this beacon: it never connects to a Mac GATT presence service, opens a Classic
presence socket, or enumerates other bonded computers. The beacon is a discovery
hint, not an authenticated presence proof; it grants no command/session access.

The original #2 policy and timing remain: an initial nearby success arms it;
while significant movement is recent (two minutes), scan for 20 seconds at most
once per minute. Two completed missed rounds and at least 45 seconds since the
first miss can trigger a reminder. Separations expire after ten minutes. A
successful scan rearms the next separation. Unavailable/interrupted scans reset
the miss streak. Android idle modes can delay callbacks. Radio ownership during
mirroring is respected; those scans are unavailable, never invented successes.

## Presentation

**Use Live Activity until Mac returns** is optional and off by default:

- Off: a normal notification that clears when the Mac beacon is detected again
  or the user dismisses it.
- On: an ongoing Live Activity, using the same Android promotion request as the
  recently-mirrored indicator. It clears when a completed beacon scan detects the
  Mac again or the user presses Dismiss. There is **no fixed timeout**. Devices
  without Live Activity promotion show an ongoing notification with the same
  lifecycle. Android/system settings control actual promotion.

Both modes have only a **Dismiss** action. Correct/Incorrect controls have been
removed. The selected mode is attached to each notification, so changing settings
only affects future reminders. Either type of posted reminder clears on return
even if the preference is changed while it is visible. Bridge shutdown, trust
reset, and disabling the feature clear reminders in either mode.

## History and compatibility

Original #2 notification, preference, and database IDs are retained. Historical
#1/#3/#4 counters and old decisions are preserved as archived data and never
renumbered. Reset counts clears only the selected detector's counters; it does
not erase decision/lifetime history. New dismissals are logged as unanswered with
the observed posted lifetime and end reason; returning-Mac dismissal of either type of reminder is logged separately by reason. Old action PendingIntents are still
understood for compatibility, but new notifications expose no rating controls.

Counts mean notify() submissions, not separately visible banners/sounds. Clock
changes do not distort monotonic lifetimes. If removals were missed while the
process was stopped, the log marks the last observed lifetime as uncertain;
reboots yield unknown durations. Only the most recent records are shown in the
settings UI; the SQLite log retains the full history.

## Validation and updates

Run `bash Native/test-left-behind.sh` for selected-policy, UUID compatibility and
lifetime checks. Run `bash Native/test-ble-session.sh` to compile/link the actual
Mac receiver and check session behavior; build Android with `:assembleDebug`.

End active mirroring gracefully before updating either app. This change affects
app-process detection and receiver advertising, not code loaded by the Shizuku
display guard; it does not require a display-guard user-service version bump.
Radio behavior, Live Activity promotion, and return-to-Mac dismissal still need
hardware validation after installing the matching apps.

See `docs/presence-experiment-archive.md` for the retired experiments and earlier
field trials.
