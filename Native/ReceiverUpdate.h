#import <AppKit/AppKit.h>

// LaunchServices retains the original bundle URL after an atomic app swap.
// A helper started before its installed executable was rebuilt is stale even
// when NSRunningApplication still reports the current installation path.
static BOOL DMReceiverNeedsRefresh(NSDate *launched, NSDate *modified, BOOL mirrorRunning) {
    return !mirrorRunning && launched && modified && [modified compare:launched] == NSOrderedDescending;
}

static void DMOpenReceiver(NSURL *receiver) {
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

static void DMWaitForReceiverExit(NSRunningApplication *running, NSURL *receiver, NSUInteger remaining) {
    if (running.terminated) { DMOpenReceiver(receiver); return; }
    if (remaining == 0) {
        NSLog(@"DroidMirror updated receiver is waiting for the previous helper to quit");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        DMWaitForReceiverExit(running, receiver, remaining - 1);
    });
}

static void DMEnsureReceiver(NSURL *receiver, BOOL mirrorRunning) {
    NSRunningApplication *running = [NSRunningApplication runningApplicationsWithBundleIdentifier:
        @"app.droidmirror.notifications"].firstObject;
    if (!running) { DMOpenReceiver(receiver); return; }
    NSURL *executable = [receiver URLByAppendingPathComponent:@"Contents/MacOS/DroidMirrorNotifications"];
    NSDate *modified = nil;
    [executable getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
    if (!DMReceiverNeedsRefresh(running.launchDate, modified, mirrorRunning)) return;
    NSLog(@"DroidMirror refreshing background receiver after an app update");
    // Normal AppKit termination only. Never kill a helper or replace it while
    // the host has a running renderer; the next idle launch can retry instead.
    if ([running terminate]) DMWaitForReceiverExit(running, receiver, 150);
}
