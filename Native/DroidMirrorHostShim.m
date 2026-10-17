#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <limits.h>

static void (*DMOriginalSetExecutableURL)(NSTask *, SEL, NSURL *);
static void (*DMOriginalReplyToTerminate)(NSApplication *, SEL, BOOL);
static BOOL DMQuitting;
static BOOL DMFinishingQuit;
static NSUInteger DMQuitGeneration;
static id DMQuitObserver;
static id DMRequestObserver;
static NSTask *DMMirrorTask;
static void (*DMStopBLE)(void);
static BOOL DMMirrorStarted;
static void (*DMRefreshBLEMenu)(void);
static void (*DMOriginalSetMainMenu)(NSApplication *, SEL, NSMenu *);
static void (*DMOriginalMenuUpdate)(NSMenu *, SEL);

static void DMPublishSessionState(void) {
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"app.droidmirror.sessionState"
        object:nil userInfo:@{@"pid": @(NSProcessInfo.processInfo.processIdentifier),
                             @"active": @(DMMirrorTask.running && !DMQuitting)} deliverImmediately:YES];
}

static void DMSetMainMenu(NSApplication *app, SEL selector, NSMenu *menu) {
    DMOriginalSetMainMenu(app, selector, menu);
    if (!DMQuitting && DMRefreshBLEMenu) DMRefreshBLEMenu();
}

static void DMMenuUpdate(NSMenu *menu, SEL selector) {
    DMOriginalMenuUpdate(menu, selector);
    // Repair after SwiftUI's validation/reconstruction, before presentation.
    if (!DMQuitting && DMRefreshBLEMenu) DMRefreshBLEMenu();
}

// Call the retained host's exported Swift methods with the compiler's Swift
// calling convention. No guessed object offsets or accessibility access.
__attribute__((visibility("default")))
void DroidMirrorRequestMirror(void) {
    if (DMQuitting) return;
    typedef void **(*SharedAddress)(void) __attribute__((swiftcall));
    typedef void (*Refresh)(BOOL, void * __attribute__((swift_context))) __attribute__((swiftcall));
    typedef void (*Start)(void * __attribute__((swift_context))) __attribute__((swiftcall));
    SharedAddress shared = (SharedAddress)dlsym(RTLD_DEFAULT, "$s11DroidMirror0B5ModelC6sharedACvau");
    Refresh refresh = (Refresh)dlsym(RTLD_DEFAULT, "$s11DroidMirror0B5ModelC14refreshDevices8silentlyySb_tF");
    Start start = (Start)dlsym(RTLD_DEFAULT, "$s11DroidMirror0B5ModelC5startyyF");
    if (!shared || !refresh || !start) return;
    void **address = shared();
    if (address && *address) { refresh(YES, *address); start(*address); }
}

static void DMFinishQuit(NSApplication *app) {
    if (DMFinishingQuit) return;
    DMFinishingQuit = YES;
    if (DMMirrorTask.running) [DMMirrorTask terminate];
    DMPublishSessionState();
    // The delegate has already finished cleanup (or reached its bounded deadline).
    // Re-entering AppKit termination can itself wait again. Notify observers and
    // exit normally so atexit handlers run and macOS removes the app immediately.
    [[NSNotificationCenter defaultCenter] postNotificationName:NSApplicationWillTerminateNotification
                                                       object:app];
    exit(EXIT_SUCCESS);
}

static void DMReplyToTerminate(NSApplication *app, SEL selector, BOOL shouldTerminate) {
    if (!DMQuitting) {
        DMOriginalReplyToTerminate(app, selector, shouldTerminate);
        return;
    }
    if (shouldTerminate) DMFinishQuit(app);
    else DMQuitting = NO;
}

static void DMBeginQuit(NSApplication *app, SEL selector, id sender) {
    if (DMQuitting) return;
    DMQuitting = YES;
    NSUInteger generation = ++DMQuitGeneration;
    if (DMStopBLE) DMStopBLE();
    // Start the existing rotation/AOD/lock cleanup while keeping the normal
    // main run loop alive. AppKit's NSTerminateLater termination loop can starve
    // the Swift main-queue continuations needed to finish that cleanup.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (!DMQuitting || generation != DMQuitGeneration) return;
        DMFinishQuit(app);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (!DMQuitting || generation != DMQuitGeneration) return;
        if (DMMirrorTask.running) [DMMirrorTask terminate];
        // Independent fallback if an unreachable phone stalls the main queue.
        exit(EXIT_SUCCESS);
    });

    id delegate = app.delegate;
    SEL shouldTerminate = @selector(applicationShouldTerminate:);
    if (![delegate respondsToSelector:shouldTerminate]) {
        DMFinishQuit(app);
        return;
    }
    Method method = class_getInstanceMethod([delegate class], shouldTerminate);
    NSApplicationTerminateReply (*requestCleanup)(id, SEL, NSApplication *) =
        (void *)method_getImplementation(method);
    NSApplicationTerminateReply reply = requestCleanup(delegate, shouldTerminate, app);
    if (reply == NSTerminateNow) DMFinishQuit(app);
    else if (reply == NSTerminateCancel) {
        // Respect delegate cancellation. Scheduled deadlines must not force exit.
        DMQuitting = NO;
    }
}

@interface DMHostQuitTarget : NSObject
- (void)quit:(id)sender;
@end
@implementation DMHostQuitTarget
- (void)quit:(id)sender { [NSApp terminate:sender]; }
@end
static DMHostQuitTarget *DMQuitTarget;

static void DMFixQuitMenu(NSMenu *menu) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == @selector(terminate:) ||
            [item.keyEquivalent.lowercaseString isEqualToString:@"q"]) {
            item.target = DMQuitTarget;
            item.action = @selector(quit:);
            item.keyEquivalent = @"q";
            item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
            item.enabled = YES;
        }
        if (item.submenu) DMFixQuitMenu(item.submenu);
    }
}

static void DMSetExecutableURL(NSTask *task, SEL selector, NSURL *url) {
    if ([url.lastPathComponent isEqualToString:@"DroidMirrorRenderer"]) {
        DMMirrorTask = task;
    }
    if ([url.lastPathComponent isEqualToString:@"scrcpy"]) {
        NSURL *bundledClient = [[NSBundle.mainBundle.bundleURL
            URLByAppendingPathComponent:@"Contents/Helpers"]
            URLByAppendingPathComponent:@"scrcpy"];

        if ([[NSFileManager defaultManager] isExecutableFileAtPath:bundledClient.path]) {
            url = bundledClient;
        }
        DMMirrorTask = task;
    }

    DMOriginalSetExecutableURL(task, selector, url);
}

__attribute__((constructor))
static void DMInstallBundledScrcpyResolver(void) {
    // The launcher injects this image into the host. Child processes may inherit
    // that environment; never install application hooks in Bluetooth/ADB/helpers.
    char executable[PATH_MAX]; uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0 ||
        ![[[NSString stringWithUTF8String:executable] lastPathComponent] isEqualToString:@"DroidMirrorHost"] ||
        ![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"app.droidmirror.mac"]) return;
    // The image is already loaded. Do not inject it into any future subprocess.
    unsetenv("DYLD_INSERT_LIBRARIES");
    Method method = class_getInstanceMethod(NSTask.class, @selector(setExecutableURL:));
    if (method == NULL) {
        return;
    }

    DMOriginalSetExecutableURL = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)DMSetExecutableURL);
    Method terminate = class_getInstanceMethod(NSApplication.class, @selector(terminate:));
    method_setImplementation(terminate, (IMP)DMBeginQuit);
    Method reply = class_getInstanceMethod(NSApplication.class, @selector(replyToApplicationShouldTerminate:));
    DMOriginalReplyToTerminate = (void *)method_getImplementation(reply);
    method_setImplementation(reply, (IMP)DMReplyToTerminate);
    Method setMainMenu = class_getInstanceMethod(NSApplication.class, @selector(setMainMenu:));
    DMOriginalSetMainMenu = (void *)method_getImplementation(setMainMenu);
    method_setImplementation(setMainMenu, (IMP)DMSetMainMenu);
    Method menuUpdate = class_getInstanceMethod(NSMenu.class, @selector(update));
    DMOriginalMenuUpdate = (void *)method_getImplementation(menuUpdate);
    method_setImplementation(menuUpdate, (IMP)DMMenuUpdate);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *receiver = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:
            @"Contents/Helpers/DroidMirror Notifications.app"];
        if ([NSRunningApplication runningApplicationsWithBundleIdentifier:@"app.droidmirror.notifications"].count == 0) {
            NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
            configuration.activates = NO;
            NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
            [environment removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
            [environment removeObjectForKey:@"DROIDMIRROR_HOST_PID"];
            configuration.environment = environment;
            [[NSWorkspace sharedWorkspace] openApplicationAtURL:receiver configuration:configuration
                completionHandler:^(NSRunningApplication *app, NSError *error) {
                    if (error) NSLog(@"DroidMirror receiver launch failed: %@", error.localizedDescription);
                }];
        }
        NSString *blePath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:
            @"Contents/Frameworks/libDroidMirrorBLE.dylib"];
        void *bleLibrary = dlopen(blePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (bleLibrary) {
            void (*startBLE)(void) = dlsym(bleLibrary, "DroidMirrorStartBLE");
            DMStopBLE = dlsym(bleLibrary, "DroidMirrorStopBLE");
            DMRefreshBLEMenu = dlsym(bleLibrary, "DroidMirrorRefreshBLEMenu");
            if (startBLE) startBLE();
        } else {
            NSLog(@"DroidMirror BLE could not load: %s", dlerror());
        }
        DMQuitTarget = [DMHostQuitTarget new];
        DMFixQuitMenu(NSApp.mainMenu);
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) {
            DMFixQuitMenu(NSApp.mainMenu);
            // The persistent renderer publishes whether a stream is active.
            if (!DMQuitting && !DMMirrorStarted && DMMirrorTask.running) {
                DMMirrorStarted = YES;
                [[NSNotificationCenter defaultCenter] postNotificationName:@"app.droidmirror.mirrorStarted"
                                                                   object:nil];
            }
        }];
        // The model handles stream completion after reading its diagnostics.
        // Exiting here races standalone phone-use and connection-failure alerts.
        DMQuitObserver = [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:@"app.droidmirror.quit" object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *notification) {
                if ([notification.object intValue] == NSProcessInfo.processInfo.processIdentifier)
                    [NSApp terminate:nil];
            }];
        DMRequestObserver = [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:@"app.droidmirror.requestMirror" object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *notification) { DroidMirrorRequestMirror(); }];
    });
}
