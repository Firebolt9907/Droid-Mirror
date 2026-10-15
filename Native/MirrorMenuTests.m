#import "MirrorMenu.h"
#include <assert.h>
@interface QuitTarget : NSObject
@end
@implementation QuitTarget
- (void)quit:(id)sender {}
@end
int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        QuitTarget *target = [QuitTarget new];
        app.mainMenu = nil;
        DMEnsureMirrorQuitMenu(app, target);
        NSMenu *application = app.mainMenu.itemArray.firstObject.submenu;
        NSMenuItem *quit = application.itemArray.lastObject;
        assert([quit.title isEqual:@"Quit DroidMirror"] && [quit.keyEquivalent isEqual:@"q"]);
        assert(quit.target == target && quit.action == @selector(quit:));
        assert(quit.keyEquivalentModifierMask == NSEventModifierFlagCommand && quit.enabled);
        DMEnsureMirrorQuitMenu(app, target);
        assert(application.numberOfItems == 1); // Repeated installation must not duplicate Quit.
        quit.action = @selector(terminate:); quit.target = app; quit.keyEquivalent = @"";
        DMEnsureMirrorQuitMenu(app, target);
        assert(application.numberOfItems == 1 && quit.target == target && [quit.keyEquivalent isEqual:@"q"]);
        puts("Mirror menu: missing-menu creation, Quit, Command-Q and idempotent repair passed");
    }
}
