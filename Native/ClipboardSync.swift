import AppKit

struct ClipboardTextPolicy {
    static let maximumBytes = 4_096
    static func allowed(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maximumBytes else { return false }
        var bytes = text.utf8.count
        for scalar in text.unicodeScalars {
            if scalar.value < 32 { bytes += 5 }
            else if [34, 47, 92].contains(scalar.value) { bytes += 1 }
            else if [0x2028, 0x2029].contains(scalar.value) { bytes += 3 }
        }
        return bytes <= 5_500
    }
}

struct ClipboardFilePolicy {
    static let limit = 5_000_000
    static let chunk = 3072
    static func allowed(_ size: Int) -> Bool { size >= 0 && size < limit }
    static func nameAllowed(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 240
            && !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 || "/\\:".unicodeScalars.contains($0) }
    }
}

/// Owned only by the background BLE receiver. Received files use a bounded private cache.
final class ClipboardSync {
    static let enabledKey = "DroidMirror.clipboard.enabled"
    weak var controller: BLEController?
    private var timer: Timer?
    private let pasteboard: NSPasteboard
    private var changeCount: Int
    private var ready = false
    private struct Transfer {
        var id: String
        var name: String
        var size: Int
        var data: Data
        var offset = 0
        var changedAt = Date()
    }
    private var incoming: Transfer?
    private var outgoing: Transfer?
    private let fileCache: URL

    private(set) var status = "Clipboard mirroring off"

    init(pasteboard: NSPasteboard = .general, fileCache: URL? = nil) {
        self.fileCache = fileCache ?? FileManager.default.temporaryDirectory.appendingPathComponent("DroidMirror-Clipboard", isDirectory: true)
        self.pasteboard = pasteboard
        self.changeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private var enabled: Bool { NotificationRuntime.preferences.bool(forKey: Self.enabledKey) }
    func connected() {
        ready = false; resetFiles()
        changeCount = pasteboard.changeCount
        guard enabled else { status = "Clipboard mirroring off"; return }
        guard controller?.supportsClipboard == true else { status = "Clipboard needs an updated Android app"; return }
        status = "Starting clipboard mirroring…"
        controller?.send(["type": "clipboardSubscribe", "enabled": true, "files": controller?.supportsClipboardFiles == true])
    }
    func disconnected() {
        ready = false; resetFiles(); changeCount = pasteboard.changeCount
        status = enabled ? "Clipboard waiting for Bluetooth" : "Clipboard mirroring off"
    }
    func configure() {
        if enabled { connected() }
        else {
            ready = false; resetFiles(); status = "Clipboard mirroring off"
            if controller?.supportsClipboard == true { controller?.send(["type": "clipboardSubscribe", "enabled": false]) }
        }
    }
    func receive(_ event: [String: Any]) {
        guard enabled, controller?.authenticated == true else { return }
        switch event["type"] as? String {
        case "clipboardStatus":
            let available = event["status"] as? String == "ready"
            if available && !ready { changeCount = pasteboard.changeCount }
            if !available { resetFiles() }
            ready = available
            if available { status = "Clipboard mirroring ready" }
            else if event["status"] as? String == "locked" { status = "Clipboard paused while phone is locked" }
            else { status = "Clipboard waiting for Shizuku" }
        case "clipboardFileBegin", "clipboardFileChunk", "clipboardFileAck", "clipboardFileCancel":
            guard ready, controller?.supportsClipboardFiles == true else { return }
            receiveFile(event)
        case "clipboard":
            guard ready, let text = event["text"] as? String, ClipboardTextPolicy.allowed(text) else { return }
            // Prefer a local copy made since the last poll over an arriving phone copy.
            guard pasteboard.changeCount == changeCount else { return }
            resetFiles(notify: true)
            if pasteboard.string(forType: .string) != text {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            changeCount = pasteboard.changeCount
        case "clipboardResult":
            status = event["success"] as? Bool == true ? "Clipboard mirroring ready" : "Clipboard not applied; unlock phone and check Shizuku"
        default: break
        }
    }
    func poll() {
        guard enabled, controller?.authenticated == true else {
            ready = false; resetFiles(); changeCount = pasteboard.changeCount
            status = enabled ? "Clipboard waiting for Bluetooth" : "Clipboard mirroring off"
            return
        }
        if let incoming, Date().timeIntervalSince(incoming.changedAt) > 60 { resetFiles(notify: true) }
        if let outgoing, Date().timeIntervalSince(outgoing.changedAt) > 60 { resetFiles(notify: true) }
        guard ready, pasteboard.changeCount != changeCount else { return }
        resetFiles(notify: true)
        changeCount = pasteboard.changeCount
        // Respect password-manager and transient clipboard markers.
        let excluded = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        guard !excluded.contains(where: { pasteboard.types?.contains(NSPasteboard.PasteboardType($0)) == true }) else { return }
        if pasteboard.types?.contains(.fileURL) == true {
            sendFile(); return
        }
        guard let text = pasteboard.string(forType: .string), ClipboardTextPolicy.allowed(text) else { return }
        if controller?.send(["type": "clipboardSet", "text": text]) != true { status = "Clipboard connection interrupted" }
    }
    private func resetFiles(notify: Bool = false) {
        if notify {
            for transfer in [incoming, outgoing].compactMap({ $0 }) {
                controller?.send(["type": "clipboardFileCancel", "id": transfer.id])
            }
        }
        incoming = nil; outgoing = nil
    }
    private func sendFile() {
        guard controller?.supportsClipboardFiles == true else { status = "File clipboard needs an updated Android app"; return }
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == 1, let url = urls.first else { status = "Copy one file at a time"; return }
        do {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  ClipboardFilePolicy.nameAllowed(url.lastPathComponent) else { status = "Clipboard file is unsupported"; return }
            guard let size = info.fileSize, ClipboardFilePolicy.allowed(size) else { status = "Clipboard files must be less than 5 MB"; return }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            // Read at most the limit even if a source grows after its size was checked.
            var data = Data()
            while data.count < ClipboardFilePolicy.limit {
                guard let chunk = try file.read(upToCount: min(65_536, ClipboardFilePolicy.limit - data.count)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard data.count == size, ClipboardFilePolicy.allowed(data.count) else { status = "Clipboard file changed or exceeds the size limit"; return }
            let transfer = Transfer(id: UUID().uuidString, name: url.lastPathComponent, size: size, data: data)
            outgoing = transfer
            if controller?.send(["type": "clipboardFileBegin", "id": transfer.id, "name": transfer.name, "size": size]) != true { resetFiles(); return }
            status = "Sending clipboard file…"
        } catch { status = "Clipboard file could not be read" }
    }
    private func receiveFile(_ event: [String: Any]) {
        guard let id = event["id"] as? String, UUID(uuidString: id) != nil else { return }
        let type = event["type"] as? String
        if type == "clipboardFileCancel" {
            if incoming?.id == id { incoming = nil }
            if outgoing?.id == id { outgoing = nil }
            status = "Clipboard file transfer cancelled"
            return
        }
        guard pasteboard.changeCount == changeCount else { resetFiles(notify: true); controller?.send(["type": "clipboardFileCancel", "id": id]); return }
        switch type {
        case "clipboardFileBegin":
            guard let size = event["size"] as? Int, ClipboardFilePolicy.allowed(size),
                  let name = event["name"] as? String, ClipboardFilePolicy.nameAllowed(name) else {
                controller?.send(["type": "clipboardFileCancel", "id": id]); return
            }
            resetFiles(notify: true)
            incoming = Transfer(id: id, name: name, size: size, data: Data())
            status = "Receiving clipboard file…"
            if size == 0 { completeFile() } else { controller?.send(["type": "clipboardFileAck", "id": id, "offset": 0]) }
        case "clipboardFileChunk":
            guard incoming?.id == id else { return }
            guard event["offset"] as? Int == incoming!.data.count,
                  let encoded = event["data"] as? String, encoded.utf8.count <= 4096,
                  let chunk = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")), !chunk.isEmpty,
                  chunk.count <= ClipboardFilePolicy.chunk, incoming!.data.count + chunk.count <= incoming!.size else { resetFiles(notify: true); return }
            incoming!.data.append(chunk); incoming!.changedAt = Date()
            if incoming!.data.count == incoming!.size { completeFile() }
            else { controller?.send(["type": "clipboardFileAck", "id": id, "offset": incoming!.data.count]) }
        case "clipboardFileAck":
            guard var transfer = outgoing, transfer.id == id else { return }
            guard event["offset"] as? Int == transfer.offset else { resetFiles(notify: true); return }
            if transfer.offset == transfer.size { outgoing = nil; status = "Clipboard mirroring ready"; return }
            let end = min(transfer.offset + ClipboardFilePolicy.chunk, transfer.size)
            let chunk = transfer.data.subdata(in: transfer.offset..<end)
            guard controller?.send(["type": "clipboardFileChunk", "id": id, "offset": transfer.offset, "data": chunk.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")]) == true else { resetFiles(); return }
            transfer.offset = end; transfer.changedAt = Date(); outgoing = transfer
        default: break
        }
    }
    private func completeFile() {
        guard let transfer = incoming else { return }
        let manager = FileManager.default
        var directory: URL?
        do {
            try manager.createDirectory(at: fileCache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let previous = try manager.contentsOfDirectory(at: fileCache, includingPropertiesForKeys: [.creationDateKey])
                .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            for old in previous.prefix(max(0, previous.count - 9)) { try? manager.removeItem(at: old) }
            let target = fileCache.appendingPathComponent(UUID().uuidString, isDirectory: true)
            directory = target
            try manager.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = target.appendingPathComponent(transfer.name)
            try transfer.data.write(to: file, options: .atomic)
            guard pasteboard.changeCount == changeCount else { throw CocoaError(.userCancelled) }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([file as NSURL]) else { throw CocoaError(.fileWriteUnknown) }
            changeCount = pasteboard.changeCount
            controller?.send(["type": "clipboardFileAck", "id": transfer.id, "offset": transfer.size])
            incoming = nil; status = "Clipboard mirroring ready"
        } catch {
            if let directory { try? manager.removeItem(at: directory) }
            resetFiles(notify: true); status = "Clipboard file could not be received"
        }
    }
    func stop() { timer?.invalidate(); timer = nil; ready = false; resetFiles() }
}
