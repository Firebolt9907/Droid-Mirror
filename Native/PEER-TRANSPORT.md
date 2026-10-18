# LAN → wireless ADB → Bluetooth (companion 0.29)

Automatic mode starts video over Classic Bluetooth immediately. Once capture is
running, it tries these video paths in order:

1. Iroh over direct LAN or Tailscale/VPN IPs, discovered through authenticated BLE hints and local multicast.
2. An already-authorized wireless ADB device, using a session-owned loopback forward.
3. Bluetooth, which continues while both faster paths are unavailable.

**Relay servers are disabled on both endpoints. Public Iroh DNS/pkarr discovery
is also disabled.** The transport uses the Minimal preset, explicit
`RelayMode::Disabled`, local `iroh-mdns-address-lookup`, and session-local
IP candidates received over authenticated BLE. It cannot fall back to
a hosted relay. No account, paid service, Tailscale or internet connection is
needed for the LAN path. LAN multicast/peer isolation can make multicast discovery unavailable; BLE address hints allow a reachable Tailscale/VPN path to work independently.

Bluetooth continues to carry startup, input, acknowledgements, events and recovery.
This is not internet-only remote control. Shizuku is still required for privileged
capture/input. Wireless ADB fallback requires Wireless debugging and one-time Mac
ADB pairing; the background bridge does not turn debugging on automatically.

The Mac waits for the LAN probe to fail before trying ADB. LAN dialing has a
five-second budget; its application handshake has a separate twenty-second safety
budget. A missing native library or failed LAN authentication also advances to
ADB. Only online wireless ADB devices are tried; USB transports are excluded.
Both paths must authenticate with the selected phone's BLE pairing key, so an
unrelated connected ADB device cannot take over. Unavailable/untrusted candidates
leave Bluetooth streaming. Discovery repeats after ten seconds when no upgrade
succeeds. Iroh must also pass a latency comparison with Bluetooth before handoff. Both
paths carry phone monotonic packet timestamps; comparing arrival-minus-send
medians cancels the clock offset and includes packet queueing and delivery time.
At least three samples per path are required. A seven-sample median and 10 ms
hysteresis filter jitter. While Iroh is active, delivery that remains slower than
the measured Bluetooth baseline for two seconds triggers authenticated Bluetooth
recovery. The baseline is refreshed during Bluetooth streaming and each preview;
it is an estimate of Bluetooth performance while Iroh is active. Rejected or
slow Iroh paths have a 60-second retry cooldown. Wireless ADB remains an optional
fallback under the existing discovery policy. These are packet delivery measures,
not screen-to-screen latency measurements.

## Pairing, handoff and recovery

The random 32-byte BLE pairing credential derives separate phone/Mac Ed25519
identities using HMAC-SHA256 with distinct role labels. Iroh authenticates the
remote identity using TLS; Android rejects any unpaired identity before opening
the application socket. Keys are never placed in arguments, environment variables,
discovery records or logs. Updating the pairing changes endpoint identities.

Android waits for the QUIC stream and `DMPEER01` preface before opening its local
handoff socket. This prevents discovery/stream setup from consuming the local
application's two-second proof deadline. The Mac helper allows the LAN dial to
finish before waiting for the DMWIFI05 challenge. DMWIFI05 authenticates the
requested quality profile and exact byte cutoff again on either path.

Before committing a cutoff, Android mirrors video chunks and frame boundaries
into a bounded candidate queue while continuing to write every byte over Classic.
The endpoint worker sends that preview over Iroh (or the ADB fallback); it never
writes to the candidate socket while holding the Bluetooth writer monitor. The
Mac authenticates the preview, requires three frame completions (the first may
be partial) over at least 250 ms, and confirms readiness. Only then does Android
stop the preview and perform the existing byte-exact cutoff handshake. Quality
increases after the receiver drains the Classic cutoff. A blocked candidate,
queue overflow, missing confirmation or 10-second warm-up deadline leaves
Bluetooth video active. Both apps must be updated for this warm-up protocol. DMWIFI05 adds timestamp
preview records (length -2 followed by a big-endian 64-bit nanosecond timestamp)
and video envelope type 5 (the same 8-byte timestamp). Telemetry starts only after
the new authenticated handshake. Older companion handshakes leave Bluetooth active.

The same HEVC capture, decoder, scrcpy process and window are retained across
handoffs. BLE input remains connected. On loss, the authenticated BLE recovery
request restores Bluetooth video and its original quality profile, replaying the
unacknowledged suffix without changing decoder byte continuity. After recovery,
the Mac again tries LAN before wireless ADB. Session-owned ADB forwards are removed
at teardown; stale forwards are recreated after ADB disconnection/reconnection.

The JNI endpoint exists only during capture. Android releases its multicast lock
and endpoint at teardown. The Mac closes its endpoint with the Bluetooth helper.
Copies have bounded buffers and backpressure. EOF closes both stream directions.
Native errors appear under `DroidMirrorIroh` in Android logcat and in the Mac
session log. No network endpoint listens while mirroring readiness is merely idle.

## Build and validation

Install Rust 1.91+, Android NDK 28+ and the Android target:

```sh
rustup target add aarch64-linux-android
cargo test --locked --manifest-path PeerTransport/Cargo.toml
bash Native/test-wireless-upgrade.sh
ANDROID_HOME="$HOME/Library/Android/sdk" ./BluetoothCompanion/gradlew -p BluetoothCompanion assembleDebug lintDebug
./build-app.sh
```

The Mac bundles and signs `libdroidmirror_peer.dylib`. Gradle builds the matching
JNI library using locked Rust dependencies. The default APK ABI is `arm64-v8a`.
For other devices/emulators, install the corresponding Rust targets and set
`DROIDMIRROR_ANDROID_ABIS` to a comma-separated subset of
`arm64-v8a,armeabi-v7a,x86_64`. `ANDROID_NDK_HOME` can select the NDK.

Tests cover production endpoints with no relay addresses and no public lookup,
exact transfer of two million bytes over encrypted direct QUIC, unpaired identity
rejection, delayed QUIC startup without expiring the application proof deadline,
and a delayed native challenge that exceeded the old two-second Mac timeout.
The existing handoff suite checks authentication, Java-to-C byte continuity,
quality confirmation, BLE recovery and preservation of the decoder stream. Swift
compilation and Android assemble/lint check integration. Actual LAN discovery,
network isolation, ADB fallback and radio-failure behavior also require physical
phone testing with the matching builds.

## Direct VPN address exchange (0.27)

Android advertises its actual Iroh UDP ports and unicast interface addresses over
the capture session's authenticated BLE return channel. Native wildcard bind ports
are read directly, then Android NetworkInterface and ConnectivityManager LinkProperties addresses add VPN interfaces
(such as Tailscale IPv4 and IPv6) even when native discovery omits them. Wildcard,
loopback, multicast and scoped link-local addresses are not advertised as routes.
A snapshot reset plus at most 32 fixed-size DMIP0001 records carries IPv4/IPv6
and per-family UDP ports in BLE setup envelopes (type 3, 32-byte payload).
Updates are published when addresses change. No ADB operation locates Iroh.

The Mac reassembles these records, caches them before starting the native endpoint,
and supplies them as explicit EndpointAddr IP candidates on subsequent dials.
These hints are transport locations, not authentication: QUIC still requires the
phone identity derived from the selected BLE pairing. Iroh selects a working
direct path; the session log prints the selected IP/port to distinguish LAN and
Tailscale. Iroh relays and public discovery remain disabled. Tailscale itself
controls whether its underlying connection is direct or uses its own DERP service.

Install the current Mac build and Android 0.29: an older Mac does not understand
the address setup records. Tests cover Tailscale IPv4/IPv6 hints, wildcard bind
ports, malformed/unsafe candidates, fragmented BLE envelopes, snapshot reset,
deduplication, decoder isolation and QUIC dialing without any discovery service.

## Listener reuse and idle capture (0.29)

Closing the phone upgrade endpoint first calls `Os.shutdown(SHUT_RDWR)` on its
listening descriptor, closes the descriptor and candidate, and briefly joins
its worker. This wakes Android's blocking accept before the next session reuses
the abstract socket name. A stale listener previously prevented construction of
both the upgrade socket and Iroh endpoint, leaving every probe on Bluetooth.
`Native/AndroidUpgradeListenerProbe.java` exercises 30 real Android accept/rebind
cycles when run through app_process.

Warm-up does not depend on screen activity. Capture retains at most 128 KiB of
the latest complete Bluetooth frame; an idle candidate can send that packet at
100 ms intervals until the Mac confirms delivery. These copies never enter the
Mac decoder or Classic stream. Fresh video still continues over Bluetooth until
the cutoff commits. Endpoint tests cover a fully static screen and verify both
unchanged Classic bytes and the exact final cutoff.

QUIC uses 1200-byte UDP payloads with path-MTU probing and segmentation offload
disabled on both peers. This avoids depending on VPN/hotspot driver support for
larger or offloaded datagrams. Live testing reproduced successful small
handshakes followed by stalled high-quality video with the defaults; the
conservative packet settings delivered the larger video frames and sustained
ACK progress. Relays and public discovery remain disabled. Each tunnel logs
three early local/peer byte counters to distinguish application stalls from
transport delivery failures without recording media or credentials.
