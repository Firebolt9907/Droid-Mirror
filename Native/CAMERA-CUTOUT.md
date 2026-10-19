# Circular camera cutout

The mirror draws an antialiased black circle inscribed in each camera cutout's
reported rectangle. It is part of the Mac renderer and does not change the
phone's display. On phones with a reported cutout, the floating top toolbar is
hidden. Click and drag the camera circle to move the Mac window immediately,
using AppKit’s standard `performWindowDragWithEvent:` behavior. Cutout presses
are consumed on the Mac; touches elsewhere continue to Android. Disconnect with
Cmd+Q or the phone's live activity. Phones without a cutout keep the toolbar. No computer vision or model-specific
camera position is used. Phones without reported cutouts receive no overlay.

Hole-punch/cutout presence is cached separately from its current coordinates.
The per-device PhoneAppearance JSON stores `hasCameraCutout` as `yes` or `no`;
a missing key is unknown. A frame-matching response can establish absence, and
observing a cutout upgrades the device to present. Once present, an empty
fullscreen/landscape response or temporarily mismatched metadata does not undo
that device fact. Geometry and hit targets still clear when stale. This keeps
the toolbar hidden while rotation waits for new coordinates and when rotation
completion restores session chrome. A newly connected device reloads its own
cache before showing the toolbar. Reads occur on device changes, and writes on
presence changes, rather than on every rendered frame.

Android's logical `DisplayInfo.displayCutout` supplies rotation-aware bounds via
`DisplayCutout.getBoundingRects()`. On Android 12+, the per-cutout intersection
with `getCutoutPath()` supplies tighter bounds when available: safe-area rectangles
can include padding between the camera opening and the edge of the display.
The circle is centered on the selected bounds and uses their smaller dimension
as its diameter, keeping it inside the rectangle. Non-circular notches are also
represented as circles, as requested. Android versions before 9 expose no cutout
metadata and receive no overlay.

The controller inverses its existing touch coordinate mapping to put these bounds
in encoded-video coordinates. That handles downscaling, capture rotation and
cropping. Metadata refreshes when capture geometry changes; mismatched frame
sizes are hidden until the corresponding metadata arrives. The client requests
fresh geometry whenever decoded frame dimensions change (including Bluetooth to
LAN/ADB quality upgrades and fallback), and retries missing/mismatched geometry
at most once per second while new frames arrive. Metadata updates post a redraw
event, so a late BLE reply can restore the punch hole immediately even when the
phone is showing a static screen. A valid empty response stops those retries. The client then applies
the same content rectangle, letterboxing, display rotation and mirror transform as
the video. Rendering happens after video filters, keeping edges smooth regardless
of sharpening/upscaling. The circle is clipped to video content, excluded on the
disconnected icon, and never placed on camera feeds or separate virtual displays.

Protocol: client control type 25 (one byte) opts into camera geometry. Device type 3
returns video width/height (two big-endian uint16s), count (uint8, at most four), and
four big-endian int32 rectangle coordinates per cutout. Empty metadata clears the
overlay. The opt-in prevents sending an unknown message to older clients. The BLE
queue recognizes type 25; existing authenticated control replies carry the response.
ADB and Bluetooth compile the same Android controller. Use matching Mac/companion
builds: older Android servers/companions do not understand the new request.

Validation:

- `sh Native/test-camera-cutout.sh` checks actual rendered pixels (a circle rather
  than a rectangle), placement, resize scale, rotation/mirroring, letterboxing,
  absent/stale geometry, delayed metadata redraw events across repeated Bluetooth/LAN/ADB resolution transitions, partial/malformed protocol packets, and opt-in serialization.
- `Native/CameraCutoutWindowTests.m` checks toolbar hiding/restoration, immediate
  delegation to AppKit window dragging and ordinary input passthrough.
  Renderer tests also verify the normalized hit geometry and stale/absent resets.
- Existing device/control message regression tests and BLE queue tests pass.
- `CameraCutoutPhoneProbe.java` is a read-only `app_process` probe compiled against
  Android SDK/companion classes. It checks the real Android bounds, inverse video
  mapping, controller response and message serialization without capturing content,
  injecting input or changing settings.
- On the connected 1080×2400 phone, padded bounds are `(479,0)-(601,132)`, but the
  tighter camera outline bounds are `(503,29)-(576,102)`: a 73-pixel circle centered
  at `(539.5,65.5)`. The live probe passed. A software-rendered preview was visually
  inspected. Full ADB server, SDL client and Bluetooth companion builds pass.

Build the Mac with `./build-app.sh`; build the companion with JDK 21 and Android SDK
36 via `JAVA_HOME=$(/usr/libexec/java_home -v 21) ANDROID_HOME=~/Library/Android/sdk
./BluetoothCompanion/gradlew -p BluetoothCompanion assembleDebug`.

`sh Native/test-toolbar-motion.sh` also exercises persistent positive/negative
cutout state, a valid empty landscape response after a positive detection,
rotation-end toolbar suppression, reconnect before geometry arrives, and
per-device isolation. The renderer tests distinguish stale/unknown geometry from
confirmed absence and verify metadata presence is not republished every frame.
