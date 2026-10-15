# Bluetooth input traffic audit

The installed Mac build limits consecutive absolute mouse MOVE/hover positions
to 60 Hz for sustained movement and replaces wholly unsent moves with the newest position for the same
pointer and button/display state. Clicks, releases, keys and other state changes
are ordering barriers. The final position flushes before a barrier. There is no
phone-side smoothing. Resolution and the video profile are unchanged.

The queue reassembles scrcpy messages across arbitrary TCP read boundaries and
packs ready input envelopes into available ATT payload space. It does not wait
for a full packet. Video ACK priority and one in-flight GATT operation remain.

| Activity | Rate / trigger | Goes to phone? |
|---|---|---|
| Absolute pointer moves and hover | 60 Hz cap; latest position and source event time retained | BLE input writes |
| Mouse buttons and keyboard | Actual state changes; OS key repeat retained | BLE input writes |
| Trackpad drag/scroll | Position updates use the same 60 Hz cap | BLE input writes |
| Discrete wheel scrolling | Coalesced for 28 ms, then DOWN/MOVE/UP | BLE input writes; up to roughly 36 gestures / 108 control messages per second while continuously scrolling |
| Video ACK plus liveness | Every 250 ms, cumulative unsent ACKs coalesce | BLE, about 4 records/s; may share a write with input |
| Control/event return reads | 500 ms idle target, plus immediate reads until empty | BLE requests, about 2/s idle; timer scheduling can lower this |
| Phone heartbeat echoes | At most once per second | Phone-to-Mac BLE replies |
| Bridge socket servicing | Every 20 ms | Local sockets only unless data or an ACK is due |
| BLE watchdog | Every 200 ms | Local state checks; initiates a read only when due |
| Device refresh | Every 3 s while not mirroring | Local bonded-device enumeration in Classic mode |
| Toolbar placement / installation | Local timers | No Bluetooth messages |
| ADB lock/PIN checks | Disabled for Bluetooth | No phone polling on the Bluetooth path |
| Shizuku lease heartbeat | Every 250 ms | Internal phone Binder call, no Bluetooth traffic |

The remaining burst source is discrete mouse-wheel gesture synthesis. Its DOWN
and UP messages cannot be discarded like obsolete positions. A persistent wheel
gesture would reduce transitions, but changes Android fling/scroll behavior and
has not been implemented in this change. There is no other 1000 Hz polling loop
sending data to the phone in the audited Classic/BLE application path. OS-level
Bluetooth scheduling/acknowledgements are outside these application rates.

Validation: a deterministic 1000 Hz input producer emitted 59 position records
in one second; the test accepts 58–60 depending on interval rounding. Tests also
cover newest-coordinate selection, immediate release flushing, key/pointer
barriers, ACK progress, TCP fragmentation, ATT packing, and large control payloads
whose bytes resemble motion records. A native-to-Android fixture confirms that a
101 ms gesture remains 101 ms despite simulated delivery jitter. The original
SDL event time is carried through the bounded queue, coalescing, BLE clock
mapping, Android parsing and MotionEvent injection. There is no navigation
classifier or generated Home shortcut in this timing change.
