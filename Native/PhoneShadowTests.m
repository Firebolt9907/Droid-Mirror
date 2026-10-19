// clang -fobjc-arc -fblocks -I/opt/homebrew/include -L/opt/homebrew/lib \
//   -lSDL3 -framework Cocoa -framework QuartzCore \
//   Native/PhoneShadowTests.m -o /tmp/droidmirror-shadow-tests
#import "ScrcpyWindowStyle.m"
#include <assert.h>

static BOOL appActive;
static BOOL TestAppActive(id app, SEL selector) { return appActive; }

@interface ShadowTestScreen : NSObject
@property(nonatomic) NSRect visibleFrame;
@end
@implementation ShadowTestScreen
@end

@interface ShadowTestWindow : NSWindow
@property(nonatomic) BOOL testKey;
@property(nonatomic, strong) ShadowTestScreen *testScreen;
@end
@implementation ShadowTestWindow
- (BOOL)isKeyWindow { return self.testKey; }
- (NSScreen *)screen { return (NSScreen *)self.testScreen ?: super.screen; }
@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        Method activeGetter = class_getInstanceMethod(NSApplication.class, @selector(isActive));
        IMP originalActive = method_setImplementation(activeGetter, (IMP)TestAppActive);
        ShadowTestWindow *phone = [[ShadowTestWindow alloc] initWithContentRect:NSMakeRect(200, 200, 400, 800)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        [phone orderFront:nil];
        NSWindow *key = NSApp.keyWindow;
        NSRect original = phone.frame;
        DMWindowController *controller = [DMWindowController new];
        controller.window = phone;
        controller.screenView = phone.contentView;
        [controller buildPhoneShadow];
        NSPanel *shadow = controller.phoneShadowWindow;
        assert(!shadow.visible);
        assert(controller.phoneShadowLayer.opacity == 0);
        appActive = YES;
        [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidBecomeActiveNotification object:NSApp];
        assert(!shadow.visible); // Another app window has focus.
        phone.testKey = YES;
        [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidBecomeKeyNotification object:phone];
        assert(shadow.visible && shadow.parentWindow == phone && controller.phoneShadowLayer.opacity == 1);
        phone.testKey = NO;
        [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidResignKeyNotification object:phone];
        assert(!shadow.visible && controller.phoneShadowLayer.opacity == 0);
        phone.testKey = YES;
        [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidBecomeKeyNotification object:phone];
        appActive = NO;
        [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidResignActiveNotification object:NSApp];
        assert(!shadow.visible && controller.phoneShadowLayer.opacity == 0);
        appActive = YES;
        [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidBecomeActiveNotification object:NSApp];
        assert(shadow.visible && controller.phoneShadowLayer.opacity == 1);
        assert(shadow.ignoresMouseEvents && !shadow.canBecomeKeyWindow && !shadow.hasShadow);
        assert(NSEqualRects(phone.frame, original) && NSApp.keyWindow == key);
        assert(NSEqualRects(shadow.frame, NSInsetRect(phone.frame, -96, -96)));
        // Resizing during a connecting screen must still update the shadow,
        // even though positioning the session toolbar returns early.
        NSView *status = [[NSView alloc] initWithFrame:phone.contentView.bounds];
        status.identifier = @"DroidMirrorConnecting";
        [phone.contentView addSubview:status];
        [phone setFrame:NSMakeRect(300, 250, 500, 700) display:YES];
        [controller positionToolbar];
        assert(NSEqualRects(shadow.frame, NSInsetRect(phone.frame, -96, -96)));
        assert(CGRectEqualToRect(CGPathGetBoundingBox(controller.phoneShadowLayer.shadowPath),
                                 CGRectMake(0, 0, 500, 700)));
        // Padding must stop below the menu bar without moving the silhouette.
        ShadowTestScreen *screen = [ShadowTestScreen new];
        screen.visibleFrame = NSMakeRect(0, 0, 1440, 875);
        NSRect usable = screen.visibleFrame;
        [phone setFrame:NSMakeRect(NSMidX(usable) - 200, NSMaxY(usable) - 600, 400, 600) display:YES];
        phone.testScreen = screen;
        [controller positionPhoneShadow];
        phone.testScreen = nil;
        assert(NSMaxY(shadow.frame) == NSMaxY(usable));
        assert(NSMinY(shadow.frame) == NSMinY(phone.frame) - 96);
        NSRect silhouette = NSOffsetRect(controller.phoneShadowLayer.frame,
                                         shadow.frame.origin.x, shadow.frame.origin.y);
        assert(NSEqualRects(silhouette, phone.frame));
        [phone setFrame:NSMakeRect(NSMidX(usable) - 200, NSMaxY(usable) - 750, 400, 600) display:YES];
        phone.testScreen = screen;
        [controller positionPhoneShadow];
        phone.testScreen = nil;
        assert(NSEqualRects(shadow.frame, NSInsetRect(phone.frame, -96, -96)));
        [phone orderOut:nil];
        assert(!shadow.visible);
        [phone orderFront:nil];
        assert(shadow.visible && shadow.parentWindow == phone);
        controller = nil;
        assert(!shadow.parentWindow && !shadow.visible);
        [phone orderOut:nil];
        method_setImplementation(activeGetter, originalActive);
        puts("PASS: phone shadow follows focus, resize/status and visibility; stays below menu bar, preserves silhouette/frame/input and tears down");
    }
}
