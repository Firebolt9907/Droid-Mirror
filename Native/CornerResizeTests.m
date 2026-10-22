#import "CornerResize.h"
#import "DeviceCorners.h"
#import <assert.h>
#import <math.h>

int main(void) {
    // Exercise both unknown/square geometry and the actual rounded phone profile.
    for (NSString *dump in @[
        @"DisplayDeviceInfo{phone, 1080 x 2400, position=TopLeft, radius=0, position=BottomLeft, radius=0, type INTERNAL}",
        @"DisplayDeviceInfo{phone, 1080 x 2400, position=TopLeft, radius=104, position=BottomLeft, radius=102, type INTERNAL}"
    ]) {
    assert(DMUpdateDeviceGeometryFromDisplayDump(dump));
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
            // The full corner target includes edges and points well inside the
            // previous six-point arc band, in all four orientations.
            for (NSValue *offset in @[[NSValue valueWithPoint:NSMakePoint(0, 0)],
                                     [NSValue valueWithPoint:NSMakePoint(2, 24)],
                                     [NSValue valueWithPoint:NSMakePoint(24, 2)],
                                     [NSValue valueWithPoint:NSMakePoint(28, 28)]]) {
                NSPoint p = offset.pointValue;
                assert(DMCornerAtPoint(NSMakePoint(left ? p.x : width - p.x,
                                                   bottom ? p.y : height - p.y), size) == corner);
            }
            if (radius > 30) {
                // A point twelve points inward from the visible arc was outside
                // the old handle, but should now be easy to grab.
                CGPoint arc = DMSuperellipseCornerPoint(radius, .1);
                NSPoint p = NSMakePoint(arc.x + 12, arc.y);
                assert(DMCornerAtPoint(NSMakePoint(left ? p.x : width - p.x,
                                                   bottom ? p.y : height - p.y), size) == corner);
            }
            NSRect start = NSMakeRect(100, 100, width, height);
            NSPoint delta = NSMakePoint(left ? -width / 2 : width / 2, bottom ? -height / 2 : height / 2);
            NSRect result = DMCornerResizeFrame(start, delta, corner, NSMakeSize(80, 160), NSMakeSize(5000, 5000), NO);
            assert(fabs(result.size.width / result.size.height - width / height) < 1e-10);
            assert(fabs(result.size.width - width * 1.5) < 1e-10);
            assert(fabs((left ? NSMaxX(result) : NSMinX(result)) - (left ? NSMaxX(start) : NSMinX(start))) < 1e-10);
            assert(fabs((bottom ? NSMaxY(result) : NSMinY(result)) - (bottom ? NSMaxY(start) : NSMinY(start))) < 1e-10);
            result = DMCornerResizeFrame(start, NSMakePoint(left ? 10000 : -10000, bottom ? 10000 : -10000), corner, NSMakeSize(80, 160), NSZeroSize, NO);
            assert(result.size.width >= 80 && result.size.height >= 160);
            // Option-drag moves both edges, preserving the original center
            // through enlargement, shrinking, and either size limit.
            for (NSNumber *factor in @[@1, @(-.25), @(-100), @100]) {
                CGFloat f = factor.doubleValue;
                result = DMCornerResizeFrame(start, NSMakePoint(delta.x * f, delta.y * f), corner,
                                             NSMakeSize(width / 2, height / 2), NSMakeSize(width * 3, height * 3), YES);
                CGFloat expectedScale = MAX(.5, MIN(3, 1 + f));
                assert(fabs(result.size.width - width * expectedScale) < 1e-9);
                assert(fabs(result.size.height - height * expectedScale) < 1e-9);
                assert(fabs(NSMidX(result) - NSMidX(start)) < 1e-9);
                assert(fabs(NSMidY(result) - NSMidY(start)) < 1e-9);
            }
        }
        assert(DMCornerAtPoint(NSMakePoint(width / 2, height / 2), size) == DMResizeCornerNone);
        assert(DMCornerAtPoint(NSMakePoint(1, height / 2), size) == DMResizeCornerNone);
        assert(DMCornerAtPoint(NSMakePoint(width / 2, 1), size) == DMResizeCornerNone);
        assert(DMCornerAtPoint(NSMakePoint(60, 60), size) == DMResizeCornerNone);
        assert(DMCornerAtPoint(NSMakePoint(-1, 5), size) == DMResizeCornerNone);
        assert(DMCornerAtPoint(NSMakePoint(width + 1, height - 5), size) == DMResizeCornerNone);
    }
    }
    NSLog(@"PASS: corner targets, rounded and square phones, fixed aspect ratio, opposite-corner anchors, centered Option resizing, size limits and untouched sides/interior");
    return 0;
}
