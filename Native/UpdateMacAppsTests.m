#define main DMUpdateProgramMain
#import "UpdateMacApps.m"
#undef main
#include <assert.h>
@interface UpdateTestApplication : NSObject
@property(nonatomic) BOOL terminated;
@property(nonatomic) BOOL refuse;
@property(nonatomic) NSUInteger quits;
@end
@implementation UpdateTestApplication
- (BOOL)isTerminated { return _terminated; }
- (pid_t)processIdentifier { return getpid(); }
- (BOOL)terminate { ++_quits; if (!_refuse) _terminated=YES; return !_refuse; }
@end
int main(void) {
    @autoreleasepool {
        UpdateTestApplication *host=[UpdateTestApplication new], *helper=[UpdateTestApplication new];
        assert(DMStopApplications((id)@[host,helper],.01));
        assert(host.terminated && helper.terminated && host.quits==1 && helper.quits==1);
        assert(DMStopApplications((id)@[host,helper],.01) && host.quits==1);
        UpdateTestApplication *stuck=[UpdateTestApplication new]; stuck.refuse=YES;
        assert(!DMStopApplications((id)@[stuck],.01)); // Abort replacement; no force-quit fallback.
        NSURL *app=[NSURL fileURLWithPath:@"/Applications/DroidMirror.app"];
        assert(DMResumeTargets(@{},app).count==0);
        assert([DMResumeTargets(@{@"host":@YES},app) isEqual:@[app]]);
        NSArray<NSURL *> *targets=DMResumeTargets(@{@"host":@YES,@"helper":@YES},app);
        assert(targets.count==2 && [targets[0].path hasPrefix:app.path] && [targets[1] isEqual:app]);
        assert([targets[0].lastPathComponent isEqualToString:@"DroidMirror Notifications.app"]);
        puts("Mac update lifecycle: graceful host/helper quit, terminated processes, refusal abort and installed-bundle resume targets passed");
    }
}
