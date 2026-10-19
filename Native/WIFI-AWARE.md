# Wi-Fi Aware experimental connection

This is an investigation scaffold, **not a working third video transport**.
Select **Wi-Fi Aware (experimental)** in connection settings and use **Check
Wi-Fi Aware support** for the local readiness result. This mode never starts
ADB, discovers ADB devices, or silently falls back to Bluetooth. Mirror remains
unavailable until a real NAN data path and streaming integration exist.

## What was verified on this Mac

On macOS 27.0.1 (26A434), arm64, on October 14, 2026:

- WiFiAware.framework loads and exports WACapabilities.supportedFeatures.
- The installed SDK marks its Swift API unavailable on macOS.
- Calling that API in an isolated probe with availability checking disabled
  returns an empty feature set and zero device/publish/subscribe limits.
- WiFiPeerToPeer.framework contains Objective-C WiFiAwareSubscriber,
  WiFiAwareDataSession, and WiFiAwareDeviceCapabilities implementations.
- The private `+[WiFiAwareDeviceCapabilities currentDeviceCapabilities]`
  returns nil. This does not establish whether the hardware supports NAN.
- An actual private discovery request fails with error 1. Outside the command
  sandbox, the system log explicitly reports missing `com.apple.wifip2pd` OR
  `com.apple.developer.wifi-aware` entitlement. The daemon itself is running.
- Temporary ad hoc signed executables with either entitlement terminate with
  status 137. Merely adding an entitlement plist does not make this usable.
  The later development-signed test below identified a missing provisioning
  profile as its AMFI rejection reason.

No SIP, AMFI, Wi-Fi settings, provisioning, or system files were changed.
No claimed throughput or Android interoperability has been measured.

## Reproduce

See [the local private API inventory](WIFI-AWARE-PRIVATE-APIS.md) for additional
discovery, data-session, pairing, state-monitoring, and XPC entry points recovered
from this Mac's installed frameworks.

The helper uses dlopen and runtime selector checks, keeping the unsupported
framework out of the main app's linkage and retaining macOS 14 deployment.
It produces one JSON document; private API exceptions cause a nonzero exit.
A successful command exit means the probe ran, not that NAN is supported.

```sh
xcrun clang -Wall -Wextra -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
  -framework Foundation -framework Security Native/WiFiAwareBridge.m -o /tmp/DroidMirrorWiFiAware
/tmp/DroidMirrorWiFiAware --probe
/tmp/DroidMirrorWiFiAware --test-discovery
```

`--probe` only queries capabilities. `--test-discovery` attempts a subscription
to `_droidmirror._tcp` for at most five seconds and stops it before exit. It
reports started, rejected (with raw error code), timeout, or apiUnavailable.
The app attempts native discovery once on selection or explicit refresh;
it does not attempt radio discovery every three seconds.

## Remaining work before a direct stream can ship

1. Obtain signing/provisioning that the Mac accepts for daemon access, then
   verify actual capabilities. Runtime existence alone is insufficient.
2. Validate subscription callbacks and discover an Android publisher using
   Android WifiAwareManager. The current Android companion has no NAN service.
3. Negotiate an authenticated NAN data path with a per-pair credential, a
   selected peer, and a verified interface-scoped IPv6 endpoint. Do not send
   raw mirroring video over an unauthenticated advertised endpoint.
4. Bind sockets to that direct interface, adapt the existing capture/video
   protocol to TCP, and feed the bundled scrcpy external-video input. Preserve
   session end, phone takeover, cancellation, backpressure, and cleanup.
5. Measure throughput/latency and exercise reconnect, Wi-Fi toggling, concurrent
   Bluetooth sessions, unsupported Android hardware, and authorization failure
   on physical devices. Only then enable Mirror for this transport.

No fabricated peer, LAN/ADB substitute, unrestricted-entitlement workaround,
or untested success path is included.

## Native app integration and authorization

The Catalyst experiment, build flag, persistent IPC server, and Catalyst tests
have been removed. The app uses the native macOS helper only. Rebuilding removes
any retired Catalyst helper from the app bundle before signing it.

**Check Wi-Fi Aware support** now invokes `DroidMirrorWiFiAware --check`: it loads
`WiFiPeerToPeer.framework`, queries capabilities, checks the calling process's
Wi-Fi Aware subscription entitlement with `SecTask`, and attempts a real private
subscription for up to five seconds. The app displays the discovery outcome.
The check runs on selection/explicit refresh, not every background timer tick.
`--probe` remains a capability-only CLI operation; `--test-discovery` aliases
`--check`. No successful discovery or capability query enables mirroring by itself.

On October 14, 2026, the native helper reports:

```json
{"authorizationStatus":"missingEntitlement","capabilitiesAvailable":false,"discoveryStatus":"rejected","discoveryError":1,"streamImplemented":false}
```

Disassembly of the installed `+[WiFiP2PXPCConnection supportsWiFiP2P]` shows it
checks the caller's entitlements. Therefore its false result must not be treated
as a hardware capability result. `currentDeviceCapabilities` also goes through
this XPC connection layer. Private API presence does not establish usability.

A fresh test outside the command sandbox produced the same discovery rejection.
A temporary native executable with service metadata and the documented entitlement
`com.apple.developer.wifi-aware = ["Subscribe"]`, signed using the available Apple
Development identity, was killed by macOS before emitting JSON (signal 9). No local
provisioning profiles were found in either standard Xcode provisioning directory.
AMFI logged `AppleMobileFileIntegrityError Code=-413`, `No matching profile found`,
with `com.apple.developer.wifi-aware` listed as the unsatisfied entitlement.
The same certificate ran a baseline helper with an empty entitlement dictionary,
confirming the certificate itself was usable.
The shipping app/helper retain their runnable ad hoc signatures.

The native discovery API is integrated, but the requested working NAN connection
remains blocked: a macOS-accepted Wi-Fi Aware authorization/signing configuration
is required before we can test actual platform support, Android discovery, or
PMK/passphrase data paths. A development certificate alone did not supply that
access. An authorized profile would not itself prove the Mac supports NAN.

[Apple's entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.wifi-aware)
defines `Subscribe`/`Publish` as array entries; adding a Boolean entitlement is not
an equivalent configuration. The private API does not remove the authorization
requirement.
