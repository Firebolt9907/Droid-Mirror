# Persistent phone window

DroidMirror owns a persistent private renderer at
`Contents/Helpers/DroidMirror Renderer.app`. Its bundle and SDL application name
are **DroidMirror**. The viewer is the regular foreground app and owns the one
public Dock tile and menu bar. The controller runs as a hidden accessory app for
Settings, pairing, notifications and lifecycle cleanup. The phone is explicitly
marked primary and managed for Stage Manager and Spaces. Its toolbar and shadow
are auxiliary children, so they follow the phone instead of joining other apps.
Dock reopening restores the same phone, and Dock Quit also terminates the owning
controller. The viewer explicitly finishes AppKit launch even when the injected
menu layer creates NSApp before SDL. This lets macOS recognize launch completion,
menu ownership and normal Dock/AppleEvent handling. Background status updates
change the existing phone surface without activating it over another app.
The host sends explicit focus requests straight to the viewer without first
activating its accessory application. Attaching video does not activate or raise
the persistent viewer again, including when Settings has focus. Host, viewer and
notification receiver share the DroidMirror bundle icon; stream startup leaves
the viewer's Dock icon alone instead of replacing it with scrcpy's icon.
The video engine remains in an isolated helper process; it is not loaded into the
Swift host process.

The renderer owns one SDL_Window/NSWindow for its entire lifetime. Connecting,
streaming, connection errors, local phone use and disconnection all use that
surface. Loading and status views use DMApplyDeviceCorners, the same
superellipse mask and shadow as video, without traffic-light chrome. Stream
cleanup destroys decoder/renderer resources but keeps the window. Reconnects
reuse it, including its position and size.

MirrorRenderer sends per-attempt arguments and environment through atomic files
in a private temporary directory. Stream completion is distinct from helper
process termination; it lets the host stop Bluetooth and restore phone state
without closing the phone surface. Inline status messages replace NSAlert. A
per-attempt stop file handles cancellation even before the command is consumed.
The helper exits on app shutdown or loss of its host. Settings opens only from an
explicit command.

After two minutes in the background, the viewer requests an inactivity stop
instead of quitting. The host stops the active transport and restores phone
state, keeping the renderer and its window open. The phone shows **Stopped due
to inactivity** with a **Reconnect** button. Cancellation and stream completion
preserve this reason; a new connection clears it. Idle windows ignore stale
inactivity timer notifications.

Bluetooth emits LISTENING when loopback sockets exist, allowing the video engine
to start before radio setup completes. READY still means both radio channels
are authenticated; its bound video port survives accepting the early client.
ADB waits on an approval file while the host checks phone availability and audio
activity. No Android session starts before that approval. Final diagnostics are
drained from both stdout and stderr before checking the phone-use marker.

Regression checks (interactive macOS session required):

```sh
bash Native/test-connecting-phone.sh
bash Native/test-phone-appearance.sh
bash Native/test-session-windows.sh
bash Native/test-inactivity-timeout.sh
bash Native/test-renderer-lifecycle.sh
bash Native/test-host-isolation.sh
```

The native geometry test asserts SDL pointer, NSWindow number and exact CGPath
identity. The inline-state test checks errors and phone-use messages without
alerts or Settings. The lifecycle test runs the actual bundled renderer through
failed connections, locally generated H.264 frames, disconnection, retries and
immediate cancellation. It asserts one process/window, native presentation of
messages, DroidMirror foreground/menu ownership, regular viewer activation, primary managed
window classification, one public Dock app and shutdown.
These synthetic tests do not require or connect to a physical phone.

Phone appearance is cached per transport device identifier under Application
Support/DroidMirror/PhoneAppearance. The authorized Shizuku shell service reads
the physical display record and a small home wallpaper preview. Classic L2CAP
record type 4 carries a bounded JSON appearance record before video; the bridge
keeps it out of the decoder and atomically merges it into the private cache.
The renderer watches that cache, applies its geometry to loading and video, and
uses a clamped Gaussian blur with a dark overlay for loading and stopped states.
Connection headings use the phone's configured name (or the discovered name).
ADB display queries update the same cache for that ADB identifier. Unknown
geometry stays square until reported, with no device-model preset. Unsupported
wallpaper reads retain the last successful preview; a new phone without a
readable static wallpaper uses the neutral background. A companion update is
required for Shizuku appearance records (APK 0.38, display guard version 40).
