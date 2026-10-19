#import "ScrcpyWindowStyle.m"
#include <assert.h>

static BOOL reduceMotion;
static BOOL TestReduceMotion(id workspace, SEL selector) { return reduceMotion; }

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 400, 800)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        [window orderFront:nil];
        NSWindow *keyWindow = NSApp.keyWindow;
        NSRect frame = window.frame;
        DMWindowController *controller = [DMWindowController new];
        controller.window = window;
        controller.screenView = window.contentView;
        controller.screenView.wantsLayer = YES;
        controller.bluetoothStream = YES;
        [controller buildToolbar];
        objc_setAssociatedObject(window, DMControllerKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        Method getter = class_getInstanceMethod(NSWorkspace.class, @selector(accessibilityDisplayShouldReduceMotion));
        IMP original = method_setImplementation(getter, (IMP)TestReduceMotion);
        // Keep reveal pending to exercise teardown during an animation without
        // depending on wall-clock speed or altering system accessibility settings.
        controller.toolbarContainer.layer.speed = 0;
        DroidMirrorSessionChrome(window, YES);
        assert(controller.toolbarWindow.visible && controller.toolbarWindow.parentWindow == window);
        assert([controller.toolbarContainer.layer animationForKey:DMToolbarRevealKey]);
        assert(controller.toolbarContainer.layer.opacity == 1);
        assert(controller.pinButtonControl.enabled && controller.pinButtonControl.target == controller);
        assert(NSEqualRects(frame, window.frame) && NSApp.keyWindow == keyWindow);
        DroidMirrorSessionChrome(window, NO);
        assert(!controller.toolbarWindow.visible && !controller.toolbarWindow.parentWindow);
        assert(![controller.toolbarContainer.layer animationForKey:DMToolbarRevealKey]);
        // Reconnect while the previous reveal would still be pending.
        DroidMirrorSessionChrome(window, YES);
        assert(controller.toolbarWindow.visible);
        [controller updateCameraCutouts:@[[NSValue valueWithRect:NSMakeRect(.5, .05, .025, .0125)]]];
        assert(!controller.toolbarWindow.visible && !controller.toolbarWindow.parentWindow);
        assert(![controller.toolbarContainer.layer animationForKey:DMToolbarRevealKey]);
        [controller updateCameraCutouts:@[]];
        assert(!controller.toolbarWindow.visible && controller.deviceHasCameraCutout);
        // A different device can still use the floating toolbar.
        NSString *otherDevice = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        setenv("DROIDMIRROR_APPEARANCE_CACHE", otherDevice.UTF8String, 1);
        [controller showToolbar];
        assert(controller.toolbarWindow.visible && controller.toolbarWindow.parentWindow == window);
        NSView *status = [[NSView alloc] initWithFrame:window.contentView.bounds];
        status.identifier = @"DroidMirrorConnecting";
        [window.contentView addSubview:status];
        [controller positionToolbar];
        assert(!controller.toolbarWindow.visible && !controller.toolbarWindow.parentWindow);
        DroidMirrorSessionChrome(window, YES);
        assert(!controller.toolbarWindow.visible); // Status cannot reveal session controls.
        [status removeFromSuperview];
        reduceMotion = YES;
        DroidMirrorSessionChrome(window, YES);
        assert(controller.toolbarWindow.visible && controller.toolbarContainer.layer.opacity == 1);
        assert(![controller.toolbarContainer.layer animationForKey:DMToolbarRevealKey]);
        assert(NSEqualRects(frame, window.frame) && NSApp.keyWindow == keyWindow);
        DroidMirrorSessionChrome(window, NO);
        method_setImplementation(getter, original);
        unsetenv("DROIDMIRROR_APPEARANCE_CACHE");
        objc_setAssociatedObject(window, DMControllerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [window orderOut:nil];
        puts("PASS: toolbar reveal interruption, reconnect, cutout/status hiding, immediate controls, Reduce Motion, stable frame and focus");
    }
}
