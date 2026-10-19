# Phone hotspot

The background receiver shows a personal-hotspot icon in the menu bar, separate
from phone handoff, only while the Mac has no Wi-Fi connection or is connected to
the known phone hotspot. Other Wi-Fi networks hide the icon, even with no Internet
access or while a shutdown/error message is pending. Ethernet Internet access does
not hide it when Wi-Fi is disconnected. Wi-Fi association is checked separately
from SSID access, so a redacted network name is not mistaken for disconnected Wi-Fi.

Click once to turn the phone hotspot on; after Android confirms success, it uses
an inset green capsule with a white hotspot symbol, like the macOS active indicator. Click again to turn it off; the icon remains
visible with no background after shutdown is confirmed while Wi-Fi is disconnected
or still associated with the phone hotspot. Pending operations disable
the button; errors appear in its tooltip. Failed shutdowns keep the green state.

Configure the hotspot name/password on Android and save the network on the Mac
once. Join it using the Mac Wi-Fi menu; macOS may auto-join a saved network.
The toggle does not transfer credentials or force a Wi-Fi connection.

The companion returns the saved hotspot SSID over authenticated BLE. CoreWLAN
checks the Mac's connected SSID every second and on route changes. After observing
the Mac on that hotspot, observing another Wi-Fi SSID requests shutdown. Merely
starting while already connected to another network does not immediately shut it
off. Loss of Wi-Fi, Ethernet route changes, and unavailable/redacted SSIDs do not
count as switching networks. macOS requires Location Services permission to read
Wi-Fi names; the receiver requests it on first enable. Denying access leaves manual
toggling available but prevents automatic shutdown on network changes. A missing
phone SSID also disables automatic departure detection rather than guessing.

A departure detected during BLE loss queues shutdown until the authenticated phone
reconnects. Failures/timeouts require manual retry and do not loop. A pending stop
interrupted by BLE loss is retained for reconnect. A start with a lost acknowledgement
is ambiguous; check the phone before retrying. The icon reflects confirmed operations
from this receiver; independent phone-side changes and state across receiver restarts
are not synchronized.

**Settings → Phone hotspot** retains the optional automatic enable preference,
off by default. It makes one request after 15 continuous seconds without a usable
route, once the phone is authenticated and advertises toggle support. There are no
Internet probes. Manual enable consumes that outage's automatic attempt, and a
five-minute cooldown limits route flapping. Uses mobile data.

## Protocol and Android behavior

Requires matching Mac/Android builds, Android 11+, Bluetooth, the background bridge,
and running, authorized Shizuku. No ADB or display/capture lease is needed.
The encrypted BLE `ready` advertises `hotspot: 2` for start/stop support; older
companions leave the new toggle disabled. `hotspotStart` and `hotspotStop` carry a
random UUID. The Mac accepts only authenticated `hotspotResult` messages matching
the pending UUID and expected operation. Existing encryption and sequence checks
remain in place. Android validates identifiers, rechecks authorization before
main-thread dispatch, and binds replies to the original session/handshake.

A separate non-daemon Shizuku service uses the shell attribution context to call
`TetheringManager`. Start retains saved configuration and entitlement checks,
suppresses provisioning UI, and waits for Android's callback. Successful starts
include the saved SSID, without passwords. Stop calls `stopTethering` for Wi-Fi
and polls AP state until disabled before reporting `stopped`. Missing/OEM-restricted
APIs report failure. No hotspot configuration is rewritten.

Only one operation may run at once. Starts are rate-limited to one per 30 seconds;
stops bypass that cooldown so a newly enabled hotspot can be switched off immediately.
A confirmed stop resets the start cooldown to permit turning it on again.
Framework confirmation has a 20-second deadline, service binding/operation 28
seconds, and the Mac 35 seconds. Stopping the bridge itself only unbinds the service;
it does not change tethering or end an active mirror.

## Validation

`bash Native/test-phone-hotspot.sh` checks automatic policy,
conditional visibility on other Wi-Fi, no Wi-Fi, Ethernet and redacted SSIDs,
direct button dispatch, green/clear backgrounds, matching authenticated replies,
duplicate clicks, manual shutdown, Wi-Fi departure, redacted SSIDs, delayed joining,
BLE reconnect shutdown, send/stop failures, and unsupported companions. Run with
window-server access; the script requires the assertions' completion message.
`bash Native/test-ble-session.sh` compiles the production controller/receiver together.
Compile the Android Kotlin/Java and generated AIDL together as well.

Physical-device validation remains required: install matching builds after ending
any active mirror gracefully, grant Wi-Fi name access, save/join the phone network,
then switch to another Wi-Fi network and verify shutdown. Also check carrier errors,
missing Shizuku, phone-side auto-shutoff, BLE loss mid-operation, and denied location
access. Updating components during active mirroring can invalidate BLE services;
an atomic bundle replacement alone does not prevent it.

API references: [Android tethering implementation](https://android.googlesource.com/platform/packages/modules/Connectivity/+/refs/heads/main/Tethering/common/TetheringLib/src/android/net/TetheringManager.java),
[CoreWLAN SSID](https://developer.apple.com/documentation/corewlan/cwinterface/ssid()),
and [shell permissions](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/packages/Shell/AndroidManifest.xml).
