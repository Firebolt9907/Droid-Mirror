# Phone apps in Spotlight

The background receiver creates small, user-owned launcher bundles in
`~/Applications/Droidmirror/`. It registers them with LaunchServices; Spotlight
must have Applications enabled and must not exclude this folder. Indexing latency
is controlled by macOS and still needs validation on the target Mac.

Every launcher contains the same small native executable, the Android app label,
a stable identifier, an icon, and a URL carrying the paired phone identity and
launcher component. Filenames use the app label; actual collisions use readable numbers such as
`App (2).app`. Opaque identities stay in bundle metadata and identifiers. Existing
hash-suffixed launchers are renamed in place, preserving icons and launch targets. Nothing requires writing to `/Applications`.

Opening a launcher starts the installed background receiver, which validates the
phone identity and cached catalog membership, requests/focuses the existing host
mirror. Cold launches wait for a fresh visible-frame report from a verified host
PID. Warm launches reuse prior frame readiness only with a current, verified
active-session heartbeat; they focus the renderer directly and dispatch at once.
For hidden/new viewers, a per-click presentation token keeps the loading cover
opaque while the phone opens the app. The renderer reads it before focusing or
presenting its first frame. Android's shell launch uses `am start -W`; the reply
includes the phone's monotonic display-confirmation timestamp. Fade/zoom/unblur
begins only when a decoded frame's capture timestamp is at least that value.
Frame readiness can authorize dispatch underneath the cover, so waiting for the
app never deadlocks waiting for a reveal. Already visible viewers are not covered
or reanimated. Cancellation, failure and lease expiry release the presentation
hold; stale acknowledgments cannot release a newer click's token.

It sends `appLaunch` over the existing authenticated, sequenced BLE
channel. The phone checks current launcher membership and Shizuku authorization,
resolves only the requested launcher component on a separate launch worker (no
full-library scan or artwork queue), waits up to 25 seconds for the existing mirror unlock flow, checks keyguard again
in the shell service, and launches the explicit MAIN/LAUNCHER component. An
unconfirmed launch is never replayed. The Mac's unsent request expires after 60
seconds; a newer unsent click replaces the previous destination.

## Onboarding and catching up

* Pull paginated metadata first (eight apps per response), publishing each page
  immediately so searchability does not wait for artwork. Only a complete snapshot
  permits removal of obsolete generated bundles. User-created apps are preserved.
* Check the catalog every 15 seconds while connected. Unchanged revisions produce
  a small acknowledgment instead of retransmitting the library. On reconnect,
  cached metadata repairs missing launchers without requiring a fresh icon sync.
* Fetch 48px previews for all missing icons before any optional 256px artwork.
  Existing launchers retain their prior icons during an update; completely new
  apps initially use the DroidMirror icon and remain launchable throughout.
* When a catalog reveals at least 12 new/changed/removed apps, or 12 uncached
  high resolution icons, attempt a dedicated Iroh bulk connection. The first
  metadata page is still published immediately. A fresh capability and direct
  address hints are exchanged over authenticated BLE; the new endpoint derives
  its own `phone-library`/`mac-library` identities and uses only
  `droidmirror/app-library/1`. Video and audio endpoints are independent. The
  library endpoint has no public discovery or relays, and does not require an
  active mirror session.
* Iroh carries only catalog/icon reads, with monotonic request sequence numbers,
  a one-use session capability, one outstanding request and 32 KiB icon chunks.
  App launches remain on BLE. A dial/handshake failure continues on BLE; a broken
  icon transfer restarts that icon at offset zero to respect BLE chunk alignment.
  Retry attempts are limited to once a minute. End the lane when sync drains,
  BLE authorization is lost, it is idle for 15 seconds, or its five-minute lease
  expires. Older companions keep using BLE without attempting an upgrade.
* On BLE pull one 768-byte icon chunk at a time with a 40ms yield between chunks;
  Iroh yields 2ms between chunks. Both paths yield 100ms between icons. Phone-side artwork uses the bulk queue, allowing
  control traffic to take priority. Both rendering and filesystem work use
  background queues. There is no unsolicited artwork stream or parallel flood.
* Verify component, version, dimensions, offsets, total size and SHA-256 before
  accepting an icon. Persist completed PNGs keyed by phone/component/app version;
  reconnects reuse them. An interrupted individual icon restarts, while completed
  icons do not. Failed artwork is retried after a minute without resetting BLE.
* Remove obsolete cache versions after complete snapshots. Prefer retaining small
  previews when trimming high resolution cache entries to a 64 MiB target.

256px artwork is sufficient for Retina Spotlight icons. These pacing values are
conservative defaults, not measured latency guarantees; a large first sync can
show placeholders while artwork catches up. Real phone timing and Spotlight
ranking need end-to-end measurement before claiming the catch-up is invisible.

The catalog covers enabled, exported launcher activities in the companion's
current Android user. Work profiles/private spaces require separate user-aware
catalog and launch support. No attempt is made to bypass profile locks.

## Validation and updates

Run `cargo test --locked --manifest-path PeerTransport/Cargo.toml` (local socket
permissions required) to check separate identities, ALPN and library progress
while video is blocked. Run `bash Native/test-phone-app-library.sh` for threshold,
successful catalog upgrade, failed dial, mid-icon fallback and incremental
publication, duplicate names, safe filenames, app pruning, mirror readiness,
unconfirmed-launch behavior, chunked progressive icons and ICNS decoding.
The background receiver publishes `appLibrary` diagnostics with the negotiated
transport, app count and successful Iroh read count. A missing folder before the
first valid catalog can mean the installed Android companion is too old; there
is no separate enable switch. Build/install both platforms together.

The Android compile covers the AIDL interface, Shizuku implementation and runtime
routing; Mac BLE sources and receiver must also compile/link together.

Live validation on the Pixel 8 on October 29, 2026 confirmed 281 generated
launchers indexed by Spotlight, clean display names, and catalog reads over the
separate Iroh channel. A GroupMe warm request was confirmed by the phone in
288 ms with unchanged host/viewer PIDs. This measures command confirmation,
not the app's first rendered frame or a cold connection.

The task URL Shizuku user service is version **8** for this implementation and
logs `Launcher displayed via Shizuku v8` on a dispatch attempt. Before installing
an APK/Mac build, gracefully end any active mirror using the existing update
workflow. Verify replacement of the old `task_urls` service process and the v8
runtime marker before treating device observations as validation of this code.
