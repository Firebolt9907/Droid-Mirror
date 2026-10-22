# Bluetooth input traffic audit

DroidMirror disables mouse hover forwarding for both Bluetooth and ADB sessions.
Mouse movement without a held button is discarded by the client before it reaches
the control queue, so it sends no input traffic and triggers no phone hover animations.
Clicks, releases, dragging and scrolling still send their coordinates normally.

The Mac build limits consecutive absolute mouse drag MOVE positions
to 60 Hz for sustained movement and retains the newest unsent position per 16.7 ms source-time bucket for the same
pointer and button/display state. Clicks, releases, keys and other state changes
are ordering barriers. The final position flushes before a barrier. Direct mouse drags and trackpads have no
phone-side smoothing. Physical wheel commands alone use local phone playback. Resolution and the video profile are unchanged.

The queue reassembles scrcpy messages across arbitrary TCP read boundaries and
packs ready input envelopes into available ATT payload space. It does not wait
for a full packet. Video ACK priority and one in-flight GATT operation remain.
Updated companions deliver encrypted return packets through acknowledged BLE
indications. A return read can otherwise remain outstanding in CoreBluetooth,
holding input and video/lease acknowledgements behind it until the session ends.
Indications keep that server-to-client transaction separate from input writes.
Older companions retain alternating return reads and ready input writes. BLE work
runs on a dedicated serial queue with interactive QoS.

Background notification snapshots also use confirmed indications. An unconfirmed
notification's completion callback can precede delivery, allowing fragment loops
to fill the Bluetooth transmit queue and stall mirror GATT transactions. The
notification endpoint therefore advertises indications, keeping each fragment
pending until the Mac acknowledges it instead of filling the shared radio queue.

| Activity | Rate / trigger | Goes to phone? |
|---|---|---|
| Mouse hover (no held button) | Discarded before the control queue | No |
| Absolute pointer moves while dragging | 60 Hz cap; latest position and source event time retained | BLE input writes |
| Mouse buttons and keyboard | Actual state changes; OS key repeat retained | BLE input writes |
| Trackpad drag/scroll | Position updates use the same 60 Hz cap | BLE input writes |
| Discrete mouse wheel scrolling | Direction/distance commands, at most 30 Hz; summed during backpressure | BLE writes; Android synthesizes touch movement locally every 16 ms |
| Video ACK plus liveness | Every 40 ms with moving video, 250 ms while idle; unsent ACKs coalesce | BLE, up to 25 records/s while moving and 4/s idle; may share a write with input |
| Control/event returns | Encrypted indications when subscribed; no idle polling | Older companions use 500 ms idle reads, alternating with input |
| Phone heartbeat echoes | At most once per second | Phone-to-Mac BLE replies |
| Bridge input socket | Readiness callback as soon as data arrives; 20 ms housekeeping fallback | Local sockets only unless data or an ACK is due |
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

The control socket uses TCP_NODELAY for prompt small replies. Input readiness
wakes the bridge without waiting for its video/housekeeping timer, removing up to
one 20 ms polling interval from that stage. This is an application scheduling
bound, not a measured end-to-end radio improvement. Regression tests forward
socket input without any polling timer and interleave 100 authenticated input
packets with a continuous return stream, checking sequence/order, single-operation
ATT serialization, immediate reply draining when idle, and empty-read backoff.

The input ATT watchdog allows four seconds for an outstanding read/write, below
the phone's five-second peer lease. This tolerates slow startup completions, but
extending the deadline alone does not repair a blocked return read. A delayed write
stays in flight, newer cumulative video ACKs coalesce, and the next authenticated
sequence is sent only after completion. Service recovery keeps its separate
bounded rediscovery and authenticated sequence reconciliation.

READY waits for the return subscription to complete. Indicated packets retain
the same per-session encryption, strict receive sequence and recovery replay
proofs as polled packets. Incoming indications do not reset the deadline of an
outstanding input write. Regression coverage sends 100 cumulative ACKs while
withholding all returns, checks that no read is issued, then verifies encrypted
return delivery and duplicate rejection during an outstanding input write.

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

## Shared-link regression validation (2026-10-21)

Unconfirmed background notifications reproduced Android L2CAP transmit congestion,
return status 129 and stalled Mac ATT writes. Confirmed notifications alone passed
an idle three-minute run but still failed during active control traffic. The final
endpoint advertises write-with-response and indications only, bounding both
background directions while preserving encrypted input and return sequences.

A 180-second run using the renderer control socket completed 779 authenticated
mirror writes, 17 Home key down/up pairs, and three notification receiver
reconnections (at 30, 90 and 140 seconds). Both helper and renderer remained alive
until the scheduled test stop. Matched phone/Mac diagnostics contained no ATT
stalls, return failures or L2CAP congestion. This verifies the exercised workload;
it is not an unlimited-duration or RF-interference guarantee. Transport, MTU,
notification session and fragmented wire-event regressions passed as well.

Launch testing also exposed a separate Classic channel lifecycle failure before
BLE authentication. Each helper now requests its own Classic connection even
when macOS reports the phone already connected, then waits for completion before
opening L2CAP. Shutdown explicitly closes the compatibility peer's PSM, including
pending opens. Startup regressions cover both paths. The installed build passed
launch, normal quit and relaunch without restarting the phone or resetting its
Bluetooth connection between sessions.
