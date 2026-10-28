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

## Shizuku user-service version bumps

When changing code loaded by a Shizuku user service, bump that service's
`Shizuku.UserServiceArgs.version(...)` value. For the display guard and its
embedded capture, encoder, and scrcpy control/gesture code, bump the version in
`ShizukuDisplayClient.arguments(...)`. Apply the same requirement to other
Shizuku user services when their loaded code changes.

Daemonized Shizuku processes can survive APK replacement and continue executing
old classes. A successful build or APK install does not prove that the new code
is running. End active mirror sessions gracefully before replacing the service,
then verify that the old process was replaced and that runtime logs or behavior
identify the updated implementation before evaluating the fix. Do not count
observations from a surviving old process as validation of the new code.
