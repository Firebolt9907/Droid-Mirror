# Phone hotspot

The background receiver shows its own personal-hotspot status item, separate from
the phone handoff status item, when `NWPathMonitor` reports
no usable route. It does not make Internet probes; captive portals and a route
with broken upstream Internet do not count as offline. Click the icon and choose
**Turn On Phone Hotspot**, then select the phone in the Mac Wi-Fi menu. Configure
the hotspot name/password on Android and save the network on the Mac once;
macOS can then auto-join according to its own saved-network preferences.

The icon also offers **Automatically Turn On When Mac Is Offline**, off by default.
The same preference is available in **Settings → Phone hotspot**, including while
the Mac is online. This makes one request after 15 continuous offline seconds, once the paired phone
has authenticated and advertised hotspot support. A manual request also consumes
that outage's automatic attempt. There are no automatic retries, and a five-minute
cooldown prevents repeated requests during route flapping. This setting can use
mobile data. The feature enables tethering; it does not verify cellular Internet,
transfer credentials, force the Mac onto a network or turn the hotspot off later.

Requires matching Mac/Android builds, Android 11+, Bluetooth, an enabled background
bridge and running, authorized Shizuku. It works between mirror sessions without
ADB, a shared network or a display/capture lease. Older companions remain usable
for their existing features and show hotspot control as unavailable.

## Protocol and Android behavior

The encrypted BLE `ready` advertises `hotspot: 1`. The Mac sends `hotspotStart`
with a random UUID request, and accepts only an authenticated `hotspotResult`
matching its pending UUID. Both messages use the existing authenticated encryption
and sequence checks. Android bounds request identifiers, rechecks the session
before main-thread dispatch, and binds replies to the original session/handshake.
The companion rate-limits requests to one per 30 seconds and permits one in flight.

A separate non-daemon Shizuku user service calls Android's `TetheringManager`
through reflection, using the shell attribution context. It requests Internet
Wi-Fi tethering with the phone's saved configuration. Entitlement checks remain
enabled; provisioning UI is disabled, so an unmet carrier requirement fails and
can be resolved in Android settings. No hotspot configuration is rewritten.
Android's callback determines success; merely dispatching the request does not.
These APIs can differ on OEM builds, and denied/missing APIs report failure.

The framework callback has a 20-second deadline, service binding/operation a
28-second deadline, and the Mac a 35-second deadline. A timeout is ambiguous:
Android may still complete an accepted request. The UI tells the user to check
the phone, and automatic mode never retries that outage. Disconnects clear the
pending Mac request. Stopping the bridge unbinds the hotspot service without
changing hotspot state or ending an active mirror session.

## Validation

`bash Native/test-phone-hotspot.sh` checks the delay, opt-in, readiness gate,
once-per-outage rule, route-flap cooldown, offline status item, command dispatch,
request correlation, unauthenticated replies, pairing changes and old companions.
The production BLE sources must also compile together; the hotspot result must
be routed as an event rather than parsed as an ADB endpoint.

Physical-device validation is still required: install matching builds after ending
any active mirror gracefully, save/join the hotspot once, then take the Mac
offline and try the command. Verify actual Internet access, existing credentials,
carrier rejection, missing Shizuku, phone-side auto-shutoff, BLE loss mid-request,
and optional automatic mode. Updating components during active mirroring can
invalidate BLE services; an atomic bundle replacement alone does not prevent it.

API references: [Android tethering implementation](https://android.googlesource.com/platform/packages/modules/Connectivity/+/refs/heads/main/Tethering/common/TetheringLib/src/android/net/TetheringManager.java)
and [shell permissions](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/packages/Shell/AndroidManifest.xml).
