// clang -fobjc-arc -fblocks -framework AppKit -framework QuartzCore \
//   Native/PhoneShadowTests.m -o /tmp/droidmirror-shadow-tests
#import "DeviceCorners.m"
#import <assert.h>

static void Draw(DMPhoneShadowView *view, NSBitmapImageRep *bitmap) {
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [view drawRect:view.bounds];
    [NSGraphicsContext restoreGraphicsState];
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        DMPhoneShadowView *view = [[DMPhoneShadowView alloc] initWithFrame:NSMakeRect(0, 0, 900, 1100)];
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:900 pixelsHigh:1100 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
            isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        view.phoneRect = NSMakeRect(120, 120, 300, 800);
        Draw(view, bitmap);
        assert([bitmap colorAtX:270 y:550].alphaComponent == 0);
        assert([bitmap colorAtX:425 y:550].alphaComponent > 0);
        // Reuse the backing store with a smaller silhouette at a new location.
        view.phoneRect = NSMakeRect(500, 300, 200, 500);
        Draw(view, bitmap);
        assert([bitmap colorAtX:600 y:550].alphaComponent == 0);
        assert([bitmap colorAtX:425 y:550].alphaComponent == 0);
        assert([bitmap colorAtX:705 y:550].alphaComponent > 0);

        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 360, 800)
            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        [window orderFront:nil];
        DMApplyDeviceCorners(window.contentView);
        DMPhoneShadow *shadow = objc_getAssociatedObject(window, DMPhoneShadowKey);
        id observer = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidMoveNotification
            object:window queue:nil usingBlock:^(NSNotification *note) {
                // AppKit still owns child movement while delivering this event.
                // An absolute frame update here can advance the shadow twice.
                NSRect before = shadow.panel.frame;
                NSRect silhouetteBefore = ((DMPhoneShadowView *)shadow.panel.contentView).phoneRect;
                DMApplyDeviceCorners(window.contentView);
                assert(NSEqualRects(before, shadow.panel.frame));
                assert(NSEqualRects(silhouetteBefore, ((DMPhoneShadowView *)shadow.panel.contentView).phoneRect));
            }];
        for (NSValue *value in @[[NSValue valueWithRect:NSMakeRect(300, 250, 360, 800)],
                                 [NSValue valueWithRect:NSMakeRect(250, 150, 270, 600)],
                                 [NSValue valueWithRect:NSMakeRect(-40, 300, 360, 800)]]) {
            [window setFrame:value.rectValue display:NO];
            DMApplyDeviceCorners(window.contentView);
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
            NSRect expected = [window convertRectToScreen:[window.contentView convertRect:window.contentView.bounds toView:nil]];
            NSRect actual = [shadow.panel convertRectToScreen:((DMPhoneShadowView *)shadow.panel.contentView).phoneRect];
            assert(NSEqualRects(expected, actual));
            assert(shadow.panel.parentWindow == window);
            assert(shadow.panel.ignoresMouseEvents && !window.hasShadow);
            assert(!shadow.updateScheduled);
        }
        // Fast direction changes must coalesce using the final window position.
        for (NSUInteger i = 0; i < 40; ++i) {
            [window setFrameOrigin:NSMakePoint(i % 2 ? 420 : 180, 200 + i)];
        }
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
        NSRect settledPhone = [window convertRectToScreen:
            [window.contentView convertRect:window.contentView.bounds toView:nil]];
        assert(NSEqualRects(settledPhone, [shadow.panel convertRectToScreen:
            ((DMPhoneShadowView *)shadow.panel.contentView).phoneRect]));
        assert(!shadow.updateScheduled);
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        [window close];
        assert(!shadow.panel.visible);
        puts("PASS: transparent shadow interior, cleared backing store, move/resize/desktop-edge alignment and close");
    }
}
