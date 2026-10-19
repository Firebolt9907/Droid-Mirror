# Wireless content encryption audit

Auditor: Jeffrey Turkstra. Date: October 16, 2026.

## Scope and conclusion

Reviewed the current working tree, including its uncommitted Swift, Objective-C/C, Java, Kotlin and customized scrcpy changes. This is a source audit with focused protocol tests, not a radio capture or a verification of the installed APK/app. Existing application files were not changed.

**Normal paired Bluetooth and Android 11+ TLS Wireless debugging paths are designed to encrypt user content in transit. There is no basis to claim the normal screen stream is broadcast unencrypted. However, the app does not enforce TLS for every wireless ADB connection: legacy plaintext ADB can carry the full video stream, and direct ADB mode can expose additional content.**

“No application encryption” differs from “no encryption over the air.” Video has no app-level confidentiality layer, but Bluetooth link encryption or ADB TLS normally protects it. H.264/HEVC compression and HMAC authentication are not encryption.

## How much content is exposed?

| Mode | User payload without app-level encryption | Expected protection over the wireless hop | Potential unencrypted user content |
| --- | --- | --- | --- |
| Bluetooth startup and fallback | Entire compressed screen video and its stream headers | Authenticated, encrypted Classic L2CAP requested from Android | None expected under the platform contract; actual negotiated radio security was not measured |
| Automatic handoff through TLS ADB | Entire compressed screen video | ADB TLS | None expected; BLE controls remain separately encrypted |
| Automatic handoff through legacy TCP ADB | Entire compressed screen video | No ADB encryption; Wi-Fi/VPN protection depends on deployment | 100% of video payload on that leg, plus stream metadata; BLE controls remain encrypted |
| Direct TLS ADB mode | Video, enabled audio, input, clipboard, file transfers and ADB commands | ADB TLS | None expected |
| Direct legacy TCP ADB mode | Same as direct TLS mode | No ADB encryption; Wi-Fi/VPN protection depends on deployment | 100% of the ADB payload on that leg |
| BLE notification and endpoint bridge | User content has app encryption | AES-256-GCM | Discovery and protocol metadata remain visible if the link itself is unencrypted |

These are fractions of each affected payload, not measured fractions of all traffic. There is no packet capture or byte accounting from an actual session to establish an aggregate percentage. Video normally dominates bandwidth. At the default 12 Mbps video target, a plaintext ADB leg could expose about 1.5 MB/s or 90 MB/min of compressed screen content if the encoder sustains that target, excluding overhead and other channels. This is an illustration, not a measured throughput result; actual bitrate varies. See `Sources/DroidMirror/Models.swift:67`.

Even plaintext ADB over WPA-protected Wi-Fi may be encrypted on the radio hop. It is still readable after Wi-Fi decryption by an access point/operator or another suitably positioned interceptor. A genuinely encrypted VPN tunnel can also protect a legacy ADB leg. The app does not establish or validate either protection for arbitrary endpoints.

## Findings

### 1. High: wireless ADB connections are accepted without a TLS requirement

`Sources/DroidMirror/ClassicBluetoothTransport.swift:60` iterates connected ADB devices and accepts either a serial containing `:` or the TLS mDNS suffix. An `IP:port` serial is not proof of TLS. It forwards `localabstract:droidmirror_video_upgrade` through that transport and attempts handoff. A previously authorized legacy ADB connection to the same phone can therefore qualify. The pairing-key HMAC still has to succeed: a random other phone cannot simply take over the stream.

The manual connection path (`Sources/DroidMirror/MirrorModel.swift:645`) passes arbitrary addresses to `adb connect`. Device enumeration and selection (`MirrorModel.swift:159`) do not reject unencrypted ADB transports. The app does not itself enable `adb tcpip`; exposure requires a legacy listener/connection to exist.

The hybrid handoff authenticates the profile and cutoff, but subsequent video records are written directly: `BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/BluetoothWire.java:92` and `:126`. That handshake authenticates the peer; it does not encrypt or individually authenticate subsequent video records. Legacy ADB consequently permits observation and, for an attacker able to modify the connection, stream corruption/substitution. Malformed stream injection adds decoder attack surface, without establishing a decoder exploit.

Direct ADB uses the same underlying transport for substantially more functionality. Consequences by content type appear below.

**Fix:** enforce a verified TLS transport before manual connection, direct mirroring and automatic handoff. Do not infer security from a colon, a port number, a device name or authorization status. Add explicit rejection tests for legacy authenticated ADB, including handoff to the correct paired phone over that connection. An authenticated-encryption video protocol would provide defense in depth for hybrid video, but would not fix plaintext direct ADB shell, audio or file traffic.

### 2. Medium: the Android TLS probe accepts plaintext ADB responses

`BluetoothCompanion/src/main/java/app/droidmirror/bluetooth/bridge/AdbEndpointFinder.kt:189` returns true for `STLS`, `AUTH` or `CNXN`. Only `STLS` signals the TLS upgrade here. Legacy ADB can return `AUTH` or `CNXN`, so `isAdbTlsPort` proves only that a listener resembles ADB.

This affects mDNS candidate checks, cached-listener refresh and the fallback scan of ports 30000–65535. The preferred `service.adb.tls.port` property and TLS mDNS service normally lead to TLS; the weak probe is a conditional alternate path, not evidence that ordinary discovery always chooses plaintext. Standard legacy port 5555 is outside the fallback scan, but custom legacy ports can be inside it. The Mac then invokes `adb connect` without an independent TLS check (`Native/BLEController.swift:85`). A real Tailscale route would independently encrypt transport; the endpoint field alone does not prove one exists.

**Fix:** reject `AUTH` and `CNXN` in a TLS-only probe, require `STLS`, and validate the eventual connection security. Add tests covering all three response types. Treat the port property and mDNS name as discovery information, not sufficient proof of the actual connection's security.

### 3. Low: discovery and protocol metadata can remain observable

BLE advertising exposes the app service UUID and presence, allowing nearby observers to infer use of DroidMirror. The bridge deliberately excludes the device name (`bridge/BlePeripheral.kt:91`). Its GATT characteristics use ordinary read/write permissions, so the code does not require BLE link encryption; application encryption protects the content instead.

Bridge hello/challenge/finish messages expose random nonces and HMAC proofs. Fragment headers expose message ID, offset and total length; encrypted envelopes expose sequence/size information. Input-channel setup exposes a public 32-byte session nonce and authenticated uptime/clock data to the selected bonded peer (`BleInputServer.java:147`). These are not the pairing key. A passive observer of an unencrypted link may infer timing, message sizes and activity. The source does not establish that link encryption is absent in a specific session.

ADB mDNS discovery can expose service identity, endpoint addresses and ports on the local network independently of encrypted session content. Android's ADB documentation describes this discovery mechanism. Experimental Wi-Fi Aware only probes discovery for `_droidmirror._tcp`; `Native/WiFiAwareBridge.m:89` explicitly reports no implemented streaming transport.

**Fix:** consider requiring encrypted GATT access, stop unnecessary advertising when idle, and minimize discovery lifetime. Padding is an optional response to traffic analysis; ordinary content encryption does not hide packet timing or size.

## Risk for each user-content type

| Content | Current protection | Risk if carried on a plaintext legacy ADB connection |
| --- | --- | --- |
| Screen video | Classic link encryption or ADB TLS; no app-level video cipher | **High:** reveals all captured pixels: messages, documents, account details and visible authentication codes. Android-protected blank screens remain blank; the app's secure-screen overlay reports WindowManager flags; it provides no encryption. |
| Forwarded audio | ADB transport; hybrid Bluetooth mode explicitly disables audio | **High:** exposes audio actually forwarded by scrcpy, potentially private playback or spoken information. This is not evidence of microphone capture in the normal profile. |
| Keyboard, pasted text, PINs and navigation | Hybrid uses AES-256-CTR plus HMAC with directional keys and replay/order checks; direct mode uses ADB | **High:** direct ADB can reveal typed secrets and permit command/input manipulation by an active interceptor. A black or secure video screen does not hide input records. Pointer movements and scrolling also reveal behavior. |
| Clipboard text and clipboard replies | Hybrid control/return records use encrypted BLE; direct mode uses ADB | **High:** may reveal passwords, tokens or private copied text. Clipboard modification can change pasted destinations or commands. Applies to text the clipboard features actually transmit, not arbitrary clipboard history. |
| Dragged files and APK installation requests | scrcpy file pusher invokes ADB push/install | **High:** full transferred contents and paths can be exposed; active modification can compromise file integrity. Only files actually transferred are included. |
| Notification app labels, titles, bodies, icons, action identifiers and reply text | Separate BLE bridge uses AES-256-GCM and authenticated sessions | **Low residual wireless confidentiality risk under the implemented crypto:** not exposed merely because ADB is plaintext. These would be highly sensitive if pairing credentials or endpoints were compromised. |
| ADB endpoint port/IP and bridge status | AES-GCM over BLE; separate mDNS advertisements may still disclose endpoints | **Low metadata risk:** enables service discovery and targeting; an endpoint is not a credential. |
| Shell commands, settings and UI hierarchy checks | ADB TLS when used correctly | **High on plaintext ADB:** commands and returned UI/system information can be observed or modified. Passive observation does not by itself recover the host's private ADB authentication key. |
| Session events, heartbeats, acknowledgements, control replies | Hybrid encrypts these through BLE; wireless video also includes a sparse transport heartbeat | **Low standalone sensitivity:** reveals liveness and timing if exposed. Modification can disrupt sessions where transport integrity is absent. |

## Existing protections and remaining limits

- Classic Android sockets use `listenUsingL2capOn`, not its insecure counterpart, and require the selected bonded Mac (`ClassicL2capService.java:45`, `:77`). AOSP defines that API as encrypted and authenticated. The one-argument overload does not request the optional stronger pairing MITM/PIN flags. The app does not inspect negotiated key strength or add its own video AEAD; platform behavior and pairing quality remain dependencies.
- Input and return records use separate AES-256-CTR and HMAC-SHA256-derived keys, a 128-bit MAC tag and strict sequence checks. `BleInputCrypto.java:34` verifies the MAC before decryption. The public session nonce derives session keys from the private pairing root; transmitting it is not transmitting that root.
- Notifications, actions, replies and BLE endpoint payloads use AES-256-GCM with direction-specific derived keys and sequence checks (`bridge/BleSecurity.kt:54`; `Native/BLESecurity.swift:96`).
- BLE session keys derive from static pairing credentials plus transmitted nonces; there is no ephemeral key exchange providing forward secrecy. Later compromise of a root credential can expose previously recorded BLE sessions. Android stores pairing roots in private SharedPreferences; macOS uses Keychain. This is a credential-compromise concern, not proof of plaintext transmission.
- The Mac video/control bridge binds loopback (`Native/ClassicBluetoothBridge.m:451`); Android upgrade sockets are local abstract sockets. Their plaintext bytes are not independently broadcast over Wi-Fi. Local malware is a separate endpoint threat.
- No third-party HTTP/WebSocket content upload path was found in the reviewed application network code. This does not audit the external ADB binary, Android/macOS, other phone apps, or network infrastructure.

## Validation

Ran the existing C and Java BLE input crypto tests against current sources: independent vectors, both transmission directions, tamper rejection, replay/order rejection, directional/session isolation and bounds passed.

Ran `Native/test-wireless-upgrade.sh` successfully, including endpoint/profile authentication, failed-confirmation teardown, Java/C stream continuity, Bluetooth fallback, BLE queues and startup/socket recovery. The initial sandboxed run could not bind a local test socket; the permitted rerun passed the full suite. These tests exercise protocol behavior and cannot prove TLS enforcement or the negotiated radio encryption of a real device.

To quantify a real session, capture traffic for Bluetooth-only, TLS handoff and direct TLS ADB modes; verify Bluetooth encryption state and ADB STLS/TLS negotiation; map byte counts to each transport. Test legacy rejection in an isolated environment after remediation. Do not substitute an IP/port naming convention for transport verification.

## Platform references

- [AOSP BluetoothAdapter implementation](https://android.googlesource.com/platform/packages/modules/Bluetooth/+/refs/heads/main/framework/java/android/bluetooth/BluetoothAdapter.java): encrypted/authenticated L2CAP API and its insecure counterpart.
- [AOSP Architecture of ADB Wifi](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/adb_wifi.md): legacy TCP ADB is unencrypted; paired Wireless debugging uses TLS; service discovery and STLS behavior.
