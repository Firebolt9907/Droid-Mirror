#import "CornerResize.h"
#import "DeviceCorners.h"
#import <math.h>

DMResizeCorner DMCornerAtPoint(NSPoint point, NSSize size) {
    if (point.x < 0 || point.y < 0 || point.x > size.width || point.y > size.height) return DMResizeCornerNone;
    BOOL left = point.x < size.width / 2, bottom = point.y < size.height / 2;
    CGFloat x = left ? point.x : size.width - point.x;
    CGFloat y = bottom ? point.y : size.height - point.y;
    CGFloat radius = MIN(DMPixelCornerRadius(size.width, !bottom), MIN(size.width, size.height) / 2);
    // Use AppKit points so the target stays easy to grab at every window size.
    // Include the rectangular corner and a generous band around the visible arc;
    // square/unknown phone geometry must also have usable resize handles.
    const CGFloat target = 28, tolerance = 16;
    CGFloat reach = MAX(target, radius * .65 + tolerance);
    if (x > reach || y > reach) return DMResizeCornerNone;
    BOOL inCornerTarget = x <= target && y <= target;
    if (!inCornerTarget && radius <= 0) return DMResizeCornerNone;
    CGFloat distance = CGFLOAT_MAX;
    CGPoint previous = DMSuperellipseCornerPoint(radius, 0);
    for (NSUInteger i = 1; i <= 128; ++i) {
        CGPoint next = DMSuperellipseCornerPoint(radius, (CGFloat)i / 128);
        CGFloat dx = next.x - previous.x, dy = next.y - previous.y;
        CGFloat lengthSquared = dx * dx + dy * dy;
        CGFloat t = lengthSquared > 0 ? ((x - previous.x) * dx + (y - previous.y) * dy) / lengthSquared : 0;
        t = MAX(0, MIN(1, t));
        distance = MIN(distance, hypot(x - (previous.x + t * dx), y - (previous.y + t * dy)));
        previous = next;
    }
    if (!inCornerTarget && distance > tolerance) return DMResizeCornerNone;
    if (bottom) return left ? DMResizeCornerBottomLeft : DMResizeCornerBottomRight;
    return left ? DMResizeCornerTopLeft : DMResizeCornerTopRight;
}

NSRect DMCornerResizeFrame(NSRect start, NSPoint delta, DMResizeCorner corner,
                          NSSize minimum, NSSize maximum, BOOL centered) {
    if (corner == DMResizeCornerNone || start.size.width <= 0 || start.size.height <= 0) return start;
    BOOL left = corner == DMResizeCornerBottomLeft || corner == DMResizeCornerTopLeft;
    BOOL bottom = corner == DMResizeCornerBottomLeft || corner == DMResizeCornerBottomRight;
    CGFloat width = start.size.width, height = start.size.height;
    CGFloat dx = left ? -delta.x : delta.x, dy = bottom ? -delta.y : delta.y;
    // Both edges move when resizing around the center, so a corner drag
    // changes the full size by twice the pointer's movement.
    if (centered) { dx *= 2; dy *= 2; }
    // Project the drag onto the fixed-aspect-ratio size vector.
    CGFloat scale = 1 + (dx * width + dy * height) / (width * width + height * height);
    CGFloat minScale = MAX(MAX(minimum.width / width, minimum.height / height), .01);
    CGFloat maxScale = CGFLOAT_MAX;
    if (maximum.width > 0) maxScale = MIN(maxScale, maximum.width / width);
    if (maximum.height > 0) maxScale = MIN(maxScale, maximum.height / height);
    scale = MAX(minScale, MIN(MAX(minScale, maxScale), scale));
    NSSize size = NSMakeSize(width * scale, height * scale);
    if (centered) {
        return NSMakeRect(NSMidX(start) - size.width / 2,
                          NSMidY(start) - size.height / 2, size.width, size.height);
    }
    return NSMakeRect(left ? NSMaxX(start) - size.width : NSMinX(start),
                      bottom ? NSMaxY(start) - size.height : NSMinY(start), size.width, size.height);
}

static NSCursor *DMResizeCursor(DMResizeCorner corner) {
    if (@available(macOS 15.0, *)) {
        NSCursorFrameResizePosition position;
        switch (corner) {
            case DMResizeCornerTopLeft: position = NSCursorFrameResizePositionTopLeft; break;
            case DMResizeCornerTopRight: position = NSCursorFrameResizePositionTopRight; break;
            case DMResizeCornerBottomLeft: position = NSCursorFrameResizePositionBottomLeft; break;
            case DMResizeCornerBottomRight: position = NSCursorFrameResizePositionBottomRight; break;
            default: return NSCursor.arrowCursor;
        }
        return [NSCursor frameResizeCursorFromPosition:position inDirections:NSCursorFrameResizeDirectionsAll];
    }
    // macOS 14 has no public diagonal frame-resize cursor API.
    BOOL rising = corner == DMResizeCornerTopRight || corner == DMResizeCornerBottomLeft;
    static NSCursor *up, *down;
    NSCursor *cached = rising ? up : down;
    if (cached) return cached;
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(24, 24)];
    [image lockFocus];
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    if (rising) {
        [arrow moveToPoint:NSMakePoint(5, 5)]; [arrow lineToPoint:NSMakePoint(19, 19)];
        [arrow moveToPoint:NSMakePoint(5, 11)]; [arrow lineToPoint:NSMakePoint(5, 5)]; [arrow lineToPoint:NSMakePoint(11, 5)];
        [arrow moveToPoint:NSMakePoint(13, 19)]; [arrow lineToPoint:NSMakePoint(19, 19)]; [arrow lineToPoint:NSMakePoint(19, 13)];
    } else {
        [arrow moveToPoint:NSMakePoint(5, 19)]; [arrow lineToPoint:NSMakePoint(19, 5)];
        [arrow moveToPoint:NSMakePoint(5, 13)]; [arrow lineToPoint:NSMakePoint(5, 19)]; [arrow lineToPoint:NSMakePoint(11, 19)];
        [arrow moveToPoint:NSMakePoint(13, 5)]; [arrow lineToPoint:NSMakePoint(19, 5)]; [arrow lineToPoint:NSMakePoint(19, 11)];
    }
    [NSColor.whiteColor setStroke]; arrow.lineWidth = 4; [arrow stroke];
    [NSColor.blackColor setStroke]; arrow.lineWidth = 2; [arrow stroke];
    [image unlockFocus];
    cached = [[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(12, 12)];
    if (rising) up = cached; else down = cached;
    return cached;
}

void DMInstallCornerResizing(NSWindow *window, NSView *screen) {
    static id monitor;
    if (monitor || !window || !screen) return;
    __weak NSWindow *weakWindow = window;
    __weak NSView *weakScreen = screen;
    __block DMResizeCorner dragging = DMResizeCornerNone;
    __block NSPoint startMouse;
    __block NSRect startFrame;
    __block BOOL showingCursor = NO;
    window.acceptsMouseMovedEvents = YES;
    monitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        NSEventMaskMouseMoved | NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp
        handler:^NSEvent *(NSEvent *event) {
            NSWindow *host = weakWindow;
            NSView *surface = weakScreen;
            if (!host || !surface) return event;
            if (dragging != DMResizeCornerNone && (event.type == NSEventTypeLeftMouseDown ||
                (event.type == NSEventTypeMouseMoved && !(NSEvent.pressedMouseButtons & 1)))) {
                dragging = DMResizeCornerNone; // Recover if focus change swallowed mouse-up.
            }
            if (dragging != DMResizeCornerNone) {
                if (event.type == NSEventTypeLeftMouseDragged) {
                    NSPoint mouse = NSEvent.mouseLocation;
                    NSPoint delta = NSMakePoint(mouse.x - startMouse.x, mouse.y - startMouse.y);
                    BOOL centered = (event.modifierFlags & NSEventModifierFlagOption) != 0;
                    [host setFrame:DMCornerResizeFrame(startFrame, delta, dragging, host.minSize, host.maxSize, centered) display:YES];
                    return nil;
                }
                if (event.type == NSEventTypeLeftMouseUp) {
                    dragging = DMResizeCornerNone;
                    [NSCursor.arrowCursor set]; showingCursor = NO;
                    return nil;
                }
            }
            if (event.window != host || !(host.styleMask & NSWindowStyleMaskResizable) ||
                (host.styleMask & NSWindowStyleMaskFullScreen)) {
                if (showingCursor) { [NSCursor.arrowCursor set]; showingCursor = NO; }
                return event;
            }
            NSPoint point = [surface convertPoint:event.locationInWindow fromView:nil];
            point.x -= NSMinX(surface.bounds); point.y -= NSMinY(surface.bounds);
            if (surface.isFlipped) point.y = surface.bounds.size.height - point.y;
            DMResizeCorner corner = DMCornerAtPoint(point, surface.bounds.size);
            if (corner != DMResizeCornerNone) {
                [DMResizeCursor(corner) set]; showingCursor = YES;
                if (event.type == NSEventTypeLeftMouseDown) {
                    dragging = corner;
                    startMouse = [host convertPointToScreen:event.locationInWindow];
                    startFrame = host.frame;
                    return nil; // No Android tap or touch-down while resizing.
                }
            } else if (showingCursor) { [NSCursor.arrowCursor set]; showingCursor = NO; }
            return event;
        }];
}
