// clang -fobjc-arc -fblocks -I/opt/homebrew/include -L/opt/homebrew/lib \
//   -lSDL3 -framework Cocoa -framework QuartzCore \
//   Native/CameraCutoutWindowTests.m -o /tmp/droidmirror-cutout-window-tests
#import "ScrcpyWindowStyle.m"
#include <assert.h>

@interface DMCutoutTestEvent : NSEvent
@property(nonatomic) NSEventType testType;
@property(nonatomic, strong) NSWindow *testWindow;
@property(nonatomic) NSPoint testLocation;
@property(nonatomic) NSTimeInterval testTimestamp;
@end
@implementation DMCutoutTestEvent
- (NSEventType)type { return self.testType; }
- (NSWindow *)window { return self.testWindow; }
- (NSPoint)locationInWindow { return self.testLocation; }
- (NSTimeInterval)timestamp { return self.testTimestamp; }
@end

@interface DMCutoutTestWindow : NSWindow
@property(nonatomic, strong) NSEvent *dragEvent;
@property(nonatomic) NSUInteger dragCount;
@end
@implementation DMCutoutTestWindow
- (void)performWindowDragWithEvent:(NSEvent *)event {
    self.dragEvent = event;
    self.dragCount++;
}
@end

static NSEvent *Mouse(NSWindow *window, NSEventType type, NSPoint screen, double time) {
    DMCutoutTestEvent *event = [DMCutoutTestEvent new];
    event.testType = type;
    event.testWindow = window;
    event.testLocation = [window convertPointFromScreen:screen];
    event.testTimestamp = time;
    return event;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        DMCutoutTestWindow *window = [[DMCutoutTestWindow alloc] initWithContentRect:NSMakeRect(100, 100, 400, 800)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        [window orderFront:nil];
        DMWindowController *controller = [DMWindowController new];
        controller.window = window;
        controller.screenView = window.contentView;
        controller.toolbarWindow = [[NSPanel alloc] initWithContentRect:NSMakeRect(100, 910, 400, 58)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        [window addChildWindow:controller.toolbarWindow ordered:NSWindowAbove];
        [controller.toolbarWindow orderFront:nil];
        NSArray *circles = @[[NSValue valueWithRect:NSMakeRect(.5, .05, .025, .0125)]];
        [controller updateCameraCutouts:circles];
        assert(!controller.toolbarWindow.visible);
        assert(controller.toolbarWindow.parentWindow == nil);
        NSPoint start = NSMakePoint(300, 860);
        NSEvent *down = Mouse(window, NSEventTypeLeftMouseDown, start, 1);
        assert([controller handleCutoutMouseEvent:down] == nil);
        // Delegate immediately on mouse-down, with the original event and no timer.
        assert(window.dragCount == 1 && window.dragEvent == down);
        down = Mouse(window, NSEventTypeLeftMouseDown, start, 1.01);
        assert([controller handleCutoutMouseEvent:down] == nil);
        assert(window.dragCount == 2 && window.dragEvent == down);
        // Ordinary phone touches pass through, including just outside the circle.
        NSEvent *outside = Mouse(window, NSEventTypeLeftMouseDown, NSMakePoint(311, 860), 3);
        assert([controller handleCutoutMouseEvent:outside] == outside);
        [controller updateCameraCutouts:@[]];
        assert(controller.toolbarWindow.visible && controller.toolbarWindow.parentWindow == window);
        NSEvent *noCutout = Mouse(window, NSEventTypeLeftMouseDown, start, 4);
        assert([controller handleCutoutMouseEvent:noCutout] == noCutout);
        assert(window.dragCount == 2);
        [controller.toolbarWindow orderOut:nil];
        [window orderOut:nil];
        puts("PASS: cutout toolbar visibility, immediate AppKit window dragging and phone input passthrough");
    }
}
