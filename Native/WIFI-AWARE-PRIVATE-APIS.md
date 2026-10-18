# Private Wi-Fi Aware APIs on this Mac

Read-only inventory on October 14, 2026: macOS 27.0.1 (26A434), arm64.
These are names and ABI signatures recovered from the installed runtime and
dyld exports, not inferred from iOS headers. Presence does not prove hardware
support, daemon authorization, or Android interoperability.

## Primary implementation: WiFiPeerToPeer.framework

`/System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/WiFiPeerToPeer`
loads successfully and exports the following Objective-C implementations.

| Purpose | Classes and selectors verified locally |
| --- | --- |
| Capabilities | `+[WiFiAwareDeviceCapabilities currentDeviceCapabilities]`; instance getters `supportedFeatures`, `supportedCipherSuites`, `supportsDataTransfer`, `discoveryInterfaceName`, `maxPeers`, `maxPublishers`, `maxSubscribers`, `maxDatapaths` |
| Discovery | `WiFiAwarePublisher`, `WiFiAwareSubscriber`: `initWithConfiguration:`, `setDelegate:`, `start`, `stop` |
| Configuration | `WiFiAwarePublishConfiguration`, `WiFiAwareSubscribeConfiguration`: `initWithServiceName:` |
| Discovery messages | Publisher and subscriber: `sendMessage:toPeerAddress:withInstanceID:completionHandler:` |
| Subscriber results | `subscribeReceivedDiscoveryResult:`, `subscribeLostDiscoveryResultForPublishID:address:`; results represented by `WiFiAwareDiscoveryResult` |
| Data path | `WiFiAwareDataSession`: `initWithDiscoveryResult:serviceType:serviceSpecificInfo:passphrase:`, `initWithDiscoveryResult:serviceType:serviceSpecificInfo:pmk:`, `start`, `stop`, `localInterfaceIndex`, `localDataAddress`, `initiatorDataAddress` |
| Data confirmation | `datapathStartedWithInstanceID:initiatorDataAddress:localInterfaceIndex:`; `datapathConfirmedForPeerDataAddress:serviceSpecificInfo:` |
| Publisher security | `WiFiAwarePublishDatapathSecurityConfiguration`: `initWithPMK:andPMKID:`, `initWithPMKList:passphraseList:`, pairing configuration initializers |
| Pairing | `WiFiAwarePairingSession`: `initWithPairingConfig:delegate:`, `pairWithDiscoveryResult:`, PIN/passphrase callbacks |
| State queries | `+[WiFiAwareState currentState]`; `WiFiAwareStateMonitor`: `queryNANEnabled`, `queryNANState`, `queryNANDataPathState`, `queryNANAvail`, `queryNANPeerAvail`, `queryNANSrv` |
| Monitoring | `WiFiAwareStateMonitor`, `WiFiP2PNANStateMonitor`: `beginMonitoring`, `endMonitoring` |

The data-session initializers are the most relevant candidate for a future
Android experiment. They expose passphrase/PMK setup and interface information
needed for an authenticated, interface-scoped socket. This is an inference from
the API surface; no data session or socket has been established.

## Daemon/XPC layer

`WiFiP2PXPCConnection` exposes:

```text
+ supportsWiFiP2P
+ endpointForEndpointType:
+ directQueryOnEndpointType:error:querying:
- initWithEndpointType:queue:retryTimeout:
- withRemoteObjectProxy:
```

The runtime protocol `WiFiP2PXPCProtocol` declares:

```text
queryCurrentDeviceCapabilities:
createPublishWithConfiguration:completionHandler:
createSubscribeWithConfiguration:completionHandler:
createDatapathWithConfiguration:completionHandler:
createDatapathInfoWithDatapathID:role:peerMacAddress:completion:
createPairingInitiatorForDiscoveryResult:pairingConfig:completionHandler:
queryNANEnabledWithCompletionHandler:
queryNANStateWithCompletionHandler:
queryNANDataPathStateWithCompletionHandler:
startMonitoringNANStateWithConfiguration:completionHandler:
```

Additional operation/delegate protocols include `WiFiAwareDatapathXPC`,
`WiFiAwarePublisherXPC`, `WiFiAwareSubscriberXPC`, and their delegate protocols.
For example, `WiFiAwareDatapathXPC` provides cancellation, statistics, link status,
and RSSI updates. The inventory records required/optional and instance/class
method flags and raw Objective-C type encodings. Block parameter types and enum
values cannot be recovered fully from those encodings.

The installed launchd plist identifies `/usr/libexec/wifip2pd` and its
`com.apple.wifip2pd` Mach service. Daemon strings include
`com.apple.developer.wifi-aware`, `WiFiAwareAllowedBundleIds`, `WiFiAwareServices`,
and diagnostics for missing entitlement capabilities and missing legacy
entitlements. Strings identify likely policy checks; they do not establish the
precise control flow or imply those checks can be skipped by using XPC directly.

The previous actual discovery probe returned error 1; its external system-log
investigation reported a missing `com.apple.wifip2pd` or
`com.apple.developer.wifi-aware` entitlement. See `WIFI-AWARE.md` for those results.
The new inventory does not invoke these operations or alter signing policy.

## Other installed layers

- `CoreWiFi.framework` contains `-[CWFInterface NANData]`,
  `-[CWFInterface NANRadioSchedule]`, `-[CWFApple80211 NANRadioSchedule:]`, and
  `-[CWFXPCConnection queryNANRadioScheduleWithRequestParams:reply:]`.
  Their names suggest diagnostics/state access; no query was invoked.
- `Apple80211.framework` and `IO80211.framework` both load. No exported name
  containing `NAN` or `Aware` was found in the Apple80211 export listing.
  That does not exclude generic IOCTL interfaces, internal code, or driver APIs.
- Public `WiFiAware.framework` contains runtime classes named
  `WiFiAwareCapabilitiesPrivate`, `WiFiAwareDatapathInfoPrivate`,
  `WiFiAwarePairedDevicePrivate`, and `WiFiAwareServicesPrivate`. These expose
  no directly declared Objective-C methods in this inventory; Swift metadata
  is not a callable Objective-C interface.

## Reproduce and inspect

```sh
xcrun clang -Wall -Wextra -fobjc-arc -fblocks -framework Foundation \
  Native/WiFiAwareAPIInventory.m -o /tmp/droidmirror-wifi-api-inventory
/tmp/droidmirror-wifi-api-inventory > /tmp/droidmirror-wifi-api-inventory.json
dyld_info -exports \
  /System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/WiFiPeerToPeer
plutil -p /System/Library/LaunchDaemons/com.apple.wifip2pd.plist
```

Saved evidence is in `outputs/wifi-aware-research/`: `runtime-inventory.json`,
`WiFiPeerToPeer-exports.txt`, and `Apple80211-exports.txt`. The runtime inventory
contains 88 selected classes and 26 Wi-Fi protocols, including supporting AWDL
classes and general CoreWiFi methods. It is not a count of 88 working NAN APIs.
The utility loads frameworks and reads runtime metadata; it does not instantiate
private classes, query nearby peers, initiate discovery, or change Wi-Fi settings.
