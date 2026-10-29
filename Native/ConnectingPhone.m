#import "ConnectingPhone.h"
#import "DeviceCorners.h"
#import "PhoneAppearance.h"
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <SDL3/SDL.h>
#import <dlfcn.h>
#import <unistd.h>
#import <objc/runtime.h>

static NSView *DMLoadingSurface;
static SDL_Window *DMPhoneWindow;
static id DMConnectingFocusObserver;
static id DMShortcutRevealObserver;
static NSString *DMShortcutToken;
static NSTimeInterval DMShortcutDeadline;
static BOOL DMShortcutWaiting, DMShortcutReleased, DMShortcutFrameReady;
static BOOL DMShortcutAnimate = YES;
static uint64_t DMShortcutFrames, DMShortcutReleaseFrame;
static int64_t DMShortcutMinimumPTS, DMShortcutLastPTS;

static NSString *DMCurrentSession;
static NSDictionary *DMState;
static NSData *DMStateBytes;
static BOOL DMSessionRunning;
static BOOL DMStopRequested;
static NSUInteger DMPresentationGeneration;
static const CFTimeInterval DMFirstFrameRevealDuration = 1.25;
static __weak CALayer *DMRevealVideoLayer;
static NSString *const DMRevealBlurName = @"DroidMirrorRevealBlur";

static void DMCancelVideoReveal(void) {
    CALayer *layer = DMRevealVideoLayer;
    [layer removeAnimationForKey:@"firstFrameZoom"];
    [layer removeAnimationForKey:@"firstFrameBlur"];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    NSMutableArray *filters = [layer.filters mutableCopy];
    for (CIFilter *filter in filters.copy)
        if ([filter.name isEqualToString:DMRevealBlurName]) [filters removeObject:filter];
    layer.filters = filters.count ? filters : nil;
    [CATransaction commit];
    DMRevealVideoLayer = nil;
}
// Core Animation stores CATransition under this reserved key even when callers
// supply another key. Use it for replacement and immediate video cancellation.
static NSString *const DMStatusTransitionKey = @"transition";

static void DMHostCommand(NSString *name) {
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:name
        object:NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"] userInfo:nil deliverImmediately:YES];
}

@interface DMPhoneActions : NSObject
- (void)connect:(id)sender;
- (void)settings:(id)sender;
- (void)setup:(id)sender;
- (void)cancel:(id)sender;
@end
@implementation DMPhoneActions
- (void)connect:(id)sender { DMHostCommand(@"app.droidmirror.requestMirror"); }
- (void)settings:(id)sender { DMHostCommand(@"app.droidmirror.showSettings"); }
- (void)setup:(id)sender { DMHostCommand(@"app.droidmirror.showOnboarding"); }
- (void)cancel:(id)sender { DMHostCommand(@"app.droidmirror.cancelMirror"); }
@end
static DMPhoneActions *DMActions;

void DroidMirrorInstallSessionMenu(void) {
    if (!DMActions) DMActions = [DMPhoneActions new];
    if (!NSApp.mainMenu.numberOfItems) return;
    NSMenu *menu = [NSApp.mainMenu itemAtIndex:0].submenu;
    NSMenuItem *settings = nil;
    for (NSMenuItem *item in menu.itemArray)
        if ([item.title hasPrefix:@"Settings"]) { settings = item; break; }
    if (!settings) {
        settings = [[NSMenuItem alloc] initWithTitle:@"Settings…" action:@selector(settings:) keyEquivalent:@","];
        [menu insertItem:settings atIndex:MIN(1, menu.numberOfItems)];
    }
    settings.target = DMActions;
    settings.action = @selector(settings:);
    settings.keyEquivalent = @",";
    settings.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    settings.enabled = YES;
    NSMenuItem *setup = [menu itemWithTag:0x444d5355];
    if (!setup) {
        setup = [[NSMenuItem alloc] initWithTitle:@"Set Up Phone…" action:@selector(setup:) keyEquivalent:@""];
        setup.tag = 0x444d5355;
        [menu insertItem:setup atIndex:MIN(2, menu.numberOfItems)];
    }
    setup.target = DMActions;
    setup.action = @selector(setup:);
    setup.enabled = YES;
}


// Keep status motion separate from the first-frame video reveal.
static BOOL DMPhoneMotionAllowed(NSWindow *window) {
    return window.visible && !window.miniaturized &&
        !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}

@interface DMConnectionActivityView : NSView
@property(nonatomic, strong) CAShapeLayer *ring;
@property(nonatomic, strong) CALayer *glow;
- (void)updateMotion;
@end
@implementation DMConnectionActivityView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.glow = [CALayer layer];
        self.glow.frame = CGRectMake(4, 4, 48, 48);
        self.glow.cornerRadius = 24;
        self.glow.backgroundColor = [NSColor colorWithWhite:1 alpha:0.08].CGColor;
        [self.layer addSublayer:self.glow];
        self.ring = [CAShapeLayer layer];
        self.ring.frame = CGRectMake(0, 0, 56, 56);
        CGPathRef path = CGPathCreateWithEllipseInRect(CGRectMake(2, 2, 52, 52), NULL);
        self.ring.path = path; CGPathRelease(path);
        self.ring.fillColor = nil;
        self.ring.strokeColor = [NSColor colorWithWhite:1 alpha:0.75].CGColor;
        self.ring.lineWidth = 1.5;
        self.ring.lineCap = kCALineCapRound;
        self.ring.strokeEnd = 0.23;
        [self.layer addSublayer:self.ring];
        NSImageView *phone = [NSImageView imageViewWithImage:
            [NSImage imageWithSystemSymbolName:@"iphone.gen3" accessibilityDescription:nil]];
        phone.frame = NSMakeRect(17, 14, 22, 28);
        phone.imageScaling = NSImageScaleProportionallyUpOrDown;
        phone.contentTintColor = NSColor.whiteColor;
        [self addSubview:phone];
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityProgressIndicatorRole;
        self.accessibilityLabel = @"Connecting to your phone";
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(updateMotion)
            name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    }
    return self;
}
- (void)dealloc { [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self]; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self updateMotion]; }
- (void)updateMotion {
    [self.ring removeAllAnimations];
    [self.glow removeAllAnimations];
    if (!DMPhoneMotionAllowed(self.window)) return;
    CABasicAnimation *orbit = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    // AppKit layers use an upward Y axis, so negative rotation is clockwise.
    orbit.fromValue = @0; orbit.toValue = @(-2 * M_PI);
    orbit.duration = 1.65; orbit.repeatCount = HUGE_VALF;
    [self.ring addAnimation:orbit forKey:@"connectionOrbit"];
    CABasicAnimation *breath = [CABasicAnimation animationWithKeyPath:@"opacity"];
    breath.fromValue = @0.35; breath.toValue = @1;
    breath.duration = 1.2; breath.autoreverses = YES; breath.repeatCount = HUGE_VALF;
    breath.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.glow addAnimation:breath forKey:@"connectionBreath"];
}
@end

@interface DMConnectingPhoneView : NSView
@property(nonatomic, strong) NSImage *wallpaper;
@property(nonatomic) BOOL revealingVideo;
- (void)reloadWallpaper;
@end
@implementation DMConnectingPhoneView
- (NSView *)hitTest:(NSPoint)point { return self.revealingVideo ? nil : [super hitTest:point]; }
- (void)reloadWallpaper {
    self.wallpaper = nil;
    id encoded = DMReadPhoneAppearance()[@"wallpaper"];
    NSData *data = [encoded isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:encoded options:0] : nil;
    CIImage *image = data ? [CIImage imageWithData:data] : nil;
    if (image && image.extent.size.width > 0 && image.extent.size.height > 0) {
        // The cached thumbnail is enlarged to fill the phone, magnifying this blur too.
        CIImage *blur = [[image imageByClampingToExtent] imageByApplyingFilter:@"CIGaussianBlur"
            withInputParameters:@{kCIInputRadiusKey:@0.75}];
        CGImageRef output = [[CIContext contextWithOptions:nil] createCGImage:blur fromRect:image.extent];
        if (output) { self.wallpaper = [[NSImage alloc] initWithCGImage:output size:NSZeroSize]; CGImageRelease(output); }
    }
    self.needsDisplay = YES;
}
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)rect {
    [[NSColor colorWithWhite:0.06 alpha:1] setFill]; NSRectFill(rect);
    if (self.wallpaper) {
        NSSize size = self.wallpaper.size;
        CGFloat scale = MAX(self.bounds.size.width / size.width, self.bounds.size.height / size.height);
        NSRect target = NSMakeRect(NSMidX(self.bounds) - size.width * scale / 2,
            NSMidY(self.bounds) - size.height * scale / 2, size.width * scale, size.height * scale);
        [self.wallpaper drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        [[NSColor colorWithWhite:0 alpha:0.58] setFill]; NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
    }
}
- (void)layout { [super layout]; DMApplyDeviceCorners(self.superview); }
@end

static NSWindow *DMNativePhone(void) {
    if (!DMPhoneWindow) return nil;
    return (__bridge NSWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(DMPhoneWindow),
        SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
}

NSWindow *DMConnectingPhoneWindow(void) { return DMNativePhone(); }

static void DMSetChrome(BOOL streaming) {
    void (*chrome)(NSWindow *, BOOL) = dlsym(RTLD_DEFAULT, "DroidMirrorSessionChrome");
    if (chrome) chrome(DMNativePhone(), streaming);
}

static void DMShowPhoneState(NSString *title, NSString *message, BOOL connecting) {
    NSWindow *window = DMNativePhone();
    if (!window) return;
    DMSetChrome(NO);
    NSView *screen = window.contentView;
    // Keep wallpaper geometry stable while status controls settle into view.
    ++DMPresentationGeneration;
    DMCancelVideoReveal();
    BOOL replacingStatus = DMLoadingSurface.superview == screen;
    DMConnectingPhoneView *overlay = replacingStatus ? (DMConnectingPhoneView *)DMLoadingSurface
        : [[DMConnectingPhoneView alloc] initWithFrame:screen.bounds];
    overlay.wantsLayer = YES;
    [overlay.layer removeAllAnimations];
    overlay.revealingVideo = NO;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    overlay.layer.opacity = 1;
    [CATransaction commit];
    // Capture the old layer content before replacing its controls. A single
    // keyed transition cannot queue stale content or delayed completion work.
    if (replacingStatus && DMPhoneMotionAllowed(window)) {
        CATransition *transition = [CATransition animation];
        transition.type = kCATransitionFade;
        transition.duration = 0.24;
        transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [overlay.layer addAnimation:transition forKey:DMStatusTransitionKey];
    }
    for (NSView *view in overlay.subviews.copy) [view removeFromSuperview];
    [overlay reloadWallpaper];
    overlay.identifier = @"DroidMirrorConnecting";
    overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    overlay.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSStackView *stack = [NSStackView new];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    if (connecting) {
        DMConnectionActivityView *activity = [[DMConnectionActivityView alloc] initWithFrame:NSMakeRect(0, 0, 56, 56)];
        [activity.widthAnchor constraintEqualToConstant:56].active = YES;
        [activity.heightAnchor constraintEqualToConstant:56].active = YES;
        [stack addArrangedSubview:activity];
    } else {
        NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:
            [title containsString:@"use"] ? @"iphone.gen3" : @"iphone.gen3.radiowaves.left.and.right"
            accessibilityDescription:nil]];
        icon.contentTintColor = NSColor.secondaryLabelColor;
        icon.imageScaling = NSImageScaleProportionallyUpOrDown;
        [icon.widthAnchor constraintEqualToConstant:42].active = YES;
        [icon.heightAnchor constraintEqualToConstant:48].active = YES;
        [stack addArrangedSubview:icon];
    }
    if (connecting) {
        id cachedName = DMReadPhoneAppearance()[@"deviceName"];
        NSString *name = [cachedName isKindOfClass:NSString.class] ? cachedName : NSProcessInfo.processInfo.environment[@"DROIDMIRROR_DEVICE_NAME"];
        if (name.length) title = [NSString stringWithFormat:@"Connecting to %@…", name];
    }
    NSTextField *heading = [NSTextField wrappingLabelWithString:title ?: @"DroidMirror"];
    heading.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
    heading.alignment = NSTextAlignmentCenter;
    heading.textColor = NSColor.whiteColor;
    [stack addArrangedSubview:heading];
    NSTextField *body = [NSTextField wrappingLabelWithString:message ?: @""];
    body.font = [NSFont systemFontOfSize:13]; body.textColor = NSColor.secondaryLabelColor;
    body.alignment = NSTextAlignmentCenter; body.maximumNumberOfLines = 10;
    [stack addArrangedSubview:body];
    [heading.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [body.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    if (!DMActions) DMActions = [DMPhoneActions new];
    NSButton *primary = [NSButton buttonWithTitle:connecting ? @"Cancel" : ([title isEqualToString:@"Ready to connect"] ? @"Connect" : ([title isEqualToString:@"Stopped due to inactivity"] ? @"Reconnect" : @"Connect Again"))
        target:DMActions action:connecting ? @selector(cancel:) : @selector(connect:)];
    primary.bezelStyle = NSBezelStyleRounded;
    [stack addArrangedSubview:primary];
    if (!connecting) {
        NSButton *settings = [NSButton buttonWithTitle:@"Settings…" target:DMActions action:@selector(settings:)];
        settings.bezelStyle = NSBezelStyleInline;
        [stack addArrangedSubview:settings];
    }
    [overlay addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [stack.widthAnchor constraintEqualToAnchor:overlay.widthAnchor constant:-72]
    ]];
    if (!replacingStatus) {
        [DMLoadingSurface removeFromSuperview];
        [screen addSubview:overlay]; DMLoadingSurface = overlay;
    }
    // SDL may have inserted a Metal view since this status was first installed.
    [screen addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
    [overlay layoutSubtreeIfNeeded];
    if (DMPhoneMotionAllowed(window)) {
        if (!replacingStatus) {
            // Returning from video to an error/status page uses the same gentle
            // crossfade as connecting, rather than abruptly covering the frame.
            CABasicAnimation *background = [CABasicAnimation animationWithKeyPath:@"opacity"];
            background.fromValue = @0; background.toValue = @1; background.duration = 0.24;
            [overlay.layer addAnimation:background forKey:@"statusBackgroundEntrance"];
        }
        stack.wantsLayer = YES;
        CABasicAnimation *settle = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        settle.fromValue = @(-10); settle.toValue = @0;
        settle.duration = 0.36;
        settle.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.16 :1 :0.3 :1];
        [stack.layer addAnimation:settle forKey:@"statusEntrance"];
        CABasicAnimation *appear = [CABasicAnimation animationWithKeyPath:@"opacity"];
        appear.fromValue = @0; appear.toValue = @1; appear.duration = 0.24;
        [stack.layer addAnimation:appear forKey:@"statusOpacity"];
    }
    window.movableByWindowBackground = YES;
    DMApplyDeviceCorners(screen);
    [window displayIfNeeded];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"app.droidmirror.presentationApplied"
        object:NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"]
        userInfo:@{@"title": title ?: @"", @"window": @(window.windowNumber), @"connecting": @(connecting), @"behavior": @(window.collectionBehavior), @"level": @(window.level)} deliverImmediately:YES];
}

// Presentation capability only: the receiver still authorizes app commands over BLE.
static NSDictionary *DMShortcutRevealState(void) {
    NSString *testPath = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_REVEAL_STATE"];
    if (testPath.length) {
        NSData *data = [NSData dataWithContentsOfFile:testPath];
        return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    }
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"app.droidmirror.mac"];
    [defaults synchronize];
    return [defaults dictionaryForKey:@"DroidMirror.shortcutReveal"];
}

void DMPrepareShortcutReveal(void) {
    NSDictionary *state = DMShortcutRevealState();
    if (![state isKindOfClass:NSDictionary.class]) return;
    NSString *token = [state[@"token"] isKindOfClass:NSString.class] ? state[@"token"] : nil;
    NSTimeInterval expires = [state[@"expires"] doubleValue];
    if (!token.length || token.length > 64 || expires <= NSDate.timeIntervalSinceReferenceDate) return;
    NSWindow *window = DMNativePhone();
    // Do not cover or animate a mirror the user can already see.
    if (!DMLoadingSurface && window.visible && !window.miniaturized) return;
    if ([(DMConnectingPhoneView *)DMLoadingSurface revealingVideo]) return;
    BOOL hiddenVideo = !DMLoadingSurface;
    if (hiddenVideo) DMShowPhoneState(@"Opening app…", @"", YES);
    if (![DMShortcutToken isEqual:token]) {
        DMShortcutToken = token; DMShortcutDeadline = MIN(expires, NSDate.timeIntervalSinceReferenceDate + 60);
        DMShortcutWaiting = YES; DMShortcutReleased = NO; DMShortcutMinimumPTS = 0; DMShortcutFrameReady = hiddenVideo;
        DMShortcutAnimate = YES;
        NSString *generation = token;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, DMShortcutDeadline - NSDate.timeIntervalSinceReferenceDate) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (![DMShortcutToken isEqual:generation] || !DMShortcutWaiting) return;
            DMShortcutWaiting = NO;
            if (DMShortcutFrameReady) DMFinishConnectingPhone();
        });
    }
    if ([state[@"ready"] boolValue] && !DMShortcutReleased) {
        DMShortcutReleased = YES; DMShortcutReleaseFrame = DMShortcutFrames;
        if ([state[@"displayedAtUs"] isKindOfClass:NSNumber.class]) DMShortcutMinimumPTS = MAX(0, [state[@"displayedAtUs"] longLongValue]);
        NSString *generation = token;
        // Static screens may not produce another decoded frame. Never leave the
        // cover stuck; Android's -W acknowledgment already confirms app display.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (![DMShortcutToken isEqual:generation] || !DMShortcutWaiting || !DMShortcutFrameReady) return;
            if (DMShortcutMinimumPTS && DMShortcutLastPTS < DMShortcutMinimumPTS) return;
            DMShortcutWaiting = NO;
            if (DMShortcutAnimate) DMFinishConnectingPhone(); else DMFinishConnectingPhoneWithoutAnimation();
        });
    }
}

void DMShortcutRevealFramePresented(int64_t pts) {
    ++DMShortcutFrames; DMShortcutLastPTS = pts;
    if (!DMShortcutWaiting || !DMShortcutReleased || !DMShortcutFrameReady || DMShortcutFrames <= DMShortcutReleaseFrame ||
        (DMShortcutMinimumPTS && pts < DMShortcutMinimumPTS)) return;
    DMShortcutWaiting = NO;
    if (DMShortcutAnimate) DMFinishConnectingPhone(); else DMFinishConnectingPhoneWithoutAnimation();
}

__attribute__((visibility("default")))
void DroidMirrorShowConnecting(SDL_Window *sdlWindow) {
    DMPhoneWindow = sdlWindow;
    NSWindow *window = DMNativePhone();
    if (!window) return;
    window.styleMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
    // A borderless phone is still a primary viewer, not a global utility panel.
    window.collectionBehavior = NSWindowCollectionBehaviorPrimary | NSWindowCollectionBehaviorManaged |
        NSWindowCollectionBehaviorParticipatesInCycle | NSWindowCollectionBehaviorFullScreenPrimary;
    window.opaque = NO; window.backgroundColor = NSColor.clearColor;
    window.minSize = NSMakeSize(310, 520);
    window.level = [NSProcessInfo.processInfo.environment[@"DROIDMIRROR_ALWAYS_ON_TOP"] isEqualToString:@"1"]
        ? NSFloatingWindowLevel : NSNormalWindowLevel;
    NSRect frame = window.frame, desktop = (window.screen ?: NSScreen.mainScreen).visibleFrame;
    if (frame.size.height > desktop.size.height - 96) {
        CGFloat scale = (desktop.size.height - 96) / frame.size.height;
        frame.size.width *= scale; frame.size.height *= scale;
        frame.origin = NSMakePoint(NSMidX(desktop) - frame.size.width / 2, NSMidY(desktop) - frame.size.height / 2);
        [window setFrame:frame display:NO];
    }
    DMShowPhoneState(@"Connecting…", @"Keep your phone locked and nearby.", YES);
    DMRefreshDeviceCornersFromPhone(window.contentView);
    if (!DMShortcutRevealObserver) {
        DMShortcutRevealObserver = [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:@"app.droidmirror.shortcutReveal" object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) {
                if (DMSessionRunning || !DMState || [DMState[@"connecting"] boolValue]) DMPrepareShortcutReveal();
            }];
    }
    DMPrepareShortcutReveal();
    if (!DMConnectingFocusObserver) {
        DMConnectingFocusObserver = [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:@"app.droidmirror.focusMirror"
            object:NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"] queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) {
                DMPrepareShortcutReveal();
                [window deminiaturize:nil]; [NSApp activateIgnoringOtherApps:YES]; [window makeKeyAndOrderFront:nil];
                // Each notification click waits for fresh readiness, including
                // when this persistent window already has a rendered stream.
                DroidMirrorReportMirrorVisible();
            }];
    }
    [window makeKeyAndOrderFront:nil];
    for (NSView *view in DMLoadingSurface.subviews.firstObject.subviews)
        if ([view isKindOfClass:DMConnectionActivityView.class]) [(DMConnectionActivityView *)view updateMotion];
    DMHostCommand(@"app.droidmirror.connectingVisible");
}

__attribute__((visibility("default")))
void DroidMirrorVideoSurfaceReady(void) {
    // SDL may insert/reinsert its Metal view while creating or presenting the
    // first drawable. Cover that empty drawable in the same main-thread turn.
    DMConnectingPhoneView *overlay = (DMConnectingPhoneView *)DMLoadingSurface;
    if (!overlay || !overlay.superview) return;
    NSView *screen = overlay.superview;
    // SDL can reinsert the Metal view during a drawable/size change, including
    // while the entrance is running. Preserve coverage for the whole reveal.
    CGFloat top = 0;
    for (NSView *view in screen.subviews)
        if (view != overlay) top = MAX(top, view.layer.zPosition);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    overlay.layer.zPosition = top + 1;
    [CATransaction commit];
    if (screen.subviews.lastObject != overlay)
        [screen addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
}

static void DMFinishConnectingPhoneWithMotion(BOOL animate) {
    DMConnectingPhoneView *overlay = (DMConnectingPhoneView *)DMLoadingSurface;
    if (!overlay || overlay.revealingVideo) return;
    if (DMShortcutWaiting) {
        DMShortcutFrameReady = YES; DMShortcutAnimate = animate;
        if (NSDate.timeIntervalSinceReferenceDate < DMShortcutDeadline &&
            (!DMShortcutReleased || DMShortcutFrames <= DMShortcutReleaseFrame ||
             (DMShortcutMinimumPTS && DMShortcutLastPTS < DMShortcutMinimumPTS))) return;
        DMShortcutWaiting = NO;
    }
    NSView *screen = overlay.superview;
    // SDL creates its Metal view after the loading page. Restore the overlay
    // above that opaque video view before fading it, or the reveal is invisible.
    DroidMirrorVideoSurfaceReady();
    screen.window.movableByWindowBackground = NO;
    DMApplyDeviceCorners(screen);
    [overlay.layer removeAllAnimations];
    // First-frame arrival enables interaction immediately. Reveal the running
    // video underneath a fading wallpaper, without snapshots or buffering frames.
    overlay.revealingVideo = YES;
    NSUInteger generation = ++DMPresentationGeneration;
    if (!animate || !DMPhoneMotionAllowed(screen.window)) {
        [overlay removeFromSuperview]; DMLoadingSurface = nil; DMSetChrome(YES);
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.layer.opacity = 0;
    [CATransaction commit];
    CAMediaTimingFunction *easing = [CAMediaTimingFunction functionWithControlPoints:0.25 :0.1 :0.25 :1];
    // Animate the real video layer, leaving the window's silhouette, border and
    // input geometry stable. The model transform remains unchanged throughout.
    for (NSView *view in screen.subviews) {
        if (![view.layer isKindOfClass:CAMetalLayer.class]) continue;
        CALayer *video = view.layer;
        DMRevealVideoLayer = video;
        CGFloat scale = 1.12;
        CGFloat centerX = (0.5 - video.anchorPoint.x) * video.bounds.size.width;
        CGFloat centerY = (0.5 - video.anchorPoint.y) * video.bounds.size.height;
        CATransform3D zoom = CATransform3DMakeScale(scale, scale, 1);
        zoom.m41 = (1 - scale) * centerX;
        zoom.m42 = (1 - scale) * centerY;
        CABasicAnimation *settle = [CABasicAnimation animationWithKeyPath:@"transform"];
        settle.fromValue = [NSValue valueWithCATransform3D:CATransform3DConcat(zoom, video.transform)];
        settle.toValue = [NSValue valueWithCATransform3D:video.transform];
        settle.duration = DMFirstFrameRevealDuration;
        settle.timingFunction = easing;
        [video addAnimation:settle forKey:@"firstFrameZoom"];

        CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
        blur.name = DMRevealBlurName;
        [blur setValue:@0 forKey:kCIInputRadiusKey];
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        video.filters = [(video.filters ?: @[]) arrayByAddingObject:blur];
        [CATransaction commit];
        CABasicAnimation *focus = [CABasicAnimation animationWithKeyPath:
            [NSString stringWithFormat:@"filters.%@.inputRadius", DMRevealBlurName]];
        focus.fromValue = @32; focus.toValue = @0;
        focus.duration = DMFirstFrameRevealDuration;
        focus.timingFunction = easing;
        [video addAnimation:focus forKey:@"firstFrameBlur"];
        break;
    }
    // The wallpaper clears slightly ahead of the focus/scale settling so the
    // blurred, enlarged picture is visible while it resolves into live video.
    CABasicAnimation *reveal = [CABasicAnimation animationWithKeyPath:@"opacity"];
    reveal.fromValue = @1; reveal.toValue = @0;
    reveal.duration = DMFirstFrameRevealDuration * 0.75;
    reveal.timingFunction = easing;
    [overlay.layer addAnimation:reveal forKey:@"firstFrameReveal"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DMFirstFrameRevealDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // A disconnect/retry may have reused this surface during the reveal.
        if (generation != DMPresentationGeneration || DMLoadingSurface != overlay) return;
        DMCancelVideoReveal();
        [overlay.layer removeAllAnimations];
        [overlay removeFromSuperview]; DMLoadingSurface = nil; DMSetChrome(YES);
    });
}

void DMFinishConnectingPhone(void) { DMFinishConnectingPhoneWithMotion(YES); }
void DMFinishConnectingPhoneWithoutAnimation(void) { DMFinishConnectingPhoneWithMotion(NO); }

static NSString *DMStopPath(void) {
    NSString *command = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_SESSION_COMMANDS"];
    return [[command stringByDeletingLastPathComponent] stringByAppendingPathComponent:
        [@"stop." stringByAppendingString:DMCurrentSession ?: @""]];
}

__attribute__((visibility("default")))
int DroidMirrorSessionCancelled(void) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:DMStopPath()]) {
        [[NSFileManager defaultManager] removeItemAtPath:DMStopPath() error:nil];
        DMStopRequested = YES;
        return 1;
    }
    return DMStopRequested;
}

__attribute__((visibility("default")))
void DroidMirrorPumpPresentation(void) {
    if (DMSessionRunning && !DMStopRequested && DroidMirrorSessionCancelled()) {
        SDL_Event event = {.type = SDL_EVENT_QUIT}; SDL_PushEvent(&event);
    }
    static NSTimeInterval checked;
    static NSData *appearanceBytes;
    static NSString *appearancePath;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - checked > 0.5) {
        checked = now;
        NSString *cache = DMPhoneAppearancePath();
        NSData *bytes = cache.length ? [NSData dataWithContentsOfFile:cache] : nil;
        if (!(cache == appearancePath || [cache isEqual:appearancePath])
            || !(bytes == appearanceBytes || [bytes isEqual:appearanceBytes])) {
            appearancePath = cache; appearanceBytes = bytes;
            DMLoadCachedDeviceCorners(DMNativePhone().contentView);
            if ([DMLoadingSurface isKindOfClass:DMConnectingPhoneView.class]) {
                if (DMState) DMShowPhoneState(DMState[@"title"], DMState[@"message"], [DMState[@"connecting"] boolValue]);
                else [(DMConnectingPhoneView *)DMLoadingSurface reloadWallpaper];
            }
        }
    }
    NSString *path = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_SESSION_STATE"];
    if (!path.length) return;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || [data isEqual:DMStateBytes]) return;
    NSDictionary *state = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![state isKindOfClass:NSDictionary.class]) return;
    DMStateBytes = data; DMState = state;
    if ([state[@"deviceName"] isKindOfClass:NSString.class])
        setenv("DROIDMIRROR_DEVICE_NAME", [state[@"deviceName"] UTF8String], 1);
    if ([state[@"appearanceCache"] isKindOfClass:NSString.class])
        setenv("DROIDMIRROR_APPEARANCE_CACHE", [state[@"appearanceCache"] UTF8String], 1);
    DMLoadCachedDeviceCorners(DMNativePhone().contentView);
    DMShowPhoneState(state[@"title"], state[@"message"], [state[@"connecting"] boolValue]);
}

__attribute__((visibility("default")))
SDL_Window *DroidMirrorPhoneWindow(void) { return DMPhoneWindow; }

static BOOL DMRendererReopen(id delegate, SEL command, NSApplication *app, BOOL visible) {
    NSWindow *window = DMNativePhone();
    [window deminiaturize:nil];
    [app activateIgnoringOtherApps:YES];
    [window makeKeyAndOrderFront:nil];
    return YES;
}

__attribute__((visibility("default")))
int DroidMirrorNextSession(int *argc, char ***argv) {
    if (!DMPhoneWindow) {
        [NSProcessInfo.processInfo setProcessName:@"DroidMirror"];
        SDL_SetHint(SDL_HINT_APP_NAME, "DroidMirror");
        SDL_SetHint(SDL_HINT_APP_ID, "app.droidmirror.mac");
        if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) return 0;
        DMPhoneWindow = SDL_CreateWindow("DroidMirror", 430, 955,
            SDL_WINDOW_BORDERLESS | SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
        if (!DMPhoneWindow) return 0;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        // The injected menu layer can create NSApp before SDL does. In that
        // case SDL skips its launch completion; finish it for Dock/AppleEvents.
        if (!NSRunningApplication.currentApplication.finishedLaunching) [NSApp finishLaunching];
        // The one public Dock tile belongs to this viewer. Reopen restores the
        // existing phone rather than launching a second controller or window.
        if (NSApp.delegate) class_replaceMethod([NSApp.delegate class],
            @selector(applicationShouldHandleReopen:hasVisibleWindows:), (IMP)DMRendererReopen, "B@:@B");
        [NSApp activateIgnoringOtherApps:YES];
        DroidMirrorShowConnecting(DMPhoneWindow);
        DMShowPhoneState(@"Ready to connect", @"Keep your phone locked and nearby.", NO);

    }
    NSString *path = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_SESSION_COMMANDS"];
    while (getppid() > 1) {
        @autoreleasepool {
            DroidMirrorPumpPresentation();
            SDL_Event event;
            while (SDL_PollEvent(&event)) {
                if (event.type == SDL_EVENT_QUIT) {
                    NSString *shutdown = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"shutdown"];
                    if (![NSFileManager.defaultManager fileExistsAtPath:shutdown]) DMHostCommand(@"app.droidmirror.quit");
                    return 0;
                }
            }
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (data) {
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([command[@"quit"] boolValue]) return 0;
                NSArray *args = command[@"arguments"];
                NSDictionary *environment = command[@"environment"];
                if ([args isKindOfClass:NSArray.class] && [environment isKindOfClass:NSDictionary.class]
                    && [command[@"session"] isKindOfClass:NSString.class]) {
                    DMCurrentSession = command[@"session"];
                    DMSessionRunning = YES;
                    DMStopRequested = NO;
                    for (NSString *key in @[@"ADB", @"DROIDMIRROR_SERIAL", @"DROIDMIRROR_START_GATE", @"DROIDMIRROR_TRANSPORT"])
                        unsetenv(key.UTF8String);
                    for (NSString *key in environment) {
                        if ([key hasPrefix:@"DROIDMIRROR_"] || [key isEqual:@"ADB"] || [key isEqual:@"PATH"] || [key isEqual:@"SCRCPY_SERVER_PATH"])
                            setenv(key.UTF8String, [environment[key] UTF8String], 1);
                    }
                    *argc = (int)args.count + 1;
                    *argv = calloc(*argc + 1, sizeof(char *));
                    (*argv)[0] = strdup("DroidMirror");
                    for (NSUInteger i=0; i<args.count; ++i) (*argv)[i+1] = strdup([args[i] UTF8String]);
                    DMRefreshDeviceCornersFromPhone(DMNativePhone().contentView);
                    DMShowPhoneState(@"Connecting…", @"Keep your phone locked and nearby.", YES);
                    return 1;
                }
            }
        }
        SDL_Delay(20);
    }
    return 0;
}

__attribute__((visibility("default")))
void DroidMirrorSessionFinished(int code) {
    DMSessionRunning = NO;
    DMStopRequested = NO;
    DMShortcutWaiting = NO; DMShortcutFrameReady = NO; DMShortcutReleased = NO; DMShortcutToken = nil;
    void (*stopped)(void) = dlsym(RTLD_DEFAULT, "DroidMirrorSessionDidStop");
    if (stopped) stopped();
    DMSetChrome(NO);
    // Present a neutral status immediately; the host supplies specific errors
    // after it has read bridge diagnostics and restored the phone's state.
    if (!DMState || [DMState[@"connecting"] boolValue])
        DMShowPhoneState(code == 0 ? @"Disconnected" : @"Connection ended",
            @"Connect again when you’re ready.", NO);
    else DMShowPhoneState(DMState[@"title"], DMState[@"message"], NO);
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"app.droidmirror.streamEnded"
        object:NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"]
        userInfo:@{@"session": DMCurrentSession ?: @"", @"code": @(code), @"window": @(DMNativePhone().windowNumber)}
        deliverImmediately:YES];
}
