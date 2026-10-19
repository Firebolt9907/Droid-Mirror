#import <AppKit/AppKit.h>
#include <signal.h>
#include <errno.h>

// Build-time lifecycle tool: normal AppKit quit only, never kill a live mirror.
static NSArray<NSRunningApplication *> *DMApps(NSString *identifier) {
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier];
}
static BOOL DMHasExited(NSRunningApplication *app) {
    if (app.terminated) return YES;
    pid_t pid=app.processIdentifier;
    // NSRunningApplication can retain stale termination state in command-line
    // tools. Signal zero only probes existence; it never signals the process.
    return pid>0 && kill(pid,0)<0 && errno==ESRCH;
}
static BOOL DMStopApplications(NSArray<NSRunningApplication *> *apps, NSTimeInterval timeout) {
    for (NSRunningApplication *app in apps) if (!DMHasExited(app) && ![app terminate]) return NO;
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:timeout];
    while (YES) {
        BOOL running=NO;
        for (NSRunningApplication *app in apps) if (!DMHasExited(app)) running=YES;
        if (!running) return YES;
        if (deadline.timeIntervalSinceNow<=0) return NO;
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    }
}
static NSArray<NSURL *> *DMResumeTargets(NSDictionary *state, NSURL *app) {
    NSMutableArray *targets=[NSMutableArray array];
    if ([state[@"helper"] boolValue])
        [targets addObject:[app URLByAppendingPathComponent:@"Contents/Helpers/DroidMirror Notifications.app"]];
    if ([state[@"host"] boolValue]) [targets addObject:app];
    return targets;
}
static BOOL DMOpenApp(NSURL *url) {
    NSWorkspaceOpenConfiguration *configuration=NSWorkspaceOpenConfiguration.configuration;
    configuration.activates=NO;
    NSMutableDictionary *environment=[NSProcessInfo.processInfo.environment mutableCopy];
    [environment removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    [environment removeObjectForKey:@"DROIDMIRROR_HOST_PID"];
    configuration.environment=environment;
    __block BOOL finished=NO, success=NO;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:configuration
        completionHandler:^(NSRunningApplication *app, NSError *error) {
            success=app!=nil && error==nil; finished=YES;
            if (error) fprintf(stderr,"Could not reopen %s: %s\n",url.path.UTF8String,error.localizedDescription.UTF8String);
        }];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:15];
    while (!finished && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    return finished && success;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        if (argc<3) { fprintf(stderr,"Usage: update-mac-apps prepare STATE | resume STATE APP\n"); return 2; }
        NSString *operation=@(argv[1]), *path=@(argv[2]);
        if ([operation isEqualToString:@"prepare"]) {
            puts("Ending mirror sessions and stopping Mac helpers before update…"); fflush(stdout);
            NSArray *hosts=DMApps(@"app.droidmirror.mac"), *helpers=DMApps(@"app.droidmirror.notifications");
            // Keep the first snapshot when rechecking immediately before install.
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                NSDictionary *state=@{@"host":@(hosts.count>0),@"helper":@(helpers.count>0)};
                if (![state writeToFile:path atomically:YES]) return 1;
            }
            if (!DMStopApplications(hosts,30) || !DMStopApplications(DMApps(@"app.droidmirror.renderer"),15)
                    || !DMStopApplications(DMApps(@"app.droidmirror.notifications"),15)) {
                fprintf(stderr,"DroidMirror or its helper did not quit. End mirroring and retry; no forced termination was attempted.\n");
                return 1;
            }
            return 0;
        }
        if ([operation isEqualToString:@"resume"] && argc==4) {
            NSDictionary *state=[NSDictionary dictionaryWithContentsOfFile:path];
            if (!state) return 1;
            NSURL *app=[NSURL fileURLWithPath:@(argv[3]) isDirectory:YES];
            for (NSURL *target in DMResumeTargets(state,app)) if (!DMOpenApp(target)) return 1;
            return 0;
        }
        return 2;
    }
}
