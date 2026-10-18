#import "ConnectingPhone.h"
#import "DeviceCorners.h"
#import "PhoneAppearance.h"
#import <CoreImage/CoreImage.h>
#import <SDL3/SDL.h>
#import <dlfcn.h>
#import <unistd.h>
#import <objc/runtime.h>

static NSView *DMLoadingSurface;
static SDL_Window *DMPhoneWindow;
static id DMConnectingFocusObserver;
static NSString *DMCurrentSession;
static NSDictionary *DMState;
static NSData *DMStateBytes;
static BOOL DMSessionRunning;
static BOOL DMStopRequested;

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


@interface DMConnectingPhoneView : NSView
@property(nonatomic, strong) NSImage *wallpaper;
- (void)reloadWallpaper;
@end
@implementation DMConnectingPhoneView
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

static void DMSetChrome(BOOL streaming) {
    void (*chrome)(NSWindow *, BOOL) = dlsym(RTLD_DEFAULT, "DroidMirrorSessionChrome");
    if (chrome) chrome(DMNativePhone(), streaming);
}

static void DMShowPhoneState(NSString *title, NSString *message, BOOL connecting) {
    NSWindow *window = DMNativePhone();
    if (!window) return;
    DMSetChrome(NO);
    [DMLoadingSurface removeFromSuperview];
    NSView *screen = window.contentView;
    DMConnectingPhoneView *overlay = [[DMConnectingPhoneView alloc] initWithFrame:screen.bounds];
    [overlay reloadWallpaper];
    overlay.identifier = @"DroidMirrorConnecting";
    overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    overlay.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSStackView *stack = [NSStackView new];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    if (connecting) {
        NSProgressIndicator *spinner = [NSProgressIndicator new];
        spinner.style = NSProgressIndicatorStyleSpinning;
        [spinner.widthAnchor constraintEqualToConstant:24].active = YES;
        [spinner.heightAnchor constraintEqualToConstant:24].active = YES;
        [stack addArrangedSubview:spinner]; [spinner startAnimation:nil];
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
    [screen addSubview:overlay]; DMLoadingSurface = overlay;
    window.movableByWindowBackground = YES;
    DMApplyDeviceCorners(screen);
    [window displayIfNeeded];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"app.droidmirror.presentationApplied"
        object:NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"]
        userInfo:@{@"title": title ?: @"", @"window": @(window.windowNumber), @"connecting": @(connecting), @"behavior": @(window.collectionBehavior), @"level": @(window.level)} deliverImmediately:YES];
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
    if (!DMConnectingFocusObserver) {
        DMConnectingFocusObserver = [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:@"app.droidmirror.focusMirror"
            object:NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"] queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) {
                [window deminiaturize:nil]; [NSApp activateIgnoringOtherApps:YES]; [window makeKeyAndOrderFront:nil];
            }];
    }
    [window makeKeyAndOrderFront:nil];
    DMHostCommand(@"app.droidmirror.connectingVisible");
}

void DMFinishConnectingPhone(void) {
    NSView *screen = DMLoadingSurface.superview;
    [DMLoadingSurface removeFromSuperview]; DMLoadingSurface = nil;
    screen.window.movableByWindowBackground = NO;
    DMApplyDeviceCorners(screen); DMSetChrome(YES);
}

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
