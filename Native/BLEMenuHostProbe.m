#import <AppKit/AppKit.h>

static void CheckMenu(void) {
    NSMenu *menu = NSApp.mainMenu.itemArray.firstObject.submenu;
    [menu update];
    NSPredicate *match = [NSPredicate predicateWithBlock:^BOOL(NSMenuItem *item, NSDictionary *bindings) {
        return [item.identifier isEqualToString:@"DroidMirror.wirelessADB"];
    }];
    NSArray *commands = [menu.itemArray filteredArrayUsingPredicate:match];
    NSMenuItem *root = commands.firstObject;
    NSMenuItem *pair = [root.submenu.itemArray filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSMenuItem *item, NSDictionary *bindings) {
            return [item.title isEqualToString:@"Pair phone using authorized ADB…"];
        }]].firstObject;
    if (commands.count != 1 || pair != nil) {
        NSLog(@"FAIL: discovery menu missing or legacy pairing still present; menu=%@", [menu.itemArray valueForKey:@"title"]);
        exit(2);
    }
}

__attribute__((constructor)) static void Probe(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        CheckMenu();
        NSMenu *replacement = [[NSMenu alloc] initWithTitle:@"DroidMirror"];
        [replacement addItemWithTitle:@"Quit DroidMirror" action:@selector(terminate:) keyEquivalent:@"q"];
        NSApp.mainMenu.itemArray.firstObject.submenu = replacement;
        CheckMenu();
        [replacement removeAllItems];
        [replacement addItemWithTitle:@"Quit DroidMirror" action:@selector(terminate:) keyEquivalent:@"q"];
        CheckMenu();
        NSLog(@"PASS: discovery menu survives reconstruction without a separate notification pairing action");
        [NSApp terminate:nil];
    });
}
