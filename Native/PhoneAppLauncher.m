#import <AppKit/AppKit.h>

static NSString *const Receiver = @"Contents/Helpers/DroidMirror Notifications.app";

// Older copies share app.droidmirror.mac but predate droidmirror-app.
static BOOL HandlesLaunch(NSURL *host) {
    if (!host) return NO;
    NSBundle *receiver = [NSBundle bundleWithURL:[host URLByAppendingPathComponent:Receiver]];
    for (NSDictionary *type in receiver.infoDictionary[@"CFBundleURLTypes"])
        if ([type[@"CFBundleURLSchemes"] containsObject:@"droidmirror-app"]) return YES;
    return NO;
}

// Identical tiny executable in every generated app; destination lives in its plist.
int main(void) {
    @autoreleasepool {
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSURL *url = [NSURL URLWithString:info[@"DroidMirrorLaunchURL"] ?: @""];
        if (![url.scheme isEqual:@"droidmirror-app"]) return 1;
        // Prefer the host that wrote this shortcut over LaunchServices' pick.
        NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
        if ([info[@"DroidMirrorHostPath"] length]) [candidates addObject:[NSURL fileURLWithPath:info[@"DroidMirrorHostPath"]]];
        [candidates addObjectsFromArray:[NSWorkspace.sharedWorkspace URLsForApplicationsWithBundleIdentifier:@"app.droidmirror.mac"]];
        NSURL *host = nil;
        for (NSURL *candidate in candidates) if (HandlesLaunch(candidate)) { host = candidate; break; }
        if (!host) return 1;
        NSURL *receiver = [host URLByAppendingPathComponent:Receiver];
        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        configuration.activates = NO;
        __block BOOL done = NO;
        __block BOOL failed = NO;
        [NSWorkspace.sharedWorkspace openURLs:@[url] withApplicationAtURL:receiver configuration:configuration
            completionHandler:^(NSRunningApplication *app, NSError *error) { failed = error != nil; done = YES; }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        while (!done && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
        return done && !failed ? 0 : 1;
    }
}
