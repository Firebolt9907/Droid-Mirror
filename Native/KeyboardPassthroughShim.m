#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "DeviceCorners.h"
#import "CornerResize.h"
#import "ScrollDirection.h"
#import "MirrorMenu.h"

static id DMKeyboardMonitor;
static id DMWindowCloseObserver;
static BOOL DMCommandQuitActive;
static BOOL DMHostQuitRequested;
static NSUInteger DMPINSyntheticEventsRemaining;
static void (*DMOriginalSendEvent)(NSApplication *, SEL, NSEvent *);
static NSView *DMSecureOverlay;
static NSUInteger DMSecureGeneration;
static BOOL DMSecureBlack;
static __weak id DMSecureController;
static void (*DMOriginalDetectPINPrompt)(id, SEL);
static CFAbsoluteTime DMLastPINCheck;
static void (*DMOriginalPositionToolbar)(id, SEL);

static void DMPositionToolbarWithDeviceCorners(id controller, SEL selector) {
    DMOriginalPositionToolbar(controller, selector);
    NSView *screen = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"screenView"));
    if ([screen isKindOfClass:NSView.class]) DMApplyDeviceCorners(screen);
}
static BOOL DMFrameRendered;
static __weak NSWindow *DMMirrorWindow;
static id DMFocusObserver;

static void DMReportMirrorVisible(void) {
    if (!DMFrameRendered || !DMMirrorWindow.visible || DMMirrorWindow.miniaturized) return;
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"app.droidmirror.mirrorVisible"
        object:NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"] userInfo:nil deliverImmediately:YES];
}
__attribute__((visibility("default")))
void DroidMirrorFrameVisible(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ DMFrameRendered = YES; DMReportMirrorVisible(); });
}

static void DMDetectPINPrompt(id controller, SEL selector) {
    // A regular lock screen has visible content; unrelated secure apps may be
    // black, so still let the original PIN-specific hierarchy check confirm it.
    if (!DMSecureBlack || DMHostQuitRequested || !DMOriginalDetectPINPrompt) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - DMLastPINCheck < 1.25) return; // Coalesce frame and timer triggers.
    DMLastPINCheck = now;
    DMOriginalDetectPINPrompt(controller, selector);
}

@interface DMSecurePageView : NSView
@end
@implementation DMSecurePageView
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)isOpaque { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
    // Only draw the message: leave Android's navigation pill visible underneath.
    CGFloat width = MIN(280, MAX(80, self.bounds.size.width - 40));
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineSpacing = 4;
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.72 alpha:1],
        NSParagraphStyleAttributeName: paragraph
    };
    NSString *message = @"Android prevents this screen from being mirrored.\nYou can still type using your keyboard.";
    NSRect textBounds = [message boundingRectWithSize:NSMakeSize(width, 160)
        options:NSStringDrawingUsesLineFragmentOrigin attributes:attributes];
    CGFloat height = ceil(textBounds.size.height);
    CGFloat bottom = NSMidY(self.bounds) - (height + 98) / 2;
    NSImage *lock = [NSImage imageWithSystemSymbolName:@"lock.fill" accessibilityDescription:@"Restricted secure page"];
    lock = [lock imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPaletteColors:@[[NSColor colorWithWhite:0.72 alpha:1]]]];
    [lock drawInRect:NSMakeRect(NSMidX(self.bounds) - 18, bottom + height + 62, 36, 36)
        fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [message drawWithRect:NSMakeRect(NSMidX(self.bounds) - width / 2, bottom, width, height)
        options:NSStringDrawingUsesLineFragmentOrigin attributes:attributes];
    NSMutableDictionary *titleAttributes = [attributes mutableCopy];
    titleAttributes[NSFontAttributeName] = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    titleAttributes[NSForegroundColorAttributeName] = [NSColor colorWithWhite:0.9 alpha:1];
    [@"Secure screen" drawWithRect:NSMakeRect(NSMidX(self.bounds) - width / 2, bottom + height + 16, width, 24)
        options:NSStringDrawingUsesLineFragmentOrigin attributes:titleAttributes];
}
@end

// Called by the patched client on black/nonblack frame transitions. No change
// to SDL's keyboard, pointer or HID handling: this view cannot take focus.
__attribute__((visibility("default")))
void DroidMirrorSetSecureScreen(int black) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL enteringBlackScreen = black && !DMSecureBlack;
        DMSecureBlack = black != 0;
        NSUInteger generation = ++DMSecureGeneration;
        if (!black) {
            DMSecureOverlay.hidden = YES;
            return;
        }
        if (enteringBlackScreen && DMSecureController) {
            DMLastPINCheck = 0;
            DMDetectPINPrompt(DMSecureController, NSSelectorFromString(@"detectPINPrompt"));
        }
        // A black frame may be a brief app transition. Also works for static
        // secure pages where the encoder emits just one frame and then idles.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (generation != DMSecureGeneration || DMHostQuitRequested) return;
            DMSecureOverlay.hidden = NO;
            [DMSecureOverlay setNeedsDisplay:YES];
        });
    });
}

@interface DMMirrorQuitTarget : NSObject
- (void)quit:(id)sender;
@end

static void DMRequestHostQuit(void) {
    @synchronized (NSProcessInfo.processInfo) {
        if (DMHostQuitRequested) {
            return;
        }
        DMHostQuitRequested = YES;
    }

    NSString *hostPID = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"];
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@"app.droidmirror.quit"
                      object:hostPID
                    userInfo:nil
          deliverImmediately:YES];

    pid_t processIdentifier = (pid_t)hostPID.intValue;
    if (processIdentifier > 1 && processIdentifier != getpid()) {
        NSRunningApplication *host =
            [NSRunningApplication runningApplicationWithProcessIdentifier:processIdentifier];
        [host terminate];
    }
}

static BOOL DMEventIsQ(NSEvent *event) {
    if (event.keyCode == 12) {
        return YES;
    }

    NSString *characters = event.charactersIgnoringModifiers.lowercaseString;
    return [characters isEqualToString:@"q"];
}

@implementation DMMirrorQuitTarget
- (void)quit:(id)sender {
    DMRequestHostQuit();
    [NSApp terminate:sender];
}
@end
static DMMirrorQuitTarget *DMMirrorQuit;

static void DMSendEvent(NSApplication *app, SEL selector, NSEvent *event) {
    if ((event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) &&
        DMEventIsQ(event) && (event.modifierFlags & NSEventModifierFlagCommand)) {
        if (event.type == NSEventTypeKeyDown && !event.isARepeat)
            [DMMirrorQuit quit:nil];
        return;
    }
    BOOL previousScrollContext = DMBeginScrollDirectionEvent(event);
    @try { DMOriginalSendEvent(app, selector, event); }
    @finally { DMEndScrollDirectionEvent(previousScrollContext); }
}

static NSInteger DMPINButtonTagForEvent(NSEvent *event) {
    switch (event.keyCode) {
        case 29: case 82: return 0;
        case 18: case 83: return 1;
        case 19: case 84: return 2;
        case 20: case 85: return 3;
        case 21: case 86: return 4;
        case 23: case 87: return 5;
        case 22: case 88: return 6;
        case 26: case 89: return 7;
        case 28: case 91: return 8;
        case 25: case 92: return 9;
        case 51: case 117: return -1; // Delete
        case 36: case 76: return -2;  // Return / keypad Enter
        default: return NSIntegerMin;
    }
}

static BOOL DMPINPopoverIsVisible(id controller) {
    SEL popoverSelector = NSSelectorFromString(@"pinPopover");
    if (![controller respondsToSelector:popoverSelector]) {
        return NO;
    }

    id (*sendObject)(id, SEL) = (void *)objc_msgSend;
    id popover = sendObject(controller, popoverSelector);
    return [popover isKindOfClass:NSPopover.class] && ((NSPopover *)popover).isShown;
}

static void DMForwardPINKey(id controller, NSInteger tag) {
    SEL pinButtonSelector = NSSelectorFromString(@"pinButton:");
    if (![controller respondsToSelector:pinButtonSelector]) {
        return;
    }

    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.tag = tag;

    // pinButton: updates the local dots, focuses the scrcpy surface, and posts
    // a down/up pair that the UHID backend can deliver to the secure screen.
    DMPINSyntheticEventsRemaining += 2;
    void (*sendButton)(id, SEL, id) = (void *)objc_msgSend;
    sendButton(controller, pinButtonSelector, button);
}

// Replaces DroidMirror's previous keyboard translation layer. scrcpy receives
// every key unchanged, except Command-Q, which belongs to the macOS host app.
static void DMSetupKeyboardPassthrough(id self, SEL command) {
    (void)self;
    (void)command;

    if (DMKeyboardMonitor != nil) {
        return;
    }
    DMSecureController = self;

    SEL windowSelector = NSSelectorFromString(@"window");
    if ([self respondsToSelector:windowSelector]) {
        id (*sendObject)(id, SEL) = (void *)objc_msgSend;
        NSWindow *mirrorWindow = sendObject(self, windowSelector);
        if ([mirrorWindow isKindOfClass:NSWindow.class]) {
            DMMirrorWindow = mirrorWindow;
            DMFocusObserver = [[NSDistributedNotificationCenter defaultCenter]
                addObserverForName:@"app.droidmirror.focusMirror"
                object:NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"] queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
                    if (DMHostQuitRequested) return;
                    [mirrorWindow deminiaturize:nil];
                    [NSApp activateIgnoringOtherApps:YES];
                    [mirrorWindow makeKeyAndOrderFront:nil];
                    DMReportMirrorVisible();
                }];
            // Run after the styling controller finishes attaching its toolbar,
            // so the stream, rather than its child toolbar, receives focus.
            dispatch_async(dispatch_get_main_queue(), ^{
                if (DMHostQuitRequested) return;
                [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
                [NSApp activateIgnoringOtherApps:YES];
                [mirrorWindow makeKeyAndOrderFront:nil];
                DMReportMirrorVisible();
                SEL screenSelector = NSSelectorFromString(@"screenView");
                if ([self respondsToSelector:screenSelector]) {
                    NSView *screen = sendObject(self, screenSelector);
                    if ([screen isKindOfClass:NSView.class]) {
                        DMApplyDeviceCorners(screen);
                        DMRefreshDeviceCornersFromPhone(screen);
                        DMInstallCornerResizing(mirrorWindow, screen);
                        [mirrorWindow makeFirstResponder:screen];
                        DMSecurePageView *overlay = [[DMSecurePageView alloc] initWithFrame:screen.bounds];
                        overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                        overlay.wantsLayer = YES;
                        overlay.hidden = YES;
                        [screen addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
                        DMSecureOverlay = overlay;
                        NSLog(@"DroidMirror secure overlay attached to %@ (%@)",
                              NSStringFromClass(screen.class), NSStringFromRect(screen.bounds));
                        if (DMSecureBlack) {
                            DMDetectPINPrompt(self, NSSelectorFromString(@"detectPINPrompt"));
                            DroidMirrorSetSecureScreen(1);
                        }
                    }
                }
            });
            DMWindowCloseObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:NSWindowWillCloseNotification
                            object:mirrorWindow
                             queue:nil
                        usingBlock:^(__unused NSNotification *notification) {
                DMRequestHostQuit();
            }];
        }
    }

    NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp;
    DMKeyboardMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                                              handler:^NSEvent *(NSEvent *event) {
        if (DMPINSyntheticEventsRemaining > 0) {
            DMPINSyntheticEventsRemaining -= 1;
            return event;
        }

        BOOL isQuitEvent = DMEventIsQ(event) &&
            (((event.modifierFlags & NSEventModifierFlagCommand) != 0) || DMCommandQuitActive);

        if (!isQuitEvent) {
            NSInteger pinTag = DMPINButtonTagForEvent(event);
            BOOL hasCommandModifier = (event.modifierFlags &
                (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) != 0;
            if (pinTag != NSIntegerMin && !hasCommandModifier && DMPINPopoverIsVisible(self)) {
                if (event.type == NSEventTypeKeyDown && !event.isARepeat) {
                    DMForwardPINKey(self, pinTag);
                }
                return nil;
            }
            return event;
        }

        if (event.type == NSEventTypeKeyDown) {
            DMCommandQuitActive = YES;
            if (!event.isARepeat) {
                DMRequestHostQuit();
            }
        } else if (event.type == NSEventTypeKeyUp) {
            DMCommandQuitActive = NO;
        }

        return nil;
    }];
}

static void DMInstallKeyboardPassthrough(void) {
    Class controllerClass = NSClassFromString(@"DMWindowController");
    SEL selector = NSSelectorFromString(@"setupKeyboardRemapping");
    Method method = class_getInstanceMethod(controllerClass, selector);
    if (controllerClass == Nil || method == NULL) {
        return;
    }
    DMInstallScrollDirection(controllerClass);

    class_replaceMethod(controllerClass,
                        selector,
                        (IMP)DMSetupKeyboardPassthrough,
                        method_getTypeEncoding(method));
    SEL position = NSSelectorFromString(@"positionToolbar");
    Method positionMethod = class_getInstanceMethod(controllerClass, position);
    if (positionMethod) {
        DMOriginalPositionToolbar = (void *)method_getImplementation(positionMethod);
        class_replaceMethod(controllerClass, position, (IMP)DMPositionToolbarWithDeviceCorners,
                            method_getTypeEncoding(positionMethod));
    }
    SEL detectPIN = NSSelectorFromString(@"detectPINPrompt");
    Method detectMethod = class_getInstanceMethod(controllerClass, detectPIN);
    if (detectMethod) {
        DMOriginalDetectPINPrompt = (void *)method_getImplementation(detectMethod);
        class_replaceMethod(controllerClass, detectPIN, (IMP)DMDetectPINPrompt,
                            method_getTypeEncoding(detectMethod));
    }
}

__attribute__((constructor))
static void DMLoadOriginalAndInstall(void) {
    Dl_info imageInfo;
    if (dladdr((const void *)&DMLoadOriginalAndInstall, &imageInfo) == 0 || imageInfo.dli_fname == NULL) {
        return;
    }

    NSString *shimPath = [NSString stringWithUTF8String:imageInfo.dli_fname];
    NSString *originalPath = [[shimPath stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"libDroidMirrorStyleOriginal.dylib"];

    void *handle = dlopen(originalPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (handle == NULL) {
        return;
    }

    DMInstallKeyboardPassthrough();
}

// The wrapper normally owns scrcpy, but closing scrcpy's window can bypass the
// wrapper's quit path. Notify the host while Cocoa is still available, and keep
// the process-exit fallback for ordinary SDL shutdowns.
__attribute__((constructor))
static void DMObserveScrcpyTermination(void) {
    Method sendEvent = class_getInstanceMethod(NSApplication.class, @selector(sendEvent:));
    DMOriginalSendEvent = (void *)method_getImplementation(sendEvent);
    method_setImplementation(sendEvent, (IMP)DMSendEvent);
    dispatch_async(dispatch_get_main_queue(), ^{
        DMMirrorQuit = [DMMirrorQuitTarget new];
        DMEnsureMirrorQuitMenu(NSApp, DMMirrorQuit);
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) {
            DMEnsureMirrorQuitMenu(NSApp, DMMirrorQuit);
        }];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSApplicationWillTerminateNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *notification) {
            DMRequestHostQuit();
        }];
    });
}

__attribute__((destructor))
static void DMNotifyHostWhenScrcpyExits(void) {
    DMRequestHostQuit();
}
