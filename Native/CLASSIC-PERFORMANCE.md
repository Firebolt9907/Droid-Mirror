# Classic L2CAP measurements — October 15, 2026

The previous 64 kbps setting was an H.264 encoder target, not measured transport
capacity. Android uses hidden `BluetoothAdapter.listenUsingL2capOn(0x1001)` in
Shizuku. Both the live path and diagnostic report Classic TX MTU 672, RX MTU 8087.
There is a persistent pipe across the process boundary, not a Binder call per packet.

The generated-data diagnostic runs on PSM 0x1003. It bypasses capture, encoding,
decoding, BLE and the application video window. Each test generates data for ten
seconds, then drains queued output. The Mac verifies every byte and the script
requires exact sender/receiver byte-count agreement. Payloads are never saved.

| Test | Sent and received bytes | Sender elapsed | Receiver data duration | Actual receive rate |
|---|---:|---:|---:|---:|
| Direct, 672-byte writes | 858,816 | 10.072 s | 11.431 s | 601 kbps |
| Direct, 256-byte writes | 504,832 | 10.616 s | 12.072 s | 335 kbps |
| Persistent pipe, 672-byte producer / 4 KiB relay | 989,184 | 10.293 s | 12.798 s | 618 kbps |

All three passed integrity and byte-total checks. Rates include time spent draining
queued data, so they are lower than sender write rates. These are samples under the
current radio conditions, not guarantees or a hardware maximum. The similar direct
and pipe rates do not indicate a large IPC penalty here. Smaller writes reduced
throughput substantially.

The profile starts at 256 kbps and up to 16 fps, preserving capture dimensions
and disabling automatic downsizing on codec errors. The application window is
24 KiB with cumulative BLE ACKs every 250 ms, coalescing obsolete unsent ACKs.
Mac BLE operations run on their own serial queue. A full window represents 768 ms
of payload at the starting target; this is a queue bound, not end-to-end latency.
Encoder output older than 400 ms lowers bitrate by 25%, at most once a second,
with a 128 kbps floor. Ten continuous healthy seconds gradually restores bitrate.
The two-second stale-frame threshold retains safe keyframe recovery.

A 30-second live receive test delivered 15.04 fps between first and last frames,
157.8 kbps averaged over startup and streaming, and 692 ms of relative delay growth.
A 60-second sample delivered 12.95 fps between first and last frames and 117.3 kbps
over the full interval, including startup and periods without new frames.
Its relative delay growth was -307 ms. Both kept 464×1056 dimensions and delivered
the stream-start event over BLE. These are samples, not guaranteed frame rates.
The user accepted this performance as sufficient before the menu/pairing fix.

An earlier test with the application credit gate removed accumulated about 6.2
seconds of relative delay in 20 seconds at 256 kbps. Increasing bitrate without
bounded queues can therefore increase latency even below raw diagnostic throughput.
BLE coexistence, ACK scheduling and video bursts make raw capacity an optimistic
reference for the live pipeline.

Full media chunks align the envelope plus payload to four negotiated TX MTUs.
The shell relay buffer holds up to six MTUs. Short frames/tails are sent immediately,
without waiting to accumulate another frame. This reduces partial packets and
write calls while avoiding timer-based batching delays.

The earlier 16 fps / 64 kbps / 4 KiB window / 500 ms stale-frame threshold regressed
quality. Phone logs showed recovery halving the bitrate to 32 kbps, with no prior
mechanism to raise it again. Those aggressive queue/recovery settings were reverted;
bitrate recovery is now tested separately.

Reproduce with:

```sh
python3 tools/benchmark-classic.py PHONE_CLASSIC_ADDRESS
python3 tools/check-classic-stream.py PHONE_CLASSIC_ADDRESS --seconds 15
```

The live check drains the video and control sockets without a decoder and reports
frames, dimensions and BLE stream-start events. It can establish receive rate and
protocol delivery, but cannot establish displayed FPS, motion-to-photon latency,
or perceptual quality. Motion testing in the actual mirror remains necessary.

The first 320 kbps live sample spent 2270 ms of a 5000 ms interval waiting on the
12 KiB application window, versus 2287 ms total send time. A later interval spent
4026 ms of 4047 ms waiting on ACK credit, then triggered encoder recovery. This
identified the ACK window/feedback path as the immediate live-stream bottleneck;
the normal sample was not saturating the raw 618 kbps transport. The window and
coalescing changes address this measured wait rather than increasing bitrate alone.
