#import "CornerResize.h"
#import "DeviceCorners.h"
#import <assert.h>
#import <math.h>

int main(void) {
    for (NSNumber *value in @[@180, @360, @720]) {
        CGFloat width = value.doubleValue, height = width * 2400.0 / 1080.0;
        NSSize size = NSMakeSize(width, height);
        for (DMResizeCorner corner = DMResizeCornerBottomLeft; corner <= DMResizeCornerTopRight; ++corner) {
            BOOL left = corner == DMResizeCornerBottomLeft || corner == DMResizeCornerTopLeft;
            BOOL bottom = corner == DMResizeCornerBottomLeft || corner == DMResizeCornerBottomRight;
            CGFloat radius = DMPixelCornerRadius(width, !bottom);
            CGFloat inset = DMSuperellipseCornerPoint(radius, .5).x;
            NSPoint point = NSMakePoint(left ? inset : width - inset, bottom ? inset : height - inset);
            assert(DMCornerAtPoint(point, size) == corner);
            NSRect start = NSMakeRect(100, 100, width, height);
            NSPoint delta = NSMakePoint(left ? -width / 2 : width / 2, bottom ? -height / 2 : height / 2);
            NSRect result = DMCornerResizeFrame(start, delta, corner, NSMakeSize(80, 160), NSMakeSize(5000, 5000));
            assert(fabs(result.size.width / result.size.height - width / height) < 1e-10);
            assert(fabs(result.size.width - width * 1.5) < 1e-10);
            assert(fabs((left ? NSMaxX(result) : NSMinX(result)) - (left ? NSMaxX(start) : NSMinX(start))) < 1e-10);
            assert(fabs((bottom ? NSMaxY(result) : NSMinY(result)) - (bottom ? NSMaxY(start) : NSMinY(start))) < 1e-10);
            result = DMCornerResizeFrame(start, NSMakePoint(left ? 10000 : -10000, bottom ? 10000 : -10000), corner, NSMakeSize(80, 160), NSZeroSize);
            assert(result.size.width >= 80 && result.size.height >= 160);
        }
        assert(DMCornerAtPoint(NSMakePoint(width / 2, height / 2), size) == DMResizeCornerNone);
        assert(DMCornerAtPoint(NSMakePoint(1, height / 2), size) == DMResizeCornerNone);
        assert(DMCornerAtPoint(NSMakePoint(0, 0), size) == DMResizeCornerNone);
    }
    NSLog(@"PASS: four rounded-arc hit areas, size invariance, fixed aspect ratio, opposite-corner anchors, minimum size and untouched sides/interior");
    return 0;
}
