#import "ScrcpyWindowStyle.m"
#include <assert.h>

@interface DMEdgeTestWindow : NSObject
@end
@implementation DMEdgeTestWindow
- (BOOL)isKeyWindow { return YES; }
@end
@interface DMEdgeTestTouch : NSTouch
@property NSPoint point;
@property NSTouchPhase testPhase;
@end
@implementation DMEdgeTestTouch
- (NSPoint)normalizedPosition { return self.point; }
- (NSTouchPhase)phase { return self.testPhase; }
- (id)identity { return @"edge-test"; }
- (BOOL)isResting { return NO; }
@end
@interface DMEdgeTestEvent : NSEvent
@property NSSet *contacts;
@end
@implementation DMEdgeTestEvent
- (NSSet *)touchesMatchingPhase:(NSTouchPhase)phase inView:(NSView *)view { return self.contacts; }
- (NSTimeInterval)timestamp { return NSProcessInfo.processInfo.systemUptime; }
@end

@interface DMPhoneGestureTestEvent : NSEvent
@property(nonatomic) NSEventType inputType;
@property(nonatomic) NSEventPhase inputPhase;
@property(nonatomic) CGFloat inputMagnification;
@property(nonatomic) NSPoint inputPoint;
@property(nonatomic) CGFloat inputDeltaX;
@property(nonatomic) CGFloat inputDeltaY;
@end
@implementation DMPhoneGestureTestEvent
- (NSEventType)type { return self.inputType; }
- (NSEventPhase)phase { return self.inputPhase; }
- (CGFloat)magnification { return self.inputMagnification; }
- (NSPoint)locationInWindow { return self.inputPoint; }
- (BOOL)hasPreciseScrollingDeltas { return YES; }
- (NSEventPhase)momentumPhase { return NSEventPhaseNone; }
- (CGFloat)scrollingDeltaX { return self.inputDeltaX; }
- (CGFloat)scrollingDeltaY { return self.inputDeltaY; }
@end

static SDL_Event Next(Uint32 type, SDL_FingerID finger) {
    SDL_Event e;
    if (!SDL_PollEvent(&e) && !SDL_PollEvent(&e)) { fprintf(stderr, "Missing type %u finger %lld\n", type, (long long)finger); abort(); }
    assert(e.type == type && e.tfinger.fingerID == finger);
    assert(e.tfinger.x > 0 && e.tfinger.x < 1 && e.tfinger.y > 0 && e.tfinger.y < 1);
    assert(e.tfinger.pressure == (type == SDL_EVENT_FINGER_UP ? 0 : 1));
    return e;
}

int main(void) {
    @autoreleasepool {
        SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "dummy");
        assert(SDL_Init(SDL_INIT_VIDEO));
        SDL_Window *window = SDL_CreateWindow("test", 400, 800, SDL_WINDOW_HIDDEN);
        assert(window);
        DMWindowController *controller = [DMWindowController new];
        controller.sdlWindow = window;
        controller.screenView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 800)];
        SDL_FlushEvents(SDL_EVENT_FIRST, SDL_EVENT_LAST);
        DMEdgeTestWindow *keyWindow = [DMEdgeTestWindow new];
        controller.window = (NSWindow *)keyWindow;
        DMEdgeTestTouch *contact = [DMEdgeTestTouch new];
        DMEdgeTestEvent *edgeEvent = [DMEdgeTestEvent new];
        edgeEvent.contacts = [NSSet setWithObject:contact];
        DMGestureNavigationEnabled = YES;
        // Physical edge determines the Android anchor, independently of the cursor.
        for (NSInteger edge = 1; edge <= 4; ++edge) {
            contact.point = edge == 1 ? NSMakePoint(.5,.02) : edge == 2 ? NSMakePoint(.5,.98) :
                            edge == 3 ? NSMakePoint(.02,.5) : NSMakePoint(.98,.5);
            contact.testPhase = NSTouchPhaseBegan;
            [controller handleEdgeTouches:edgeEvent];
            assert(controller.edgeKind == edge && !controller.edgeActive);
            assert(!SDL_PollEvent(&(SDL_Event){0}));
            contact.testPhase = NSTouchPhaseMoved;
            contact.point = NSMakePoint(contact.point.x + (edge == 3 ? .1 : edge == 4 ? -.1 : 0),
                                       contact.point.y + (edge == 1 ? .1 : edge == 2 ? -.1 : 0));
            [controller handleEdgeTouches:edgeEvent];
            SDL_Event anchor = Next(SDL_EVENT_FINGER_DOWN,104);
            assert(edge == 1 ? anchor.tfinger.y > .99 : edge == 2 ? anchor.tfinger.y < .01 :
                   edge == 3 ? anchor.tfinger.x < .01 : anchor.tfinger.x > .99);
            Next(SDL_EVENT_FINGER_MOTION,104);
            contact.testPhase = NSTouchPhaseEnded;
            [controller handleEdgeTouches:edgeEvent];
            Next(SDL_EVENT_FINGER_MOTION,104);
            Next(SDL_EVENT_FINGER_UP,104);
            assert(!controller.edgeTouchIdentity && !controller.edgeActive);
        }
        contact.point = NSMakePoint(.5,.5);
        contact.testPhase = NSTouchPhaseBegan;
        [controller handleEdgeTouches:edgeEvent];
        assert(!controller.edgeTouchIdentity);
        DMGestureNavigationEnabled = NO;
        for (NSInteger edge = 1; edge <= 4; ++edge) {
            contact.point = edge == 1 ? NSMakePoint(.5,.02) : edge == 2 ? NSMakePoint(.5,.98) :
                            edge == 3 ? NSMakePoint(.02,.5) : NSMakePoint(.98,.5);
            contact.testPhase = NSTouchPhaseBegan;
            [controller handleEdgeTouches:edgeEvent];
            assert((controller.edgeTouchIdentity != nil) == (edge == 2));
            [controller finishEdgeTouch];
        }
        DMGestureNavigationEnabled = YES;
        contact.point = NSMakePoint(.05,.5);
        contact.testPhase = NSTouchPhaseBegan;
        [controller handleEdgeTouches:edgeEvent];
        assert(!controller.edgeTouchIdentity); // Near-edge app swipes remain ordinary input.
        controller.window = nil;
        DMPhoneGestureTestEvent *event = [DMPhoneGestureTestEvent new];
        event.inputType = NSEventTypeRightMouseDown;
        event.inputPoint = NSMakePoint(100, 200);
        assert(![controller handlePhoneGestureEvent:event]);
        SDL_Event down = Next(SDL_EVENT_FINGER_DOWN, 101);
        assert(down.tfinger.x == 0.25f && down.tfinger.y == 0.75f);
        event.inputType = NSEventTypeRightMouseUp;
        assert(![controller handlePhoneGestureEvent:event]);
        SDL_Event unused;
        assert(!SDL_PollEvent(&unused)); // A short click still holds the touch.
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.72]];
        Next(SDL_EVENT_FINGER_UP, 101);
        assert(!controller.longPressActive);
        assert(!SDL_PollEvent(&unused));

        event.inputType = NSEventTypeMagnify;
        event.inputPhase = NSEventPhaseBegan;
        event.inputMagnification = 0.5;
        [controller handlePhoneGestureEvent:event];
        SDL_Event left = Next(SDL_EVENT_FINGER_DOWN, 102);
        SDL_Event right = Next(SDL_EVENT_FINGER_DOWN, 103);
        // Android ignores pinches narrower than ~40% of the short side, so the
        // initial span must leave room to zoom out above that floor.
        CGFloat startSpan = hypot((right.tfinger.x - left.tfinger.x) * 400, (right.tfinger.y - left.tfinger.y) * 800);
        assert(startSpan >= 400 * 0.48 * 1.4);
        assert(controller.pinchMaxRadius / controller.pinchMinRadius >= 2);
        SDL_Event spread = Next(SDL_EVENT_FINGER_MOTION, 102);
        Next(SDL_EVENT_FINGER_MOTION, 103);
        assert(spread.tfinger.x < left.tfinger.x);
        event.inputType = NSEventTypeScrollWheel;
        event.inputDeltaX = 12;
        event.inputDeltaY = 8;
        CGFloat radius = controller.pinchRadius;
        [controller handleScrollEvent:event];
        SDL_Event translated = Next(SDL_EVENT_FINGER_MOTION, 102);
        Next(SDL_EVENT_FINGER_MOTION, 103);
        assert(translated.tfinger.x > spread.tfinger.x);
        assert(translated.tfinger.y > spread.tfinger.y);
        assert(controller.pinchRadius == radius);
        assert(!SDL_PollEvent(&unused));
        event.inputDeltaX = 10000;
        event.inputDeltaY = -10000;
        [controller handleScrollEvent:event];
        Next(SDL_EVENT_FINGER_MOTION, 102);
        Next(SDL_EVENT_FINGER_MOTION, 103);
        event.inputType = NSEventTypeMagnify;
        event.inputPhase = NSEventPhaseChanged;
        event.inputMagnification = -0.5;
        [controller handlePhoneGestureEvent:event];
        SDL_Event inward = Next(SDL_EVENT_FINGER_MOTION, 102);
        Next(SDL_EVENT_FINGER_MOTION, 103);
        assert(inward.tfinger.x > spread.tfinger.x);
        // Zoom-out bottoms out at the Android minimum span, never below it.
        event.inputMagnification = -0.9;
        for (int i = 0; i < 5; ++i) {
            [controller handlePhoneGestureEvent:event];
            Next(SDL_EVENT_FINGER_MOTION, 102);
            Next(SDL_EVENT_FINGER_MOTION, 103);
        }
        assert(controller.pinchRadius == controller.pinchMinRadius);
        event.inputPhase = NSEventPhaseEnded;
        event.inputMagnification = 0;
        [controller handlePhoneGestureEvent:event];
        Next(SDL_EVENT_FINGER_MOTION, 102);
        Next(SDL_EVENT_FINGER_MOTION, 103);
        Next(SDL_EVENT_FINGER_UP, 102);
        Next(SDL_EVENT_FINGER_UP, 103);
        assert(!controller.pinchActive);

        // Edge gestures stay in bounds even at extreme magnification, and
        // cancellation releases both pointers.
        event.inputPoint = NSMakePoint(1, 799);
        event.inputPhase = NSEventPhaseBegan;
        event.inputMagnification = 100;
        [controller handlePhoneGestureEvent:event];
        Next(SDL_EVENT_FINGER_DOWN, 102);
        Next(SDL_EVENT_FINGER_DOWN, 103);
        Next(SDL_EVENT_FINGER_MOTION, 102);
        Next(SDL_EVENT_FINGER_MOTION, 103);
        event.inputPhase = NSEventPhaseCancelled;
        [controller handlePhoneGestureEvent:event];
        Next(SDL_EVENT_FINGER_UP, 102);
        Next(SDL_EVENT_FINGER_UP, 103);
        assert(!SDL_PollEvent(&unused));
        controller.sdlWindow = NULL;
        SDL_DestroyWindow(window);
        SDL_Quit();
        puts("PASS: long press; simultaneous pinch and pan; bounded contacts; release on end/cancel");
    }
}
