# QR delivery of the existing pairing key

In Mac setup or Bluetooth settings, select the phone and choose **Pair with QR
code…**. In the Android **Pair DroidMirror** step, select the same bonded Mac and
choose **Scan Mac QR code**. Wait for the save confirmation on both devices.
System Bluetooth bonding, Shizuku and notification permissions remain separate.
Android requests camera permission for scanning, and Nearby devices scanning
permission (location permission on Android 8–11).

This is an optional provisioning path. It uses `BlePairing.key(context, mac)`,
exactly like **Show pairing code**: an existing per-Mac key is returned unchanged;
a first-time key is created only by the explicit user action. Mac storage uses
`ClassicBluetoothTransport.pair`, including the existing Keychain items and
notification-key derivation. The existing authentication and transport protocols
are unchanged. Older clients continue to use manual code entry. No existing
client is required to rescan, rotate keys or upgrade for its existing pairing.

## Bootstrap protocol v1

The Mac temporarily advertises a random 128-bit service UUID, containing one
read/write characteristic `A946DDA2-7E71-4ACD-B670-F77C3D715891`. Android acts as the
central for this separate service; normal mirroring retains its existing roles.

The QR URI is `droidmirror-pair://v1` with `service`, `mac` and `secret` query
parameters. `mac` is the host's bonded Classic address, used to select the
existing Android key, not the BLE advertiser's possibly private address. `secret`
is a fresh 32-byte CSPRNG value encoded as unpadded URL-safe Base64. Treat the QR
as a temporary authorization credential: only scan it with the intended phone.
No permanent key appears in the QR, advertisements, logs or network URLs.

Android checks that `mac` matches the Mac selected in setup. It scans for the
invitation's service UUID and sends a 60-byte AES-256-GCM packet: 12-byte random
nonce, 32-byte encrypted existing key and 16-byte tag. Associated data is UTF-8:

```
DroidMirror QR key transfer v1|UPPERCASE-SERVICE-UUID|UPPERCASE:MAC:ADDRESS
```

Writes use ATT responses and 20-byte fragments, requiring no MTU upgrade. The Mac
bounds the buffer to 60 bytes, binds fragments to one central and clears partial
transfers after five seconds of inactivity when the next write arrives. It checks
its two-minute deadline and GCM authentication before any save. Once a valid
packet is accepted, the invitation is consumed before awaiting Keychain; duplicate
or replayed writes cannot cause another save. Closing setup stops advertising,
removes the service and clears temporary credentials. Mirror startup and manual
pairing are blocked while QR setup is open.

Only after the existing save path succeeds does the Mac acknowledge the final
write. Android then reads a 16-byte truncated HMAC-SHA256 proof keyed by `secret`,
over the associated data followed by UTF-8 `|saved|` and the complete encrypted
packet. It compares the proof in constant time before displaying success. A
lookalike BLE service cannot forge this confirmation merely by accepting writes.
The Mac keeps this read-only confirmation available to the same central for
15 seconds or until setup closes; further writes are rejected. Android bounds
scan/connect/transfer to 90 seconds and cleans up on activity destruction.

The bootstrap secret protects this transfer only. Existing per-session mutual
authentication, directional encryption keys and sequence checks remain unchanged.

## Validation

- `bash Native/test-qr-pairing.sh`: actual Java encryption to Swift decryption,
  cross-language save confirmation, unchanged key bytes, fresh nonces, every
  packet byte tampered, wrong target/invitation/secret, malformed lengths.
- `bash Native/test-onboarding.sh`: QR pairing excludes simultaneous mirror,
  manual save and second invitation; cancellation does not mark pairing verified.
- Android `assembleDebug`, Mac `swift build`, and existing integrated BLE tests.

Physical-device QR scanning, Mac advertising and the complete Keychain/GATT save
round trip still require a walkthrough using matching builds. A successful build
or cryptography test does not verify radio interoperability. These changes do
not install or restart either app. When installing updates, end active mirroring
gracefully before replacing components, as required by `AGENTS.md`.
