import AppKit

final class BLEController {
    var clipboardPreparingID: String?
    var holdPreparation = false
    var preparationCompletion: (() -> Void)?
    func prepareClipboardFile(_ id: String, completion: @escaping () -> Void) {
        clipboardPreparingID = id
        if holdPreparation { preparationCompletion = completion } else { completion() }
    }
    func finishClipboardPreparation(_ id: String, cancelled: Bool) { if clipboardPreparingID == id { clipboardPreparingID = nil } }
    var authenticated = true
    var supportsClipboard = true
    var supportsClipboardFiles = true
    var supportsApkInstall = true
    var supportsClipboardDownloads = true
    var supportsClipboardBulk = false
    var bulkReady = false
    var bulkSent = [[String: Any]]()
    func setClipboardBulkReady(_ value: Bool) { bulkReady = value }
    @discardableResult func sendClipboardFile(_ value: [String: Any]) -> Bool {
        if supportsClipboardBulk { bulkSent.append(value); sent.append(value); return authenticated }
        return send(value)
    }
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
        precondition(ApkInstallPolicy.allowed(5_000_001))
        precondition(!ApkInstallPolicy.allowed(256 * 1024 * 1024))
        precondition(ApkInstallPolicy.nameAllowed("Sample.APK"))
        precondition(!ApkInstallPolicy.nameAllowed("sample.zip"))
        var installFinished = 0
        sync.installStatus = { _, finished, _ in if finished { installFinished += 1 } }
        controller.supportsApkInstall = false
        precondition(!sync.canInstallApk)
        precondition(!sync.installApk(URL(fileURLWithPath: "/private/tmp/test.apk")))
        precondition(installFinished == 1)
        controller.supportsApkInstall = true
        precondition(sync.canInstallApk)
        precondition(!sync.installApk(URL(fileURLWithPath: "/private/tmp/test.zip")))
        precondition(installFinished == 2)
        sync.installStatus = nil
        // Bulk codec uses each authenticated declaration, including on the Iroh lane.
        do {
            let key = Data(repeating: 7, count: 32), token = String(repeating: "12", count: 32)
            var sender = try ClipboardBulkCodec(key: key, token: token)
            var receiver = try ClipboardBulkCodec(key: key, token: token, mac: false)
            let id = UUID().uuidString
            let begin: [String: Any] = ["type": "clipboardFileBegin", "id": id, "name": "sample.apk", "destination": "install", "size": 5_000_001]
            _ = try receiver.open(sender.seal(begin))
            let chunk: [String: Any] = ["type": "clipboardFileChunk", "id": id, "offset": 5_000_000, "data": "AQ=="]
            let decoded = try receiver.open(sender.seal(chunk))
            precondition(decoded["offset"] as? Int == 5_000_000)
            var bad = chunk; bad["offset"] = 5_000_001
            do { _ = try sender.seal(bad); preconditionFailure("Offset outside declared transfer accepted") } catch {}
            var invalid = begin; invalid["destination"] = "downloads"
            do { _ = try sender.seal(invalid); preconditionFailure("Downloads limit raised") } catch {}
            invalid = begin; invalid["size"] = ApkInstallPolicy.limit
            do { _ = try sender.seal(invalid); preconditionFailure("Install limit accepted") } catch {}
        } catch { preconditionFailure("Bulk install codec: \(error)") }
        let installRace = ClipboardTransferRace()
        var laneBytes = [0: 0, 1: 0]
        installRace.wire = { lane, event in
            if event["type"] as? String == "clipboardFileChunk" {
                laneBytes[lane, default: 0] += Data(base64Encoded: event["data"] as! String)!.count
            }
            return lane == 0
        }
        let raceID = UUID().uuidString, raceSize = 5_000_001
        precondition(installRace.send(["type": "clipboardFileBegin", "id": raceID, "size": raceSize, "name": "large.apk", "destination": "install"]))
        for offset in stride(from: 0, to: raceSize, by: 3072) {
            let data = Data(repeating: 1, count: min(3072, raceSize - offset))
            precondition(installRace.send(["type": "clipboardFileChunk", "id": raceID, "offset": offset, "data": data.base64EncodedString()]))
        }
        precondition(laneBytes[0] == raceSize && laneBytes[1] == 0)
        precondition(!installRace.send(["type": "clipboardFileChunk", "id": raceID, "offset": raceSize, "data": "AQ=="]))
        installRace.receive(["type": "clipboardFileAck", "id": raceID, "offset": raceSize], lane: 0)
        precondition(installRace.activeID == nil)
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
        func awaitPreparation() {
            let deadline = Date().addingTimeInterval(3)
            while controller.clipboardPreparingID != nil && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            precondition(controller.clipboardPreparingID == nil)
        }
        func copyFile() { board.clearContents(); precondition(board.writeObjects([source as NSURL])); sync.poll(); awaitPreparation() }
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
        // Regression: a 66 KiB screenshot takes three eight-chunk batches,
        // rather than 22 application round trips. Exact bytes and final ACK matter.
        let screenshot = Data((0..<(66 * 1024)).map { UInt8($0 % 251) })
        try! screenshot.write(to: source)
        for requestedWindow in [8, 999] {
            copyFile()
            let windowID = controller.sent.last!["id"] as! String
            precondition(controller.sent.last!["window"] as? Int == 8)
            var received = Data()
            var batches = 0
            while received.count < screenshot.count {
                let before = controller.sent.count
                sync.receive(["type": "clipboardFileAck", "id": windowID, "offset": received.count, "window": requestedWindow])
                let chunks = Array(controller.sent.dropFirst(before))
                precondition(chunks.count <= 8 && !chunks.isEmpty)
                for chunk in chunks {
                    precondition(chunk["offset"] as? Int == received.count)
                    received.append(Data(base64Encoded: (chunk["data"] as! String).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))!)
                }
                batches += 1
            }
            precondition(received == screenshot && batches == 3)
            sync.receive(["type": "clipboardFileAck", "id": windowID, "offset": received.count])
            precondition(sync.status == "Clipboard mirroring ready")
        }
        let windowReceiveID = UUID().uuidString
        sync.receive(["type": "clipboardFileBegin", "id": windowReceiveID, "name": "screenshot.bin", "size": screenshot.count, "window": 8])
        precondition(controller.sent.last!["window"] as? Int == 8)
        let initialAcks = controller.sent.count
        for offset in stride(from: 0, to: screenshot.count, by: ClipboardFilePolicy.chunk) {
            let end = min(offset + ClipboardFilePolicy.chunk, screenshot.count)
            sync.receive(["type": "clipboardFileChunk", "id": windowReceiveID, "offset": offset, "data": screenshot.subdata(in: offset..<end).base64EncodedString()])
            precondition(controller.sent.count - initialAcks == (end == screenshot.count ? 3 : end / (8 * ClipboardFilePolicy.chunk)))
        }
        let screenshotURL = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as! [URL])[0]
        precondition(try! Data(contentsOf: screenshotURL) == screenshot)
        // A partial/out-of-order batch acknowledgment must not advance the sender.
        copyFile()
        let badAckID = controller.sent.last!["id"] as! String
        sync.receive(["type": "clipboardFileAck", "id": badAckID, "offset": 0, "window": 8])
        sync.receive(["type": "clipboardFileAck", "id": badAckID, "offset": ClipboardFilePolicy.chunk])
        precondition(controller.sent.last!["type"] as? String == "clipboardFileCancel")
        try! Data(repeating: 0, count: 5_000_000).write(to: source)
        let beforeLarge = controller.sent.count
        copyFile(); precondition(controller.sent.count == beforeLarge)
        precondition(sync.status.contains("less than 5 MB"))
        try! Data(repeating: 1, count: 4_999_999).write(to: source)
        copyFile(); precondition(controller.sent.last?["size"] as? Int == 4_999_999)
        sync.receive(["type": "clipboardFileCancel", "id": controller.sent.last!["id"] as! String])
        controller.holdPreparation = true
        board.clearContents(); board.setData(Data([1,2,3]), forType: .png); sync.poll()
        let preparationID = controller.clipboardPreparingID!
        let beforePrepareCancel = controller.sent.count
        sync.receive(["type": "clipboardFileCancel", "id": preparationID])
        controller.preparationCompletion?(); controller.preparationCompletion = nil; controller.holdPreparation = false
        precondition(controller.clipboardPreparingID == nil && controller.sent.count == beforePrepareCancel)
        // A clipboard change while readiness is pending must discard the old snapshot.
        controller.holdPreparation = true
        board.clearContents(); board.setData(Data([4,5,6]), forType: .png); sync.poll()
        let beforePrepareChange = controller.sent.count
        copy("new text before preparation finishes")
        controller.preparationCompletion?(); controller.preparationCompletion = nil; controller.holdPreparation = false
        precondition(controller.clipboardPreparingID == nil && controller.sent.count == beforePrepareChange)
        sync.poll()
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
            sync.poll(); awaitPreparation()
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
        controller.supportsClipboard = true; controller.supportsClipboardBulk = true
        let replay = ClipboardSync(pasteboard: board, fileCache: cache, retryDelay: { _ in 0 })
        replay.controller = controller; replay.connected(); replay.receive(["type": "clipboardStatus", "status": "ready"])
        func replayCopy() {
            board.clearContents(); board.setData(Data([1, 2, 3, 4]), forType: .png); replay.poll()
        }
        replayCopy()
        let firstReplayID = controller.bulkSent.last!["id"] as! String
        replay.receive(["type": "clipboardBulkFailed"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let secondReplayID = controller.bulkSent.last!["id"] as! String
        precondition(firstReplayID != secondReplayID, "Unchanged source retries with a fresh transfer ID")
        replay.receive(["type": "clipboardBulkFailed"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let retriesDone = controller.bulkSent.count
        replay.receive(["type": "clipboardBulkFailed"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(controller.bulkSent.count == retriesDone, "Retries are bounded")
        replayCopy(); replay.receive(["type": "clipboardBulkFailed"])
        copy("newer text cancels file replay")
        let beforeReplayCancel = controller.bulkSent.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(controller.bulkSent.count == beforeReplayCancel, "Changed source must not replay")
        replay.poll()
        precondition(controller.sent.last?["type"] as? String == "clipboardSet", "Text stays on GATT")
        replayCopy(); replay.receive(["type": "clipboardBulkFailed"])
        let beforeLockedRetry = controller.bulkSent.count
        replay.receive(["type": "clipboardStatus", "status": "locked"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(controller.bulkSent.count == beforeLockedRetry, "Lock cancels pending replay")
        replay.receive(["type": "clipboardStatus", "status": "ready"])
        replayCopy(); replay.receive(["type": "clipboardBulkFailed"])
        let beforeDisconnectRetry = controller.bulkSent.count
        replay.disconnected()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(controller.bulkSent.count == beforeDisconnectRetry, "Disconnect cancels pending replay")
        replay.stop()
        precondition(ClipboardTextPolicy.allowed(String(repeating: "😀", count: 1024)))
        let drops = ClipboardSync(pasteboard: board)
        defer { drops.stop() }
        drops.controller = controller
        drops.connected(); drops.receive(["type": "clipboardStatus", "status": "ready"])
        let dropURL = cache.appendingPathComponent("drop.apk")
        try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try! Data([1, 2, 3]).write(to: dropURL)
        let boardBeforeDrop = board.changeCount
        var dropMessages = [String]()
        drops.dropStatus = { dropMessages.append($0) }
        controller.supportsClipboardDownloads = false
        precondition(!drops.sendDroppedFile(dropURL)) // Old peers must not apply a drop to clipboard.
        controller.supportsClipboardDownloads = true
        precondition(drops.sendDroppedFile(dropURL))
        precondition(!drops.sendDroppedFile(dropURL)) // No concurrent operation.
        let deadline = Date().addingTimeInterval(2)
        while !controller.sent.contains(where: { $0["destination"] as? String == "downloads" }) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let dropBegin = controller.sent.last { $0["destination"] as? String == "downloads" }!
        let dropID = dropBegin["id"] as! String
        precondition(dropBegin["name"] as? String == "drop.apk")
        drops.receive(["type": "clipboardFileAck", "id": dropID, "offset": 0])
        drops.receive(["type": "clipboardFileAck", "id": dropID, "offset": 3])
        precondition(dropMessages.last == "Saved to phone Downloads")
        precondition(board.changeCount == boardBeforeDrop)
        precondition(drops.sendDroppedFile(dropURL))
        drops.disconnected()
        precondition(dropMessages.last == "File transfer ended before completion.")
        drops.connected(); drops.receive(["type": "clipboardStatus", "status": "ready"])
        controller.supportsApkInstall = true
        var results = [(Bool, Bool)]()
        drops.installStatus = { _, finished, ok in results.append((finished, ok)) }
        precondition(drops.installApk(dropURL))
        let installDeadline = Date().addingTimeInterval(3)
        while controller.sent.last?["destination"] as? String != "install" && Date() < installDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let installBegin = controller.sent.last!
        precondition(installBegin["destination"] as? String == "install")
        let installID = installBegin["id"] as! String
        drops.receive(["type": "clipboardFileAck", "id": installID, "offset": 0])
        drops.receive(["type": "clipboardFileAck", "id": installID, "offset": 3])
        precondition(!results.contains { $0.0 })
        drops.receive(["type": "clipboardApkInstallResult", "id": installID, "ok": true, "message": "Success", "package": "example.app"])
        drops.receive(["type": "clipboardApkInstallResult", "id": installID, "ok": true])
        precondition(results.filter { $0.0 }.count == 1 && results.last!.1)
        results.removeAll()
        precondition(drops.installApk(dropURL)); drops.disconnected()
        precondition(results.filter { $0.0 }.count == 1 && !results.last!.1)
        print("Mac clipboard and file-drop tests passed")
    }
}
