#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <SDL3/SDL.h>
#import <assert.h>
#import <objc/runtime.h>
#import "ConnectingPhone.h"
#import "DeviceCorners.h"
#import "PhoneAppearance.h"
#undef MIN
#undef MAX
#include "util/sdl.h"
#include "util/log.h"

// The SDL utility logs only on failure; keep this focused test independent of FFmpeg.
void sc_log(enum sc_log_level level, const char *format, ...) { abort(); }
extern void DroidMirrorShowConnecting(SDL_Window *window);
extern void DroidMirrorPumpPresentation(void);

static BOOL reduceMotion;
static BOOL TestReduceMotion(id workspace, SEL selector) { return reduceMotion; }

static void PresentState(NSString *path, NSString *title, BOOL connecting) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:
        @{@"title": title, @"message": @"Status transition test", @"connecting": @(connecting)} options:0 error:nil];
    assert([data writeToFile:path atomically:YES]);
    DroidMirrorPumpPresentation();
}

int main(void) {
    @autoreleasepool {
        assert(SDL_Init(SDL_INIT_VIDEO));
        NSString *cache = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        setenv("DROIDMIRROR_APPEARANCE_CACHE", cache.UTF8String, 1);
        setenv("DROIDMIRROR_DEVICE_NAME", "Test Phone", 1);
        NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:2
            bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        NSUInteger red[] = {255, 0, 0};
        for (NSInteger x=0; x<2; x++) for (NSInteger y=0; y<2; y++) [image setPixel:red atX:x y:y];
        NSData *png = [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        DMCachePhoneAppearance(@{@"wallpaper": [png base64EncodedStringWithOptions:0]});
        NSMenu *menu = [NSMenu new];
        NSMenuItem *application = [NSMenuItem new];
        application.submenu = [NSMenu new];
        NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"Settings…" action:NULL keyEquivalent:@""];
        settings.enabled = NO;
        [application.submenu addItem:settings];
        [menu addItem:application];
        NSApp.mainMenu = menu;
        DroidMirrorInstallSessionMenu();
        assert(settings.enabled && settings.target && settings.action == NSSelectorFromString(@"settings:"));
        assert([settings.keyEquivalent isEqualToString:@","]);
        NSMenuItem *setup = [application.submenu itemWithTag:0x444d5355];
        assert(setup && setup.enabled && setup.target && setup.action == NSSelectorFromString(@"setup:"));
        NSInteger count = application.submenu.numberOfItems;
        DroidMirrorInstallSessionMenu();
        assert(application.submenu.numberOfItems == count);

        SDL_Window *loading = sc_sdl_create_window("DroidMirror — Test", 100, 100, 360, 720,
            SDL_WINDOW_BORDERLESS | SDL_WINDOW_RESIZABLE);
        assert(loading);
        NSWindow *native = (__bridge NSWindow *)SDL_GetPointerProperty(
            SDL_GetWindowProperties(loading), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
        NSInteger number = native.windowNumber;
        DroidMirrorShowConnecting(loading);
        assert(!(native.styleMask & NSWindowStyleMaskTitled));
        assert(native.collectionBehavior & NSWindowCollectionBehaviorPrimary);
        assert(native.collectionBehavior & NSWindowCollectionBehaviorManaged);
        assert(!(native.collectionBehavior & (NSWindowCollectionBehaviorAuxiliary |
            NSWindowCollectionBehaviorCanJoinAllApplications | NSWindowCollectionBehaviorTransient |
            NSWindowCollectionBehaviorStationary)));
        assert(native.level == NSNormalWindowLevel);
        assert(![native standardWindowButton:NSWindowCloseButton] || [native standardWindowButton:NSWindowCloseButton].hidden);
        assert(native.contentView.subviews.count > 0);
        NSView *overlay = native.contentView.subviews.lastObject;
        assert([overlay.identifier isEqual:@"DroidMirrorConnecting"]);
        assert([overlay valueForKey:@"wallpaper"] != nil);
        NSStackView *stack = (NSStackView *)overlay.subviews.firstObject;
        assert([((NSTextField *)stack.arrangedSubviews[1]).stringValue isEqual:@"Connecting to Test Phone…"]);
        NSBitmapImageRep *render = [overlay bitmapImageRepForCachingDisplayInRect:overlay.bounds];
        [overlay cacheDisplayInRect:overlay.bounds toBitmapImageRep:render];
        NSColor *pixel = [[render colorAtX:10 y:100] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        assert(pixel.redComponent > .2 && pixel.redComponent < .6 && pixel.greenComponent < .1);
        // Exercise rapid replacement and accessibility without changing the
        // user's global preference. Only this synthetic test process is patched.
        Method motionGetter = class_getInstanceMethod(NSWorkspace.class,
            @selector(accessibilityDisplayShouldReduceMotion));
        IMP originalMotionGetter = method_setImplementation(motionGetter, (IMP)TestReduceMotion);
        NSString *statePath = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        setenv("DROIDMIRROR_SESSION_STATE", statePath.UTF8String, 1);
        NSString *transitionKey = @"transition";
        // Freeze only the test layer's clock so slow layout/CI rendering cannot
        // finish the short transition before its cancellation is inspected.
        overlay.layer.speed = 0;
        PresentState(statePath, @"Connection ended", NO);
        assert(native.contentView.subviews.lastObject == overlay);
        assert([overlay.layer animationForKey:transitionKey]);
        stack = (NSStackView *)overlay.subviews.firstObject;
        NSButton *connect = (NSButton *)stack.arrangedSubviews[3];
        assert(connect.enabled && connect.action == NSSelectorFromString(@"connect:"));
        PresentState(statePath, @"Retrying", YES);
        assert(overlay.subviews.count == 1);
        stack = (NSStackView *)overlay.subviews.firstObject;
        NSButton *cancel = (NSButton *)stack.arrangedSubviews[3];
        assert(cancel.enabled && cancel.action == NSSelectorFromString(@"cancel:"));
        reduceMotion = YES;
        PresentState(statePath, @"Stopped due to inactivity", NO);
        assert(![overlay.layer animationForKey:transitionKey]);
        stack = (NSStackView *)overlay.subviews.firstObject;
        assert([((NSButton *)stack.arrangedSubviews[3]).title isEqualToString:@"Reconnect"]);
        reduceMotion = NO;
        PresentState(statePath, @"Connecting again", YES);
        assert([overlay.layer animationForKey:transitionKey]);
        overlay.layer.speed = 1;
        NSView *loadingActivity = overlay.subviews.firstObject.subviews.firstObject;
        CABasicAnimation *orbit = (CABasicAnimation *)[[loadingActivity valueForKey:@"ring"] animationForKey:@"connectionOrbit"];
        assert(orbit && [orbit.toValue doubleValue] < [orbit.fromValue doubleValue]);
        assert([[loadingActivity valueForKey:@"glow"] animationForKey:@"connectionBreath"]);
        reduceMotion = YES;
        [NSWorkspace.sharedWorkspace.notificationCenter postNotificationName:
            NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
        assert(![[loadingActivity valueForKey:@"ring"] animationKeys].count);
        assert(![[loadingActivity valueForKey:@"glow"] animationKeys].count);
        reduceMotion = NO;
        [NSWorkspace.sharedWorkspace.notificationCenter postNotificationName:
            NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
        assert([[loadingActivity valueForKey:@"ring"] animationForKey:@"connectionOrbit"]);
        CAShapeLayer *mask = (CAShapeLayer *)native.contentView.layer.mask;
        CGPathRef loadingPath = CGPathCreateCopy(mask.path);
        assert(loadingPath);
        sc_sdl_keep_connecting_window(loading);
        SDL_Window *video = sc_sdl_create_window("DroidMirror — Test", 0, 0, 256, 256, SDL_WINDOW_HIDDEN);
        assert(video == loading);
        assert(native.windowNumber == number);
        DMFinishConnectingPhone();
        CAKeyframeAnimation *reveal = (CAKeyframeAnimation *)[overlay.layer animationForKey:@"firstFrameReveal"];
        assert(overlay.superview && reveal.duration == 1.25);
        assert([reveal.values[1] doubleValue] == 1 && [reveal.values[2] doubleValue] > 0.8);
        assert(![overlay hitTest:NSMakePoint(NSMidX(overlay.frame), NSMidY(overlay.frame))]);
        assert(!native.movableByWindowBackground);
        // A second frame must not restart or extend the reveal.
        DMFinishConnectingPhone();
        assert([overlay.layer animationForKey:@"firstFrameReveal"]);
        // A failure/retry during the fade cancels its stale completion.
        PresentState(statePath, @"Disconnected during reveal", NO);
        assert(![overlay.layer animationForKey:@"firstFrameReveal"] && overlay.layer.opacity == 1);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.4];
        while (deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        assert(overlay.superview == native.contentView);
        assert(native.movableByWindowBackground);
        PresentState(statePath, @"Retry after reveal", YES);
        DMFinishConnectingPhone();
        deadline = [NSDate dateWithTimeIntervalSinceNow:1.4];
        while (deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        assert(!overlay.superview && !overlay.layer.animationKeys.count);
        // Accessibility skips both the entrance and the first-frame fade.
        reduceMotion = YES;
        PresentState(statePath, @"Reduced motion retry", YES);
        NSView *reducedOverlay = native.contentView.subviews.lastObject;
        NSView *activity = reducedOverlay.subviews.firstObject.subviews.firstObject;
        assert(![[activity valueForKey:@"ring"] animationKeys].count);
        DMFinishConnectingPhone();
        assert(!reducedOverlay.superview && ![reducedOverlay.layer animationForKey:@"firstFrameReveal"]);
        method_setImplementation(motionGetter, originalMotionGetter);
        unsetenv("DROIDMIRROR_SESSION_STATE");
        [NSFileManager.defaultManager removeItemAtPath:statePath error:nil];
        [NSFileManager.defaultManager removeItemAtPath:cache error:nil];
        assert(CGPathEqualToPath(loadingPath, ((CAShapeLayer *)native.contentView.layer.mask).path));
        for (NSView *view in native.contentView.subviews)
            assert(![view.identifier isEqualToString:@"DroidMirrorConnecting"]);
        assert(native.windowNumber == number);
        CGPathRelease(loadingPath);
        SDL_DestroyWindow(video);
        SDL_Quit();
        puts("PASS: animated loading, interruptible first-frame reveal, reduced motion, shared window and exact corners");
    }
}
