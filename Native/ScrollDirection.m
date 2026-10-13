#import "ScrollDirection.h"
#import <objc/runtime.h>
#import <objc/message.h>

static _Thread_local BOOL DMWheelEvent;
static void (*DMOriginalSetPendingScrollY)(id, SEL, double);

BOOL DMScrollIsTouchBased(NSEvent *event) {
    return event.hasPreciseScrollingDeltas || event.phase != NSEventPhaseNone ||
        event.momentumPhase != NSEventPhaseNone;
}

BOOL DMBeginScrollDirectionEvent(NSEvent *event) {
    BOOL previous = DMWheelEvent;
    DMWheelEvent = event.type == NSEventTypeScrollWheel && !DMScrollIsTouchBased(event);
    return previous;
}

void DMEndScrollDirectionEvent(BOOL previous) { DMWheelEvent = previous; }

static void DMSetPendingScrollY(id controller, SEL selector, double value) {
    if (DMWheelEvent) {
        double previous = ((double (*)(id, SEL))objc_msgSend)(controller,
            NSSelectorFromString(@"pendingScrollY"));
        // The retained swipe renderer reverses Y for every source. Undo that
        // extra reversal only for this wheel increment, preserving accumulated
        // ticks and the direction already supplied by macOS/Scroll Reverser.
        value = previous - (value - previous);
    }
    DMOriginalSetPendingScrollY(controller, selector, value);
}

void DMInstallScrollDirection(Class controllerClass) {
    SEL selector = NSSelectorFromString(@"setPendingScrollY:");
    Method method = class_getInstanceMethod(controllerClass, selector);
    if (!method || DMOriginalSetPendingScrollY) return;
    DMOriginalSetPendingScrollY = (void *)method_getImplementation(method);
    class_replaceMethod(controllerClass, selector, (IMP)DMSetPendingScrollY,
        method_getTypeEncoding(method));
}
