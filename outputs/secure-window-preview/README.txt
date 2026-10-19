Secure-window detection preview

Mac: DroidMirror.app
Phone: DroidMirror-Bluetooth-0.39-debug.apk

This preview replaces black-frame heuristics with secure-window flags read by the
existing Shizuku/shell controller. Update both endpoints together after gracefully
stopping active mirroring. Neither endpoint has been installed by this build.

Validation: metadata parser (including live Pixel output), Java/C wire protocol,
renderer build, Android assembleDebug, native overlay probe (debounce, repeated
refresh, stale expiry, session stop and input passthrough), camera cutout tests
and display-recovery tests passed. lintDebug reports five errors in unchanged
files; none is in the new secure-window code.
