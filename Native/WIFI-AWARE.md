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
  The exact signing-policy rejection was not investigated further.

No SIP, AMFI, Wi-Fi settings, provisioning, or system files were changed.
No claimed throughput or Android interoperability has been measured.

## Reproduce

The helper uses dlopen and runtime selector checks, keeping the unsupported
framework out of the main app's linkage and retaining macOS 14 deployment.
It produces one JSON document; private API exceptions cause a nonzero exit.
A successful command exit means the probe ran, not that NAN is supported.

```sh
xcrun clang -Wall -Wextra -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
  -framework Foundation Native/WiFiAwareBridge.m -o /tmp/DroidMirrorWiFiAware
/tmp/DroidMirrorWiFiAware --probe
/tmp/DroidMirrorWiFiAware --test-discovery
```

`--probe` only queries capabilities. `--test-discovery` attempts a subscription
to `_droidmirror._tcp` for at most five seconds and stops it before exit. It
reports started, rejected (with raw error code), timeout, or apiUnavailable.
The app uses only the capability query, once on selection or explicit refresh;
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
