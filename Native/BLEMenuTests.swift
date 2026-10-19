import AppKit

@main struct BLEMenuTests {
    static func main() {
        _ = NSApplication.shared
        let old = NSMenu()
        let quit = NSMenuItem(title: "Quit DroidMirror", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        old.addItem(quit)
        let command = NSMenuItem(title: "Background Bluetooth", action: nil, keyEquivalent: "")
        BLEMenuAttachment.ensure(command, in: old)
        precondition(old.items == [command, quit])
        BLEMenuAttachment.ensure(command, in: old)
        precondition(old.numberOfItems == 2)
        let replacement = NSMenu()
        let newQuit = NSMenuItem(title: "Quit DroidMirror", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        replacement.addItem(newQuit)
        BLEMenuAttachment.ensure(command, in: replacement)
        precondition(command.menu === replacement && old.items == [quit])
        replacement.removeItem(command)
        BLEMenuAttachment.ensure(command, in: replacement)
        precondition(replacement.items == [command, newQuit])
        replacement.removeItem(command)
        let duplicate = NSMenuItem(title: "Stale command", action: nil, keyEquivalent: "")
        duplicate.identifier = BLEMenuAttachment.identifier
        replacement.addItem(duplicate)
        BLEMenuAttachment.ensure(command, in: replacement)
        precondition(replacement.items == [command, newQuit])
        print("PASS: BLE menu replacement, in-place removal, duplicate prevention, Quit preservation")
    }
}
