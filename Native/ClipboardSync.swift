import CryptoKit
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

/// Owned only by the background BLE receiver. Received files use a bounded private cache.
final class ClipboardSync {
    static let enabledKey = "DroidMirror.clipboard.enabled"
    weak var controller: BLEController?
    private var timer: Timer?
    private let pasteboard: NSPasteboard
    private var changeCount: Int
    private var ready = false
    private var retryAttempts = 0
    private var retryWork: DispatchWorkItem?
    private struct Transfer {
        var id: String
        var name: String
        var size: Int
        var data: Data
        var offset = 0
        var window = 1
        var chunksSinceAck = 0
        let startedAt = Date()
        var changedAt = Date()
    }
    private var preparing: (id: String, change: Int, started: TimeInterval)?
    private let preparationQueue = DispatchQueue(label: "app.droidmirror.clipboard-prepare", qos: .userInitiated)
    private var incoming: Transfer?
    private var outgoing: Transfer?
    private let fileCache: URL
    private let retryDelay: (Int) -> TimeInterval

    private var timeline = [String]()
    var diagnostics: String { timeline.joined(separator: " | ") }
    private func trace(_ phase: String) {
        timeline.append("\(Int(Date().timeIntervalSince1970 * 1000)):\(phase)")
        if timeline.count > 12 { timeline.removeFirst() }
    }
    var canInstallApk: Bool { enabled && ready && controller?.authenticated == true && controller?.supportsApkInstall == true }
    var installStatus: ((_ message: String, _ finished: Bool, _ succeeded: Bool) -> Void)?
    private var installing = false
    private var installWait: (id: String, since: Date)?
    private func finishInstall(_ message: String, success: Bool = false) {
        guard installing else { return }
        installing = false; installWait = nil
        installStatus?(message, true, success)
    }
    @discardableResult func installApk(_ url: URL) -> Bool {
        guard canInstallApk else {
            installStatus?("Update the DroidMirror companion and make sure Shizuku is running", true, false); return false
        }
        guard !installing, preparing == nil, incoming == nil, outgoing == nil else {
            installStatus?("A file transfer is already active. Try again when it finishes.", true, false); return false
        }
        guard ApkInstallPolicy.nameAllowed(url.lastPathComponent) else {
            installStatus?("Choose a readable .apk file smaller than 256 MiB", true, false); return false
        }
        installing = true; changeCount = pasteboard.changeCount
        let id = UUID().uuidString
        preparing = (id, changeCount, ProcessInfo.processInfo.systemUptime)
        status = "Preparing APK…"
        controller?.prepareClipboardFile(id) { [weak self] in
            guard let self, self.preparing?.id == id else { return }
            self.preparationQueue.async { [weak self] in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                var snapshot: Data?
                do {
                    let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true,
                          let size = info.fileSize, ApkInstallPolicy.allowed(size) else { throw CocoaError(.fileReadCorruptFile) }
                    // A private copy freezes the bytes before mapping and hashing them.
                    let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: copy) }
                    try FileManager.default.copyItem(at: url, to: copy)
                    let data = try Data(contentsOf: copy, options: .alwaysMapped)
                    if data.count == size { snapshot = data }
                } catch {}
                let result = snapshot
                DispatchQueue.main.async { self?.finishPreparation(id, data: result, name: url.lastPathComponent, error: "Choose a readable .apk file smaller than 256 MiB") }
            }
        }
        return true
    }
    var dropStatus: ((String) -> Void)?
    private var dropping = false
    private(set) var status = "Clipboard mirroring off" {
        didSet { if dropping { dropStatus?(status) }; if installing { installStatus?(status, false, false) } }
    }

    /// Explicit drops snapshot a URL without replacing the user's pasteboard.
    @discardableResult func sendDroppedFile(_ url: URL) -> Bool {
        guard enabled, ready, controller?.authenticated == true,
              controller?.supportsClipboardDownloads == true else {
            dropStatus?("Enable clipboard sync, unlock the phone, and connect an updated companion."); return false
        }
        guard !installing, preparing == nil, outgoing == nil, incoming == nil else {
            dropStatus?("A file transfer is already active. Try again when it finishes."); return false
        }
        dropping = true
        changeCount = pasteboard.changeCount
        let id = UUID().uuidString
        preparing = (id, changeCount, ProcessInfo.processInfo.systemUptime)
        status = "Preparing file for Downloads…"
        controller?.prepareClipboardFile(id) { [weak self] in
            guard let self, self.preparing?.id == id else { return }
            self.preparationQueue.async { [weak self] in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try? Self.readClipboardFile(url)
                DispatchQueue.main.async { self?.finishPreparation(id, data: data, name: url.lastPathComponent) }
            }
        }
        return true
    }

    init(pasteboard: NSPasteboard = .general, fileCache: URL? = nil, retryDelay: @escaping (Int) -> TimeInterval = { $0 == 1 ? 1 : 3 }) {
        self.retryDelay = retryDelay
        self.fileCache = fileCache ?? FileManager.default.temporaryDirectory.appendingPathComponent("DroidMirror-Clipboard", isDirectory: true)
        self.pasteboard = pasteboard
        self.changeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private var fileWindow: Int { controller?.supportsClipboardBulk == true ? ClipboardFilePolicy.bulkWindow : ClipboardFilePolicy.window }
    private var enabled: Bool { NotificationRuntime.preferences.bool(forKey: Self.enabledKey) }
    func connected() {
        ready = false; resetFiles()
        changeCount = pasteboard.changeCount
        guard enabled else { status = "Clipboard mirroring off"; return }
        guard controller?.supportsClipboard == true else { status = "Clipboard needs an updated Android app"; return }
        status = "Starting clipboard mirroring…"
        controller?.send(["type": "clipboardSubscribe", "enabled": true, "files": controller?.supportsClipboardFiles == true, "bulk": controller?.supportsClipboardBulk == true ? 1 : 0, "race": 1])
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
        case "clipboardApkInstallResult":
            guard installing, let id = event["id"] as? String,
                  id == outgoing?.id || id == installWait?.id else { return }
            outgoing = nil
            finishInstall(event["message"] as? String ?? "APK installation failed", success: event["ok"] as? Bool == true)
        case "clipboardStatus":
            let available = event["status"] as? String == "ready"
            if available && !ready { changeCount = pasteboard.changeCount }
            if !available { resetFiles() }
            ready = available
            controller?.setClipboardBulkReady(available)
            if available { status = "Clipboard mirroring ready" }
            else if event["status"] as? String == "locked" { status = "Clipboard paused while phone is locked" }
            else { status = "Clipboard waiting for Shizuku" }
        case "clipboardFileRaceProgress":
            if ready, incoming?.id == event["id"] as? String { incoming?.changedAt = Date() }
        case "clipboardBulkFailed": bulkFailed()
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
        if let wait = installWait, Date().timeIntervalSince(wait.since) > 150 { resetFiles(notify: true) }
        if let incoming, Date().timeIntervalSince(incoming.changedAt) > 60 { resetFiles(notify: true) }
        if let outgoing, Date().timeIntervalSince(outgoing.changedAt) > 60 { resetFiles(notify: true) }
        guard ready, pasteboard.changeCount != changeCount else { return }
        resetFiles(notify: true)
        changeCount = pasteboard.changeCount
        // Respect password-manager and transient clipboard markers.
        let excluded = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        guard !excluded.contains(where: { pasteboard.types?.contains(NSPasteboard.PasteboardType($0)) == true }) else { return }
        if pasteboard.types?.contains(.fileURL) == true {
            prepareFile(image: false); return
        }
        if pasteboard.types?.contains(.png) == true || pasteboard.types?.contains(.tiff) == true {
            prepareFile(image: true); return
        }
        guard let text = pasteboard.string(forType: .string), ClipboardTextPolicy.allowed(text) else { return }
        if controller?.send(["type": "clipboardSet", "text": text]) != true { status = "Clipboard connection interrupted" }
    }
    private func resetFiles(notify: Bool = false) {
        retryWork?.cancel(); retryWork = nil; retryAttempts = 0
        if let preparing { controller?.finishClipboardPreparation(preparing.id, cancelled: true); self.preparing = nil }
        if notify {
            if let wait = installWait { controller?.sendClipboardFile(["type": "clipboardFileCancel", "id": wait.id]) }
            for transfer in [incoming, outgoing].compactMap({ $0 }) {
                controller?.sendClipboardFile(["type": "clipboardFileCancel", "id": transfer.id])
            }
        }
        if dropping { dropStatus?("File transfer ended before completion."); dropping = false }
        finishInstall("APK installation cancelled or connection interrupted")
        incoming = nil; outgoing = nil
    }
    private func prepareFile(image: Bool) {
        guard controller?.supportsClipboardFiles == true else { status = "File clipboard needs an updated Android app"; return }
        let id = UUID().uuidString
        preparing = (id, changeCount, ProcessInfo.processInfo.systemUptime)
        status = "Preparing clipboard file…"
        trace("detected \(id.prefix(8))")
        NSLog("DroidMirror clipboard preparation detected id=%@", id)
        controller?.prepareClipboardFile(id) { [weak self] in
            guard let self, self.preparing?.id == id else { return }
            guard self.enabled, self.ready, self.controller?.authenticated == true, self.pasteboard.changeCount == self.preparing?.change else {
                self.finishPreparation(id, data: nil, name: "", error: "Clipboard changed"); return
            }
            self.trace("prepare-ready \(id.prefix(8))")
            if image {
                self.trace("read-png-start")
                if let png = self.pasteboard.data(forType: .png) {
                    self.trace("read-png-end")
                    self.finishPreparation(id, data: png.isEmpty ? nil : png, name: "Clipboard Image.png"); return
                }
                self.trace("read-tiff-start")
                guard let tiff = self.pasteboard.data(forType: .tiff) else {
                    self.finishPreparation(id, data: nil, name: "", error: "Clipboard image could not be read"); return
                }
                self.trace("read-tiff-end; encoding")
                self.preparationQueue.async { [weak self] in
                    let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                    DispatchQueue.main.async { self?.finishPreparation(id, data: data, name: "Clipboard Image.png") }
                }
            } else {
                guard let urls = self.pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                      urls.count == 1, let url = urls.first else {
                    self.finishPreparation(id, data: nil, name: "", error: "Copy one file at a time"); return
                }
                self.preparationQueue.async { [weak self] in
                    let data = try? Self.readClipboardFile(url)
                    DispatchQueue.main.async { self?.finishPreparation(id, data: data, name: url.lastPathComponent) }
                }
            }
        }
    }
    private static func readClipboardFile(_ url: URL) throws -> Data {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, ClipboardFilePolicy.nameAllowed(url.lastPathComponent),
              let size = info.fileSize, ClipboardFilePolicy.allowed(size) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var data = Data()
        while data.count < ClipboardFilePolicy.limit {
            guard let chunk = try file.read(upToCount: min(65_536, ClipboardFilePolicy.limit - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count == size, ClipboardFilePolicy.allowed(data.count) else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
    private func finishPreparation(_ id: String, data: Data?, name: String, error: String = "Clipboard files must be less than 5 MB and readable") {
        guard let preparing, preparing.id == id else { return }
        self.preparing = nil
        trace("snapshot-ready \(id.prefix(8))")
        let valid = enabled && ready && controller?.authenticated == true && pasteboard.changeCount == preparing.change
        guard valid, let data, (installing ? ApkInstallPolicy.allowed(data.count) && ApkInstallPolicy.nameAllowed(name) : ClipboardFilePolicy.allowed(data.count) && ClipboardFilePolicy.nameAllowed(name)) else {
            controller?.finishClipboardPreparation(id, cancelled: true); status = error; dropping = false; finishInstall(error); return
        }
        NSLog("DroidMirror clipboard preparation ready id=%@ bytes=%d elapsedMs=%d", id, data.count,
              Int((ProcessInfo.processInfo.systemUptime - preparing.started) * 1000))
        controller?.finishClipboardPreparation(id, cancelled: false)
        sendFileData(data, name: name, id: id)
    }
    func canRetryFile(_ id: String) -> Bool {
        enabled && ready && controller?.authenticated == true && pasteboard.changeCount == changeCount &&
            (outgoing?.id == id || incoming?.id == id)
    }
    private func bulkFailed() {
        if installing { resetFiles(notify: true); return }
        incoming = nil
        guard retryWork == nil else { return }
        guard let transfer = outgoing, retryAttempts < 2, enabled, ready,
              controller?.authenticated == true, pasteboard.changeCount == changeCount else {
            resetFiles(); status = "Clipboard file transfer failed"; return
        }
        retryAttempts += 1
        status = "Retrying clipboard file…"
        let id = transfer.id
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWork = nil
            guard self.outgoing?.id == id, self.enabled, self.ready,
                  self.controller?.authenticated == true, self.pasteboard.changeCount == self.changeCount else {
                self.resetFiles(); return
            }
            self.sendFileData(transfer.data, name: transfer.name)
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay(retryAttempts), execute: work)
    }
    private func fileSendFailed() {
        if controller?.supportsClipboardBulk == true { bulkFailed() } else { resetFiles() }
    }
    private func sendFileData(_ data: Data, name: String, id: String = UUID().uuidString) {
        let transfer = Transfer(id: id, name: name, size: data.count, data: data)
        outgoing = transfer
        trace("bulk-begin \(transfer.id.prefix(8)) bytes=\(data.count)")
        NSLog("DroidMirror clipboard send begin bytes=%d bulk=%d window=%d", data.count, controller?.supportsClipboardBulk == true ? 1 : 0, fileWindow)
        var begin: [String: Any] = ["type": "clipboardFileBegin", "id": transfer.id, "name": transfer.name, "size": transfer.size, "window": fileWindow, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        if installing { begin["destination"] = "install" }
        else if dropping { begin["destination"] = "downloads" }
        if controller?.sendClipboardFile(begin) != true { fileSendFailed(); return }
        status = installing ? "Sending APK…" : dropping ? "Sending file to Downloads…" : "Sending clipboard file…"
    }
    private func receiveFile(_ event: [String: Any]) {
        guard let id = event["id"] as? String, UUID(uuidString: id) != nil else { return }
        let type = event["type"] as? String
        if type == "clipboardFileCancel" {
            if preparing?.id == id { preparing = nil; controller?.finishClipboardPreparation(id, cancelled: true) }
            if incoming?.id == id { incoming = nil }
            if outgoing?.id == id { outgoing = nil }
            finishInstall("APK transfer cancelled by phone")
            status = "Clipboard file transfer cancelled"; dropping = false
            return
        }
        guard pasteboard.changeCount == changeCount else { resetFiles(notify: true); controller?.sendClipboardFile(["type": "clipboardFileCancel", "id": id]); return }
        switch type {
        case "clipboardFileBegin":
            guard let size = event["size"] as? Int, ClipboardFilePolicy.allowed(size),
                  let name = event["name"] as? String, ClipboardFilePolicy.nameAllowed(name) else {
                controller?.sendClipboardFile(["type": "clipboardFileCancel", "id": id]); return
            }
            resetFiles(notify: true)
            incoming = Transfer(id: id, name: name, size: size, data: Data())
            incoming!.window = max(1, min(event["window"] as? Int ?? 1, fileWindow))
            status = "Receiving clipboard file…"
            if size == 0 { completeFile() } else { controller?.sendClipboardFile(["type": "clipboardFileAck", "id": id, "offset": 0, "window": incoming!.window]) }
        case "clipboardFileChunk":
            guard incoming?.id == id else { return }
            guard event["offset"] as? Int == incoming!.data.count,
                  let encoded = event["data"] as? String, encoded.utf8.count <= 4096,
                  let chunk = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")), !chunk.isEmpty,
                  chunk.count <= ClipboardFilePolicy.chunk, incoming!.data.count + chunk.count <= incoming!.size else { resetFiles(notify: true); return }
            incoming!.data.append(chunk); incoming!.changedAt = Date()
            incoming!.chunksSinceAck += 1
            if incoming!.data.count == incoming!.size { completeFile() }
            else if incoming!.chunksSinceAck == incoming!.window {
                incoming!.chunksSinceAck = 0
                controller?.sendClipboardFile(["type": "clipboardFileAck", "id": id, "offset": incoming!.data.count])
            }
        case "clipboardFileAck":
            guard var transfer = outgoing, transfer.id == id else { return }
            guard event["offset"] as? Int == transfer.offset else { resetFiles(notify: true); return }
            if installing { status = "Sending APK: \(transfer.offset * 100 / max(1, transfer.size))%" }
            if dropping { status = "Sending to Downloads: \(transfer.offset * 100 / max(1, transfer.size))%" }
            NSLog("DroidMirror clipboard acknowledged bytes=%d elapsedMs=%d", transfer.offset, Int(Date().timeIntervalSince(transfer.startedAt) * 1000))
            if installing && transfer.offset == transfer.size {
                outgoing = nil; installWait = (id, Date()); status = "Installing APK on phone…"; return
            }
            if transfer.offset == transfer.size { trace("complete \(id.prefix(8))"); outgoing = nil; retryAttempts = 0; status = dropping ? "Saved to phone Downloads" : "Clipboard mirroring ready"; dropping = false; return }
            if transfer.offset == 0 {
                trace("first-ack \(id.prefix(8))")
                transfer.window = max(1, min(event["window"] as? Int ?? 1, fileWindow))
            }
            // Bound queued bulk data and wait for one cumulative acknowledgment.
            // A peer without window support keeps the original one-chunk protocol.
            for _ in 0..<transfer.window {
                let end = min(transfer.offset + ClipboardFilePolicy.chunk, transfer.size)
                let chunk = transfer.data.subdata(in: transfer.offset..<end)
                guard controller?.sendClipboardFile(["type": "clipboardFileChunk", "id": id, "offset": transfer.offset, "data": chunk.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")]) == true else { fileSendFailed(); return }
                transfer.offset = end
                if end == transfer.size { break }
            }
            transfer.changedAt = Date(); outgoing = transfer
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
            let item = NSPasteboardItem()
            item.setString(file.absoluteString, forType: .fileURL)
            // Publish both representations on one item, so image editors can paste pixels
            // while Finder can still paste the original file.
            if let bitmap = NSBitmapImageRep(data: transfer.data),
               let png = bitmap.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
                if let tiff = bitmap.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            }
            guard pasteboard.changeCount == changeCount else { throw CocoaError(.userCancelled) }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
            changeCount = pasteboard.changeCount
            controller?.sendClipboardFile(["type": "clipboardFileAck", "id": transfer.id, "offset": transfer.size])
            incoming = nil; status = "Clipboard mirroring ready"
        } catch {
            if let directory { try? manager.removeItem(at: directory) }
            resetFiles(notify: true); status = "Clipboard file could not be received"
        }
    }
    func stop() { timer?.invalidate(); timer = nil; ready = false; resetFiles(); controller?.setClipboardBulkReady(false) }
}
