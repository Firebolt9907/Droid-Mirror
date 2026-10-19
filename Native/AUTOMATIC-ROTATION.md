# App-triggered rotation

When an Android app changes between portrait and landscape (for example, entering
or exiting a fullscreen YouTube video), the Mac mirror rotates the incoming live
video, phone outline, and shadow through a rigid 350 ms turn with easing at both ends. The visible phone
surface keeps a constant width and height; only its angle changes. The easing
starts and settles with zero velocity and acceleration. Entering
landscape turns counterclockwise; returning to portrait turns clockwise. Its center
stays fixed at the portrait window's center. No rotation buttons, menus, or new keyboard shortcuts are added.

The trigger is a reciprocal aspect-ratio change in decoded frame dimensions,
allowing encoder alignment rounding. Resolution or transport quality changes with
the same aspect ratio do not trigger rotation. A quality change during a turn
keeps that turn running. Reversing orientation during a turn continues from the
visible angle. New video frames and input continue throughout the animation;
touch and camera-cutout coordinates use the same intermediate transform.

ADB capture follows the phone orientation rather than locking encoded video to
natural portrait. The Bluetooth capture already follows app orientation. This
change does not modify authentication or restart an active stream.

Reduce Motion uses an immediate, centered resize. Flexible displays, camera
capture, stretched/unscaled rendering, and suppressed automatic resizing retain
their existing immediate behavior. Fullscreen Mac windows keep their size and
animate video inside the available bounds.

A transparent drawing canvas reserves room for the phone’s diagonal once at the
start of the turn. A rotating native mask clips the canvas to the actual phone
silhouette. The canvas stays the same size throughout; it tightens to the final
phone bounds when the turn finishes. No per-frame window resizing or fitting
is used. Toolbar controls are hidden during the turn and restored afterward.

Validation (hidden Metal window; no phone required):

```sh
CC=/usr/bin/clang OBJC=/usr/bin/clang meson setup /private/tmp/droidmirror-rotation-build scrcpy-5.0 --buildtype=release -Dcompile_server=false -Dportable=true -Dvideotoolbox=true
meson compile -C /private/tmp/droidmirror-rotation-build
sh Native/test-automatic-rotation.sh /private/tmp/droidmirror-rotation-build
sh Native/test-camera-cutout.sh
sh Native/test-toolbar-motion.sh
```

The orientation test exercises the production frame-size transition path, live
texture uploads, intermediate touch mapping, quality upgrades, interruption,
center anchoring, Reduce Motion, and resize suppression. The test also creates
and removes a constrained loading view before rotating, reproducing the live
window’s persistent Auto Layout engine. Clearing the native aspect ratio to
(0, 0) in that state caused an AppKit NaN height constraint and SIGABRT.
The animation keeps finite aspect ratios when reserving and releasing its canvas.
Regression checks sample the turn at quarter intervals and verify an unchanged
canvas size, unchanged surface dimensions, rotating mask bounds, and matching
outline/shadow paths with MetalFX active. Physical YouTube/game
behavior still requires device validation. App installation retains the existing
graceful session shutdown before replacing running components.

Animation pacing uses the display refresh rate and waits only until the next
frame deadline, accounting for time already spent rendering. Incoming video
frames update the same pose clock. Native shadows are blurred once into a
transparent cached bitmap, then rotated by Core Animation; pose updates neither
repaint the blur nor force duplicate AppKit draws. Session status polling stays
at 50 ms rather than reading files on every animation frame.

Optional synthetic pose benchmark (includes native mask/shadow and SDL present):

```sh
DROIDMIRROR_ROTATION_BENCHMARK=1 sh Native/test-automatic-rotation.sh
```

On the development Mac, the 60-update hidden-window benchmark with actual 2×
MetalFX output measured median/p95 pose costs of 8.52/22.10 ms before and
8.40/11.06 ms after caching and pacing changes. These are synthetic frame costs,
not an end-to-end phone-streaming latency measurement.
