#import <AppKit/AppKit.h>

@interface ProbeDelegate : NSObject <NSApplicationDelegate>
@end
@implementation ProbeDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    BOOL stalled = getenv("DM_PROBE_STALLED") != NULL;
    NSLog(@"PROBE: simulating %@ Android cleanup", stalled ? @"stalled" : @"asynchronous");
    if (!stalled) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
            NSLog(@"PROBE: Android cleanup finished");
            [app replyToApplicationShouldTerminate:YES];
        });
    }
    return NSTerminateLater;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSMenu *main = [NSMenu new];
    NSMenuItem *application = [NSMenuItem new];
    NSMenu *menu = [NSMenu new];
    [menu addItemWithTitle:@"Quit Probe" action:@selector(terminate:) keyEquivalent:@"q"];
    application.submenu = menu;
    [main addItem:application];
    NSApp.mainMenu = main;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSMenuItem *quit = menu.itemArray.firstObject;
        [menu update];
        NSLog(@"PROBE: quit enabled=%d target=%@", quit.enabled, quit.target);
        [NSApp sendAction:quit.action to:quit.target from:quit];
    });
}
@end
int main(void) {
    NSApplication *app = NSApplication.sharedApplication;
    __attribute__((objc_precise_lifetime)) ProbeDelegate *delegate = [ProbeDelegate new];
    app.delegate = delegate;
    [app finishLaunching];
    [app run];
    return 0;
}
