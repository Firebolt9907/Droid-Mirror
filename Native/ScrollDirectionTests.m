#import "ScrollDirection.h"
#import <assert.h>

@interface DMFakeScrollEvent : NSObject
@property NSEventType type;
@property BOOL hasPreciseScrollingDeltas;
@property NSEventPhase phase;
@property NSEventPhase momentumPhase;
@end
@implementation DMFakeScrollEvent
@end

@interface DMFakeScrollController : NSObject
@property double pendingScrollY;
@end
@implementation DMFakeScrollController
@end

int main(void) {
    @autoreleasepool {
        DMInstallScrollDirection(DMFakeScrollController.class);
        DMFakeScrollController *controller = [DMFakeScrollController new];
        DMFakeScrollEvent *event = [DMFakeScrollEvent new];
        event.type = NSEventTypeScrollWheel;
        assert(!DMScrollIsTouchBased((NSEvent *)event));
        BOOL prior = DMBeginScrollDirectionEvent((NSEvent *)event);
        controller.pendingScrollY += 3;
        controller.pendingScrollY += 2;
        assert(controller.pendingScrollY == -5);
        controller.pendingScrollY -= 7; // Third-party reversed input stays reversed.
        assert(controller.pendingScrollY == 2);
        DMEndScrollDirectionEvent(prior);
        controller.pendingScrollY = 0; // Asynchronous flush must really clear.
        assert(controller.pendingScrollY == 0);

        event.hasPreciseScrollingDeltas = YES; // Magic Mouse, including phase-less events.
        assert(DMScrollIsTouchBased((NSEvent *)event));
        prior = DMBeginScrollDirectionEvent((NSEvent *)event);
        controller.pendingScrollY += 4;
        assert(controller.pendingScrollY == 4);
        DMEndScrollDirectionEvent(prior);
        event.hasPreciseScrollingDeltas = NO; event.phase = NSEventPhaseChanged;
        assert(DMScrollIsTouchBased((NSEvent *)event));
        event.phase = NSEventPhaseNone; event.momentumPhase = NSEventPhaseChanged;
        assert(DMScrollIsTouchBased((NSEvent *)event));
        event.momentumPhase = NSEventPhaseNone; event.type = NSEventTypeKeyDown;
        prior = DMBeginScrollDirectionEvent((NSEvent *)event);
        controller.pendingScrollY = 9;
        assert(controller.pendingScrollY == 9);
        DMEndScrollDirectionEvent(prior);
        puts("Wheel, accumulated ticks, reversed wheel, touch, momentum, and flush direction tests passed");
    }
}
