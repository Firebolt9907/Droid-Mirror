#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, DMResizeCorner) {
    DMResizeCornerNone, DMResizeCornerBottomLeft, DMResizeCornerBottomRight,
    DMResizeCornerTopLeft, DMResizeCornerTopRight
};
DMResizeCorner DMCornerAtPoint(NSPoint point, NSSize size);
NSRect DMCornerResizeFrame(NSRect start, NSPoint delta, DMResizeCorner corner,
                          NSSize minimum, NSSize maximum);
void DMInstallCornerResizing(NSWindow *window, NSView *screen);
