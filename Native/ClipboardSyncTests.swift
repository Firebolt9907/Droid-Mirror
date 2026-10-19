import AppKit

final class BLEController {
    var authenticated = true
    var supportsClipboard = true
    var supportsClipboardFiles = true
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
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cache) }
        let sync = ClipboardSync(pasteboard: board, fileCache: cache)
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
        controller.authenticated = false
        sync.disconnected()
        precondition(sync.status == "Clipboard waiting for Bluetooth")
        copy("offline copy must not replay")
        controller.authenticated = true
        sync.connected()
        sync.receive(["type": "clipboardStatus", "status": "ready"])
        let afterSessionReset = controller.sent.count
        sync.poll()
        precondition(controller.sent.count == afterSessionReset)
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
        // File sender: strict decimal limit, stop-and-wait chunks and no file-URL text fallback.
        precondition(ClipboardFilePolicy.allowed(0))
        precondition(ClipboardFilePolicy.allowed(4_999_999))
        precondition(!ClipboardFilePolicy.allowed(5_000_000))
        precondition(!ClipboardFilePolicy.allowed(-1))
        for name in ["../escape", "..", "/tmp/file", "a\\b", "a:b", "a\n"] { precondition(!ClipboardFilePolicy.nameAllowed(name)) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-source-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: source) }
        let fileData = Data((0..<7000).map { UInt8($0 % 251) })
        try! fileData.write(to: source)
        func copyFile() { board.clearContents(); precondition(board.writeObjects([source as NSURL])); sync.poll() }
        copyFile()
        let begin = controller.sent.last!
        precondition(begin["type"] as? String == "clipboardFileBegin")
        let sendID = begin["id"] as! String
        var sent = Data()
        while sent.count < fileData.count {
            sync.receive(["type": "clipboardFileAck", "id": sendID, "offset": sent.count])
            let chunk = controller.sent.last!
            precondition(chunk["type"] as? String == "clipboardFileChunk")
            sent.append(Data(base64Encoded: (chunk["data"] as! String).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))!)
        }
        precondition(sent == fileData)
        sync.receive(["type": "clipboardFileAck", "id": sendID, "offset": sent.count])
        try! Data(repeating: 0, count: 5_000_000).write(to: source)
        let beforeLarge = controller.sent.count
        copyFile(); precondition(controller.sent.count == beforeLarge)
        precondition(sync.status.contains("less than 5 MB"))
        try! Data(repeating: 1, count: 4_999_999).write(to: source)
        copyFile(); precondition(controller.sent.last?["size"] as? Int == 4_999_999)
        sync.receive(["type": "clipboardFileCancel", "id": controller.sent.last!["id"] as! String])
        // File receiver writes complete contents and suppresses its own pasteboard echo.
        let receiveID = UUID().uuidString
        sync.receive(["type": "clipboardFileBegin", "id": receiveID, "name": "phone.bin", "size": fileData.count])
        for offset in stride(from: 0, to: fileData.count, by: ClipboardFilePolicy.chunk) {
            let chunk = fileData.subdata(in: offset..<min(offset + ClipboardFilePolicy.chunk, fileData.count))
            sync.receive(["type": "clipboardFileChunk", "id": receiveID, "offset": offset, "data": chunk.base64EncodedString()])
        }
        let receivedURL = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as! [URL])[0]
        precondition(try! Data(contentsOf: receivedURL) == fileData)
        let afterFile = controller.sent.count
        sync.poll(); precondition(controller.sent.count == afterFile)
        // Copy Image and screenshot clipboards have pixels but no file URL.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 127, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = bitmap.representation(using: .png, properties: [:])!
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            board.clearContents()
            board.setData(type == .png ? png : bitmap.tiffRepresentation!, forType: type)
            board.setString("image caption must not replace pixels", forType: .string)
            sync.poll()
            let imageBegin = controller.sent.last!
            precondition(imageBegin["type"] as? String == "clipboardFileBegin")
            precondition(imageBegin["name"] as? String == "Clipboard Image.png")
            let imageID = imageBegin["id"] as! String
            sync.receive(["type": "clipboardFileAck", "id": imageID, "offset": 0])
            let encoded = controller.sent.last!["data"] as! String
            let pixels = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))!
            precondition(NSBitmapImageRep(data: pixels)?.pixelsWide == 2)
            if type == .png { precondition(pixels == png) }
            sync.receive(["type": "clipboardFileAck", "id": imageID, "offset": pixels.count])
        }
        board.clearContents(); board.setData(Data(repeating: 0, count: 5_000_000), forType: .png)
        let beforeLargeImage = controller.sent.count
        sync.poll(); precondition(controller.sent.count == beforeLargeImage)
        precondition(sync.status.contains("less than 5 MB"))
        board.clearContents(); board.setData(png, forType: .png)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        sync.poll(); precondition(controller.sent.count == beforeLargeImage)
        copy("ready for incoming image"); sync.poll()
        let imageID = UUID().uuidString
        sync.receive(["type": "clipboardFileBegin", "id": imageID, "name": "phone.png", "size": png.count])
        sync.receive(["type": "clipboardFileChunk", "id": imageID, "offset": 0, "data": png.base64EncodedString()])
        precondition(board.pasteboardItems?.count == 1)
        precondition(NSBitmapImageRep(data: board.data(forType: .png)!)?.pixelsWide == 2)
        precondition(board.data(forType: .tiff) != nil)
        let imageURL = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as! [URL])[0]
        precondition(try! Data(contentsOf: imageURL) == png)
        let afterImage = controller.sent.count
        sync.poll(); precondition(controller.sent.count == afterImage)
        // Reject oversize declarations, unsafe names and out-of-order chunks without a clipboard write.
        let previousCount = board.changeCount
        for event in [
            ["type": "clipboardFileBegin", "id": UUID().uuidString, "name": "x", "size": 5_000_000],
            ["type": "clipboardFileBegin", "id": UUID().uuidString, "name": "../x", "size": 1]
        ] as [[String: Any]] { sync.receive(event); precondition(controller.sent.last?["type"] as? String == "clipboardFileCancel") }
        let invalidID = UUID().uuidString
        sync.receive(["type": "clipboardFileBegin", "id": invalidID, "name": "bad.bin", "size": 10])
        sync.receive(["type": "clipboardFileChunk", "id": invalidID, "offset": 1, "data": "YQ=="])
        precondition(board.changeCount == previousCount)
        precondition(controller.sent.last?["type"] as? String == "clipboardFileCancel")
        // A local copy during a transfer wins, including before the next poll.
        let conflictID = UUID().uuidString
        sync.receive(["type": "clipboardFileBegin", "id": conflictID, "name": "bad.bin", "size": 1])
        copy("new local text")
        sync.receive(["type": "clipboardFileChunk", "id": conflictID, "offset": 0, "data": "YQ=="])
        precondition(board.string(forType: .string) == "new local text")
        sync.poll()
        let emptyID = UUID().uuidString
        sync.receive(["type": "clipboardFileBegin", "id": emptyID, "name": "empty.bin", "size": 0])
        precondition(controller.sent.last?["offset"] as? Int == 0)
        precondition(controller.sent.last?["type"] as? String == "clipboardFileAck")
        controller.supportsClipboardFiles = false
        let beforeLegacy = controller.sent.count
        copyFile(); precondition(controller.sent.count == beforeLegacy)
        controller.supportsClipboardFiles = true
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
