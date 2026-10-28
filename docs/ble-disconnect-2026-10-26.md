# BLE disconnect investigation, 2026-10-26

Two failures had the same generic Mac message, `BLE input write failed`:

- Startup failures at 14:53:06 and 14:53:24: macOS reported an error response to
  a GATT long write at input handle 0x00b6. Android rejected prepared writes.
  The input server now buffers at most 512 bytes, echoes prepare fragments,
  authenticates the complete record only on execute, and discards cancellation.
  Replay/sequence validation remains unchanged. Reassembled length must not be
  used to infer ATT MTU.
- Mid-stream failure at 14:58:10.929: macOS explicitly logged `GATT is connected
  on 2 transports! Serializing disconnection of prev in favor of current`, then
  `Disconnecting classic device ... because LE GATT connected`. The next writes
  hit a closed bearer (status 404). Android continued accepting input through
  sequence 416 before return-indication delivery timed out during cleanup.

The phone's presence detector creates reverse LE GATT connections to the Mac
using `connectGatt(... TRANSPORT_LE)`. This matches the incoming LE connection
that caused macOS to retire its existing Classic GATT bearer. Active mirroring
now defers these independent radio probes, including startup before the first
video frame. Any in-progress probe is cancelled at mirror startup. ADB streams
also cancel probes when their live notification starts. Deferred measurements
are unavailable, never fabricated successful presence proofs. Normal probes
resume after mirroring releases the radio.

The Classic video L2CAP connection and authenticated GATT control connection are
separate: moving video to Wi-Fi does not remove the need for the control link.
No user Bluetooth pairing or OS radio settings were reset for these fixes.

## Clicks interpreted as long presses

Gesture traces at 16:33 showed DOWN delivery ages around 400–900 ms. One physical
80 ms click had a 374 ms down/up arrival interval; another 80 ms click arrived
with both edges only 9 ms apart but its DOWN was already 876 ms old. Injecting
that source DOWN time directly can put Android gesture timers in the past.

Timestamped gestures now anchor the first DOWN to phone receipt time, translate
subsequent source times relative to that anchor, and clamp bunched events to the
current phone time. Normal source spacing and real holds remain intact when
arrival permits; bunched samples can compress, rather than receiving future
Android event times. Secondary pointers share the first pointer's anchor.
Untimestamped wired ADB events retain arrival-time handling. Gesture traces
continue to report original source duration and delivery age separately from
injected duration.

The Mac also distinguishes reliable-write capacity (which can include a 512-byte
long-write transaction) from single-packet capacity. Input batches now use the
single-packet limit where available, with a bounded 128-byte long-write fallback
for links too small to carry a normal encrypted record. Slow completions over
150 ms log elapsed time, packet length and queued bytes without input contents.
These changes address false long presses and long-write batching; they do not
establish that all underlying Bluetooth scheduling latency has been eliminated.

The first click-timing APK update did not replace the daemonized Shizuku display
process: gesture logs still came from PID 8031 and lacked `injectedDurationMs`.
The display user-service version must change whenever embedded capture/control
code changes. Version 67 forces replacement; after gracefully ending mirroring
and reinstalling, a new display process (PID 9581) reached streaming at 16:43:18.
Earlier post-install click observations therefore did not exercise the timing fix.
Intermittent click correctness still requires sustained use of the new process.

## Long trackpad gestures arriving in bursts

Mac completion diagnostics showed even 37-byte writes taking 240–700 ms.
One 3.373-second source gesture took 7.532 seconds between DOWN and UP delivery
and ended 6.219 seconds behind source time. The input writer serialized every
packet behind a write-with-response completion, so the queue could preserve
60 Hz source samples while the radio path delivered them in a few bursts per
second. This is per-operation latency, not a measurement of raw BLE bandwidth.

The input characteristic now advertises write-without-response in addition to
reliable writes. Matching Macs use direct encrypted records when a single ATT value can hold
them. On minimum-MTU links they split a two-byte-length-prefixed encrypted record
into commands of at most 20 bytes, and Android authenticates only after complete
reassembly. They honor CoreBluetooth's
`canSendWriteWithoutResponse` credits and resume on its readiness callback.
AES/MAC sequence validation is unchanged. Submitted command ciphertext is never
replayed after uncertain delivery: recovery must prove the submitted sequence
was accepted or fail closed. Older companions retain reliable writes; updated small-packet links use the
bounded command stream.
Tests exercise credit exhaustion, readiness resumption, encrypted ordering, and
the original delayed reliable-write path. Runtime logs report negotiated capacity
and whether streaming writes are available; live smoothness must still be checked
on the actual negotiated connection.

Service recovery now retries a failed/short nonce read after fresh discovery within
the original four-second deadline. Changed nonces and invalid authentication still
fail immediately. A partially submitted command is not replayed across service
invalidation. Tests cover mid-frame radio-credit exhaustion and transient invalid
handles without extending the deadline or resetting cryptographic sequences.

## Return-channel timeout near 17:00

At 16:59:59 the phone ended its return sender with `BLE return delivery stalled`.
Authenticated input was still arriving at 16:59:55. The Mac's temporary log was
deleted during shutdown; the user reported only “timed out”. Those observations
do not establish which side stopped progressing first.

The return sender previously required Android's indication-completion callback
to retire each packet. Updated companions advertise notifications instead and
require an authenticated Mac acknowledgement: a dedicated input plaintext
envelope of type 3, length 8, containing the received return sequence in network
byte order. These envelopes use the ordinary input encryption and increasing
input sequence, and are intercepted before forwarding control bytes to scrcpy.
Only an ACK matching the pending return can release it. Local notification
callbacks cannot release a packet or terminate the session.

If its ACK is missing, the phone resends the identical encrypted return at
one-second intervals, with a six-second delivery deadline. The Mac accepts an
exact duplicate of its last authenticated return only to re-ACK it; it never
delivers its action again or advances the return sequence twice. Modified or
out-of-order records still fail authentication. ACKs honor input radio credits
and precede queued controls at the next packet boundary. Native regressions
cover lost ACKs, duplicate action suppression, fresh input nonces, flow control,
and tampering. A matching Mac must be installed before the new phone build;
the Mac continues supporting older indication-based companions.

The Mac now archives the last 20 connection logs under
`~/Library/Logs/DroidMirror/Connections/` on stop and prints BLE operation state
with failures. This fixes a callback-dependent timeout path; sustained device
testing is still required to establish whether it explains the observed failure.

After installing the matching phone build at 18:52, the preserved Mac log exposed
another failure: `BLE operation stalled (write=0 read=0 queued=0)` while a return
ACK was pending. CoreBluetooth had supplied no command credits for four seconds.
The Mac now waits 400 ms for credits before submitting a new, unsent record as a
write-with-response. This fallback never replays already-submitted commands or
an unfinished fragmented command. The regression forces credit starvation and
checks the fallback ciphertext's fresh input sequence and reliable completion.

The subsequent live session used reliable fallback continuously, with individual
writes often taking 200–600 ms. It ran roughly three minutes until a normal
helper-termination request, without another timeout, but the user reported laggy
scrolling. During reliable fallback the input queue now collapses unsent motion
across source-time buckets to the current position per pointer, including backlog
created before fallback. Gesture edges, keys, distinct pointer states, wheel
distance and partially transmitted data remain intact. Normal streaming retains
its 60 Hz source buckets. Return ACKs can prefix queued control bytes in the same
authenticated packet; Android strips the prefix before forwarding the remaining
control stream. This reduces round trips and queued latency, but cannot guarantee
smooth frame cadence while CoreBluetooth withholds command credits.

## Input GATT migrating to Classic

macOS unified Bluetooth logs identify the 18:54:49 and 18:59:43 mirror sessions
as `App ready ... bundle: DroidMirrorBluetooth, transport: classic`. Earlier
sessions show `transport: le`. The 200–500 ms reliable-write timings therefore
must not be presented as the capacity of the BLE radio.

An experiment using the project's `BleGattServerFactory` transport-LE overload
built and installed after graceful mirror shutdown. It did not establish a speed
improvement: attempts ended with CoreBluetooth unavailable during discovery or
before the first input record completed. ADB then went offline. Inspection of
the Android 36 SDK source shows `BluetoothGattServer.mTransport` is used only by
`connect(device, autoConnect)`; it does not restrict incoming connections or
service registration. Therefore changing this overload alone does not pin the
Mac's incoming GATT bearer to LE. That experiment was removed from the source;
the stable server build was restored after debugging reconnected at 20:38. Native
unavailable errors now include the numeric CoreBluetooth state to distinguish
power, authorization and support failures. A real transport-selection fix still
requires device validation, including coexistence with Classic video.

## Frequent short sessions: 21:04 stalled write

The archived `F2B20C0F-F107-4B3B-B872-5D5DF6BD2FA3` session lasted approximately
41.5 seconds (log creation to final modification). Its terminal error was
`BLE operation stalled (write=1 read=0 queued=135)`. Prior reliable completions
took 1,982, 1,334 and 1,677 ms, with command-credit fallback active. This is an
operation-progress deadline, not a one-minute session-duration limit.

A proposed watchdog-triggered reconciliation attempt was built and installed,
but removed from source after review: it treats the symptom rather than fixing
the write stall. The original four-second operation watchdog and the existing
four-second service-recovery budget remain unchanged in the final fix below.

`DisplayLease.TIMEOUT_MS=2000` is the app-to-Shizuku deadman, not the Mac peer
deadline. `ShizukuDisplayClient.update()` refreshes that lease every 250 ms while
allowing peer heartbeats up to 5,000 ms old. Those timeouts were not increased.
The later `0AFC8FB3` session emitted `EVENT PIN_FAILED`; normal helper shutdowns
also appear in the archive and must not be counted as this BLE watchdog failure.
The one-heartbeat diagnostic bypass used during transport investigation has
been removed; production writes continue honoring CoreBluetooth command credits.

## Recovery notification race and missing fling inertia

The user's later log ends after `reading the BLE session nonce`, with generic
`BLE service recovery authentication failed`. A deterministic callback-routing
bug reproduces that sequence: rediscovery clears `returnIndications`, but Android
may still notify on a characteristic object CoreBluetooth reuses during discovery.
Without an active return subscription flag, that callback fell through to the
pairing-proof parser. Since its UUID was not the proof UUID, `reject()` ended the
session before the pending nonce read completed. Late clock/resume/replay
callbacks could take the same path. The proof handler now handles only the proof
characteristic; unrelated out-of-phase callbacks are ignored. Valid proof replies
still require the complete MAC and unchanged same-session sequence checks. Tests
inject delayed return and clock callbacks during the nonce read and continue the
existing authenticated recovery to completion. No timeout was increased.

The reliable-fallback queue's one-sample motion coalescing also removed the
velocity history needed for Android fling inertia. The first fix kept two samples; after inconsistent fling speed was reported,
it now retains six 60 Hz source buckets (at most about 100 ms) per pointer,
preserving original timestamps, UP/DOWN,
state barriers and partially sent bytes. Tests cover both pinch pointers and a
timestamped release with two distinct preceding positions. Mac momentum remains
suppressed so it does not double-apply Android's fling.

The renderer also stamped generated trackpad SDL events with processing time,
rather than the NSEvent source time. When the main thread consumed a delayed
batch, distinct source positions could appear to occur almost simultaneously.
Trackpad source timestamps now map from macOS uptime into the SDL tick domain
before button/motion events are generated. Synthetic non-trackpad events retain
their normal timestamps. Renderer tests verify 16 ms source spacing survives a
batched delivery, through actual SDL events. No inertia multiplier was added.
Phone-side timestamp anchoring under transport jitter remains a separate risk
and still needs device-level verification; source timing tests alone do not
establish consistent end-to-end fling behavior.

## October 27: native momentum playback and Bluetooth process crash

The touch-velocity approach above was insufficient: the user still observed
inconsistent speed and occasional opposite scrolling. Bluetooth trackpad input
now forwards macOS relative deltas, including native momentum, through the
existing bounded wheel queue. The phone plays those deltas locally at 16 ms
ticks and ends with CANCEL, preventing a second Android fling. A new gesture
sends a zero-distance reset barrier, discarding whole unsent old wheel records
and cancelling pending phone playback. Partially sent authenticated records
remain immutable. Shizuku display service version is 68. Tests cover reversal,
distance conservation, reset barriers and renderer event tags; these are not
evidence of sustained device-level performance.

At 11:12:57 on October 27 the Bluetooth process crashed with BadParcelableException
while MediaController.getQueue retrieved only 66 of 101 queue entries, caused by
a Binder DeadObjectException. ActivityManager reported no ANR since boot. This
does not establish a BLE traffic overload. DroidMirror's proxy queue is bounded
to 32 items, so that 101-item queue cannot be its current published queue.

Nevertheless, PhoneMediaSync unnecessarily republished unchanged metadata and
queues on position refreshes, provoking Bluetooth media callbacks. Publication
now occurs only when corresponding content changes; artwork decoding also
reuses identical bytes. A regression test makes 1,000 position-only updates and
requires just one metadata/queue publication. BLE return notifications and
legacy read responses now call Android outside the return-channel lock, and
subscription callbacks leave sending to the existing bounded sender loop.
No disconnect timeout was increased. These fixes reduce avoidable work but do
not prove that the external/system media-queue crash cannot recur.

## October 28: service invalidation during a fragmented command

The reported `commandBytes=39 commandOffset=20` failure previously bypassed
same-session recovery altogether. The Mac now retains the outstanding ciphertext,
abandons its ATT frame, and runs the existing four-second rediscovery and fresh
pairing-proof exchange. An authenticated resume sequence determines whether the
record was accepted or needs exact-ciphertext reliable retransmission. Changed
session nonces, invalid proofs, and sequences outside the outstanding record
still terminate recovery. No input sequence is reset.

Android discards incomplete command/prepared buffers when serving the selected,
authenticated peer's resume snapshot. After this particular recovery the Mac uses
reliable writes for the remaining session, including with older companions that
may retain an incomplete command buffer. It never appends a new fragmented record
to that buffer. This can reduce input throughput on affected links, but avoids
requiring a Bluetooth toggle for this service-invalidation case. The regression
reproduces invalidation after 20 of 39 bytes and checks retained ciphertext,
bounded recovery, accepted/unaccepted sequence reconciliation and replay rejection.
This does not establish recovery from an OS Bluetooth daemon crash or a replaced
Android mirror session. No device installation or live-radio validation was done.
