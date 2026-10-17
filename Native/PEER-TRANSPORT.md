# LAN → wireless ADB → Bluetooth (companion 0.26)

Automatic mode starts video over Classic Bluetooth immediately. Once capture is
running, it tries these video paths in order:

1. Iroh with direct LAN connections and local multicast discovery only.
2. An already-authorized wireless ADB device, using a session-owned loopback forward.
3. Bluetooth, which continues while both faster paths are unavailable.

**Relay servers are disabled on both endpoints. Public Iroh DNS/pkarr discovery
is also disabled.** The transport uses the Minimal preset, explicit
`RelayMode::Disabled`, and only `iroh-mdns-address-lookup`. It cannot fall back to
a hosted relay. No account, paid service, Tailscale or internet connection is
needed for the LAN path. LAN multicast/peer isolation can make that path unavailable.

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
succeeds. A successful video path remains active until it drops or the session ends.

## Pairing, handoff and recovery

The random 32-byte BLE pairing credential derives separate phone/Mac Ed25519
identities using HMAC-SHA256 with distinct role labels. Iroh authenticates the
remote identity using TLS; Android rejects any unpaired identity before opening
the application socket. Keys are never placed in arguments, environment variables,
discovery records or logs. Updating the pairing changes endpoint identities.

Android waits for the QUIC stream and `DMPEER01` preface before opening its local
handoff socket. This prevents discovery/stream setup from consuming the local
application's two-second proof deadline. The Mac helper allows the LAN dial to
finish before waiting for the DMWIFI03 challenge. DMWIFI03 authenticates the
requested quality profile and exact byte cutoff again on either path.

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
