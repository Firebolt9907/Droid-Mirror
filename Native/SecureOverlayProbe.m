#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <assert.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

static void drainMainQueue(NSTimeInterval seconds) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 3);
        [NSApplication sharedApplication];
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
        assert(library);
        Class viewClass = NSClassFromString(@"DMSecurePageView");
        assert(viewClass);
        NSView *view = [[viewClass alloc] initWithFrame:NSMakeRect(0, 0, 360, 780)];
        assert([view hitTest:NSMakePoint(180, 390)] == nil);
        assert(!view.acceptsFirstResponder);
        NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        assert([png writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES]);
        // Exercise the same controller attachment and frame-transition hook used
        // by scrcpy, without connecting a phone or reading any keyboard input.
        Class controllerClass = NSClassFromString(@"DMWindowController");
        id controller = [controllerClass new];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 360, 780)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        NSView *surface = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 780)];
        window.contentView = surface;
        [controller setValue:window forKey:@"window"];
        [controller setValue:surface forKey:@"screenView"];
        ((void (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"setupKeyboardRemapping"));
        drainMainQueue(0.1);
        assert([surface.layer.mask isKindOfClass:CAShapeLayer.class]);
        assert(surface.layer.cornerRadius == 0);
        [surface setFrameSize:NSMakeSize(720, 1560)];
        ((void (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"positionToolbar"));
        assert(surface.layer.cornerRadius == 0); // Override original capped radius.
        assert(CGRectGetWidth(CGPathGetBoundingBox(((CAShapeLayer *)surface.layer.mask).path)) == 720);
        [surface setFrameSize:NSMakeSize(360, 780)];
        ((void (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"positionToolbar"));
        NSView *overlay = surface.subviews.lastObject;
        assert([overlay isKindOfClass:viewClass] && overlay.hidden);
        void (*setSecureScreen)(int) = dlsym(library, "DroidMirrorSetSecureScreen");
        assert(setSecureScreen);
        setSecureScreen(1);
        drainMainQueue(0.1);
        assert(overlay.hidden); // Debounce short transitions.
        drainMainQueue(0.4);
        assert(!overlay.hidden);
        assert([overlay hitTest:NSMakePoint(180, 390)] == nil);
        setSecureScreen(0);
        drainMainQueue(0.05);
        assert(overlay.hidden);
        setSecureScreen(1);
        setSecureScreen(0);
        drainMainQueue(0.5);
        assert(overlay.hidden); // Cancel a delayed show if video has recovered.
        [window orderOut:nil];
        NSLog(@"Device-corner controller resize, secure overlay rendering, attachment, debounce, recovery and input passthrough passed");
    }
    return 0;
}
