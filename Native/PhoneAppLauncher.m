#import <AppKit/AppKit.h>

// Identical tiny executable in every generated app; destination lives in its plist.
int main(void) {
    @autoreleasepool {
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSURL *url = [NSURL URLWithString:info[@"DroidMirrorLaunchURL"] ?: @""];
        NSURL *host = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"app.droidmirror.mac"];
        if (!host) host = [NSURL fileURLWithPath:info[@"DroidMirrorHostPath"] ?: @""];
        NSURL *receiver = [host URLByAppendingPathComponent:@"Contents/Helpers/DroidMirror Notifications.app"];
        if (![url.scheme isEqual:@"droidmirror-app"] || ![NSFileManager.defaultManager fileExistsAtPath:receiver.path]) return 1;
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
