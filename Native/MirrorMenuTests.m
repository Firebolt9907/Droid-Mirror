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
        assert(application.numberOfItems == 2); // Repeated installation must not duplicate Quit.
        NSMenuItem *clipboard = [application itemWithTag:0x444d434c];
        assert([clipboard.title isEqual:@"Mirror Clipboard over Bluetooth"]);
        assert(clipboard.action == NSSelectorFromString(@"toggleClipboard:") && clipboard.target != nil);
        NSMenu *edit = app.mainMenu.itemArray[1].submenu;
        assert([edit.title isEqual:@"Edit"] && edit.numberOfItems == 1);
        NSMenuItem *emoji = edit.itemArray.firstObject;
        assert([emoji.title isEqual:@"Emoji & Symbols"]);
        assert(emoji.target == app && emoji.action == @selector(orderFrontCharacterPalette:));
        assert([emoji.keyEquivalent isEqual:@" "]);
        assert(emoji.keyEquivalentModifierMask == (NSEventModifierFlagControl | NSEventModifierFlagCommand));
        quit.action = @selector(terminate:); quit.target = app; quit.keyEquivalent = @"";
        DMEnsureMirrorQuitMenu(app, target);
        assert(application.numberOfItems == 2 && quit.target == target && [quit.keyEquivalent isEqual:@"q"]);
        // SDL may replace the entire menu during a new stream session.
        app.mainMenu = nil;
        DMEnsureMirrorQuitMenu(app, target);
        assert(app.mainMenu.numberOfItems == 2);
        assert([app.mainMenu.itemArray.firstObject.submenu itemWithTag:0x444d434c] != nil);
        assert(app.mainMenu.itemArray[1].submenu.numberOfItems == 1);
        puts("Mirror menu: Quit, clipboard toggle, emoji picker, shortcuts and menu rebuild passed");
    }
}
