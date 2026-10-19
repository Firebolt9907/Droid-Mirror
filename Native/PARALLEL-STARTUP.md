# Parallel Bluetooth and LAN startup

The Mac starts its paired Iroh endpoint and direct-IP probe when the helper
starts, alongside Classic setup. The Swift host no longer waits for
`STREAM_STARTED` or sleeps three seconds before probing. Android keeps its
paired Iroh endpoint alive while the background bridge is ready, across mirror
sessions. A paired QUIC connection can wait up to 15 seconds for the session's
local video endpoint, while Classic opens and the BLE service starts.

Classic acceptance still creates the session and its BLE input service.
The local video endpoint now opens before BLE authentication finishes. Capture
continues to require authenticated BLE input; its existing fresh session keys,
sequence validation, replay protection and recovery requests remain in use.

The first video write and initial LAN selection share the wire lock. If LAN
wins, protocol `DMWIFI06` sends the `-3` initial-path marker and a zero cutoff,
authenticated with the direction-separated `initial server` proof binding the
fresh nonce, requested profile and cutoff. The Mac verifies that proof and
acknowledges receipt before wireless throughput and quality are enabled.
The first scrcpy packet can then travel on LAN. Quality is applied after the
capture guard starts; initial encoder frames can still use the Bluetooth profile
until the requested profile reset takes effect.

If Bluetooth has already sent video, the LAN candidate uses the existing
live-video preview, latency comparison and authenticated cutoff handoff instead.
Bluetooth does not wait for LAN discovery. Both startup outcomes retain the
same cumulative video accounting and bounded replay to Classic after LAN loss.
Relays and public discovery remain disabled. Multicast-blocked networks can
still require authenticated BLE address hints before Iroh finds the phone.

`bash Native/test-wireless-upgrade.sh` covers both startup outcomes, the
concurrent first-packet race, initial proof and cutoff validation, and recovery.
`cargo test --offline --manifest-path PeerTransport/Cargo.toml` covers paired QUIC
transport and discovery policy. Socket tests require local socket permissions;
they are distinct from validation of real radio and device startup timing.

Build matching Mac and Android components to exercise the new startup path.
When installing them, end active mirror sessions before replacing components.
