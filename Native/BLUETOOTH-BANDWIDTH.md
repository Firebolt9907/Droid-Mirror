# Bluetooth bandwidth and quality

Bluetooth now starts at 256 kbps and probes upward by 25% after every two
seconds of continuous current encoder output, up to 1.5 Mbps. Encoder backlog
above 400 ms backs off by 25% at most once a second. Stale-frame recovery still
halves bitrate and requests a current keyframe. The congestion floor remains
128 kbps; increasing the probing ceiling does not increase that floor. Wi-Fi
keeps its explicit profile and ordinary ADB encoding does not enable probing.

The Classic byte window starts at 8 KiB and adapts up to 64 KiB based on
cumulative ACK delivery. It samples active throughput every 500 ms, budgets
150 ms of payload plus observed ACK spacing and a 25% margin, smooths rate
increases, and reacts directly to a decrease. Window growth is limited to
8 KiB per sample. Idle periods and Wi-Fi fallback reset its estimate. This
avoids a fixed small window capping throughput when feedback is delayed.
It estimates delivered traffic, not spare capacity: encoder probes discover
headroom. Active ACKs retain the 40 ms cadence introduced in the latency fix.

`DroidMirrorPerformance` reports encoded kbps, FPS, send blocking, ACK waiting,
in-flight bytes, window capacity and delivered kbps. Shizuku service version
33 ensures existing persistent capture processes load the updated controller.

## Validation on October 16, 2026

- `bash Native/test-wireless-upgrade.sh` passes, including slow/fast delivery,
  contraction, hard cap, idle/reset, delayed ACKs, bitrate probing and backoff,
  cumulative-window accounting, BLE queueing, and Wi-Fi handoff/fallback.
- Android `assembleDebug lintDebug` passes using Java 21 and SDK 36.
- Preview APK: `outputs/DroidMirror-Bluetooth-low-latency-debug.apk`, with SHA-256
  checksum alongside it. Use a Mac helper containing the 40 ms active ACK change.

The existing generated-data benchmark verified matching sender/receiver byte
totals on the Pixel 8. Receiver rates, including queue drain:

| Path | Producer write | Received bytes | Receive duration | Received rate |
| --- | ---: | ---: | ---: | ---: |
| Direct | 672 bytes | 393120 | 18.200 s | 173 kbps |
| Direct | 256 bytes | 192256 | 15.932 s | 97 kbps |
| Pipe relay | 672 bytes | 411264 | 23.150 s | 142 kbps |

These are samples under the observed conditions, not established radio maxima.
Sender timing overstated receive throughput because queued bytes continued to
drain. A live stream logged 192 kbps and 12.5 FPS early in one run, but that run
ended with a BLE operation timeout. A subsequent 20-second drain completed
with a negative relative timestamp drift, but the companion was being replaced
and restarted during validation, so those runs do not establish sustained
quality, stability, or absolute end-to-end latency. No video was saved.

The higher ceiling allows better quality where the link supports it. It cannot
make a 100–200 kbps link deliver 1.5 Mbps or guarantee readable motion at the
existing 468×1040, up-to-16-FPS profile. The 128 kbps quality floor also remains
above the lowest measured sample; sufficiently weak links may still fall behind.
