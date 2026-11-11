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

The original #2 sampling and arming remain: an initial nearby success arms it;
scan for 20 seconds at most once per minute after significant movement. Alert
confirmation is configurable; the original two-miss/45-second rule is now the
Fast option, with a safer Balanced default as described below. Separations expire after ten minutes. A
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

## Trusted places

Open **Trusted places (pause detection at Home, etc.)** in Android settings. Add
your current position with a name and a radius from 100 to 5000 metres (default
200 m). Up to 20 circles are supported; individual places can be removed. A fresh
fix no older than two minutes, with accuracy at least as good as the radius, is
required to save. The freshly saved centre is initially considered inside once
background permissions are available. DroidMirror stores these circles locally;
Google Play services provides geofence delivery.

This feature is optional and off until enabled or a place is saved. It requires
precise location and **Allow all the time** on Android 10+, plus Android Location
enabled. The location prompt is separate from the Bluetooth reminder permission
flow. Android 11+ requires opening app settings to grant background location.
No device permission is granted by the build/install scripts.

Inside any trusted circle, stop scans, reset pending separation state, and clear
the reminder in either presentation mode. On exit, deletion, disablement or loss
of location availability, resume from a fresh warmup; the beacon must be seen
nearby again to rearm. A previous absence from inside the place is never replayed
as a departure alert. Overlapping circles remain trusted until the last is left.
Removed/unknown geofence IDs are ignored.

Android geofences can report transitions a few minutes late, particularly in the
background or indoors. There is no continuous app GPS loop. If permissions,
Location settings or geofence registration are unavailable, trusted-place
suppression is inactive and ordinary beacon detection continues; settings shows
the reason. Enter/exit receivers persist membership, registrations are restored
on app start/reboot/update, reboot clears stale membership, and replacements
serialize removal/addition to avoid late removals erasing a newer registration.

Tests cover radius/coordinate validation, stale/inaccurate fixes, overlapping
places and stale callbacks after deletion. Background transition latency and
location permission flows still require device testing after installation.

## Confirmation thresholds and backpack false alerts (2026-10-30)

**Alert confirmation** offers these presets. Both conditions must be met:

- Fast (original): two completed missed scans and at least 45 seconds after the
  first missed scan.
- Balanced (new default): three missed scans and at least two minutes after the
  first miss.
- Conservative: five missed scans and at least four minutes after the first miss.

Actual delay from leaving radio range is longer and depends on scan phase and
Android scheduling. To let longer confirmation complete after one significant
motion event, scanning/eligibility remains enabled for two minutes in Fast, four
minutes in Balanced, and six minutes in Conservative after that event. This is
recent movement evidence, not proof of continuous walking. No-motion events do
not invent movement. Mode changes reset evidence and clear an existing reminder;
nearby beacon presence must arm the new policy. Counters/history remain intact.

These thresholds are evidence rules, not calibrated confidence percentages. Any
received beacon, including a weak one, resets absence. RSSI is diagnostic only;
there is no signal-strength cutoff that would turn a shielded-but-nearby Mac
into an absent one. Successful scan logs now include advertisement count and
strongest RSSI, and missed scans include the last successful signal/time.
Settings shows confirmation progress and alerts store the selected rule and
evidence at posting time. No extra scan frequency or active connection is added.

The phone's latest read-only history showed an alert at 14:25:48 and the beacon
returning at 14:27:48 on 2026-10-30. That does not identify whether the interruption
was sleep, shielding, or interference. Without another reliable signal, a Mac
that stops advertising for minutes is indistinguishable from one left behind.
Stricter confirmation reduces short-dropout false positives at the cost of later
real alerts; it cannot guarantee that carrying a sleeping Mac never alerts.

The receiver now stays disconnected through sleep instead of being woken about
every 48 seconds (see `IDLE-BLE.md`). macOS stops app advertising during sleep, so
a sleeping Mac now advertises only during occasional maintenance wakes. Expect more
of the false alerts described above when the phone moves while the Mac sleeps.
