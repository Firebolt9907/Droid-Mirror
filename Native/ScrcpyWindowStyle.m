#import "MouseWheelRouting.h"
#include "../scrcpy-5.0/app/src/wheel_protocol.h"
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <SDL3/SDL.h>
#import <objc/runtime.h>
#include "../scrcpy-5.0/app/src/video_filter.h"
#include "../scrcpy-5.0/app/src/rotation.h"
#import "PhoneAppearance.h"

bool DroidMirrorReduceMotion(void) {
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}

static const CGFloat DMToolbarHeight = 58.0;
static const CGFloat DMToolbarCornerRadius = 24.0;
static const CGFloat DMToolbarShadowInset = 18.0;
static const CGFloat DMPhoneShadowInset = 96.0;
static const NSTimeInterval DMCtrlDoubleTapInterval = 0.18;
static void *DMControllerKey = &DMControllerKey;
static void *DMPhoneShadowVisibilityKey = &DMPhoneShadowVisibilityKey;
static NSString *const DMToolbarRevealKey = @"DroidMirrorToolbarReveal";

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
@property(nonatomic, strong) NSPanel *phoneShadowWindow;
@property(nonatomic, strong) CALayer *phoneShadowLayer;
@property(nonatomic, strong) NSArray *phoneShadowFocusObservers;
@property(nonatomic, strong) DMToolbarView *toolbar;
@property(nonatomic, strong) NSPanel *toolbarWindow;
@property(nonatomic, strong) NSView *toolbarContainer;
@property(nonatomic, strong) CALayer *toolbarShadowLayer;
@property(nonatomic, strong) NSPanel *audioWindow;
@property(nonatomic, strong) NSButton *audioButton;
@property(nonatomic, strong) NSTextField *audioLabel;
@property(nonatomic, strong) NSStackView *audioContent;
@property(nonatomic, strong) id audioStateObserver;
@property(nonatomic) BOOL sessionActive;
@property(nonatomic) BOOL audioVisible;
@property(nonatomic) NSInteger audioHelperPID;
@property(nonatomic) BOOL audioRequested;
@property(nonatomic) BOOL audioPlaying;
@property(nonatomic) BOOL audioFailed;
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
@property(nonatomic, copy) NSString *cutoutDeviceCachePath;
@property(nonatomic) BOOL cameraCutoutPresenceKnown;
@property(nonatomic) BOOL deviceHasCameraCutout;
@property(nonatomic, strong) id cutoutMouseMonitor;
@property(nonatomic, strong) id phoneGestureMonitor;
@property(nonatomic, strong) id gestureFocusObserver;
@property(nonatomic, strong) NSTimer *longPressTimer;
@property(nonatomic) BOOL longPressActive;
@property(nonatomic) NSPoint longPressPoint;
@property(nonatomic) BOOL pinchActive;
@property(nonatomic) NSPoint pinchCenter;
@property(nonatomic) CGFloat pinchRadius;
@property(nonatomic) CGFloat pinchMaxRadius;
- (NSEvent *)handlePhoneGestureEvent:(NSEvent *)event;
- (void)endPhoneGestures;
- (void)updateCameraCutouts:(NSArray<NSValue *> *)cutouts;
- (void)refreshCameraCutoutPresence;
- (void)setCameraCutoutPresence:(BOOL)present;
- (NSEvent *)handleCutoutMouseEvent:(NSEvent *)event;
- (instancetype)initWithWindow:(NSWindow *)window;
- (void)showToolbar;
- (void)hideToolbar;
- (void)buildPhoneShadow;
- (void)positionPhoneShadow;
- (void)updatePhoneShadowVisibility;
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
    _sessionActive=YES;
    [self buildAudioButton];
    // Keep the phone chrome borderless while allowing the window into the Dock.
    window.styleMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
    window.collectionBehavior = NSWindowCollectionBehaviorPrimary | NSWindowCollectionBehaviorManaged |
        NSWindowCollectionBehaviorParticipatesInCycle | NSWindowCollectionBehaviorFullScreenPrimary;
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = NO;
    [self buildPhoneShadow];
    window.movableByWindowBackground = NO;
    window.minSize = NSMakeSize(310, 520);
    [self showToolbar];
    __weak typeof(self) weakSelf = self;
    _resizeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResizeNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { [weakSelf positionToolbar]; }];
    _moveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidMoveNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { [weakSelf positionToolbar]; }];
    if (!_bluetoothStream) {
        _pinDetectionTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(__unused NSTimer *timer) { [weakSelf detectPINPrompt]; }];
    }
    if ([NSProcessInfo.processInfo.environment[@"DROIDMIRROR_SWIPE_SCROLL"] isEqualToString:@"1"]) {
        [self setupSwipeScrolling];
    }
    [self setupPhoneGestures];
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
    if (_audioStateObserver) [NSDistributedNotificationCenter.defaultCenter removeObserver:_audioStateObserver];
    [_window removeChildWindow:_audioWindow]; [_audioWindow orderOut:nil];
    if (_resizeObserver) [[NSNotificationCenter defaultCenter] removeObserver:_resizeObserver];
    if (_moveObserver) [[NSNotificationCenter defaultCenter] removeObserver:_moveObserver];
    if (_toolbarWindow) [_window removeChildWindow:_toolbarWindow];
    for (id observer in _phoneShadowFocusObservers) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
    }
    if (_phoneShadowWindow) {
        [_window removeObserver:self forKeyPath:@"visible" context:DMPhoneShadowVisibilityKey];
        [_window removeChildWindow:_phoneShadowWindow];
        [_phoneShadowWindow orderOut:nil];
    }
    [_pinDetectionTimer invalidate];
    [_ctrlTapTimer invalidate];
    _pendingCommandDownEvent = nil;
    if (_scrollMonitor) [NSEvent removeMonitor:_scrollMonitor];
    if (_keyboardMonitor) [NSEvent removeMonitor:_keyboardMonitor];
    if (_cutoutMouseMonitor) [NSEvent removeMonitor:_cutoutMouseMonitor];
    if (_phoneGestureMonitor) [NSEvent removeMonitor:_phoneGestureMonitor];
    if (_gestureFocusObserver) [[NSNotificationCenter defaultCenter] removeObserver:_gestureFocusObserver];
    [self endPhoneGestures];
    if (_resignActiveObserver) [[NSNotificationCenter defaultCenter] removeObserver:_resignActiveObserver];
    if (_becomeActiveObserver) [[NSNotificationCenter defaultCenter] removeObserver:_becomeActiveObserver];
    [_backgroundTimeoutTimer invalidate];
    [_adbShellInput closeFile];
    [_adbShell terminate];
}

- (void)refreshCameraCutoutPresence {
    const char *configured = getenv("DROIDMIRROR_APPEARANCE_CACHE");
    NSString *path = configured ? [NSString stringWithUTF8String:configured] : @"";
    if ([path isEqualToString:self.cutoutDeviceCachePath]) return;
    self.cutoutDeviceCachePath = path;
    self.cameraCutouts = @[]; // Never reuse another device's hit targets.
    NSString *cached = DMReadPhoneAppearance()[@"hasCameraCutout"];
    self.cameraCutoutPresenceKnown = [cached isEqual:@"yes"] || [cached isEqual:@"no"];
    self.deviceHasCameraCutout = [cached isEqual:@"yes"];
}

- (void)setCameraCutoutPresence:(BOOL)present {
    [self refreshCameraCutoutPresence];
    // A valid empty fullscreen/landscape response can omit a physical cutout.
    // Once observed, its presence is a device property, not a frame property.
    if (self.cameraCutoutPresenceKnown && (self.deviceHasCameraCutout || !present)) return;
    self.cameraCutoutPresenceKnown = YES;
    self.deviceHasCameraCutout = present;
    DMCachePhoneAppearance(@{@"hasCameraCutout": present ? @"yes" : @"no"});
    if (present) {
        [self.pinPopover close];
        [self.settingsPopover close];
        [self hideToolbar];
    } else [self showToolbar];
}

- (void)updateCameraCutouts:(NSArray<NSValue *> *)cutouts {
    BOOL wasHidden = self.deviceHasCameraCutout || self.cameraCutouts.count > 0;
    [self refreshCameraCutoutPresence];
    self.cameraCutouts = cutouts;
    if (cutouts.count) [self setCameraCutoutPresence:YES];
    else if (wasHidden && !self.deviceHasCameraCutout) [self showToolbar];
    // Empty/stale geometry clears hit targets, not known hardware presence.
}

- (void)hideToolbar {
    [self.toolbarContainer.layer removeAnimationForKey:DMToolbarRevealKey];
    [self.window removeChildWindow:self.toolbarWindow];
    [self.toolbarWindow orderOut:nil];
}

- (void)showToolbar {
    [self refreshCameraCutoutPresence];
    if (self.sdlWindow && SDL_GetBooleanProperty(SDL_GetWindowProperties(self.sdlWindow), SC_ROTATION_PRESENTATION_PROP, false)) { [self hideToolbar]; return; }
    if (self.deviceHasCameraCutout) { [self hideToolbar]; return; }
    for (NSView *view in self.window.contentView.subviews) {
        if ([view.identifier isEqualToString:@"DroidMirrorConnecting"]) {
            [self hideToolbar]; return;
        }
    }
    BOOL wasVisible = self.toolbarWindow.visible;
    if (!wasVisible) {
        CALayer *layer = self.toolbarContainer.layer;
        [layer removeAnimationForKey:DMToolbarRevealKey];
        if (self.window.visible && !self.window.miniaturized &&
                !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
            // Animate presentation only: the panel and its controls are fully
            // available immediately. Hiding never waits for a completion block.
            CABasicAnimation *reveal = [CABasicAnimation animationWithKeyPath:@"opacity"];
            reveal.fromValue = @0;
            reveal.toValue = @1;
            reveal.duration = 0.18;
            reveal.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [layer addAnimation:reveal forKey:DMToolbarRevealKey];
        }
    }
    [self.window addChildWindow:self.toolbarWindow ordered:NSWindowAbove];
    [self positionToolbar];
    [self.toolbarWindow orderFront:nil];
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
                [selfRef endPhoneGestures];
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
            postNotificationName:@"app.droidmirror.inactivityTimeout"
            object:hostPID
            userInfo:nil
            deliverImmediately:YES];
    } else {
        [NSApp terminate:nil];
    }
}

// Use real touch pointers so Android apps receive long presses and pinch gestures
// through the same control channel on every transport.
- (void)pushPhoneFinger:(SDL_FingerID)finger type:(Uint32)type at:(NSPoint)point {
    if (!self.sdlWindow || NSIsEmptyRect(self.screenView.bounds)) return;
    SDL_Event event;
    SDL_zero(event);
    event.type = type;
    event.tfinger.timestamp = SDL_GetTicksNS();
    event.tfinger.windowID = SDL_GetWindowID(self.sdlWindow);
    event.tfinger.touchID = 1;
    event.tfinger.fingerID = finger;
    event.tfinger.x = point.x / self.screenView.bounds.size.width;
    event.tfinger.y = 1 - point.y / self.screenView.bounds.size.height;
    event.tfinger.pressure = type == SDL_EVENT_FINGER_UP ? 0 : 1;
    SDL_PushEvent(&event);
}

- (void)pushPinchType:(Uint32)type {
    [self pushPhoneFinger:102 type:type at:NSMakePoint(self.pinchCenter.x - self.pinchRadius, self.pinchCenter.y)];
    [self pushPhoneFinger:103 type:type at:NSMakePoint(self.pinchCenter.x + self.pinchRadius, self.pinchCenter.y)];
}

- (void)endLongPress {
    [self.longPressTimer invalidate];
    self.longPressTimer = nil;
    if (!self.longPressActive) return;
    [self pushPhoneFinger:101 type:SDL_EVENT_FINGER_UP at:self.longPressPoint];
    self.longPressActive = NO;
}

- (void)endPhoneGestures {
    [self endLongPress];
    if (self.pinchActive) [self pushPinchType:SDL_EVENT_FINGER_UP];
    self.pinchActive = NO;
}

- (void)setupPhoneGestures {
    __weak typeof(self) weakSelf = self;
    self.phoneGestureMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        NSEventMaskRightMouseDown | NSEventMaskRightMouseUp | NSEventMaskRightMouseDragged | NSEventMaskMagnify
        handler:^NSEvent *(NSEvent *event) {
            return weakSelf ? [weakSelf handlePhoneGestureEvent:event] : event;
        }];
    self.gestureFocusObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowDidResignKeyNotification object:self.window
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            [weakSelf endPhoneGestures];
        }];
}

- (NSEvent *)handlePhoneGestureEvent:(NSEvent *)event {
    if (event.window != self.window || !self.sdlWindow) return event;
    NSPoint point = [self.screenView convertPoint:event.locationInWindow fromView:nil];
    NSRect bounds = self.screenView.bounds;
    if (event.type == NSEventTypeRightMouseUp || event.type == NSEventTypeRightMouseDragged) return nil;
    if (event.type == NSEventTypeRightMouseDown) {
        if (!NSPointInRect(point, bounds)) return event;
        [self endPhoneGestures];
        if (self.touchActive) [self endTrackpadTouch];
        self.longPressPoint = point;
        self.longPressActive = YES;
        [self pushPhoneFinger:101 type:SDL_EVENT_FINGER_DOWN at:point];
        __weak typeof(self) weakSelf = self;
        self.longPressTimer = [NSTimer scheduledTimerWithTimeInterval:0.65 repeats:NO block:^(__unused NSTimer *timer) {
            [weakSelf endLongPress];
        }];
        return nil;
    }
    if (event.type != NSEventTypeMagnify) return event;
    if (event.phase & NSEventPhaseCancelled) {
        [self endPhoneGestures];
        return nil;
    }
    if (!self.pinchActive && !(event.phase & NSEventPhaseEnded)) {
        if (!NSPointInRect(point, bounds) || bounds.size.width < 20) return event;
        [self endLongPress];
        if (self.touchActive) [self endTrackpadTouch];
        // Keep both fingers inside the screen, including near its edges.
        CGFloat margin = MIN(80, bounds.size.width * 0.2);
        self.pinchCenter = NSMakePoint(MIN(NSMaxX(bounds) - margin - 1, MAX(margin + 1, point.x)),
                                      MIN(NSMaxY(bounds) - 1, MAX(1, point.y)));
        self.pinchMaxRadius = MIN(self.pinchCenter.x - 1, NSMaxX(bounds) - self.pinchCenter.x - 1);
        self.pinchRadius = MIN(margin * 0.5, self.pinchMaxRadius);
        self.pinchActive = YES;
        [self pushPinchType:SDL_EVENT_FINGER_DOWN];
    }
    if (self.pinchActive) {
        self.pinchRadius = MIN(self.pinchMaxRadius, MAX(2, self.pinchRadius * (1 + event.magnification)));
        [self pushPinchType:SDL_EVENT_FINGER_MOTION];
        if (event.phase & NSEventPhaseEnded) [self endPhoneGestures];
    }
    return nil;
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
        if (selfRef.pinchActive || selfRef.longPressActive) return nil;

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

- (void)buildPhoneShadow {
    // A separate, click-through surface lets the shadow extend beyond the
    // clipped video without changing the phone's frame or input coordinates.
    _phoneShadowWindow = [[NSPanel alloc] initWithContentRect:NSZeroRect
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    _phoneShadowWindow.opaque = NO;
    _phoneShadowWindow.backgroundColor = NSColor.clearColor;
    _phoneShadowWindow.hasShadow = NO;
    _phoneShadowWindow.ignoresMouseEvents = YES;
    _phoneShadowWindow.hidesOnDeactivate = NO;
    _phoneShadowWindow.releasedWhenClosed = NO;
    _phoneShadowWindow.contentView.wantsLayer = YES;
    _phoneShadowLayer = [CALayer layer];
    _phoneShadowLayer.shadowColor = NSColor.blackColor.CGColor;
    _phoneShadowLayer.shadowOpacity = 0.60;
    _phoneShadowLayer.shadowRadius = 28.0;
    _phoneShadowLayer.shadowOffset = CGSizeMake(0, -10);
    [_phoneShadowWindow.contentView.layer addSublayer:_phoneShadowLayer];
    [self positionPhoneShadow];
    [self.window addChildWindow:_phoneShadowWindow ordered:NSWindowBelow];
    __weak typeof(self) weakSelf = self;
    NSMutableArray *observers = [NSMutableArray array];
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification,
                                      NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification]) {
        id object = [name isEqualToString:NSWindowDidBecomeKeyNotification] ||
                    [name isEqualToString:NSWindowDidResignKeyNotification] ? self.window : NSApp;
        [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:object
            queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                [weakSelf updatePhoneShadowVisibility];
            }]];
    }
    self.phoneShadowFocusObservers = observers;
    [self.window addObserver:self forKeyPath:@"visible" options:NSKeyValueObservingOptionInitial
                    context:DMPhoneShadowVisibilityKey];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                       change:(NSDictionary *)change context:(void *)context {
    if (context != DMPhoneShadowVisibilityKey) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    [self updatePhoneShadowVisibility];
}

- (void)updatePhoneShadowVisibility {
    BOOL focused = NSApp.active && self.window.keyWindow;
    // Keep the layer transparent too: AppKit may reorder child windows when
    // their parent is shown, before its focus notifications are delivered.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.phoneShadowLayer.opacity = focused ? 1.0 : 0.0;
    [CATransaction commit];
    if (focused && self.window.visible && !self.window.miniaturized) {
        if (self.phoneShadowWindow.parentWindow != self.window) {
            [self.window addChildWindow:self.phoneShadowWindow ordered:NSWindowBelow];
        }
        [self.phoneShadowWindow orderWindow:NSWindowBelow relativeTo:self.window.windowNumber];
    } else {
        [self.phoneShadowWindow orderOut:nil];
    }
}

- (void)positionPhoneShadow {
    if (!self.phoneShadowWindow) return;
    NSRect phone = self.window.frame;
    NSRect shadow = NSInsetRect(phone, -DMPhoneShadowInset, -DMPhoneShadowInset);
    NSScreen *screen = self.window.screen;
    if (screen) {
        // Transparent window padding still participates in the menu bar's
        // backdrop. Keep it below the menu bar to avoid a dark horizontal edge.
        CGFloat top = NSMaxY(screen.visibleFrame);
        shadow.size.height = MAX(0, MIN(NSMaxY(shadow), top) - NSMinY(shadow));
    }
    [self.phoneShadowWindow setFrame:shadow display:YES];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.phoneShadowLayer.frame = NSMakeRect(NSMinX(phone) - NSMinX(shadow),
                                            NSMinY(phone) - NSMinY(shadow),
                                            phone.size.width, phone.size.height);
    CGFloat radius = DMScreenCornerRadius(phone.size.width);
    self.phoneShadowLayer.shadowPath = [NSBezierPath bezierPathWithRoundedRect:self.phoneShadowLayer.bounds
        xRadius:radius yRadius:radius].CGPath;
    [CATransaction commit];
}

- (void)buildAudioButton {
    _audioWindow=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,238,36)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    _audioWindow.opaque=NO; _audioWindow.backgroundColor=NSColor.clearColor;
    _audioWindow.hasShadow=YES; _audioWindow.hidesOnDeactivate=YES;
    _audioWindow.collectionBehavior=NSWindowCollectionBehaviorAuxiliary | NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSVisualEffectView *background=[[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0,0,238,36)];
    background.material=NSVisualEffectMaterialHUDWindow; background.state=NSVisualEffectStateActive;
    background.wantsLayer=YES; background.layer.cornerRadius=18; background.layer.masksToBounds=YES;
    _audioWindow.contentView=background;
    NSImageView *icon=[NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"speaker.wave.2" accessibilityDescription:nil]];
    icon.contentTintColor=NSColor.labelColor;
    icon.translatesAutoresizingMaskIntoConstraints=NO;
    [icon.widthAnchor constraintEqualToConstant:14].active=YES;
    [icon.heightAnchor constraintEqualToConstant:14].active=YES;
    _audioLabel=[NSTextField labelWithString:@"Play phone audio over Wi-Fi"];
    _audioLabel.font=[NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    _audioLabel.textColor=NSColor.labelColor;
    _audioContent=[NSStackView stackViewWithViews:@[icon,_audioLabel]];
    _audioContent.orientation=NSUserInterfaceLayoutOrientationHorizontal;
    _audioContent.alignment=NSLayoutAttributeCenterY; _audioContent.spacing=8;
    _audioContent.translatesAutoresizingMaskIntoConstraints=NO;
    [background addSubview:_audioContent];
    [NSLayoutConstraint activateConstraints:@[
        [_audioContent.centerXAnchor constraintEqualToAnchor:background.centerXAnchor],
        [_audioContent.centerYAnchor constraintEqualToAnchor:background.centerYAnchor],
        [_audioContent.leadingAnchor constraintGreaterThanOrEqualToAnchor:background.leadingAnchor constant:16],
        [_audioContent.trailingAnchor constraintLessThanOrEqualToAnchor:background.trailingAnchor constant:-16]
    ]];
    _audioButton=[NSButton buttonWithTitle:_audioLabel.stringValue target:self action:@selector(togglePhoneAudio:)];
    _audioButton.frame=background.bounds; _audioButton.autoresizingMask=NSViewWidthSizable | NSViewHeightSizable;
    _audioButton.transparent=YES; _audioButton.bordered=NO;
    _audioButton.toolTip=@"Listen on this Mac over Wi-Fi. Phone speakers are silenced while streaming.";
    [background addSubview:_audioButton];
    NSString *hostPID=NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"];
    if (!hostPID.length) return;
    __weak typeof(self) weakSelf=self;
    _audioStateObserver=[NSDistributedNotificationCenter.defaultCenter addObserverForName:@"app.droidmirror.audioState"
        object:hostPID queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            DMWindowController *controller=weakSelf;
            if (!controller || !controller.sessionActive || !controller.bluetoothStream) return;
            [controller applyAudioState:note.userInfo];
        }];
}
- (void)applyAudioState:(NSDictionary *)state {
    if (!_sessionActive || !_bluetoothStream) return;
    self.audioHelperPID=[state[@"helper"] integerValue];
    self.audioRequested=[state[@"requested"] boolValue];
    self.audioPlaying=[state[@"playing"] boolValue];
    self.audioFailed=[state[@"failed"] boolValue];
    self.audioVisible=[state[@"available"] boolValue] || self.audioRequested;
    self.audioButton.title=self.audioRequested
        ? (self.audioPlaying ? @"Stop phone audio" : @"Cancel audio connection…")
        : (self.audioFailed ? @"Retry phone audio over Wi-Fi" : @"Play phone audio over Wi-Fi");
    self.audioLabel.stringValue=self.audioButton.title;
    [self.audioButton setAccessibilityLabel:self.audioButton.title];
    [self positionAudioButton];
}
- (void)togglePhoneAudio:(id)sender {
    if (!_sessionActive || !_audioVisible || _audioHelperPID <= 0) return;
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"app.droidmirror.audioAction"
        object:[NSString stringWithFormat:@"%ld",(long)_audioHelperPID] userInfo:nil deliverImmediately:YES];
}
- (void)positionAudioButton {
    BOOL connecting=NO;
    for (NSView *view in self.window.contentView.subviews)
        if ([view.identifier isEqualToString:@"DroidMirrorConnecting"]) connecting=YES;
    BOOL rotating=self.sdlWindow && SDL_GetBooleanProperty(SDL_GetWindowProperties(self.sdlWindow),SC_ROTATION_PRESENTATION_PROP,false);
    if (!_sessionActive || !_audioVisible || !self.window.visible || self.window.miniaturized || connecting || rotating || !NSApp.active) {
        [self.window removeChildWindow:_audioWindow]; [_audioWindow orderOut:nil]; return;
    }
    NSRect phone=self.window.frame;
    CGFloat width=ceil(self.audioLabel.intrinsicContentSize.width)+14+8+32;
    CGFloat y=MAX(NSMinY(phone)-46,NSMinY(self.window.screen.visibleFrame)+8);
    [_audioWindow setFrame:NSMakeRect(NSMidX(phone)-width/2,y,width,36) display:YES];
    [_audioWindow.contentView layoutSubtreeIfNeeded];
    if (!_audioWindow.visible) {
        [self.window addChildWindow:_audioWindow ordered:NSWindowAbove]; [_audioWindow orderFront:nil];
    }
}
- (void)positionToolbar {
    [self positionAudioButton];
    if (self.sdlWindow && SDL_GetBooleanProperty(SDL_GetWindowProperties(self.sdlWindow), SC_ROTATION_PRESENTATION_PROP, false)) {
        [self hideToolbar];
        [self.phoneShadowWindow orderOut:nil];
        return;
    }
    [self positionPhoneShadow];
    for (NSView *view in self.window.contentView.subviews) {
        if ([view.identifier isEqualToString:@"DroidMirrorConnecting"]) {
            [self hideToolbar];
            return;
        }
    }
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
    _toolbarWindow.hidesOnDeactivate = YES;
    _toolbarWindow.collectionBehavior = NSWindowCollectionBehaviorAuxiliary | NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
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
    for (NSView *view in self.window.contentView.subviews) {
        if ([view.identifier isEqualToString:@"DroidMirrorConnecting"]) {
            [self hideToolbar];
            return;
        }
    }
    [self refreshCameraCutoutPresence];
    if (self.bluetoothStream || self.deviceHasCameraCutout) return;
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
        if (found) dispatch_async(dispatch_get_main_queue(), ^{ if (!weakSelf.deviceHasCameraCutout && !weakSelf.pinPopover.shown) [weakSelf showPIN:weakSelf.pinButtonControl]; });
    });
}
@end

static void DMInstallToolbar(void) {
    for (NSWindow *window in NSApp.windows) {
        if (![window.title hasPrefix:@"DroidMirror —"]) continue;
        if (objc_getAssociatedObject(window, DMControllerKey)) continue;
        BOOL connecting = NO;
        for (NSView *view in window.contentView.subviews)
            if ([view.identifier isEqualToString:@"DroidMirrorConnecting"]) connecting = YES;
        if (connecting) continue;
        DMWindowController *controller = [[DMWindowController alloc] initWithWindow:window];
        objc_setAssociatedObject(window, DMControllerKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Stream teardown keeps the phone surface but removes session-only controls.
void DroidMirrorSessionChrome(NSWindow *window, BOOL active) {
    DMWindowController *controller = objc_getAssociatedObject(window, DMControllerKey);
    if (!controller) return;
    controller.bluetoothStream = [NSProcessInfo.processInfo.environment[@"DROIDMIRROR_TRANSPORT"] isEqualToString:@"bluetooth-classic"];
    controller.sessionActive=active;
    if (!active) {
        controller.audioVisible=NO; controller.audioRequested=NO; controller.audioHelperPID=0;
    }
    [controller positionAudioButton];
    if (active) {
        if (!controller.cameraCutouts.count) {
            [controller showToolbar];
        }
    } else {
        [controller.pinPopover close];
        [controller hideToolbar];
    }
}

void DroidMirrorRotationChrome(SDL_Window *sdlWindow, bool rotating) {
    NSWindow *window = (__bridge NSWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(sdlWindow),
        SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    DMWindowController *controller = objc_getAssociatedObject(window, DMControllerKey);
    if (!controller) return;
    [controller positionAudioButton];
    if (rotating) { [controller hideToolbar]; [controller.phoneShadowWindow orderOut:nil]; }
    else { [controller positionToolbar]; [controller showToolbar]; }
}

// Only valid, frame-matching device metadata may establish absence. Temporary
// missing geometry is deliberately not forwarded as "no cutout".
void DroidMirrorSetCameraCutoutPresence(SDL_Window *sdlWindow, bool present) {
    if (!sdlWindow) return;
    NSWindow *window = (__bridge NSWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(sdlWindow),
        SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    DMWindowController *controller = objc_getAssociatedObject(window, DMControllerKey);
    [controller setCameraCutoutPresence:present];
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
