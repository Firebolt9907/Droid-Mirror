# Overnight BLE optimization — October 21, 2026

Owner: Jeffrey Turkstra. Authorized window ends at 08:00 America/Indiana/Indianapolis (12:00 UTC). Read actual time before and after every pass. Preserve pre-existing edits and active sessions. No installation, component restart, pairing changes, commits, or pushes.

## Pass 1 — 00:42–00:45 local: baseline and benchmark

The checkout contains extensive existing changes, including the native BLE input transport, notification controller, crypto, Android input server and notification peripheral. Inspected their diffs and current scheduling paths before adding separate benchmark files. No production transport behavior changed in this pass.

### Existing implementation and coverage

- Native notification/discovery BLE schedules plaintext through `BLEOutboundQueue`, seals in dequeue order, and finishes fragments of a message before the next message. Four ordinary control messages yield to a pending file chunk. Ping is urgent. Authenticated writes without response obey platform readiness; handshake/older peers use response writes.
- Android notification peripheral has corresponding plaintext scheduling, with callback-driven frame delivery. Its queue is a separate Kotlin implementation; the new benchmark does not exercise that implementation yet.
- Native input BLE has a separate binary queue, authenticated response writes, video acknowledgments, source-time motion coalescing, and batching. Alternating return reads with input is already a pre-existing uncommitted change; do not attribute it to this loop.
- Existing tests cover ordering, bounds, requests, crypto, fragmentation, and motion coalescing. The Classic benchmark measures another transport. No BLE performance benchmark was found in this audit.

### Added artifacts

- `Native/BLETransportBenchmark.swift`: deterministic arrivals through production Swift queue, actual authenticated session sealing with synthetic keys and nonces, and actual fragmentation/reassembly. Assertions verify ATT value caps, reassembly, completion, and complete accounting of accepted messages. Six cases cover MTU 23/185/517, slow callbacks, a 500 ms readiness stall, and retirement of an in-flight message followed by a fresh authenticated session. No side effects or real device access.
- `Native/benchmark-ble-transport.sh`: isolated temporary build and module cache; removes them on exit.
- `docs/benchmarks/ble-2026-10-21-baseline.json`: raw baseline output including p50/p95/p99 queue/completion latency, reserved queue high-water, useful JSON and ATT value bytes, envelope overhead, and rejected/expired/canceled counts.

Reproduce: `bash Native/benchmark-ble-transport.sh`.

### Baseline evidence and limits

This is a host simulation, **not measured BLE radio performance**. Workload: three seconds of 1000-byte file data every 80 ms and a control message every 50 ms. Service model: one ATT value every 8 ms (30 ms in slow case), no RF loss. Actual useful bytes include JSON metadata. ATT value bytes exclude ATT/L2CAP/link headers. CPU time, OS buffers, receiver processing, and connection-event behavior are excluded. Real JSON escaping can slightly vary encrypted envelope lengths between executions. Queue high-water is reserved cost, not measured heap memory. These are workload comparisons, not hardware bandwidth predictions.

Saved baseline results:

- MTU 23, 8 ms/frame: p95 queue 18,158 ms; p95 completion 18,262 ms; modeled useful JSON 917 B/s; reserved queue high-water 167,139 bytes.
- MTU 185, 8 ms/frame: p95 queue 69 ms; p95 completion 77 ms; modeled useful JSON 13,121 B/s.
- MTU 517, 8 ms/frame: p95 queue 15 ms; p95 completion 23 ms; modeled useful JSON 14,490 B/s.
- MTU 517, 30 ms/frame: p95 queue 252 ms; p95 completion 282 ms; modeled useful JSON 8,176 B/s.
- MTU 517 with readiness stall: p95 queue 353 ms; p95 completion 377 ms.
- Disconnect/reconnect: one accepted in-flight message explicitly canceled, six arrival attempts rejected while disconnected, 91 delivered. No automatic replay across sessions.

No queue overflow or deadline expiration in these six cases. Small-MTU workload is deliberately oversubscribed: 3 seconds of arrivals takes about 47 seconds to drain. Its tail is a capacity/fairness warning, not a measured device defect. There is no before/after improvement claim yet.

### Validation performed

- `bash Native/benchmark-ble-transport.sh`: passed all six cases, including framing and message accounting assertions; saved JSON parsed successfully.
- `bash Native/test-ble-session.sh`: passed session/queue assertions and compiled the real notification receiver with current sources; exit 0. Script inspected before execution; temporary executable only.
- `clang -fobjc-arc -fblocks -framework Foundation Native/BleInputQueue.m Native/BleInputQueueTests.m -o /private/tmp/droidmirror-overnight-ble-input-queue-tests && /private/tmp/droidmirror-overnight-ble-input-queue-tests`: passed source gesture timestamps, motion, packing, TCP fragmentation, ordering, ACK priority and bounds.
- Whitespace check for new benchmark sources passed. Full Android/cross-language crypto checks not run this pass. No live component modified or restarted.

### Next focused action

Investigate whole-message file blocking and count-based four-control fairness with the real file producer/chunk sizes and acknowledgment window. Do not interleave encrypted fragments or reorder semantic file begin/chunk/end commands. Check whether producer chunk sizing or backpressure can bound interactive delay without reducing useful goodput; model candidate changes before altering production. Add urgent ping and saturation/expiry workload coverage, and benchmark/check Android queue parity. For input transport, a separate queue/return-read workload is still needed; Swift notification results must not be generalized to binary input BLE.

Hardware verification remains pending: on a separate, idle test session measure negotiated MTU, p50/p95/p99 application acknowledgment RTT under mixed transfer load, useful payload transfer rate, and failures before/after. Do not use real actions or replace running components to obtain these measurements.

## Pass 2 — 05:12–05:42 local: reduce encrypted envelope overhead

Several scheduler prompts were queued together; handled them as one pass without overlapping work. Re-read instructions, current status and relevant diffs. Prior user changes remain intact.

### Findings and implementation

The real clipboard sender negotiates a window of up to eight 3072-byte binary chunks and waits for cumulative acknowledgments. The pass-1 open-loop 1000-byte/80 ms workload is an oversubscription stress case, not a faithful simulation of the real producer. Do not change queue fairness based solely on that tail latency.

Found an independent bandwidth cost: Foundation's default JSON serialization escapes slash characters in the encrypted Base64 `box`. Updated only the outer envelope serialization in `BLESecureSession.seal` to use `.withoutEscapingSlashes`. Literal slash is valid JSON and decodes to exactly the same Base64 value. Keys, encryption, nonces, sequence numbers, message limits, ordering, and handshakes are unchanged. Android already parses ordinary JSON, so no new capability negotiation is needed. No production queue policy changed.

Extended the binary chunk crypto regression to forbid optional slash escapes in the envelope and transmit those exact raw JSON bytes to the existing Android peer. Previously the exchange helper parsed and reserialized envelopes, which would reintroduce default escaping before the Android parser.

### Measurements

Saved current pre-change and post-change simulations to `docs/benchmarks/ble-2026-10-21-envelope-before.json` and `ble-2026-10-21-envelope-after.json`. Extended the benchmark to also serialize each delivered ciphertext using the legacy escaping and count its hypothetical fragments. This paired comparison isolates representation overhead from ciphertext variation due to JSON key ordering.

- MTU 23: same-ciphertext delivered ATT value bytes 117,737 escaped vs 115,927 compact (1.537% reduction). Independently simulated total frames 5913 before vs 5814 after; modeled control completion p95 18,270 vs 17,934 ms. These separate simulations have slightly varying ciphertext, so the paired byte metric is the stronger evidence.
- MTU 185: paired bytes 68,202 vs 67,219 (1.441% reduction). Frames remain 402; modeled p95 remains 77 ms.
- MTU 517: paired bytes 66,116 vs 65,167 (1.435% reduction). Frames remain 174; modeled p95 remains 23 ms.
- Slow, stalled, and reconnect cases show 1.414–1.455% paired byte reduction. Large-MTU modeled latency and frame count do not improve, since the saved bytes do not cross fragment boundaries in this workload. Delivered-only paired metrics exclude canceled partial messages.

These are actual serialized byte counts and modeled timing, **not measured radio goodput or latency improvements**. No APK or app bundle was installed or replaced. Native input transport is unchanged by this optimization.

### Validation

- Full `bash Native/test-integrated-ble.sh` passed after the final raw-wire exchange test change: Android queue/conversation payload tests, shared pairing/migration, independent BLE input crypto vector, and Swift ↔ existing compiled Android Kotlin mutual authentication, AES-GCM, tamper/replay rejection, duplicate handshake and fragmentation checks. This script uses cached Android classes; it does not rebuild the APK. No Android production source was changed this pass.
- All six benchmark cases passed after adding paired accounting, including message accounting and reassembly assertions.
- `git diff --check -- Native/BLESecurity.swift Native/BLESecurityTests.swift` passed. Existing discovery-related modifications in both files were preserved.

### Next action

Add a producer-faithful bounded-window workload with urgent ping, and test queue saturation/expiry explicitly before considering scheduler changes. Check the Kotlin queue directly from source if adding queue changes. A separate binary input benchmark and hardware measurements remain pending. Stop by 08:00 local; do not extend the loop to chase unsupported radio claims.

## Pass 3 — 06:12–06:15 local: bounded file windows and queue lifecycle

Added six bounded-window cases to the existing host benchmark: a 48 KiB synthetic file, 3072-byte chunks, cumulative windows of one/eight, MTU 23/185/517, ordinary controls every 50 ms and urgent ping every 500 ms for three seconds. Reverse ACK transport is simplified to two frame-service intervals; the benchmark does not execute `ClipboardSync`, model the reverse queue, or include file-begin negotiation/OS processing. Production scheduling, encryption, fragmentation and reassembly still execute. File goodput counts binary payload separately from JSON, and the final modeled ACK time includes that explicit ACK delay. Saved output: `docs/benchmarks/ble-2026-10-21-window.json`.

Results under the explicit 8 ms/ATT-value service assumption:

- MTU 23: p95 all-control completion 56,379 ms, urgent ping p95 4033 ms. Nine ordinary queued messages expire; accepted messages remain fully accounted for. File goodput about 689 binary B/s. Window one/eight final ACK times 71,350/71,320 ms. Tiny-MTU capacity remains inadequate for this heavy mixed workload; urgent pings still wait for the current whole chunk. This is modeled evidence, not measured device behavior.
- MTU 185: p95 all-control completion 1905 ms, urgent ping 199 ms; file goodput 10,212 binary B/s. No expiry or rejection. Both windows complete at 4813 ms.
- MTU 517: p95 all-control and urgent ping completion 92 ms; file goodput 25,388 binary B/s. No expiry or rejection. Both windows complete at 1936 ms.
- Window eight raises reserved queue high-water (MTU 517: 105,785 vs 14,433 bytes) without reducing latency in this simplified mixed-traffic model. It is not sufficient evidence to undo the existing negotiated window or change fairness. Real OS buffering/ACK service may behave differently.

Added Swift queue regression assertions that saturating bulk reservations expire completely, then fresh semantic commands retain FIFO ordering. Added Android queue assertions for accepting and preserving fresh FIFO commands after expiry; its existing saturation/expiry checks remain. No production scheduling change.

Validation: all twelve simulation cases passed reassembly, cap and message-accounting assertions; `Native/test-ble-session.sh` passed both assertions and real receiver compilation; `Native/test-integrated-ble.sh` passed all queue, pairing and cross-language crypto regressions using existing compiled Kotlin classes; relevant tracked-file whitespace checks passed. No live components touched.

Next: measure the separate binary input queue with modeled ATT packing/backpressure, then finish with an honest handoff/manual radio verification plan. Remaining production transport tuning requires a credible hardware timing baseline; do not infer platform callback cadence from the host model.

## Pass 4 — 06:42–06:45 local: binary input baseline and final handoff

Added `Native/BleInputBenchmark.m` and `Native/benchmark-ble-input.sh`, using the production binary input queue and authenticated input seal/open functions. Builds and executables are isolated in a temporary directory and removed on exit. Synthetic workload: one 4000-byte text burst, 1000 Hz pointer samples for one second, and a key command every 100 ms for three seconds. Every reconstructed key is checked against its original creation timestamp and FIFO position, including records fragmented across ATT packets. No real key/mouse actions or device connection are used.

Reproduce: `bash Native/benchmark-ble-input.sh`. Raw output: `docs/benchmarks/ble-2026-10-21-input.json`. Assertions passed for all supported cases; all 30 keys survive each case. MTU 23 is explicitly reported unsupported because the input protocol requires more than its 20-byte ATT value after the 24-byte authenticated envelope, matching the production startup check. Notification BLE can fragment at that MTU; binary input cannot. No protocol weakened to alter this limit.

Modeled input key completion p50/p95/p99:

- MTU 185, 8 ms/serialized operation: 8/124/208 ms, 97 packets.
- MTU 517, 8 ms/operation: 8/15/72 ms, 86 packets.
- MTU 517, 30 ms/operation: 30/170/270 ms, 54 packets.
- MTU 517, 8 ms/operation plus 500 ms readiness stall: 8/408/508 ms, 58 packets.

Queue high-water was 4061 bytes in every supported case. Source motion is intentionally coalesced by the existing queue; packet counts and delivered touch counts therefore vary with service timing. These are **host simulation results, not measured input latency**. This input harness excludes video ACK/return reads, OS buffers, RF loss, receiver processing, reconnects and actual transport callback scheduling. It is a packing/backpressure baseline, not a replacement for live end-to-end tests. Production input transport remains unchanged by this loop.

### Final delivered scope

- Production optimization: outer encrypted notification/discovery JSON envelope emits literal slashes, avoiding optional escaping of Base64. Same-ciphertext comparisons save about 1.4–1.5% of ATT value bytes in the saved workload. Large-MTU modeled latency/frame counts are unchanged. This is not a claim of equivalent hardware speedup.
- Added repeatable notification and input host benchmarks, raw baseline/comparison/window/input results, and queue-expiry/FIFO and exact-wire JSON interoperability regressions.
- Session tests plus real receiver compilation, input queue tests, all notification simulation cases, input benchmark assertions, cross-language security/fragmentation, Android queue/pairing/payload and independent input crypto checks passed as recorded above. Kotlin interoperability used existing compiled classes; no full APK rebuild or live QA was performed.
- No app/APK deployment, live-session disruption, credential change, commit or push. Existing unrelated and BLE edits preserved.

### Remaining hardware validation and stop decision

Further callback/queue/chunk tuning needs an isolated idle-device baseline that is unavailable in this non-disruptive loop. Disable the schedule early after this pass rather than make unmeasured behavioral changes. Do not restart on queued duplicate triggers once disabled.

On a separate idle test setup, build review artifacts without replacing a running session. Record actual negotiated MTU, response-write vs readiness-paced streaming mode, callback cadence, p50/p95/p99 authenticated ping/application-ACK RTT with/without file load, binary file completion goodput, errors and queue growth. Compare compact-envelope vs previous build under the same device/radio conditions and both directions. Exercise stop/reconnect/service change with fresh authentication and preserved replay/sequence checks. Use synthetic data/actions only. Before any eventual live component replacement, gracefully end the active mirror session as required by AGENTS.md.

Production scheduling changes and hardware improvement claims are deferred. The measurable source-level byte reduction and reproducible host baselines are ready for review.
