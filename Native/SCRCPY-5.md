# DroidMirror scrcpy 5.0 upgrade

The customized client is now in `scrcpy-5.0/`. `scrcpy-4.1/` and
`outputs/DroidMirror-before-scrcpy-5.0.app` retain the previous version for rollback.
Upstream source: https://github.com/Genymobile/scrcpy/releases/tag/v5.0

The Android server is now built from the customized 5.0 sources by `build-app.sh`
and bundled as `Contents/Helpers/scrcpy-server`. It includes the shared gesture-pill
controller used by ADB and the Bluetooth companion. Portable server lookup prevents
accidentally launching Homebrew's old server. See [gesture-pill behavior](GESTURE-PILL.md).

Hardware decoding uses upstream's default `--hwdec=auto` with software fallback.
VideoToolbox/Metal zero-copy texture import was verified on this Mac using ten
synthetic H.265 frames through the actual 5.0 hardware and texture implementations.
The existing SDL 3.4.16 and FFmpeg 9.0.1_1 Homebrew dependencies satisfy the build;
this upgrade does not change global Homebrew packages.

Preserved customizations:

- Escape → Android Back; physical Cmd+Q handled by the native shim.
- Command/Control swap and clipboard synchronization.
- Non-droppable UHID state messages under network backpressure.
- Actual-rendered-frame reporting for notification clicks.
- Secure-page overlay, now supporting NV12 and VideoToolbox pixel buffers.
- All native toolbar, touch swipe, wheel direction, superellipse, resize, lifecycle,
  and authenticated BLE notification behavior remains in the existing native shims.

Secure-page checks run at most five times/second. VideoToolbox IOSurfaces are read
through CoreVideo without downloading full hardware frames; supported software
YUV420/NV12 frames use the same black-frame checker. The mask is a UI overlay,
not a bypass of Android protected-content restrictions.

Build:

```sh
CC=clang meson setup scrcpy-5.0/build scrcpy-5.0 --buildtype=release -Dcompile_server=false -Dportable=true -Dvideotoolbox=true
meson compile -C scrcpy-5.0/build
cp scrcpy-5.0/build/app/scrcpy outputs/DroidMirror.app/Contents/Helpers/scrcpy
# Use ./build-app.sh to compile and package the customized Android server too.
sh Native/sign-droidmirror.sh
```

Regression tests target the new source tree. Tests cover Cmd/Ctrl clipboard/HID
reports, Escape/Back, UHID queue preservation, software NV12 black frames, and
actual CoreVideo secure-page detection. HardwareDecodeProbe uses a hidden window
and a synthetic clip, not desktop capture or a real phone session.
