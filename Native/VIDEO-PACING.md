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
