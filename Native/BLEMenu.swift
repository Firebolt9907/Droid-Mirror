import AppKit

enum BLEMenuAttachment {
    static let identifier = NSUserInterfaceItemIdentifier("DroidMirror.wirelessADB")

    // SwiftUI can replace either the application submenu or its items. Keep
    // ownership of our command but attach it to the currently displayed menu.
    static func ensure(_ item: NSMenuItem, in menu: NSMenu) {
        guard item.menu !== menu else { return }
        item.menu?.removeItem(item)
        for duplicate in menu.items where duplicate.identifier == identifier {
            menu.removeItem(duplicate)
        }
        item.identifier = identifier
        let quit = menu.items.firstIndex { $0.keyEquivalent.lowercased() == "q" }
        menu.insertItem(item, at: quit ?? menu.numberOfItems)
    }
}
