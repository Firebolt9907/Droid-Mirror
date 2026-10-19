#import <AppKit/AppKit.h>

// Android's reported physical corner radii determine the superellipse extents.
// Normalized to the stream: encoder resolution and Mac backing scale do not
// change the silhouette. No point-size minima, maxima or window-size presets.
CGFloat DMPixelCornerRadius(CGFloat streamWidth, BOOL top);
CGFloat DMCornerExtentForRadius(CGFloat radius);
BOOL DMUpdateDeviceGeometryFromDisplayDump(NSString *dump);
void DMLoadCachedDeviceCorners(NSView *screen);
void DMRefreshDeviceCornersFromPhone(NSView *screen);
// Local corner coordinates for an exponent-3 superellipse, from (0, extent)
// to (extent, 0). The legacy radius value is now the corner's extent.
CGPoint DMSuperellipseCornerPoint(CGFloat extent, CGFloat progress);
CGPathRef DMCreatePixelScreenPath(CGSize size, BOOL flipped) CF_RETURNS_RETAINED;
void DMApplyDeviceCorners(NSView *screen);
