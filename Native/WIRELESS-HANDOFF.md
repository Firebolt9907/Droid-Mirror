> Companion 0.26 tries Iroh on the LAN first, wireless ADB second, and Bluetooth
> last. Relays and public Iroh discovery are disabled. See [the current transport
> order](PEER-TRANSPORT.md). The DMWIFI03 handoff and BLE recovery below apply to
> both network paths; ADB pairing is needed only for the second path.

# Bluetooth-first wireless video handoff

Use matching Mac sources and companion 0.16 or newer. The default Connection
setting is **Automatic (Bluetooth → Wi-Fi)**; complete the existing Bluetooth/Shizuku setup.
On first launch of this Mac update, a one-time preferences migration resets any
saved transport selection to Automatic before device selection and startup.
It saves the result immediately, preserves the remembered phone and all other
settings, and respects subsequent manual transport choices on later launches.
Mirroring starts through Classic L2CAP without waiting for ADB.

For wireless video, enable Android's Wireless debugging, pair the Mac once through
the app's wireless pairing sheet, and keep both devices on a reachable network.
ADB normally discovers and reconnects previously paired wireless-debugging devices.
If needed, use the wireless connection sheet to connect the address Android shows.
This feature does not enable debugging, approve a new ADB host, or change networks.

After STREAM_STARTED, the Mac polls `adb devices` for online wireless devices.
It creates its own dynamically allocated loopback forwards to the active companion's
`localabstract:droidmirror_video_upgrade` endpoint. It probes one at a time, waits
three seconds between devices and ten seconds between scans. USB devices are
excluded. Each forward belongs to this session and is removed at teardown.

The endpoint exists only during a Bluetooth capture session. A fresh random
32-byte nonce and HMAC-SHA256 proofs in separate client/server domains authenticate
both sides with the saved BLE pairing key. Protocol DMWIFI03 authenticates the
requested resolution limit, frame-rate limit and bitrate in both proofs. The
server proof also covers the exact cumulative video payload byte offset. Neither a device name nor an ADB serial
is accepted as proof that the target is the selected Bluetooth phone.

Android commits the switch under the same lock that writes complete video
envelopes. It sends the cutoff and proof on the new socket, followed by DMBT0006
and subsequent envelopes. Mac waits until the old Classic parser has delivered
exactly the cutoff and completed its current envelope before reading wireless
video. A separate envelope parser feeds the same existing scrcpy loopback socket.
No video bytes are replayed or discarded, including when the cutoff falls inside
a scrcpy frame. The decoder, process and native window stay in place. After the Mac drains the
cutoff, it sends a receiver-ready byte over ADB. Android then applies the requested
Wi-Fi profile to the existing shell capture through the owner-checked Shizuku
Binder. The encoder uses its normal EOS/reset path to reconfigure the codec and
surface, emitting new scrcpy session metadata, HEVC configuration and a fresh
keyframe on the same byte stream. The session metadata marks a client resize,
which preserves the native window position, size and focus. No window-recreation or position-copying path is used.

All screen-capture sizes preserve the source display's exact integer aspect
ratio. Width and height are selected together from multiples of the reduced
ratio that also meet codec alignment and the longest-edge resolution limit.
For 1080×2400, the Pixel 8's encoder produces 468×1040 for Bluetooth, 864×1920
for the 1920 px Wi-Fi limit, 576×1280 for the 1280 px limit, and 1080×2400 for
Native. These all have exactly the same 9:20 ratio. Bluetooth no longer imposes
an unnecessary 16-pixel alignment; the actual encoder requirement is used.

The hybrid client uses normal aspect-preserving fitting. The earlier stretching
workaround is removed. Because capture aspect ratios now match across quality
changes, the same window continues to fill without alignment-induced padding,
cropping or nonuniform scaling. Direct ADB input and codec selection stay unchanged;
its screen capture also uses the shared exact-aspect sizing. If no exact-ratio
size meets the limit and encoder constraints, capture fails explicitly rather
than silently distorting the screen. Native can be reduced on an encoder whose
alignment cannot represent the source resolution exactly.

BLE continues carrying input, video acknowledgements, heartbeats and phone-use
events. Classic remains connected as part of the session lifetime. Bluetooth starts
at approximately 480p / up to 16 fps / 256 kbps. After the confirmed handoff, Wi-Fi
uses the saved **Picture (Wi-Fi / ADB)** resolution, frame-rate and bitrate targets:
1920 px longest edge, up to 60 fps and 12 Mbps by default. Regular HEVC (H.265
Main, 8-bit) is required for both Bluetooth and Wi-Fi in hybrid mode, regardless
of the direct ADB codec preference. No H.264 fallback or SCC is enabled. Direct
ADB sessions keep their selected codec and carry their input through ADB. Native resolution (limit 0) is also supported; actual
frame rate and dimensions depend on the phone and codec. Settings are captured
when starting the session. Audio is still disabled.

The Bluetooth codec-specific 16 fps, gradual-refresh and adaptive bitrate options
are removed at reconfiguration so they cannot cap Wi-Fi quality. The video ACK
window grows from 24 KiB to 2 MiB only after receiver confirmation, with cumulative
BLE ACK validation retained. The relay accepts encoded packets up to 8 MiB after
handoff and emits envelopes up to 16 KiB. The Mac drains up to 512 KiB each 20 ms
tick, retaining its bounded 128 KiB pending queue. These changes remove the prior
BLE-ACK and single-read throughput caps without adding a video playback buffer.

The window labels its Bluetooth controls, while connection status shows the
Wi-Fi resolution, frame-rate and bitrate targets after the cutoff is reached.
There may be a short pause while Android resets the codec. An unsupported profile
or codec reconfiguration failure ends the session through normal recovery.

Failed discovery, authentication or pre-commit probes leave Bluetooth running.
After a committed handoff, ADB socket loss triggers an authenticated BLE request
to restart Classic video. Bluetooth video stays idle while Wi-Fi is active; no
parallel encoder or video stream runs. The request carries the connection's random
nonce and the exact cumulative payload offset accepted by the Mac. Old connection
requests cannot reset a newer upgrade. Android closes the ADB socket to unblock any
writer, restores the original Bluetooth HEVC profile (exact-aspect resolution,
16 fps, 256 kbps, bitrate control and freshness recovery), and replays the bounded
unacknowledged byte suffix on Classic. This completes a packet interrupted by ADB
loss without duplicate bytes or decoder corruption. The same local scrcpy socket,
process and window remain alive. Recovery waits for this suffix before continuing
new Bluetooth-profile frames, so a large in-flight frame can extend the pause.
Companion 0.21 shuts down both directions of the ADB socket before closing it,
releasing a native write before recovery acquires the video lock. Replay obeys
the Bluetooth ACK window without counting already-sent bytes twice. ACK progress
renews the stall deadline, so a long but advancing replay does not end capture;
duplicate ACKs do not renew it. Wireless reservations allow twelve seconds without
progress to cover silent-loss detection and BLE recovery; Bluetooth retains its
five-second stalled-peer timeout. The Mac shows recovery status and retries the
nonce-bound BLE request once per second until Classic data resumes.

Sparse one-second ADB envelope heartbeats never enter the decoder. Four seconds
without transport data triggers the same BLE fallback for silent network loss.
Input, acknowledgements and phone-use handling continue over BLE during recovery.
After Bluetooth resumes, the Mac resumes wireless discovery after a three-second
backoff; subsequent upgrades reuse the same capture session. BLE or Classic loss
still ends the session. Direct ADB sessions keep their existing behavior.

Older companions continue Bluetooth-only mirroring when their endpoint does not
advertise DMWIFI03. Install both matching builds for automatic fallback.

Validation: `bash Native/test-wireless-upgrade.sh` runs the existing Bluetooth
wire regression tests, Java handoff/authentication tests, and Java-generated
fixtures through the real C parser with address/undefined-behavior sanitizers.
It verifies exact payload continuity across different offsets and fragmentation,
cutoff authentication, direction/nonce separation, repeated-upgrade rejection,
Bluetooth continuation after a response-write failure, large-frame throughput
accounting, authenticated profile bounds and profile tampering. JVM socket
substitutes exercise the production upgrade endpoint: wrong-key/invalid-profile
rejection, receiver confirmation before requesting quality, continued video and
failed-confirmation recovery, stale-nonce rejection and repeated upgrades. Fault
injection disconnects within envelope headers and frame payloads, then checks exact
byte continuity through both Java and the C parser. BLE queue tests check recovery
signal priority without splitting input envelopes; a real native socket EOF test
checks that recovery requests preserve the existing scrcpy socket. Swift compilation,
native helper linking and Android assemble/lint are also checked. Physical-device
validation is still required for wireless ADB reconnection, actual window identity,
input during transition, phone takeover, teardown and radio/network failure.

## HEVC encoder selection and validation

Companion 0.15 selects a Main-profile, surface-input HEVC encoder, preferring
hardware. It requests CBR if advertised, otherwise VBR, and requests gradual
intra refresh only if the selected codec advertises that feature. The 256 kbps
value remains a target, not a guaranteed hard traffic cap. A phone without a usable
HEVC encoder reports capture failure instead of switching to AVC. The Shizuku
display-guard version is incremented so APK replacement cannot retain an old
H.264 capture daemon. The wire codec ID is `h265` and the diagnostic stream checker
requires that header.

`Native/test-hybrid-hevc.py` compiles a synthetic GPU source and runs the real
SurfaceEncoder from the built companion on an authorized test phone. It does not
install the APK, capture the physical screen or inject input. On the connected
Pixel 8 it selected `c2.exynos.hevc.encoder`, encoded a 468×1040 Bluetooth profile,
then reset the same stream through Wi-Fi, Bluetooth fallback, another Wi-Fi
upgrade, 576×1280, native 1080×2400, and a second Bluetooth fallback. The Wi-Fi
targets use 60 fps / 12 Mbps; both fallbacks restored 468×1040 / 16 fps / 256 kbps. Every decoded frame preserves the source
aspect ratio exactly.
All resolutions decoded with the Mac FFmpeg HEVC decoder; subsequent session
metadata retained the client-resize flag that prevents automatic window resizing.
The driver reported VBR in its output format despite advertising/receiving the
CBR request, so this test does not establish strict CBR. Intra refresh was not
advertised and was omitted. This is codec/reconfiguration validation with synthetic
frames, not a radio-throughput, perceived-quality, actual-fps or live-window test.

```sh
JAVA_HOME=/path/to/jdk python3 Native/test-hybrid-hevc.py
```

Build the companion first (`assembleDebug`); the probe uses its compiled classes
and APK from `BluetoothCompanion/build`. SDK/build-tools 36 and local FFprobe are
required. Temporary probe files and synthetic video are removed after testing.
