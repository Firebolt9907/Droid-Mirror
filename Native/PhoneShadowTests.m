// clang -fobjc-arc -fblocks -I/opt/homebrew/include -L/opt/homebrew/lib \
//   -lSDL3 -framework Cocoa -framework QuartzCore \
//   Native/PhoneShadowTests.m -o /tmp/droidmirror-shadow-tests
#import "ScrcpyWindowStyle.m"
#include <assert.h>

static BOOL appActive;
static BOOL TestAppActive(id app, SEL selector) { return appActive; }

@interface ShadowTestWindow : NSWindow
@property(nonatomic) BOOL testKey;
@end
@implementation ShadowTestWindow
- (BOOL)isKeyWindow { return self.testKey; }
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
        [phone orderOut:nil];
        assert(!shadow.visible);
        [phone orderFront:nil];
        assert(shadow.visible && shadow.parentWindow == phone);
        controller = nil;
        assert(!shadow.parentWindow && !shadow.visible);
        [phone orderOut:nil];
        method_setImplementation(activeGetter, originalActive);
        puts("PASS: phone shadow follows window/app focus, resize/status and visibility; preserves frame/input and tears down");
    }
}
