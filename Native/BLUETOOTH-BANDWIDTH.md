# Bluetooth bandwidth and quality

Bluetooth starts at 128 kbps with a roughly 320-pixel short edge and up to
15 FPS. Recovery returns toward the same 128 kbps ceiling after ten seconds
of continuous healthy output, with a 64 kbps congestion floor. Encoder backlog above 250 ms backs off by 25% at most once a second.
Frames over 500 ms old trigger reference-safe keyframe recovery instead of
allowing two seconds of codec backlog. The same limits apply after Wi-Fi
fallback. Wi-Fi keeps its explicit profile, and ordinary ADB encoding does
not enable freshness control.

The Classic byte window starts at 8 KiB and adapts up to 64 KiB based on
cumulative ACK delivery. It samples active throughput every 500 ms, budgets
150 ms of payload plus observed ACK spacing and a 25% margin, smooths rate
increases, and reacts directly to a decrease. Window growth is limited to
8 KiB per sample. Idle periods and Wi-Fi fallback reset its estimate. This
avoids a fixed small window capping throughput when feedback is delayed.
It estimates delivered traffic, not spare capacity: the encoder stays within its conservative bitrate ceiling. Active ACKs retain the 40 ms cadence introduced in the latency fix.

`DroidMirrorPerformance` reports encoded kbps, FPS, send blocking, ACK waiting,
in-flight bytes, window capacity and delivered kbps. Shizuku service version
37 ensures existing persistent capture processes load the updated controller.

## 128 kbps ceiling validation on October 16, 2026

- `bash Native/test-wireless-upgrade.sh` passes, including the 128 kbps ceiling,
  64 kbps floor, ten-second recovery, and Wi-Fi handoff/fallback coverage.
- Android `assembleDebug lintDebug` and the Swift app build pass.
- APK: `outputs/DroidMirror-Bluetooth-128kbps-debug.apk`, with SHA-256 alongside it.
- Install the updated companion to apply the encoder changes; Shizuku service
  version 37 refreshes persistent capture processes.
- Sustained radio performance still needs live-device validation. Codec bitrate
  control is an average target; individual keyframes can still exceed it.

## Earlier 160 kbps profile validation on October 16, 2026

- `bash Native/test-wireless-upgrade.sh` passes, including the 192 kbps recovery
  ceiling, 80 kbps floor, reduced capture geometry, 500 ms frame freshness,
  and Wi-Fi handoff/fallback coverage.
- Android `assembleDebug lintDebug` succeeds using Java 21 and SDK 36.
- APK: `outputs/DroidMirror-Bluetooth-320p-debug.apk`, with SHA-256 alongside it.
- Sustained radio FPS and end-to-end latency have not been measured for this profile.

## Earlier-profile validation on October 16, 2026

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

The reduced profile trades image detail for fresher frames on the measured
100–200 kbps links. The 500 ms encoder age limit is not an end-to-end latency
guarantee: an in-progress frame, the radio window and receiver add delay.
The new defaults need live-device validation for sustained FPS and input-to-display
latency; the earlier measurements above describe the previous profile.
