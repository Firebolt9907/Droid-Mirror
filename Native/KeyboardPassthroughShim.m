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
#import "ConnectingPhone.h"
#import "SyntheticText.h"

static id DMKeyboardMonitor;
static id DMWindowCloseObserver;
static BOOL DMCommandQuitActive;
static BOOL DMEmojiShortcutActive;
static BOOL DMSyntheticTextKeyActive;
static BOOL DMPasteKeyActive;
static BOOL DMHostQuitRequested;
static NSUInteger DMPINSyntheticEventsRemaining;
static void (*DMOriginalSendEvent)(NSApplication *, SEL, NSEvent *);
static NSView *DMSecureOverlay;
static NSUInteger DMSecureGeneration;
static NSUInteger DMSecureRefreshGeneration;
static BOOL DMSecureWindow;
static BOOL DMSecureSessionStopped;
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
static id DMMinimizeObserver;

static void DMReportMirrorVisible(void) {
    // The toolbar/controller attaches after the loading overlay is removed.
    // First-frame readiness must use the persistent phone window even while
    // that controller has not been created yet.
    NSWindow *window = DMMirrorWindow ?: DMConnectingPhoneWindow();
    if (!DMFrameRendered || !window.visible || window.miniaturized) return;
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"app.droidmirror.mirrorVisible"
        object:NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"] userInfo:nil deliverImmediately:YES];
}
__attribute__((visibility("default")))
void DroidMirrorFrameVisible(void) {
    void (^present)(void) = ^{ DMSecureSessionStopped = NO; DMFinishConnectingPhone(); DMFrameRendered = YES; DMReportMirrorVisible(); };
    // SDL presents on the main thread. Reorder the loading overlay in the same
    // turn, before Core Animation can expose the new Metal view for a frame.
    if (NSThread.isMainThread) present();
    else dispatch_async(dispatch_get_main_queue(), present);
}
__attribute__((visibility("default")))
void DroidMirrorFrameVisibleWithoutAnimation(void) {
    void (^present)(void) = ^{ DMSecureSessionStopped = NO; DMFinishConnectingPhoneWithoutAnimation(); DMFrameRendered = YES; DMReportMirrorVisible(); };
    if ([NSThread isMainThread]) present(); else dispatch_async(dispatch_get_main_queue(), present);
}


__attribute__((visibility("default")))
void DroidMirrorSessionDidStop(void) {
    DMFrameRendered = NO;
    DMSecureSessionStopped = YES;
    ++DMSecureGeneration;
    ++DMSecureRefreshGeneration;
    DMSecureWindow = NO;
    DMSecureOverlay.hidden = YES;
    DMPINSyntheticEventsRemaining = 0;
}

static void DMDetectPINPrompt(id controller, SEL selector) {
    // Secure windows can belong to unrelated apps; let the original
    // PIN-specific hierarchy check confirm the lock screen.
    if (!DMSecureWindow || DMHostQuitRequested || !DMOriginalDetectPINPrompt) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - DMLastPINCheck < 1.25) return; // Coalesce state and timer triggers.
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

// WindowManager state arrives over the existing authenticated control channel.
// Unknown queries clear the message; black video frames never enter this path.
__attribute__((visibility("default")))
void DroidMirrorSetSecureScreen(int secure) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (DMSecureSessionStopped || DMHostQuitRequested) return;
        NSUInteger refresh = ++DMSecureRefreshGeneration;
        if (secure) {
            // Clear stale UI if monitoring or control delivery stops without a disconnect.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (refresh != DMSecureRefreshGeneration) return;
                ++DMSecureGeneration;
                DMSecureWindow = NO;
                DMSecureOverlay.hidden = YES;
            });
        }
        if ((secure != 0) == DMSecureWindow) return;
        DMSecureWindow = secure != 0;
        NSUInteger generation = ++DMSecureGeneration;
        if (!secure) {
            DMSecureOverlay.hidden = YES;
            return;
        }
        if (DMSecureController) {
            DMLastPINCheck = 0;
            DMDetectPINPrompt(DMSecureController, NSSelectorFromString(@"detectPINPrompt"));
        }
        // Debounce window transitions independently of video frame contents.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (generation != DMSecureGeneration || DMHostQuitRequested) return;
            // A confirmed protected page is usable without exposing black
            // video or waiting for startup content that Android cannot send.
            DMFinishConnectingPhoneWithoutAnimation();
            DMFrameRendered = YES;
            DMReportMirrorVisible();
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

// The owning host reads diagnostics before deciding whether to quit or show
// an alert. Cleanup/destructors must not turn a startup failure into Quit.
// Explicit Quit still goes through DMRequestHostQuit above.
static BOOL DMHostOwnsMirrorExit(void) {
    return NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"].length > 0;
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
    // Snippet tools can put Command on V without posting a separate modifier
    // event. SDL's physical modifier state then loses Command, producing "v".
    // Read the original Cocoa flags and send clipboard+paste as one operation.
    if (event.type == NSEventTypeKeyUp && event.keyCode == kVK_ANSI_V && DMPasteKeyActive) {
        DMPasteKeyActive = NO;
        return;
    }
    BOOL mirrorInput = DMMirrorWindow.isKeyWindow && !DMSecureWindow &&
        ![DMMirrorWindow.firstResponder isKindOfClass:NSTextView.class];
    if (mirrorInput && DMPasteShortcutEvent(event)) {
        if (!event.isARepeat) {
            NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
            if (!text || !DMQueueSyntheticText(text)) {
                NSLog(@"DroidMirror: could not queue clipboard paste");
            }
        }
        DMPasteKeyActive = YES;
        return;
    }
    // Intercept before SDL emits both the dummy physical A and text events.
    // Pair the release as well, without disturbing a real hardware A press.
    if (event.type == NSEventTypeKeyUp && event.keyCode == kVK_ANSI_A && DMSyntheticTextKeyActive) {
        DMSyntheticTextKeyActive = NO;
        return;
    }
    if (mirrorInput && DMSyntheticTextEvent(event)) {
        if (DMQueueSyntheticText(event.characters)) {
            DMSyntheticTextKeyActive = YES;
            return;
        }
    }
    // setupKeyboardRemapping is replaced below, so media keys must enter here,
    // before either SDL or AppKit handles the system-defined event.
    if (event.type == NSEventTypeSystemDefined && !DMHostQuitRequested) {
        id controller = DMSecureController;
        SEL volume = NSSelectorFromString(@"handleVolumeEvent:focused:");
        if ([controller respondsToSelector:volume] &&
            !((NSEvent *(*)(id, SEL, NSEvent *, BOOL))objc_msgSend)(
                controller, volume, event, app.isActive)) return;
    }
    if ((event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) &&
            event.keyCode == 49 &&
            (DMEmojiShortcutActive ||
             (event.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand)) ==
                (NSEventModifierFlagControl | NSEventModifierFlagCommand))) {
        DMEmojiShortcutActive = event.type == NSEventTypeKeyDown;
        if (DMEmojiShortcutActive && !event.isARepeat) [app orderFrontCharacterPalette:nil];
        return;
    }
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
            // The persistent phone already owns focus notifications before video
            // attaches. Keep this legacy route only for standalone viewers.
            BOOL persistentPhone = getenv("DROIDMIRROR_SESSION_COMMANDS") != NULL;
            if (!persistentPhone) DMFocusObserver = [[NSDistributedNotificationCenter defaultCenter]
                addObserverForName:@"app.droidmirror.focusMirror"
                object:NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"] queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
                    if (DMHostQuitRequested) return;
                    [mirrorWindow deminiaturize:nil];
                    [NSApp activateIgnoringOtherApps:YES];
                    [mirrorWindow makeKeyAndOrderFront:nil];
                    DMReportMirrorVisible();
                }];
            DMMinimizeObserver = [[NSDistributedNotificationCenter defaultCenter]
                addObserverForName:@"app.droidmirror.minimizeMirror"
                object:NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"] queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
                    if (DMHostQuitRequested || mirrorWindow.miniaturized) return;
                    NSLog(@"DroidMirror minimize: received by mirror window (style=%lu)", mirrorWindow.styleMask);
                    [mirrorWindow miniaturize:nil];
                }];
            // Run after the styling controller finishes attaching its toolbar,
            // so the stream, rather than its child toolbar, receives focus.
            dispatch_async(dispatch_get_main_queue(), ^{
                if (DMHostQuitRequested) return;
                // Attaching video to an existing phone is a content update,
                // not a new foreground application or focus request.
                if (!persistentPhone) {
                    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
                    [NSApp activateIgnoringOtherApps:YES];
                    [mirrorWindow makeKeyAndOrderFront:nil];
                }
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
                        if (DMSecureWindow) {
                            DMSecureWindow = NO; // Reapply state to the newly attached view.
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
                if (!DMHostOwnsMirrorExit()) DMRequestHostQuit();
            }];
        }
    }

    NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp;
    DMKeyboardMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                                              handler:^NSEvent *(NSEvent *event) {
        for (NSView *view in DMMirrorWindow.contentView.subviews)
            if ([view.identifier isEqualToString:@"DroidMirrorConnecting"]) return event;
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

static BOOL DMRendererShutdownRequested(void) {
    NSString *command = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_SESSION_COMMANDS"];
    if (!command.length) return NO;
    return [NSFileManager.defaultManager fileExistsAtPath:
        [[command stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"shutdown"]];
}

static void (*DMOriginalRendererTerminate)(NSApplication *, SEL, id);
static void DMRendererTerminate(NSApplication *app, SEL selector, id sender) {
    // Dock Quit must end the owning controller too. A host-requested shutdown
    // already has its cleanup in progress and must not send a second Quit.
    if (!DMRendererShutdownRequested()) DMRequestHostQuit();
    DMOriginalRendererTerminate(app, selector, sender);
}

// The wrapper normally owns scrcpy, but closing scrcpy's window can bypass the
// wrapper's quit path. Notify the host while Cocoa is still available, and keep
// the process-exit fallback for ordinary SDL shutdowns.
__attribute__((constructor))
static void DMObserveScrcpyTermination(void) {
    if (getenv("DROIDMIRROR_SESSION_COMMANDS")) {
        Method terminate = class_getInstanceMethod(NSApplication.class, @selector(terminate:));
        DMOriginalRendererTerminate = (void *)method_getImplementation(terminate);
        method_setImplementation(terminate, (IMP)DMRendererTerminate);
    }
    Method sendEvent = class_getInstanceMethod(NSApplication.class, @selector(sendEvent:));
    DMOriginalSendEvent = (void *)method_getImplementation(sendEvent);
    method_setImplementation(sendEvent, (IMP)DMSendEvent);
    dispatch_async(dispatch_get_main_queue(), ^{
        DMMirrorQuit = [DMMirrorQuitTarget new];
        DMEnsureMirrorQuitMenu(NSApp, DMMirrorQuit);
        DroidMirrorInstallSessionMenu();
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) {
            DMEnsureMirrorQuitMenu(NSApp, DMMirrorQuit);
            DroidMirrorInstallSessionMenu();
            // SDL may rebuild the main menu; keep the live video toggle reachable.
            if ([DMSecureController respondsToSelector:NSSelectorFromString(@"ensureVideoMenu")]) {
                ((void (*)(id, SEL))objc_msgSend)(DMSecureController, NSSelectorFromString(@"ensureVideoMenu"));
            }
        }];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSApplicationWillTerminateNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *notification) {
            if (!DMHostOwnsMirrorExit() || (getenv("DROIDMIRROR_SESSION_COMMANDS") && !DMRendererShutdownRequested()))
                DMRequestHostQuit();
        }];
    });
}

__attribute__((destructor))
static void DMNotifyHostWhenScrcpyExits(void) {
    if (!DMHostOwnsMirrorExit()) DMRequestHostQuit();
}
