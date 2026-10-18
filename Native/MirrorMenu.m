#import "MirrorMenu.h"

static const NSInteger DMClipboardMenuTag = 0x444d434c;

@interface DMClipboardMenuTarget : NSObject
- (void)toggleClipboard:(NSMenuItem *)sender;
@end
@implementation DMClipboardMenuTarget
- (void)toggleClipboard:(NSMenuItem *)sender {
    NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:@"app.droidmirror.mac"];
    BOOL enabled = ![preferences boolForKey:@"DroidMirror.clipboard.enabled"];
    [preferences setBool:enabled forKey:@"DroidMirror.clipboard.enabled"];
    [preferences synchronize];
    sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"app.droidmirror.clipboardConfiguration"
        object:nil userInfo:nil deliverImmediately:YES];
}
@end

static void DMEnsureClipboardMenu(NSMenu *menu) {
    static DMClipboardMenuTarget *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ target = [DMClipboardMenuTarget new]; });
    NSMenuItem *item = [menu itemWithTag:DMClipboardMenuTag];
    if (!item) {
        item = [[NSMenuItem alloc] initWithTitle:@"Mirror Clipboard over Bluetooth"
            action:@selector(toggleClipboard:) keyEquivalent:@""];
        item.tag = DMClipboardMenuTag;
        NSInteger index = menu.numberOfItems;
        for (NSMenuItem *existing in menu.itemArray) {
            if ([existing.keyEquivalent.lowercaseString isEqualToString:@"q"]) {
                index = [menu indexOfItem:existing]; break;
            }
        }
        [menu insertItem:item atIndex:index];
    }
    item.target = target;
    NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:@"app.droidmirror.mac"];
    item.state = [preferences boolForKey:@"DroidMirror.clipboard.enabled"] ? NSControlStateValueOn : NSControlStateValueOff;
}


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
    if (!menu.numberOfItems) {
        NSMenuItem *application = [[NSMenuItem alloc] initWithTitle:@"DroidMirror" action:NULL keyEquivalent:@""];
        application.submenu = [[NSMenu alloc] initWithTitle:@"DroidMirror"];
        [menu addItem:application];
    }
    // SDL can rebuild its menu. Restore the native character picker each time.
    NSMenu *edit = nil;
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.submenu.title isEqualToString:@"Edit"]) { edit = item.submenu; break; }
    }
    if (!edit) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""];
        edit = [[NSMenu alloc] initWithTitle:@"Edit"];
        item.submenu = edit;
        [menu addItem:item];
    }
    NSMenuItem *emoji = [edit itemWithTag:0x444d454d];
    if (!emoji) {
        emoji = [[NSMenuItem alloc] initWithTitle:@"Emoji & Symbols"
            action:@selector(orderFrontCharacterPalette:) keyEquivalent:@" "];
        emoji.tag = 0x444d454d;
        [edit addItem:emoji];
    }
    emoji.target = app;
    emoji.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
    DMEnsureClipboardMenu(menu.itemArray.firstObject.submenu);
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
