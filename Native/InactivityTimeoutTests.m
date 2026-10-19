#import "ScrcpyWindowStyle.m"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        NSString *hostPID = NSProcessInfo.processInfo.environment[@"DROIDMIRROR_HOST_PID"];
        assert(hostPID.length && !NSApp.active);
        NSDistributedNotificationCenter *center = NSDistributedNotificationCenter.defaultCenter;
        __block BOOL stopped = NO;
        __block BOOL quit = NO;
        id stopObserver = [center addObserverForName:@"app.droidmirror.inactivityTimeout"
            object:hostPID queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { stopped = YES; }];
        id quitObserver = [center addObserverForName:@"app.droidmirror.quit"
            object:hostPID queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { quit = YES; }];
        DMWindowController *controller = [DMWindowController new];
        [controller suspendForBackgroundTimeout];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while (!stopped && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        assert(stopped && !quit);
        [center removeObserver:stopObserver];
        [center removeObserver:quitObserver];
        puts("PASS: background timeout requests a mirror stop instead of quitting the app");
    }
}
