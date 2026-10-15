#import "MirrorMenu.h"

static BOOL DMConfigureQuitItems(NSMenu *menu, id target) {
    BOOL found = NO;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == @selector(terminate:) || item.action == NSSelectorFromString(@"quit:") ||
                [item.keyEquivalent.lowercaseString isEqualToString:@"q"]) {
            item.title = @"Quit DroidMirror";
            item.target = target; item.action = NSSelectorFromString(@"quit:");
            item.keyEquivalent = @"q"; item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
            item.enabled = YES; found = YES;
        }
        if (item.submenu) found = DMConfigureQuitItems(item.submenu, target) || found;
    }
    return found;
}

void DMEnsureMirrorQuitMenu(NSApplication *app, id target) {
    NSMenu *menu = app.mainMenu;
    if (!menu) { menu = [NSMenu new]; app.mainMenu = menu; }
    if (DMConfigureQuitItems(menu, target)) return;
    NSMenuItem *application = menu.itemArray.firstObject;
    if (!application.submenu) {
        application = [[NSMenuItem alloc] initWithTitle:@"DroidMirror" action:NULL keyEquivalent:@""];
        application.submenu = [[NSMenu alloc] initWithTitle:@"DroidMirror"];
        [menu insertItem:application atIndex:0];
    }
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit DroidMirror"
        action:NSSelectorFromString(@"quit:") keyEquivalent:@"q"];
    quit.target = target; quit.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [application.submenu addItem:quit];
}
