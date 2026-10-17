#import "MouseWheelRouting.h"
#include "../scrcpy-5.0/app/src/wheel_protocol.h"
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <SDL3/SDL.h>
#import <objc/runtime.h>
#include "../scrcpy-5.0/app/src/video_filter.h"

static const CGFloat DMToolbarHeight = 58.0;
static const CGFloat DMToolbarCornerRadius = 24.0;
static const CGFloat DMToolbarShadowInset = 18.0;
static const NSTimeInterval DMCtrlDoubleTapInterval = 0.18;
static void *DMControllerKey = &DMControllerKey;

static inline CGFloat DMScreenCornerRadius(CGFloat width) {
    return MIN(24.0, MAX(16.0, width * 0.042));
}

@interface DMToolbarView : NSVisualEffectView
@property(nonatomic, weak) NSWindow *hostWindow;
@end
@implementation DMToolbarView
- (void)mouseDown:(NSEvent *)event {
    NSPoint startMouse = NSEvent.mouseLocation;
    NSPoint startOrigin = self.hostWindow.frame.origin;
    while (YES) {
        NSEvent *next = [self.window nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)];
        if (next.type == NSEventTypeLeftMouseUp) break;
        NSPoint current = NSEvent.mouseLocation;
        [self.hostWindow setFrameOrigin:NSMakePoint(startOrigin.x + current.x - startMouse.x,
                                                   startOrigin.y + current.y - startMouse.y)];
    }
}
@end

@interface DMWindowController : NSObject <NSMenuItemValidation>
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic) SDL_Window *sdlWindow;
@property(nonatomic, strong) NSView *screenView;
@property(nonatomic, strong) DMToolbarView *toolbar;
@property(nonatomic, strong) NSPanel *toolbarWindow;
@property(nonatomic, strong) NSView *toolbarContainer;
@property(nonatomic, strong) CALayer *toolbarShadowLayer;
@property(nonatomic, strong) NSButton *pinButtonControl;
@property(nonatomic, strong) NSButton *sharpenButtonControl;
@property(nonatomic, strong) NSButton *spatialButtonControl;
@property(nonatomic, strong) NSMenuItem *spatialMenuItem;
@property(nonatomic, strong) NSPopover *pinPopover;
@property(nonatomic, strong) NSPopover *settingsPopover;
@property(nonatomic, strong) NSTextField *pinDots;
@property(nonatomic) NSInteger pinCount;
@property(nonatomic, strong) id resizeObserver;
@property(nonatomic, strong) id moveObserver;
@property(nonatomic, strong) NSTimer *pinDetectionTimer;
@property(nonatomic, strong) NSTimer *ctrlTapTimer;
@property(nonatomic) NSInteger ctrlTapCount;
@property(nonatomic) BOOL ctrlKeyDown;
@property(nonatomic, strong) id scrollMonitor;
@property(nonatomic, strong) id keyboardMonitor;
@property(nonatomic) BOOL commandQuitActive;
@property(nonatomic, strong) NSEvent *pendingCommandDownEvent;
@property(nonatomic) BOOL commandChordActive;
@property(nonatomic, strong) id resignActiveObserver;
@property(nonatomic, strong) id becomeActiveObserver;
@property(nonatomic, strong) NSTimer *backgroundTimeoutTimer;
@property(nonatomic, strong) NSTask *adbShell;
@property(nonatomic, strong) NSFileHandle *adbShellInput;
@property(nonatomic) CGFloat pendingScrollX;
@property(nonatomic) CGFloat pendingScrollY;
@property(nonatomic) BOOL swipeScheduled;
@property(nonatomic) CGFloat pendingWheelX;
@property(nonatomic) CGFloat pendingWheelY;
@property(nonatomic) BOOL wheelScheduled;
@property(nonatomic) NSUInteger wheelGeneration;
@property(nonatomic) NSTimeInterval lastWheelCommand;
@property(nonatomic) BOOL touchActive;
@property(nonatomic) CGFloat touchX;
@property(nonatomic) CGFloat touchY;
@property(nonatomic) NSInteger androidWidth;
@property(nonatomic) NSInteger androidHeight;
@property(nonatomic) BOOL bluetoothStream;
@property(nonatomic, copy) NSArray<NSValue *> *cameraCutouts;
@property(nonatomic, strong) id cutoutMouseMonitor;
- (void)updateCameraCutouts:(NSArray<NSValue *> *)cutouts;
- (NSEvent *)handleCutoutMouseEvent:(NSEvent *)event;
- (instancetype)initWithWindow:(NSWindow *)window;
@end

@implementation DMWindowController
- (instancetype)initWithWindow:(NSWindow *)window {
    if (!(self = [super init])) return nil;
    _window = window;
    _bluetoothStream = [NSProcessInfo.processInfo.environment[@"DROIDMIRROR_TRANSPORT"] isEqualToString:@"bluetooth-classic"];
    int sdlWindowCount = 0;
    SDL_Window **sdlWindows = SDL_GetWindows(&sdlWindowCount);
    for (int i = 0; i < sdlWindowCount; i++) {
        void *native = SDL_GetPointerProperty(SDL_GetWindowProperties(sdlWindows[i]), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
        if ((__bridge NSWindow *)native == window) { _sdlWindow = sdlWindows[i]; break; }
    }
    SDL_free(sdlWindows);
    _screenView = window.contentView;
    _screenView.wantsLayer = YES;
    // Match the tight outer radius of a modern phone display without clipping
    // status bar elements, clocks, or navigation indicators.
    _screenView.layer.cornerRadius = DMScreenCornerRadius(window.frame.size.width);
    _screenView.layer.cornerCurve = kCACornerCurveContinuous;
    _screenView.layer.masksToBounds = YES;
    [self buildToolbar];
    window.styleMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable;
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = YES;
    window.movableByWindowBackground = NO;
    window.minSize = NSMakeSize(310, 520);
    [window addChildWindow:_toolbarWindow ordered:NSWindowAbove];
    [self positionToolbar];
    __weak typeof(self) weakSelf = self;
    _resizeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResizeNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { [weakSelf positionToolbar]; }];
    _moveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidMoveNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { [weakSelf positionToolbar]; }];
    if (!_bluetoothStream) {
        _pinDetectionTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(__unused NSTimer *timer) { [weakSelf detectPINPrompt]; }];
    }
    if ([NSProcessInfo.processInfo.environment[@"DROIDMIRROR_SWIPE_SCROLL"] isEqualToString:@"1"]) {
        [self setupSwipeScrolling];
    }
    [self setupBackgroundTimeout];
    [self setupKeyboardRemapping];
    _cutoutMouseMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        NSEventMaskLeftMouseDown
        handler:^NSEvent *(NSEvent *event) {
            return weakSelf ? [weakSelf handleCutoutMouseEvent:event] : event;
        }];
    return self;
}

- (void)dealloc {
    if (_resizeObserver) [[NSNotificationCenter defaultCenter] removeObserver:_resizeObserver];
    if (_moveObserver) [[NSNotificationCenter defaultCenter] removeObserver:_moveObserver];
    if (_toolbarWindow) [_window removeChildWindow:_toolbarWindow];
    [_pinDetectionTimer invalidate];
    [_ctrlTapTimer invalidate];
    _pendingCommandDownEvent = nil;
    if (_scrollMonitor) [NSEvent removeMonitor:_scrollMonitor];
    if (_keyboardMonitor) [NSEvent removeMonitor:_keyboardMonitor];
    if (_cutoutMouseMonitor) [NSEvent removeMonitor:_cutoutMouseMonitor];
    if (_resignActiveObserver) [[NSNotificationCenter defaultCenter] removeObserver:_resignActiveObserver];
    if (_becomeActiveObserver) [[NSNotificationCenter defaultCenter] removeObserver:_becomeActiveObserver];
    [_backgroundTimeoutTimer invalidate];
    [_adbShellInput closeFile];
    [_adbShell terminate];
}

- (void)updateCameraCutouts:(NSArray<NSValue *> *)cutouts {
    BOOL wasHidden = self.cameraCutouts.count > 0;
    self.cameraCutouts = cutouts;
    BOOL hidden = cutouts.count > 0;
    if (hidden == wasHidden) return;
    if (hidden) {
        [self.pinPopover close];
        [self.settingsPopover close];
        [self.window removeChildWindow:self.toolbarWindow];
        [self.toolbarWindow orderOut:nil];
    } else {
        [self.window addChildWindow:self.toolbarWindow ordered:NSWindowAbove];
        [self positionToolbar];
        [self.toolbarWindow orderFront:nil];
    }
}

- (NSEvent *)handleCutoutMouseEvent:(NSEvent *)event {
    if (event.type != NSEventTypeLeftMouseDown || event.window != self.window ||
        (self.window.styleMask & NSWindowStyleMaskFullScreen)) return event;
    NSRect bounds = self.screenView.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return event;
    NSPoint point = [self.screenView convertPoint:event.locationInWindow fromView:nil];
    CGFloat x = (point.x - NSMinX(bounds)) / bounds.size.width;
    CGFloat y = (point.y - NSMinY(bounds)) / bounds.size.height;
    if (!self.screenView.isFlipped) y = 1 - y;
    for (NSValue *value in self.cameraCutouts) {
        NSRect circle = value.rectValue; // center x/y, radius x/y, normalized from SDL.
        CGFloat dx = (x - circle.origin.x) / circle.size.width;
        CGFloat dy = (y - circle.origin.y) / circle.size.height;
        if (dx * dx + dy * dy > 1) continue;
        [self.window makeKeyWindow];
        // AppKit owns the drag, just as it does for a standard window titlebar.
        [self.window performWindowDragWithEvent:event];
        return nil;
    }
    return event;
}

- (void)setupKeyboardRemapping {
    if (self.keyboardMonitor) return;
    __weak typeof(self) weakSelf = self;
    NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged;
    self.keyboardMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
        typeof(self) selfRef = weakSelf;
        if (!selfRef || (event.window && event.window != selfRef.window && event.window != selfRef.toolbarWindow)) {
            return event;
        }

        // Cancel pending single-tap Control action if any other key event arrives.
        if (selfRef.ctrlTapTimer) {
            BOOL isCtrlModifierEvent = (event.type == NSEventTypeFlagsChanged && (event.keyCode == 59 || event.keyCode == 62));
            if (!isCtrlModifierEvent) {
                [selfRef.ctrlTapTimer invalidate];
                selfRef.ctrlTapTimer = nil;
                selfRef.ctrlTapCount = 0;
            }
        }

        // Keep the app-level quit behavior even though Command is otherwise
        // exposed to Android as its Control modifier.
        if (event.keyCode == 12 &&
            ((event.modifierFlags & NSEventModifierFlagCommand) || selfRef.commandQuitActive)) {
            selfRef.pendingCommandDownEvent = nil;
            selfRef.commandChordActive = NO;
            if (event.type == NSEventTypeKeyDown && !event.isARepeat) {
                selfRef.commandQuitActive = YES;
                NSString *hostPID = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"];
                [[NSDistributedNotificationCenter defaultCenter]
                    postNotificationName:@"app.droidmirror.quit"
                    object:hostPID
                    userInfo:nil
                    deliverImmediately:YES];
            } else if (event.type == NSEventTypeKeyUp) {
                selfRef.commandQuitActive = NO;
            }
            return nil;
        }

        // Escape is an unconditional Android Back action, including when an
        // Android text field or full-screen app currently owns focus.
        if (event.keyCode == 53) {
            selfRef.pendingCommandDownEvent = nil;
            if (event.type == NSEventTypeKeyDown && !event.isARepeat) {
                [selfRef runAndroidKey:@"KEYCODE_BACK"];
            }
            return nil;
        }

        // Modifier keys arrive as flagsChanged events. A physical macOS
        // Control press is reserved as the Android navigation shortcut:
        // single tap for Home, double tap for App Switcher (Recents).
        if (event.type == NSEventTypeFlagsChanged && (event.keyCode == 59 || event.keyCode == 62)) {
            selfRef.pendingCommandDownEvent = nil;
            BOOL isCtrlDown = (event.modifierFlags & NSEventModifierFlagControl) != 0;
            if (isCtrlDown) {
                if (!selfRef.ctrlKeyDown) {
                    selfRef.ctrlKeyDown = YES;
                    if (selfRef.ctrlTapCount == 1) {
                        // Double tap: bring up the Android App Switcher!
                        [selfRef.ctrlTapTimer invalidate];
                        selfRef.ctrlTapTimer = nil;
                        selfRef.ctrlTapCount = 0;
                        [selfRef runAndroidKey:@"KEYCODE_APP_SWITCH"];
                    } else {
                        // First tap down: start timer for single-tap Home
                        selfRef.ctrlTapCount = 1;
                        [selfRef.ctrlTapTimer invalidate];
                        selfRef.ctrlTapTimer = [NSTimer scheduledTimerWithTimeInterval:DMCtrlDoubleTapInterval repeats:NO block:^(__unused NSTimer *timer) {
                            typeof(self) strongSelf = weakSelf;
                            if (!strongSelf) return;
                            strongSelf.ctrlTapCount = 0;
                            strongSelf.ctrlTapTimer = nil;
                            [strongSelf runAndroidKey:@"KEYCODE_HOME"];
                        }];
                    }
                }
            } else {
                selfRef.ctrlKeyDown = NO;
            }
            return nil;
        }

        NSEventModifierFlags flags = event.modifierFlags;
        BOOL commandDown = (flags & NSEventModifierFlagCommand) != 0;
        flags &= ~(NSEventModifierFlagCommand | NSEventModifierFlagControl);
        if (commandDown) flags |= NSEventModifierFlagControl;

        unsigned short keyCode = event.keyCode;
        if (event.type == NSEventTypeFlagsChanged) {
            if (keyCode == 55) keyCode = 59;      // left Command -> left Control
            else if (keyCode == 54) keyCode = 62; // right Command -> right Control
        }

        // Suppress individual Command presses: do not forward Command to Android
        // unless another key was pressed at the same time (chorded).
        if (event.type == NSEventTypeFlagsChanged && (event.keyCode == 55 || event.keyCode == 54)) {
            if (commandDown) {
                // Command down: defer forwarding until another key is pressed.
                selfRef.pendingCommandDownEvent = [NSEvent keyEventWithType:NSEventTypeFlagsChanged
                                                                   location:event.locationInWindow
                                                              modifierFlags:flags
                                                                  timestamp:event.timestamp
                                                               windowNumber:event.windowNumber
                                                                    context:nil
                                                                 characters:@""
                                                charactersIgnoringModifiers:@""
                                                                   isARepeat:NO
                                                                     keyCode:keyCode];
                selfRef.commandChordActive = NO;
                return nil;
            } else {
                // Command up:
                if (selfRef.pendingCommandDownEvent) {
                    // Standalone Command press released without another key: drop both down and up.
                    selfRef.pendingCommandDownEvent = nil;
                    selfRef.commandChordActive = NO;
                    return nil;
                } else if (selfRef.commandChordActive) {
                    // A chord was used, so forward Command release as Control up.
                    selfRef.commandChordActive = NO;
                    return [NSEvent keyEventWithType:NSEventTypeFlagsChanged
                                            location:event.locationInWindow
                                       modifierFlags:flags
                                           timestamp:event.timestamp
                                        windowNumber:event.windowNumber
                                             context:nil
                                          characters:@""
                         charactersIgnoringModifiers:@""
                                            isARepeat:NO
                                              keyCode:keyCode];
                }
                return nil;
            }
        }

        // If another key is pressed while Command is held, flush the deferred Command down event first.
        if (event.type == NSEventTypeKeyDown && selfRef.pendingCommandDownEvent) {
            NSEvent *cmdDown = selfRef.pendingCommandDownEvent;
            selfRef.pendingCommandDownEvent = nil;
            selfRef.commandChordActive = YES;
            [selfRef.window sendEvent:cmdDown];
        }

        // AppKit raises an exception if -characters or -isARepeat is queried
        // on a flagsChanged event, so rebuild modifier transitions without
        // touching key-event-only properties.
        if (event.type == NSEventTypeFlagsChanged) {
            return [NSEvent keyEventWithType:NSEventTypeFlagsChanged
                                    location:event.locationInWindow
                                modifierFlags:flags
                                    timestamp:event.timestamp
                                 windowNumber:event.windowNumber
                                      context:nil
                                   characters:@""
                  charactersIgnoringModifiers:@""
                                     isARepeat:NO
                                       keyCode:keyCode];
        }
        return [NSEvent keyEventWithType:event.type
                                location:event.locationInWindow
                           modifierFlags:flags
                               timestamp:event.timestamp
                            windowNumber:event.windowNumber
                                 context:nil
                              characters:event.characters ?: @""
             charactersIgnoringModifiers:event.charactersIgnoringModifiers ?: @""
                                isARepeat:event.isARepeat
                                  keyCode:keyCode];
    }];
}

- (void)setupBackgroundTimeout {
    __weak typeof(self) weakSelf = self;
    _resignActiveObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidResignActiveNotification object:NSApp
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            typeof(self) selfRef = weakSelf;
            [selfRef.ctrlTapTimer invalidate];
            selfRef.ctrlTapTimer = nil;
            selfRef.ctrlTapCount = 0;
            selfRef.ctrlKeyDown = NO;
            if (selfRef.commandChordActive) {
                selfRef.commandChordActive = NO;
                NSEvent *ctrlUp = [NSEvent keyEventWithType:NSEventTypeFlagsChanged
                                                   location:NSZeroPoint
                                              modifierFlags:0
                                                  timestamp:NSProcessInfo.processInfo.systemUptime
                                               windowNumber:selfRef.window.windowNumber
                                                    context:nil
                                                 characters:@""
                                charactersIgnoringModifiers:@""
                                                 isARepeat:NO
                                                   keyCode:59];
                [selfRef.window sendEvent:ctrlUp];
            }
            selfRef.pendingCommandDownEvent = nil;
            [selfRef.backgroundTimeoutTimer invalidate];
            selfRef.backgroundTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:120.0 repeats:NO block:^(__unused NSTimer *timer) {
                [weakSelf suspendForBackgroundTimeout];
            }];
        }];
    _becomeActiveObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidBecomeActiveNotification object:NSApp
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            [weakSelf.backgroundTimeoutTimer invalidate];
            weakSelf.backgroundTimeoutTimer = nil;
        }];
}

- (void)suspendForBackgroundTimeout {
    if (NSApp.active) return;
    NSString *hostPID = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"];
    if (hostPID.length) {
        [[NSDistributedNotificationCenter defaultCenter]
            postNotificationName:@"app.droidmirror.quit"
            object:hostPID
            userInfo:nil
            deliverImmediately:YES];
    } else {
        [NSApp terminate:nil];
    }
}

- (void)setupSwipeScrolling {
    if (self.scrollMonitor) return;
    self.androidWidth = 1080;
    self.androidHeight = 2400;
    NSString *adb = NSProcessInfo.processInfo.environment[@"ADB"] ?: @"/opt/homebrew/bin/adb";
    NSString *serial = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_SERIAL"];
    if (!self.bluetoothStream) {
        if (!serial.length) return;

        NSTask *shell = [NSTask new];
        NSPipe *input = [NSPipe pipe];
        shell.executableURL = [NSURL fileURLWithPath:adb];
        shell.arguments = @[@"-s", serial, @"shell"];
        shell.standardInput = input;
        shell.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        shell.standardError = NSFileHandle.fileHandleWithNullDevice;
        if (![shell launchAndReturnError:nil]) return;
        self.adbShell = shell;
        self.adbShellInput = input.fileHandleForWriting;
    }

    __weak typeof(self) weakSelf = self;
    self.scrollMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel handler:^NSEvent *(NSEvent *event) {
        typeof(self) selfRef = weakSelf;
        if (!selfRef || event.window != selfRef.window) return event;

        // macOS generates momentum after fingers leave the trackpad. Android
        // generates its own fling from the injected UP velocity, so forwarding
        // both would make scrolling feel far too sensitive.
        if (event.momentumPhase != NSEventPhaseNone) return nil;

        CGFloat dx = event.scrollingDeltaX;
        CGFloat dy = event.scrollingDeltaY;
        if (event.phase != NSEventPhaseNone) {
            if ((event.phase & NSEventPhaseBegan) || !selfRef.touchActive) [selfRef beginTrackpadTouchAt:event.locationInWindow];
            if (fabs(dx) >= 0.01 || fabs(dy) >= 0.01) [selfRef moveTrackpadTouchX:dx y:dy];
            if (event.phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) [selfRef endTrackpadTouch];
            return nil;
        }

        if (selfRef.bluetoothStream && DMIsMouseWheel(event.phase, event.hasPreciseScrollingDeltas, event.momentumPhase)) {
            selfRef.pendingWheelX += dx; selfRef.pendingWheelY += dy;
            if (!selfRef.wheelScheduled) {
                NSTimeInterval delay = MAX(0, selfRef.lastWheelCommand + 1.0/30.0 - NSProcessInfo.processInfo.systemUptime);
                if (delay == 0) [selfRef flushMouseWheelCommands];
                else {
                    selfRef.wheelScheduled = YES;
                    NSUInteger generation = selfRef.wheelGeneration;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                        if (weakSelf.scrollMonitor && weakSelf.wheelGeneration == generation) [weakSelf flushMouseWheelCommands];
                    });
                }
            }
            return nil;
        }

        // Discrete mouse wheels have no gesture phase. Coalesce them into one
        // short two-dimensional swipe while preserving both axes.
        if (fabs(dx) < 0.01 && fabs(dy) < 0.01) return nil;
        selfRef.pendingScrollX += dx;
        selfRef.pendingScrollY += dy;
        if (!selfRef.swipeScheduled) {
            selfRef.swipeScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 28 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [selfRef flushSwipe]; });
        }
        return nil;
    }];

    if (self.bluetoothStream) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *sizeTask = [NSTask new];
        NSPipe *output = [NSPipe pipe];
        sizeTask.executableURL = [NSURL fileURLWithPath:adb];
        sizeTask.arguments = @[@"-s", serial, @"shell", @"wm", @"size"];
        sizeTask.standardOutput = output;
        sizeTask.standardError = [NSPipe pipe];
        if (![sizeTask launchAndReturnError:nil]) return;
        [sizeTask waitUntilExit];
        NSString *text = [[NSString alloc] initWithData:[output.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)x(\\d+)" options:0 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        if (!match) return;
        NSInteger width = [[text substringWithRange:[match rangeAtIndex:1]] integerValue];
        NSInteger height = [[text substringWithRange:[match rangeAtIndex:2]] integerValue];
        dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.androidWidth = width; weakSelf.androidHeight = height; });
    });
}

- (void)stopSwipeScrolling {
    if (self.touchActive) [self endTrackpadTouch];
    if (self.scrollMonitor) [NSEvent removeMonitor:self.scrollMonitor];
    self.scrollMonitor = nil;
    [self.adbShellInput closeFile];
    self.adbShellInput = nil;
    [self.adbShell terminate];
    self.adbShell = nil;
    self.pendingScrollX = 0;
    self.pendingScrollY = 0;
    self.swipeScheduled = NO;
    self.pendingWheelX = self.pendingWheelY = 0; self.wheelScheduled = NO;
    ++self.wheelGeneration;
}

- (void)flushMouseWheelCommands {
    CGFloat dx=self.pendingWheelX, dy=self.pendingWheelY;
    self.pendingWheelX=self.pendingWheelY=0; self.wheelScheduled=NO;
    if (!self.sdlWindow || (fabs(dx)<0.001 && fabs(dy)<0.001)) return;
    self.lastWheelCommand=NSProcessInfo.processInfo.systemUptime;
    SDL_Event event; SDL_zero(event); event.type=SDL_EVENT_MOUSE_WHEEL;
    event.wheel.timestamp=SDL_GetTicksNS(); event.wheel.windowID=SDL_GetWindowID(self.sdlWindow);
    event.wheel.which=SC_DROIDMIRROR_WHEEL_MOUSE_ID;
    event.wheel.x=dx; event.wheel.y=dy;
    event.wheel.mouse_x=NSMidX(self.screenView.bounds); event.wheel.mouse_y=NSMidY(self.screenView.bounds);
    SDL_PushEvent(&event);
}

- (void)pushSDLButtonDown:(BOOL)down at:(NSPoint)point {
    if (!self.sdlWindow) return;
    SDL_Event event;
    SDL_zero(event);
    event.type = down ? SDL_EVENT_MOUSE_BUTTON_DOWN : SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.timestamp = SDL_GetTicksNS();
    event.button.windowID = SDL_GetWindowID(self.sdlWindow);
    event.button.which = 0;
    event.button.button = SDL_BUTTON_LEFT;
    event.button.down = down;
    event.button.clicks = 1;
    event.button.x = point.x;
    event.button.y = self.screenView.bounds.size.height - point.y;
    SDL_PushEvent(&event);
}

- (void)pushSDLMotionAt:(NSPoint)point relativeX:(CGFloat)dx y:(CGFloat)dy {
    if (!self.sdlWindow) return;
    SDL_Event event;
    SDL_zero(event);
    event.type = SDL_EVENT_MOUSE_MOTION;
    event.motion.timestamp = SDL_GetTicksNS();
    event.motion.windowID = SDL_GetWindowID(self.sdlWindow);
    event.motion.which = 0;
    event.motion.state = SDL_BUTTON_LMASK;
    event.motion.x = point.x;
    event.motion.y = self.screenView.bounds.size.height - point.y;
    event.motion.xrel = dx;
    event.motion.yrel = -dy;
    SDL_PushEvent(&event);
}

- (void)beginTrackpadTouchAt:(NSPoint)point {
    NSRect bounds = self.screenView.bounds;
    self.touchX = MIN(NSMaxX(bounds) - 1, MAX(NSMinX(bounds) + 1, point.x));
    self.touchY = MIN(NSMaxY(bounds) - 1, MAX(NSMinY(bounds) + 1, point.y));
    self.touchActive = YES;
    [self pushSDLButtonDown:YES at:NSMakePoint(self.touchX, self.touchY)];
}

- (void)moveTrackpadTouchX:(CGFloat)dx y:(CGFloat)dy {
    if (!self.touchActive) return;
    const CGFloat trackpadSensitivity = 1.5;
    CGFloat scaledX = dx * trackpadSensitivity;
    CGFloat scaledY = dy * trackpadSensitivity;
    NSRect bounds = self.screenView.bounds;
    self.touchX = MIN(NSMaxX(bounds) - 1, MAX(NSMinX(bounds) + 1, self.touchX + scaledX));
    self.touchY = MIN(NSMaxY(bounds) - 1, MAX(NSMinY(bounds) + 1, self.touchY - scaledY));
    [self pushSDLMotionAt:NSMakePoint(self.touchX, self.touchY) relativeX:scaledX y:-scaledY];
}

- (void)endTrackpadTouch {
    if (!self.touchActive) return;
    [self pushSDLButtonDown:NO at:NSMakePoint(self.touchX, self.touchY)];
    self.touchActive = NO;
}

- (void)flushSwipe {
    CGFloat dx = self.pendingScrollX;
    CGFloat dy = self.pendingScrollY;
    self.pendingScrollX = 0;
    self.pendingScrollY = 0;
    self.swipeScheduled = NO;
    if (self.bluetoothStream) {
        if (fabs(dx) < 0.01 && fabs(dy) < 0.01) return;
        NSRect bounds = self.screenView.bounds;
        [self beginTrackpadTouchAt:NSMakePoint(NSMidX(bounds), NSMidY(bounds))];
        [self moveTrackpadTouchX:dx * 16 y:dy * 16];
        [self endTrackpadTouch];
        return;
    }
    if ((fabs(dx) < 0.01 && fabs(dy) < 0.01) || !self.adbShellInput) return;
    NSInteger width = MAX(1, self.androidWidth), height = MAX(1, self.androidHeight);
    CGFloat scaleX = width / MAX(1, self.screenView.bounds.size.width);
    CGFloat scaleY = height / MAX(1, self.screenView.bounds.size.height);
    NSInteger startX = width / 2;
    NSInteger startY = height / 2;
    NSInteger endX = MAX((NSInteger)(width * 0.06), MIN((NSInteger)(width * 0.94), startX + lround(dx * scaleX * 24)));
    NSInteger endY = MAX((NSInteger)(height * 0.06), MIN((NSInteger)(height * 0.94), startY - lround(dy * scaleY * 24)));
    NSString *command = [NSString stringWithFormat:@"input touchscreen swipe %ld %ld %ld %ld 100\n", (long)startX, (long)startY, (long)endX, (long)endY];
    [self.adbShellInput writeData:[command dataUsingEncoding:NSUTF8StringEncoding]];
    if ((fabs(self.pendingScrollX) > 0.01 || fabs(self.pendingScrollY) > 0.01) && !self.swipeScheduled) {
        self.swipeScheduled = YES;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [weakSelf flushSwipe]; });
    }
}

- (void)positionToolbar {
    NSRect phone = self.window.frame;
    self.screenView.layer.cornerRadius = DMScreenCornerRadius(phone.size.width);
    CGFloat width = MAX(360, phone.size.width);
    CGFloat panelWidth = width + DMToolbarShadowInset * 2;
    CGFloat panelHeight = DMToolbarHeight + DMToolbarShadowInset * 2;
    [self.toolbarWindow setFrame:NSMakeRect(NSMidX(phone) - panelWidth / 2,
                                            NSMaxY(phone) + 10 - DMToolbarShadowInset,
                                            panelWidth, panelHeight)
                                display:YES];
    NSRect toolbarFrame = NSMakeRect(DMToolbarShadowInset, DMToolbarShadowInset,
                                     width, DMToolbarHeight);
    self.toolbar.frame = toolbarFrame;
    self.toolbarShadowLayer.frame = toolbarFrame;
    self.toolbarShadowLayer.shadowPath = [NSBezierPath bezierPathWithRoundedRect:self.toolbarShadowLayer.bounds
                                                                         xRadius:DMToolbarCornerRadius
                                                                         yRadius:DMToolbarCornerRadius].CGPath;
}

- (NSButton *)symbolButton:(NSString *)symbol help:(NSString *)help action:(SEL)action {
    NSButton *button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:help] target:self action:action];
    button.bordered = NO;
    button.toolTip = help;
    button.contentTintColor = NSColor.secondaryLabelColor;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:27].active = YES;
    [button.heightAnchor constraintEqualToConstant:30].active = YES;
    return button;
}

- (void)buildToolbar {
    CGFloat width = MAX(360, self.window.frame.size.width);
    CGFloat panelWidth = width + DMToolbarShadowInset * 2;
    CGFloat panelHeight = DMToolbarHeight + DMToolbarShadowInset * 2;
    _toolbarWindow = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, panelWidth, panelHeight)
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    _toolbarWindow.opaque = NO;
    _toolbarWindow.backgroundColor = NSColor.clearColor;
    // NSWindow's built-in shadow follows the rectangular panel bounds. Draw a
    // path-based shadow ourselves so it follows the rounded toolbar instead.
    _toolbarWindow.hasShadow = NO;
    _toolbarWindow.hidesOnDeactivate = NO;
    _toolbarWindow.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
    _toolbarContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, panelWidth, panelHeight)];
    _toolbarContainer.wantsLayer = YES;
    _toolbarContainer.layer.backgroundColor = NSColor.clearColor.CGColor;
    _toolbarWindow.contentView = _toolbarContainer;

    _toolbarShadowLayer = [CALayer layer];
    _toolbarShadowLayer.frame = NSMakeRect(DMToolbarShadowInset, DMToolbarShadowInset,
                                          width, DMToolbarHeight);
    _toolbarShadowLayer.backgroundColor = NSColor.clearColor.CGColor;
    _toolbarShadowLayer.shadowColor = NSColor.blackColor.CGColor;
    _toolbarShadowLayer.shadowOpacity = 0.30;
    _toolbarShadowLayer.shadowRadius = 14.0;
    _toolbarShadowLayer.shadowOffset = CGSizeMake(0, -5);
    _toolbarShadowLayer.shadowPath = [NSBezierPath bezierPathWithRoundedRect:_toolbarShadowLayer.bounds
                                                                    xRadius:DMToolbarCornerRadius
                                                                    yRadius:DMToolbarCornerRadius].CGPath;
    [_toolbarContainer.layer addSublayer:_toolbarShadowLayer];

    _toolbar = [[DMToolbarView alloc] initWithFrame:NSMakeRect(DMToolbarShadowInset,
                                                               DMToolbarShadowInset,
                                                               width, DMToolbarHeight)];
    _toolbar.hostWindow = self.window;
    _toolbar.material = NSVisualEffectMaterialHeaderView;
    _toolbar.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    _toolbar.state = NSVisualEffectStateActive;
    _toolbar.wantsLayer = YES;
    _toolbar.layer.cornerRadius = DMToolbarCornerRadius;
    _toolbar.layer.cornerCurve = kCACornerCurveContinuous;
    _toolbar.layer.masksToBounds = YES;
    [_toolbarContainer addSubview:_toolbar];
    NSString *name = [self.window.title stringByReplacingOccurrencesOfString:@"DroidMirror — " withString:@""];
    NSTextField *label = [NSTextField labelWithString:name.length ? name : @"Android"];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [label.widthAnchor constraintLessThanOrEqualToConstant:100].active = YES;
    NSString *connection = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_CONNECTION_LABEL"];
    if (!connection.length) connection = self.bluetoothStream ? @"Bluetooth" : @"ADB";
    NSTextField *connectionLabel = [NSTextField labelWithString:connection];
    connectionLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    connectionLabel.textColor = NSColor.secondaryLabelColor;
    connectionLabel.toolTip = [NSString stringWithFormat:@"Connected via %@", connection];
    [connectionLabel setAccessibilityLabel:connectionLabel.toolTip];
    [connectionLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *power = [self symbolButton:@"power" help:@"Power" action:@selector(power:)];
    _pinButtonControl = [self symbolButton:@"lock" help:@"PIN keypad" action:@selector(showPIN:)];
    _sharpenButtonControl = [self symbolButton:@"camera.filters" help:@"Enhance video: Off" action:@selector(toggleSharpen:)];
    [_sharpenButtonControl setButtonType:NSButtonTypeToggle];
    [_sharpenButtonControl setAccessibilityLabel:@"Enhance video"];
    _spatialButtonControl = [self symbolButton:@"arrow.up.left.and.arrow.down.right" help:@"MetalFX spatial upscaling (2×): Off" action:@selector(toggleSpatial:)];
    [_spatialButtonControl setButtonType:NSButtonTypeToggle];
    [_spatialButtonControl setAccessibilityLabel:@"MetalFX spatial upscaling"];
    [self ensureVideoMenu];
    [self syncSpatialControls];
    NSButton *close = [self symbolButton:@"xmark.circle.fill" help:@"Close mirror" action:@selector(close:)];
    NSStackView *stack = [NSStackView stackViewWithViews:@[label, connectionLabel, power, _pinButtonControl, _sharpenButtonControl, _spatialButtonControl, close]];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_toolbar addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:_toolbar.leadingAnchor constant:13],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:_toolbar.trailingAnchor constant:-8],
        [stack.centerYAnchor constraintEqualToAnchor:_toolbar.centerYAnchor]
    ]];
}

- (void)ensureVideoMenu {
    NSMenu *menu = NSApp.mainMenu;
    if (!menu) { menu = [NSMenu new]; NSApp.mainMenu = menu; }
    if (!menu.numberOfItems) {
        NSMenuItem *application = [[NSMenuItem alloc] initWithTitle:@"DroidMirror" action:NULL keyEquivalent:@""];
        application.submenu = [[NSMenu alloc] initWithTitle:@"DroidMirror"];
        [menu addItem:application];
    }
    NSMenuItem *view = [menu itemWithTitle:@"View"];
    if (!view) {
        view = [[NSMenuItem alloc] initWithTitle:@"View" action:NULL keyEquivalent:@""];
        view.submenu = [[NSMenu alloc] initWithTitle:@"View"];
        [menu addItem:view];
    }
    NSMenuItem *item = [view.submenu itemWithTitle:@"MetalFX Upscaling (2×)"];
    if (!item) {
        item = [[NSMenuItem alloc] initWithTitle:@"MetalFX Upscaling (2×)"
            action:@selector(toggleSpatialFromMenu:) keyEquivalent:@""];
        [view.submenu addItem:item];
    }
    item.target = self;
    self.spatialMenuItem = item;
}

- (void)syncSpatialControls {
    SDL_PropertiesID properties = self.sdlWindow ? SDL_GetWindowProperties(self.sdlWindow) : 0;
    BOOL supported = self.sdlWindow && SDL_GetBooleanProperty(properties, SC_SPATIAL_SUPPORTED_PROP, true);
    BOOL enabled = supported && SDL_GetBooleanProperty(properties, SC_SPATIAL_FILTER_PROP, true);
    self.spatialButtonControl.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.spatialButtonControl.enabled = supported;
    self.spatialButtonControl.contentTintColor = enabled ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
    self.spatialButtonControl.toolTip = supported
        ? (enabled ? @"MetalFX spatial upscaling (2×): On" : @"MetalFX spatial upscaling (2×): Off")
        : @"MetalFX spatial upscaling is unavailable on this renderer or GPU";
    self.spatialMenuItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.spatialMenuItem.enabled = supported;
    self.spatialMenuItem.toolTip = self.spatialButtonControl.toolTip;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleSpatialFromMenu:)) {
        [self syncSpatialControls];
        return self.spatialButtonControl.enabled;
    }
    return YES;
}

- (void)toggleSpatialFromMenu:(NSMenuItem *)sender {
    [self syncSpatialControls];
    if (!self.spatialButtonControl.enabled) return;
    self.spatialButtonControl.state = self.spatialButtonControl.state == NSControlStateValueOn
        ? NSControlStateValueOff : NSControlStateValueOn;
    [self toggleSpatial:self.spatialButtonControl];
}

- (void)toggleSpatial:(NSButton *)sender {
    if (!self.sdlWindow) return;
    SDL_PropertiesID properties = SDL_GetWindowProperties(self.sdlWindow);
    if (!SDL_GetBooleanProperty(properties, SC_SPATIAL_SUPPORTED_PROP, true)) {
        [self syncSpatialControls];
        return;
    }
    SDL_SetBooleanProperty(properties, SC_SPATIAL_FILTER_PROP, sender.state == NSControlStateValueOn);
    [self syncSpatialControls];
    SDL_Event event;
    SDL_zero(event);
    event.type = SDL_EVENT_WINDOW_EXPOSED;
    event.window.windowID = SDL_GetWindowID(self.sdlWindow);
    SDL_PushEvent(&event);
}

- (void)toggleSharpen:(NSButton *)sender {
    if (!self.sdlWindow) return;
    BOOL enabled = sender.state == NSControlStateValueOn;
    SDL_SetBooleanProperty(SDL_GetWindowProperties(self.sdlWindow), SC_VIDEO_FILTER_PROP, enabled);
    sender.contentTintColor = enabled ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
    sender.toolTip = enabled ? @"Enhance video: On" : @"Enhance video: Off";
    // An exposed event redraws the retained frame even when the phone is idle.
    SDL_Event event;
    SDL_zero(event);
    event.type = SDL_EVENT_WINDOW_EXPOSED;
    event.window.windowID = SDL_GetWindowID(self.sdlWindow);
    SDL_PushEvent(&event);
}

- (void)runAndroidKey:(NSString *)key {
    if (self.bluetoothStream) {
        // SDL shortcuts use the existing scrcpy controller and BLE transport.
        NSDictionary<NSString *, NSNumber *> *shortcuts = @{
            @"KEYCODE_BACK": @(SDLK_B), @"KEYCODE_HOME": @(SDLK_H),
            @"KEYCODE_APP_SWITCH": @(SDLK_S), @"KEYCODE_POWER": @(SDLK_P),
            @"KEYCODE_VOLUME_DOWN": @(SDLK_DOWN), @"KEYCODE_VOLUME_UP": @(SDLK_UP)
        };
        NSNumber *shortcut = shortcuts[key];
        if (!self.sdlWindow || !shortcut) return;
        for (int i = 0; i < 2; ++i) {
            SDL_Event event;
            SDL_zero(event);
            event.type = i == 0 ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
            event.key.timestamp = SDL_GetTicksNS();
            event.key.windowID = SDL_GetWindowID(self.sdlWindow);
            event.key.key = shortcut.unsignedIntValue;
            event.key.mod = SDL_KMOD_LALT;
            event.key.down = i == 0;
            SDL_PushEvent(&event);
        }
        return;
    }
    NSString *adb = NSProcessInfo.processInfo.environment[@"ADB"] ?: @"/opt/homebrew/bin/adb";
    NSString *serial = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_SERIAL"];
    if (!serial.length) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:adb];
        task.arguments = @[@"-s", serial, @"shell", @"input", @"keyevent", key];
        task.standardOutput = [NSPipe pipe];
        task.standardError = [NSPipe pipe];
        [task launchAndReturnError:nil];
    });
}

- (void)sendVirtualKey:(unsigned short)key characters:(NSString *)characters {
    [self.window makeFirstResponder:self.screenView];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSEvent *down = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:now windowNumber:self.window.windowNumber context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:key];
    NSEvent *up = [NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:0 timestamp:now windowNumber:self.window.windowNumber context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:key];
    [NSApp postEvent:down atStart:NO];
    [NSApp postEvent:up atStart:NO];
}

- (void)back:(id)sender { [self runAndroidKey:@"KEYCODE_BACK"]; }
- (void)home:(id)sender { [self runAndroidKey:@"KEYCODE_HOME"]; }
- (void)apps:(id)sender { [self runAndroidKey:@"KEYCODE_APP_SWITCH"]; }
- (void)volumeDown:(id)sender { [self runAndroidKey:@"KEYCODE_VOLUME_DOWN"]; }
- (void)volumeUp:(id)sender { [self runAndroidKey:@"KEYCODE_VOLUME_UP"]; }
- (void)power:(id)sender { [self runAndroidKey:@"KEYCODE_POWER"]; }
- (void)close:(id)sender { [NSApp terminate:nil]; }

- (void)showSettings:(NSButton *)sender {
    if (self.settingsPopover.shown) return;
    NSViewController *controller = [NSViewController new];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 290, 150)];

    NSTextField *title = [NSTextField labelWithString:@"Mirror settings"];
    title.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    title.frame = NSMakeRect(18, 116, 250, 22);
    [view addSubview:title];

    NSButton *swipes = [NSButton checkboxWithTitle:@"Touch-style trackpad scrolling" target:self action:@selector(toggleSwipeScrolling:)];
    swipes.state = self.scrollMonitor ? NSControlStateValueOn : NSControlStateValueOff;
    swipes.frame = NSMakeRect(18, 80, 250, 24);
    [view addSubview:swipes];

    NSButton *onTop = [NSButton checkboxWithTitle:@"Keep mirror above other windows" target:self action:@selector(toggleAlwaysOnTop:)];
    onTop.state = self.window.level == NSFloatingWindowLevel ? NSControlStateValueOn : NSControlStateValueOff;
    onTop.frame = NSMakeRect(18, 50, 250, 24);
    [view addSubview:onTop];

    NSTextField *note = [NSTextField labelWithString:@"Video, audio, and codec changes apply the next time DroidMirror starts."];
    note.font = [NSFont systemFontOfSize:10];
    note.textColor = NSColor.secondaryLabelColor;
    note.maximumNumberOfLines = 2;
    note.frame = NSMakeRect(18, 10, 254, 32);
    [view addSubview:note];

    controller.view = view;
    self.settingsPopover = [NSPopover new];
    self.settingsPopover.contentViewController = controller;
    self.settingsPopover.behavior = NSPopoverBehaviorTransient;
    [self.settingsPopover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMaxY];
}

- (void)toggleSwipeScrolling:(NSButton *)sender {
    if (sender.state == NSControlStateValueOn) [self setupSwipeScrolling];
    else [self stopSwipeScrolling];
}

- (void)toggleAlwaysOnTop:(NSButton *)sender {
    self.window.level = sender.state == NSControlStateValueOn ? NSFloatingWindowLevel : NSNormalWindowLevel;
}

- (void)showPIN:(id)sender {
    if (self.pinPopover.shown) return;
    self.pinCount = 0;
    NSViewController *controller = [NSViewController new];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 220, 300)];
    self.pinDots = [NSTextField labelWithString:@"○ ○ ○ ○"];
    self.pinDots.alignment = NSTextAlignmentCenter;
    self.pinDots.font = [NSFont systemFontOfSize:20 weight:NSFontWeightMedium];
    self.pinDots.frame = NSMakeRect(20, 255, 180, 28);
    [view addSubview:self.pinDots];
    NSArray<NSNumber *> *keys = @[@1,@2,@3,@4,@5,@6,@7,@8,@9,@(-1),@0,@(-2)];
    for (NSInteger index = 0; index < keys.count; index++) {
        NSInteger value = keys[index].integerValue;
        NSString *title = value == -1 ? @"⌫" : (value == -2 ? @"↵" : [NSString stringWithFormat:@"%ld", (long)value]);
        NSButton *button = [NSButton buttonWithTitle:title target:self action:@selector(pinButton:)];
        button.tag = value;
        NSInteger row = index / 3, column = index % 3;
        button.frame = NSMakeRect(27 + column * 58, 196 - row * 50, 48, 40);
        button.bezelStyle = NSBezelStyleCircular;
        [view addSubview:button];
    }
    NSTextField *privacy = [NSTextField labelWithString:@"Digits are sent directly and never stored."];
    privacy.font = [NSFont systemFontOfSize:10];
    privacy.textColor = NSColor.secondaryLabelColor;
    privacy.alignment = NSTextAlignmentCenter;
    privacy.frame = NSMakeRect(8, 8, 204, 18);
    [view addSubview:privacy];
    controller.view = view;
    self.pinPopover = [NSPopover new];
    self.pinPopover.contentViewController = controller;
    self.pinPopover.behavior = NSPopoverBehaviorTransient;
    [self.pinPopover showRelativeToRect:[sender bounds] ofView:sender preferredEdge:NSRectEdgeMaxY];
}

- (void)pinButton:(NSButton *)button {
    static const unsigned short digitCodes[] = {29,18,19,20,21,23,22,26,28,25};
    if (button.tag >= 0 && button.tag <= 9) {
        [self sendVirtualKey:digitCodes[button.tag] characters:[NSString stringWithFormat:@"%ld", (long)button.tag]];
        self.pinCount = MIN(8, self.pinCount + 1);
    } else if (button.tag == -1) {
        [self sendVirtualKey:51 characters:@"\b"];
        self.pinCount = MAX(0, self.pinCount - 1);
    } else {
        [self sendVirtualKey:36 characters:@"\r"];
        self.pinCount = 0;
        [self.pinPopover close];
    }
    NSMutableArray *dots = [NSMutableArray array];
    NSInteger visible = MAX(4, self.pinCount);
    for (NSInteger i = 0; i < visible; i++) [dots addObject:i < self.pinCount ? @"●" : @"○"];
    self.pinDots.stringValue = [dots componentsJoinedByString:@" "];
}

- (void)detectPINPrompt {
    if (self.bluetoothStream || self.cameraCutouts.count) return;
    if (self.pinPopover.shown) return;
    NSString *adb = NSProcessInfo.processInfo.environment[@"ADB"] ?: @"/opt/homebrew/bin/adb";
    NSString *serial = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_SERIAL"];
    if (!serial.length) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [NSTask new];
        NSPipe *pipe = [NSPipe pipe];
        task.executableURL = [NSURL fileURLWithPath:adb];
        task.arguments = @[@"-s", serial, @"exec-out", @"uiautomator", @"dump", @"/dev/tty"];
        task.standardOutput = pipe;
        task.standardError = [NSPipe pipe];
        if (![task launchAndReturnError:nil]) return;
        [task waitUntilExit];
        NSString *text = [[NSString alloc] initWithData:[pipe.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding].lowercaseString;
        NSArray *markers = @[@"keyguard_pin_view", @"pinentry", @"pin_entry", @"pin_pad", @"credential_pin", @"enter your pin"];
        BOOL found = NO;
        for (NSString *marker in markers) if ([text containsString:marker]) { found = YES; break; }
        if (found) dispatch_async(dispatch_get_main_queue(), ^{ if (!weakSelf.cameraCutouts.count && !weakSelf.pinPopover.shown) [weakSelf showPIN:weakSelf.pinButtonControl]; });
    });
}
@end

static void DMInstallToolbar(void) {
    for (NSWindow *window in NSApp.windows) {
        if (![window.title hasPrefix:@"DroidMirror —"]) continue;
        if (objc_getAssociatedObject(window, DMControllerKey)) continue;
        DMWindowController *controller = [[DMWindowController alloc] initWithWindow:window];
        objc_setAssociatedObject(window, DMControllerKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Called on the SDL/AppKit main thread after the rendered geometry is known.
void DroidMirrorSetCameraCutouts(SDL_Window *sdlWindow, const float *circles, unsigned count) {
    if (!sdlWindow) return;
    NSWindow *window = (__bridge NSWindow *)SDL_GetPointerProperty(
        SDL_GetWindowProperties(sdlWindow), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    if (!window) return;
    DMInstallToolbar();
    DMWindowController *controller = objc_getAssociatedObject(window, DMControllerKey);
    if (!controller) return;
    NSMutableArray<NSValue *> *values = [NSMutableArray array];
    for (unsigned i = 0; i < count && i < 4; ++i) {
        const float *c = circles + 4*i;
        if (!isfinite(c[0]) || !isfinite(c[1]) || !isfinite(c[2]) || !isfinite(c[3]) || c[2] <= 0 || c[3] <= 0) continue;
        [values addObject:[NSValue valueWithRect:NSMakeRect(c[0], c[1], c[2], c[3])]];
    }
    [controller updateCameraCutouts:values];
}

__attribute__((constructor))
static void DMInstallScrcpyStyling(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(__unused NSTimer *timer) { DMInstallToolbar(); }];
    });
}
