Black-frame-triggered secure-window preview

Black detection now starts the Shizuku/shell WindowManager check. Only a confirmed
secure window shows the warning. Normal video clears the overlay and stops shell
queries. Replies are tied to each black-screen episode to reject stale results.

Mac app and matching Android APK are built here for review. Installed apps were
not modified. Update both endpoints together after gracefully stopping mirroring.

Validated: Mac and Android builds, signed bundle checks, metadata parser, monitor
scheduling/cancellation, stale-response rejection, request/reply fragmentation,
BLE queue packing, software and VideoToolbox black-frame candidates, camera-cutout
regression tests, and git diff --check.
