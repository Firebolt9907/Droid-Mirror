# Live video enhancement

The `camera.filters` button beside the PIN keypad in the mirror toolbar toggles
video enhancement. It starts off for each mirror session; the accent color and
On/Off tooltip show its state. Clicking redraws the retained decoded frame
immediately, including when the phone is idle. No stream restart or extra
Bluetooth traffic is needed.

The adjacent outward-arrows button independently toggles **MetalFX spatial
upscaling (2×)**. It starts on for each new mirror window on supported GPUs.
The scrcpy menu bar’s **View → MetalFX Upscaling (2×)** item toggles the same
setting, including when a camera cutout hides the toolbar. Its checkmark and the
toolbar highlight stay in sync. Both controls are disabled if the GPU or renderer
does not support MetalFX. Turning it off persists through texture resets in the
current session; a new window starts on again. With both buttons on, enhancement precedes
upscaling. The scaler converts NV12 to perceptual RGB using the source YUV range
and matrix, then runs Apple's `MTLFXSpatialScaler` to double both dimensions.
Scaler instances are reused until the source dimensions change. SDL displays the
entire enlarged texture; input coordinates and window aspect ratio continue to
use the phone's original frame size. This is spatial scaling only, without frame
interpolation or temporal reconstruction.


The Metal compute kernel operates directly on the video brightness plane. A 5×5
bilateral filter reduces small compression fluctuations without blending across
strong text edges. Contrast-gated unsharp masking then strengthens real edges,
with a bounded adjustment and local min/max clamp to limit new halos. There is no
temporal blending, so it cannot leave trails from previous frames. Large blocks
and missing text detail at 256 kbps remain source-quality limitations.

The previous Core Image implementation introduced a separate color-managed RGB
conversion. The revised implementation retains NV12, copies chroma unchanged,
and uses the same SDL source range and color matrix as the bypass. VideoToolbox
frames remain on the GPU; software YUV420 frames are uploaded as NV12. The
original decoded frame remains available for an exact bypass. One result is
cached per decoded frame, and the Metal pipeline/queue are reused. Frame changes
and resets invalidate the cached result. Changing either toggle also invalidates it. If processing is unavailable, the
renderer falls back to the original image.

References: [Apple's pixel-buffer Metal texture import](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage)
and [SDL's Metal pixel-buffer texture import](https://wiki.libsdl.org/SDL3/SDL_CreateTextureWithProperties).

Build and test from this checkout (use a fresh build directory if the repository
was moved; Meson build directories retain their original absolute paths):

```sh
CC=/usr/bin/clang OBJC=/usr/bin/clang meson setup /tmp/droidmirror-sharpen-build scrcpy-5.0 --buildtype=release -Dcompile_server=false -Dportable=true -Dvideotoolbox=true
meson compile -C /tmp/droidmirror-sharpen-build
sh Native/test-video-filter.sh /tmp/droidmirror-sharpen-build
```

The test uses a hidden Metal window and synthetic 480×1066 images. It verifies
default-on initialization, live menu actions and checkmarks, unsupported-renderer
disabling, idempotent menu installation, and preserving a toggle through texture
resets. It checks
software and VideoToolbox pixel buffers, edge enhancement, reduced small
compression fluctuations, unchanged flat white/black/colored patches (within one
RGB output level), idle redraw events, cached rendering, frame retention, reset
cleanup, and exact original pixels after switching off. Warm filter-plus-render
timing across 30 frames is about 8.3 ms/frame on the development Mac, excluding
transport and decoding. Combined enhancement plus MetalFX 2× also measured
about 8.3 ms/frame at this resolution. These timings are display-paced, rather
than isolated GPU times. Tests additionally cover all four toggle combinations,
2× output dimensions, preserved flat color/white/black patches within two RGB
levels, cache invalidation while idle, and scaler recreation for landscape.

See [Apple's MetalFX spatial scaler documentation](https://developer.apple.com/documentation/metalfx/mtlfxspatialscaler).

Set `DM_FILTER_REFERENCE` to a 480×1066 planar YUV420 frame to additionally export
before/after BMPs to `/tmp/droidmirror-filter-before.bmp` and
`/tmp/droidmirror-filter-after.bmp` for visual inspection. The supplied stream
screenshot was cropped/rescaled to this format and inspected through the actual
renderer; the result shows stronger text edges with remaining source blockiness.
