# Idle BLE change-only synchronization

Updated Android peers advertise `changePush: 1` in the authenticated ready event.
The existing ten-second ping/pong and connection watchdog remain responsible for
link health. Cached state is scoped to the authenticated connection; reconnects
establish fresh baselines. No components are installed or restarted by this change.

- Task continuation negotiates `changeOnly` on subscription. Android continues
  checking the foreground task locally, but sends URL/package/task/icon data only
  when changed, including a clearing event when no URL remains. The Mac retains a
  negotiated suggestion until replacement or disconnect; legacy peers keep their
  eight-second lease and refreshes.
- Mac name/battery and phone battery push only changes. Connection IDs prevent
  reuse across reconnects. Find My Mac fetches a fresh ticket on demand through
  `watchTicketRequest` / `watchMacTicket`, then uses the existing authenticated
  command, 35-second ticket expiry and replay checks. Watch-to-phone UI leases
  still renew independently over Wear OS; they are not traffic on the Mac BLE link.
- Android endpoint publication suppresses identical per-session payloads, including
  unchanged unavailable state. Explicit discovery requests still receive replies.
  New Macs stop periodic ADB endpoint requests; local endpoint discovery still runs
  and publishes actual address/port changes. Initial state is sent after handshake.
- New Macs subscribe with `appCatalogSubscribe`. Android debounces package,
  locale/configuration and external-app events, rescans locally and pushes a new
  catalog revision only when changed. The Mac then fetches the changed catalog,
  retaining pagination, bulk-channel and retry behavior. Initial/reconnect scans
  remain. Delivery revisions are tracked per authenticated subscriber, so a local
  scan cannot consume an invalidation before it is pushed and multiple Macs remain
  independent. Legacy peers retain polling.
- Notification reposts compare bounded visible content and current PendingIntent
  bindings. Identical reposts retain the advertised action version while updating
  the local notification source. Predictable activity timers use the existing
  local-clock normalization; ordinary static notifications retain changed digits.
  Meaningful content or binding changes get a new action version and are sent.
  Removal, snapshots, authentication, sequence checks and current-notification
  validation remain intact.

Validation: Android Kotlin/Java compilation, full Mac receiver compilation,
focused task/battery/catalog regressions and integrated BLE authentication,
fragmentation, activity-patch and predictive-timer tests. Device radio traffic has
not been measured; this documents code behavior, not an over-the-air benchmark.

## System sleep

A closed-lid incident on 2026-11-04 kept the Mac about 90% awake. bluetoothd
attributed all 60 AP wakeups in that window to this app's link (59 `LE Data`, one
`LE Disconnection`), and the loop sustained itself:

1. At sleep macOS clears the app's Bluetooth session and reports state `Off`, but
   keeps the physical link. Android still has an authenticated session and sends.
2. That data wakes the Mac within seconds, and powerd holds the dark wake for
   about 45 seconds.
3. State `On` used to trigger a full reconnect. Every feature resubscribed, and the
   phone pulled the whole Music cover again in 4,096-character chunks, which was
   the sustained writes on the endpoint characteristic.
4. The Mac slept mid-transfer. Android retried its chunk request, which started
   the next wake.

Now `NSWorkspace.willSleepNotification` ends the phone's subscription and
disconnects. Android revokes the session on the descriptor write, which stops its
senders, so this needs no Android update. The write can lose the race with
bluetoothd clearing the session. If the phone then wakes the Mac, the state `On`
handler connects only to finish the release. It never authenticates during sleep.
NSWorkspace reports no edges for a dark wake, so one sleep spans all of them.

`didWakeNotification` reconnects and authenticates once. The phone's snapshot and
media state then catch up. Failed reconnects back off from 1 second to 60. User
input after going to sleep also resumes, in case a wake notification is missed.

The presence beacon is unchanged and restarts in any dark wake. With fewer dark
wakes it is on the air less, so see the sleep limits in `LEFT-BEHIND.md`.

Validate with the closed-lid test on battery: run it once with DroidMirror quit as
a baseline, then with the phone connected. Check `AP wakeup by` in bluetoothd's log
as well as `pmset -g log`, since it names the app behind each wake.
