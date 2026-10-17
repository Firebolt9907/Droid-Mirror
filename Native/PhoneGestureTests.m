#import "ScrcpyWindowStyle.m"
#include <assert.h>

@interface DMPhoneGestureTestEvent : NSEvent
@property(nonatomic) NSEventType inputType;
@property(nonatomic) NSEventPhase inputPhase;
@property(nonatomic) CGFloat inputMagnification;
@property(nonatomic) NSPoint inputPoint;
@end
@implementation DMPhoneGestureTestEvent
- (NSEventType)type { return self.inputType; }
- (NSEventPhase)phase { return self.inputPhase; }
- (CGFloat)magnification { return self.inputMagnification; }
- (NSPoint)locationInWindow { return self.inputPoint; }
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
        Next(SDL_EVENT_FINGER_DOWN, 103);
        SDL_Event spread = Next(SDL_EVENT_FINGER_MOTION, 102);
        Next(SDL_EVENT_FINGER_MOTION, 103);
        assert(spread.tfinger.x < left.tfinger.x);
        event.inputPhase = NSEventPhaseChanged;
        event.inputMagnification = -0.5;
        [controller handlePhoneGestureEvent:event];
        SDL_Event inward = Next(SDL_EVENT_FINGER_MOTION, 102);
        Next(SDL_EVENT_FINGER_MOTION, 103);
        assert(inward.tfinger.x > spread.tfinger.x);
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
        puts("PASS: right-click holds a stationary touch; pinch spreads/contracts two fingers and releases on end/cancel");
    }
}
