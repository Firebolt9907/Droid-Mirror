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
  remain. Legacy peers retain polling.
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
