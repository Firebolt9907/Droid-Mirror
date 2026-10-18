import AppKit

final class BLEController {
    var authenticated = true
    var supportsClipboard = true
    var sent = [[String: Any]]()
    @discardableResult func send(_ value: [String: Any]) -> Bool { sent.append(value); return authenticated }
}
enum NotificationRuntime {
    static let preferences = UserDefaults(suiteName: "app.droidmirror.clipboard.tests.\(ProcessInfo.processInfo.processIdentifier)")!
}
@main struct ClipboardSyncTests {
    static func main() {
        let prefs = NotificationRuntime.preferences
        defer { prefs.removeObject(forKey: ClipboardSync.enabledKey) }
        let board = NSPasteboard(name: NSPasteboard.Name("DroidMirror-clipboard-test-\(UUID())"))
        defer { board.releaseGlobally() }
        func copy(_ text: String) { board.clearContents(); board.setString(text, forType: .string) }
        copy("old Mac text")
        let controller = BLEController()
        let sync = ClipboardSync(pasteboard: board)
        defer { sync.stop() }
        sync.controller = controller
        sync.connected(); sync.poll()
        precondition(controller.sent.isEmpty) // opt-in
        prefs.set(true, forKey: ClipboardSync.enabledKey)
        sync.configure()
        precondition(controller.sent.count == 1)
        sync.receive(["type": "clipboardStatus", "status": "ready"])
        sync.poll()
        precondition(controller.sent.count == 1) // no initial clipboard upload
        copy("fresh Mac text"); sync.poll()
        precondition(controller.sent.last?["text"] as? String == "fresh Mac text")
        sync.receive(["type": "clipboardStatus", "status": "locked"])
        precondition(sync.status == "Clipboard paused while phone is locked")
        let whileLocked = controller.sent.count
        copy("copy while locked"); sync.poll()
        precondition(controller.sent.count == whileLocked)
        sync.receive(["type": "clipboardStatus", "status": "ready"])
        sync.poll(); precondition(controller.sent.count == whileLocked)
        let count = controller.sent.count
        sync.receive(["type": "clipboard", "text": "phone copy"])
        precondition(board.string(forType: .string) == "phone copy")
        sync.poll(); precondition(controller.sent.count == count) // no echo
        copy("local copy wins")
        sync.receive(["type": "clipboard", "text": "concurrent phone copy"])
        precondition(board.string(forType: .string) == "local copy wins")
        sync.poll()
        board.clearContents()
        board.setString("password", forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let beforeSensitive = controller.sent.count
        sync.poll(); precondition(controller.sent.count == beforeSensitive)
        copy(String(repeating: "😀", count: 1025)); sync.poll()
        precondition(controller.sent.count == beforeSensitive)
        controller.authenticated = false
        copy("offline text"); sync.poll()
        controller.authenticated = true
        sync.connected()
        sync.receive(["type": "clipboardStatus", "status": "ready"])
        let afterReconnect = controller.sent.count
        sync.poll(); precondition(controller.sent.count == afterReconnect)
        prefs.set(false, forKey: ClipboardSync.enabledKey); sync.configure()
        precondition(controller.sent.last?["enabled"] as? Bool == false)
        prefs.set(true, forKey: ClipboardSync.enabledKey)
        controller.supportsClipboard = false
        let beforeOldPeer = controller.sent.count
        sync.connected(); precondition(controller.sent.count == beforeOldPeer)
        precondition(ClipboardTextPolicy.allowed(String(repeating: "😀", count: 1024)))
        print("Mac clipboard tests passed")
    }
}
