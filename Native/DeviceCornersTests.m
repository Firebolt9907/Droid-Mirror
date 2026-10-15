#import "DeviceCorners.h"
#import <QuartzCore/QuartzCore.h>
#import <assert.h>
#import <math.h>

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        for (NSNumber *value in @[@180, @360, @720, @1080]) {
            CGFloat width = value.doubleValue;
            CGFloat height = width * 2400.0 / 1080.0;
            CGFloat top = DMPixelCornerRadius(width, YES);
            CGFloat bottom = DMPixelCornerRadius(width, NO);
            assert(fabs(top / width - DMCornerExtentForRadius(104) / 1080.0) < 1e-12);
            assert(fabs(bottom / width - DMCornerExtentForRadius(102) / 1080.0) < 1e-12);
            assert(fabs(DMSuperellipseCornerPoint(top, .5).x - .92 * width * 104.0 / 1080.0 * (1 - M_SQRT1_2)) < 1e-10);
            for (NSNumber *direction in @[@NO, @YES]) {
                BOOL flipped = direction.boolValue;
                CGPathRef path = DMCreatePixelScreenPath(CGSizeMake(width, height), flipped);
                CGFloat low = flipped ? top : bottom;
                CGFloat high = flipped ? bottom : top;
                assert(!CGPathContainsPoint(path, NULL, CGPointMake(low * .1, low * .1), NO));
                assert(CGPathContainsPoint(path, NULL, CGPointMake(low * .5, low * .5), NO));
                // A circular corner excludes this point; the superellipse includes it.
                assert(CGPathContainsPoint(path, NULL, CGPointMake(low * .25, low * .25), NO));
                assert(!CGPathContainsPoint(path, NULL, CGPointMake(high * .1, height - high * .1), NO));
                assert(CGPathContainsPoint(path, NULL, CGPointMake(high * .5, height - high * .5), NO));
                assert(CGPathContainsPoint(path, NULL, CGPointMake(high * .25, height - high * .25), NO));
                for (NSUInteger i = 0; i <= 128; ++i) {
                    CGPoint point = DMSuperellipseCornerPoint(low, (CGFloat)i / 128);
                    assert(fabs(pow(1 - point.x / low, 3) + pow(1 - point.y / low, 3) - 1) < 1e-12);
                }
                CGPathRelease(path);
            }
            NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
            DMApplyDeviceCorners(view);
            assert(view.layer.cornerRadius == 0 && view.layer.masksToBounds);
            assert([view.layer.mask isKindOfClass:CAShapeLayer.class]);
            assert(CGPathEqualToPath(((CAShapeLayer *)view.layer.mask).path, view.layer.shadowPath));
            [view setFrameSize:NSMakeSize(width / 2, height / 2)];
            DMApplyDeviceCorners(view);
            assert(CGRectGetWidth(CGPathGetBoundingBox(((CAShapeLayer *)view.layer.mask).path)) == width / 2);
        }
        NSString *other = @"DisplayDeviceInfo{virtual, 576 x 1280, type VIRTUAL}\nDisplayDeviceInfo{phone, 1440 x 3200, cutout DisplayCutout{insets=Rect(0, 160 - 0, 0)}, position=TopLeft, radius=120, position=BottomLeft, radius=118, type INTERNAL}";
        assert(DMUpdateDeviceGeometryFromDisplayDump(other));
        assert(fabs(DMPixelCornerRadius(720, YES) - DMCornerExtentForRadius(60)) < 1e-12);
        assert(fabs(DMPixelCornerRadius(720, NO) - DMCornerExtentForRadius(59)) < 1e-12);
        assert(!DMUpdateDeviceGeometryFromDisplayDump(@"bad response"));
        assert(fabs(DMPixelCornerRadius(720, YES) - DMCornerExtentForRadius(60)) < 1e-12);
        assert(DMUpdateDeviceGeometryFromDisplayDump(@"DisplayDeviceInfo{phone, 1080 x 2400, cutout DisplayCutout{insets=Rect(0, 0 - 0, 0)}, position=TopLeft, radius=104, position=BottomLeft, radius=102, type INTERNAL}"));
        assert(fabs(DMPixelCornerRadius(1080, YES) - DMCornerExtentForRadius(104)) < 1e-12);
        assert(DMUpdateDeviceGeometryFromDisplayDump(@"DisplayDeviceInfo{nearly square phone, 1440 x 3200, cutout DisplayCutout{insets=Rect(0, 160 - 0, 0)}, position=TopLeft, radius=4, position=BottomLeft, radius=2, type INTERNAL}"));
        assert(fabs(DMPixelCornerRadius(720, YES) - DMCornerExtentForRadius(2)) < 1e-12);
        assert(DMUpdateDeviceGeometryFromDisplayDump(@"DisplayDeviceInfo{square phone, 1440 x 3200, cutout DisplayCutout{insets=Rect(0, 160 - 0, 0)}, position=TopLeft, radius=0, position=BottomLeft, radius=0, type INTERNAL}"));
        assert(DMPixelCornerRadius(720, YES) == 0 && DMPixelCornerRadius(720, NO) == 0);
        assert(!DMUpdateDeviceGeometryFromDisplayDump(@"DisplayDeviceInfo{missing radii, 1440 x 3200, cutout DisplayCutout{insets=Rect(0, 160 - 0, 0)}, type INTERNAL}"));
        NSLog(@"PASS: reported radius conversion, matched diagonal roundness, square phones, padding independence, resize and shadows");
    }
    return 0;
}
