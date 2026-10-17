# Bluetooth input traffic audit

The installed Mac build limits consecutive absolute mouse MOVE/hover positions
to 60 Hz for sustained movement and retains the newest unsent position per 16.7 ms source-time bucket for the same
pointer and button/display state. Clicks, releases, keys and other state changes
are ordering barriers. The final position flushes before a barrier. Direct mouse drags and trackpads have no
phone-side smoothing. Physical wheel commands alone use local phone playback. Resolution and the video profile are unchanged.

The queue reassembles scrcpy messages across arbitrary TCP read boundaries and
packs ready input envelopes into available ATT payload space. It does not wait
for a full packet. Video ACK priority and one in-flight GATT operation remain.

| Activity | Rate / trigger | Goes to phone? |
|---|---|---|
| Absolute pointer moves and hover | 60 Hz cap; latest position and source event time retained | BLE input writes |
| Mouse buttons and keyboard | Actual state changes; OS key repeat retained | BLE input writes |
| Trackpad drag/scroll | Position updates use the same 60 Hz cap | BLE input writes |
| Discrete mouse wheel scrolling | Direction/distance commands, at most 30 Hz; summed during backpressure | BLE writes; Android synthesizes touch movement locally every 16 ms |
| Video ACK plus liveness | Every 250 ms, cumulative unsent ACKs coalesce | BLE, about 4 records/s; may share a write with input |
| Control/event return reads | 500 ms idle target, plus immediate reads until empty | BLE requests, about 2/s idle; timer scheduling can lower this |
| Phone heartbeat echoes | At most once per second | Phone-to-Mac BLE replies |
| Bridge socket servicing | Every 20 ms | Local sockets only unless data or an ACK is due |
| BLE watchdog | Every 200 ms | Local state checks; initiates a read only when due |
| Device refresh | Every 3 s while not mirroring | Local bonded-device enumeration in Classic mode |
| Toolbar placement / installation | Local timers | No Bluetooth messages |
| ADB lock/PIN checks | Disabled for Bluetooth | No phone polling on the Bluetooth path |
| Shizuku lease heartbeat | Every 250 ms | Internal phone Binder call, no Bluetooth traffic |

Physical mouse wheels now use a dedicated 21-byte type-24 command containing
an anchor/video size and signed horizontal/vertical distance. Commands are
coalesced at 30 Hz, and adjacent unsent commands sum their distances. Android
runs the continuous touch gesture locally every 16 ms, eases toward the pending
distance, re-anchors long bursts, and releases after settling. Clicks, keys,
trackpad gestures, display remapping and shutdown cancel wheel playback.
Mouse hover is ignored while this synthetic finger is active so it cannot
become a second pointer in the gesture.

Only phase-less, non-precise events without momentum use this path. Trackpad
phases, precise deltas and existing momentum handling keep the previous path.
High-resolution mouse wheels reported as precise also conservatively retain
the old path. No wheel smoothing is applied to direct mouse drags.

At the maximum command cadence, input envelope payload is 30 × (21+5) =
780 bytes/s, versus approximately 36 × 3 × (40+5) = 4860 bytes/s for the old
wheel touch triplets (about 84% fewer application bytes). This is a protocol
estimate before encryption/ATT overhead, not a measured radio throughput gain.
Video remains one-way over Classic; all wheel commands use authenticated BLE.
There is no other 1000 Hz polling loop sending data to the phone in the audited
Classic/BLE application path. OS Bluetooth scheduling and acknowledgements are
outside these application rates.

Validation: a deterministic 1000 Hz input producer emitted 59 position records
in one second; the test accepts 58–60 depending on interval rounding. Tests also
cover newest-coordinate selection, immediate release flushing, key/pointer
barriers, ACK progress, TCP fragmentation, ATT packing, and large control payloads
whose bytes resemble motion records. A native-to-Android fixture confirms that a
101 ms gesture remains 101 ms despite simulated delivery jitter. The original
SDL event time is carried through the bounded queue, coalescing, BLE clock
mapping, Android parsing and MotionEvent injection. There is no navigation
classifier or generated Home shortcut in this timing change.

Large fast swipes exposed a second coalescing error: replacing all queued MOVE
samples could leave a 100 ms gap. Android's real VelocityTracker measured zero
velocity for that collapsed trajectory. Keeping 60 Hz source-time history
produced seven MOVE samples, a 17 ms maximum gap and -8000 px/s for the same
101 ms upward swipe on the Pixel. This probe never injects input.

The copied Meson cache also pointed to a different source checkout. build-app.sh
now validates its configured source path and wipes/reconfigures generated build
files when it differs from this workspace. The packaged client is checked for
the source-timestamp implementation marker.

Wheel validation covers strict mouse/trackpad classification, signed distance
summing and overflow, state-change barriers, fragmented transport, native C
serialization and Android decoding, local frame pacing, reversal, long-scroll
rebasing, cancellation and final release. Companion 0.10 requires the matching
Mac build; its Shizuku service version is 28 so the persistent daemon refreshes.
