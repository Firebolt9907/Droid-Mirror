# Wireless playback pacing

Wireless playback now defaults to `--video-buffer=50`. Settings → Picture →
Wireless video buffer adjusts this from 0 to 200 ms for the next session.
Wireless ADB and automatic Bluetooth/Wi-Fi sessions use the setting; USB uses 0.
The automatic session retains its buffer during Bluetooth fallback as well.

Previously both launch paths explicitly selected `--video-buffer=0`. That is
also upstream scrcpy's default, so the flag alone does not establish why the
app stutters more than a plain scrcpy session. Without a buffer, decoded frames
go directly to the screen's single pending-frame slot. Frames that arrive before
the UI consumes that slot replace the pending frame. The upstream video regulator
uses capture timestamps to pace buffered frames, absorbing short delivery bursts
at the cost of additional playback latency. A buffer cannot fix sustained encoder
or renderer overload.

During investigation, the saved app profile was 30 fps, 4 Mbps, 1280 px, HEVC;
the terminal ran Homebrew scrcpy 4.1 without flags while the app used its custom
5.0 client. The 30 fps cap affects motion cadence but does not by itself explain
irregular pauses. The custom renderer also enables MetalFX spatial upscaling by
default and waits for its GPU work before presenting; this remains a separate
candidate if buffering does not resolve the issue. Frame rate, codec, bitrate,
resolution, input handling and upscaling were left unchanged for this change.

To compare, use the same phone content and saved picture profile, reconnect with
0 ms and then 50 ms (or 100 ms for larger jitter), and swipe on the phone to
exclude Mac input handling. Separately toggle View → MetalFX Upscaling (2×)
while keeping the buffer fixed to isolate renderer overhead. Live smoothness
has not been measured by the preference/build checks.

Upstream reference: [video buffering](https://github.com/Genymobile/scrcpy/blob/master/doc/video.md#buffering).

## Recovery from seconds of video backlog

The hybrid Wi-Fi profile previously reset `maxFrameAgeUs` to zero, disabling
the stale-frame guard after upgrading from Classic. Both hybrid profiles now
discard encoder output older than 500 ms and resume only on a current keyframe.
Keyframe requests retry at most once per 500 ms while waiting: an IDR requested
behind a blocked output pipe can itself be stale when dequeued.

The hybrid encoder can adapt down to 64 kbps on either transport. Previously
Wi-Fi had no freshness-based bitrate feedback; simply enabling it with the
old half-target floor would still leave a 12 Mbps profile stuck above 6 Mbps
on a slow link. Quality recovers toward the requested profile after ten seconds
of continuous healthy encoder output. The playback buffer preference is unchanged.

`DroidMirrorPerformance` logs now include `maxCaptureAgeMs`, measured after
sending each complete video packet from the Android relay. This includes encoder,
pipe and sender backpressure, but excludes subsequent Mac decoding/presentation.
The 500 ms guard is not an end-to-end latency guarantee: a packet already being
sent must finish to preserve framing and authenticated transport replay offsets.

`bash Native/test-wireless-upgrade.sh` covers a synthetic five-second encoder
backlog, stale IDR retries, reference-safe recovery, Wi-Fi bitrate contraction
below half its target, and authenticated handoff/fallback continuity. Phone-screen
comparison is still required to establish displayed latency.
