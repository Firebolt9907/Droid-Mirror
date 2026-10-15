# Pixel stream geometry

The Pixel 8 connected on October 3, 2026 reported a physical 1080×2400 panel
with Android RoundedCorner radii 104 pixels at the top and 102 at the bottom.
The current profile uses those reported corner radii, not cutout/status-bar padding.
Each radius is converted to an exponent-3 superellipse extent by matching the
45-degree corner inset of Android's quarter-circle approximation:
`extent = radius × (1 - 1/√2) / (1 - 2^(-1/3))` (approximately 1.42×radius).
On this Pixel that gives roughly 148 pixels at the top and 145 at the bottom,
about 12% rounder than the previous padding-based version. The resulting extent
is now reduced by 8% to tighten the visible silhouette, including its shadow and
corner-resize hit areas. This conversion scales
with each reported radius: tiny corners stay tiny and zero-radius corners stay square.

At stream attachment, a background `adb -s <active serial> shell dumpsys display`
query refreshes these radii from the connected phone's INTERNAL physical display.
Virtual scrcpy/encoder displays are ignored. The query has a four-second deadline
and never blocks the UI. Cutout and status-bar padding do not influence the result.
Missing/invalid radius data preserves the last/fallback geometry rather than
misinterpreting missing values as zero; the initial fallback is the known Pixel
physical-radius profile. This remains a visual superellipse,
not a literal reconstruction of the device manufacturer's physical shape.

The mask uses exponent-3 superellipse corner segments, not circular quarter-arcs
or CALayer radius clipping. Within each corner the normalized curve satisfies
`(1 - x / extent)^3 + (1 - y / extent)^3 = 1`. This softens the original exponent-4
profile: its diagonal inset is about 30% deeper, without becoming a circular arc.
Corners are sampled at 128 points
per segment; endpoints are exact. This is a superellipse profile, not a claim
to reproduce Apple's proprietary continuous-corner geometry. Coordinates account
for the surface layer's orientation.
Only the stream is clipped: the separate toolbar keeps its existing shape. Mask
and layer shadow share their geometry and the native window shadow is invalidated.
The controller applies the mask after the original layout method on every resize.
No Accessibility API, capture of other apps, new permission or layout crop is used.

Build the style library:

```sh
xcrun clang -fobjc-arc -dynamiclib -arch arm64 -mmacosx-version-min=14.0 -framework AppKit -framework Foundation -framework QuartzCore Native/KeyboardPassthroughShim.m Native/DeviceCorners.m Native/CornerResize.m Native/ScrollDirection.m -o outputs/DroidMirror.app/Contents/Frameworks/libDroidMirrorStyle.dylib
```

Tests cover 180/360/720/1080-point widths, normalized ratios, both coordinate
orientations, mask/shadow agreement and resizing through the real controller.

`CornerResize.m` adds local mouse hit areas on the diagonal portion of each visible
superellipse curve, using distance to the same sampled curve rather than distance
to a circle. It does not introduce overlays/windows or global event taps. Corner
drags preserve the starting aspect ratio and opposite-corner anchor, respect window
size limits, and consume their down/drag/up events instead of tapping Android.
Ordinary side resizing and screen interactions are left to the existing handlers.
