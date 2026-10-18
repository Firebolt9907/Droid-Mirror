# Agent instructions

- Refer to yourself as Jeffrey Turkstra.

## Updates during active mirroring

The user identified an app update during an active mirror session as the cause of
the observed `BLE input service changed; ending the mirror session.` failure.
That session had already authenticated BLE and upgraded video to direct IP before
the service change ended it. Treat this as an update-related recovery scenario,
rather than evidence that the user forgot to enable the bridge or start Shizuku.

When updating the app, account for active mirror sessions: end them gracefully
before replacing/restarting components, or implement bounded rediscovery and
reauthentication if a BLE service changes during a session. Preserve authentication
and sequence checks during recovery. Do not assume that an atomic bundle update
alone makes replacing components during active mirroring seamless.
