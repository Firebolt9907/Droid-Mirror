# Black secure-page placeholder

The patched scrcpy client checks decoded planar YUV video frames. When every
page pixel is black (within a small codec tolerance) for 350 ms, the native styling
library displays a lock symbol and:

> Secure screen
>
> Android prevents this screen from being mirrored.
> You can still type using your keyboard.

It removes the overlay immediately when nonblack video returns. The delay also
works when a static secure page produces a single frame, without waiting for a
second frame. Camera streams are excluded. A small neutral navigation pill is
allowed only in the centered bottom 3% of portrait video, with at most 0.5% of
the frame nonblack. The overlay is transparent so the pill stays visible.

The placeholder is a subview of the existing stream view, in scrcpy's process;
there is no separate window. It refuses first-responder status and its hit test
returns nil. Existing keyboard/HID, pointer, toolbar, and PIN-popover handling
remain unchanged. It does not collect keys or display typed PIN digits.

The black-screen transition now triggers the existing PIN-specific Android UI
check immediately rather than waiting for the next 1.5-second polling tick.
Repeated timer/frame triggers are coalesced, and checks are skipped on visible
regular lock screens. Black alone does not open the keypad; the existing PIN
resource/text markers must still be found. Android's UI dump time remains a
source of latency, so this is not a guarantee of instant PIN detection.

Limitation: the video stream does not explicitly identify secure windows. This
is a black-frame heuristic, so a genuinely all-black page can also trigger it.
Partially restricted views with visible status bars or other page content will
not trigger the check. This is a placeholder, not a screen-capture bypass.

Tests:

```sh
xcrun clang -I/opt/homebrew/include Native/SecureBlackFrameTests.c -o /private/tmp/droidmirror-secure-frame-tests
/private/tmp/droidmirror-secure-frame-tests
xcrun clang -fobjc-arc -framework AppKit Native/SecureOverlayProbe.m -o /private/tmp/droidmirror-secure-overlay-probe
/private/tmp/droidmirror-secure-overlay-probe "$PWD/outputs/DroidMirror.app/Contents/Frameworks/libDroidMirrorStyle.dylib" "$PWD/outputs/secure-page-preview.png"
```

Build the client with `meson compile -C scrcpy-4.1/build`, copy
`scrcpy-4.1/build/app/scrcpy` into `Contents/Helpers/scrcpy`, rebuild the native
style library from `KeyboardPassthroughShim.m`, and sign the application bundle.
