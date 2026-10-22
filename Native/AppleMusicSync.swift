import AppKit
import ImageIO
import CryptoKit

/// Apple Music only. Scripts run serially away from the UI and never launch Music.
protocol AppleMusicAccess: AnyObject {
    var snapshot: MediaSnapshot? { get }
    var status: String { get }
    func clear()
    func poll(_ completion: @escaping ([String: Any]) -> Void)
    func command(_ event: [String: Any])
}

final class AppleMusicSync: AppleMusicAccess {
    static let snapshotScript = """
    if application id "com.apple.Music" is not running then return {}
    tell application id "com.apple.Music"
        if player state is stopped then return {}
        set coverData to ""
        try
            set coverData to raw data of artwork 1 of current track
        end try
        return {persistent ID of current track, name of current track, artist of current track, album of current track, (player state is playing), duration of current track, player position, coverData, shuffle enabled, (song repeat as string)}
    end tell
    """

    private let queue = DispatchQueue(label: "app.droidmirror.apple-music")
    private var busy = false
    private let catalogArtwork = MusicCatalogArtwork()
    private let queueAccess: MusicQueueAccess
    private var playbackQueue: MusicPlaybackQueue?
    private var nativePlayback = false
    init(queueAccess: MusicQueueAccess = LocalMusicQueueAccess()) { self.queueAccess = queueAccess }
    private(set) var snapshot: MediaSnapshot?
    private(set) var status = "Waiting for Apple Music"
    private let lock = NSLock()
    private var generation = 0
    private var epoch: Int { lock.withLock { generation } }

    func clear() { lock.withLock { generation += 1 }; queueAccess.cancel(); catalogArtwork.clear(); snapshot = nil; playbackQueue = nil; nativePlayback = false }

    func poll(_ completion: @escaping ([String: Any]) -> Void) {
        guard !busy else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty == false else {
            snapshot = nil; playbackQueue = nil; status = "Apple Music is closed"; completion(["active": false]); return
        }
        busy = true
        let epoch = self.epoch
        queue.async {
            // Resolve Music independently of global Now Playing, which our phone
            // proxy may currently own. A stuck AppleScript cannot hide controls.
            let raw = self.queueAccess.read()
            if let raw, var value = MusicPlaybackQueue.nativeSnapshot(raw),
               let playbackQueue = MusicPlaybackQueue(raw, snapshot: value) {
                value["queueRevision"] = playbackQueue.revision
                value["_queue"] = playbackQueue.event
                if let artwork = raw["artwork"] as? String, let data = Data(base64Encoded: artwork),
                   let cover = MediaArtwork.encode(data) { value["artwork"] = cover }
                if value["artwork"] == nil, let cover = self.catalogArtwork.cover(for: raw["artworkCatalogID"]) {
                    value["artwork"] = cover
                }
                self.publish(value, queue: playbackQueue, native: true, epoch: epoch, status: "Apple Music connected (native)", completion: completion)
                return
            }
            let source = "with timeout of 2 seconds\n" + Self.snapshotScript + "\nend timeout"
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let denied = (error?[NSAppleScript.errorNumber] as? Int) == -1743
            var value: [String: Any] = ["active": false]
            if error == nil, let result, result.numberOfItems == 10,
               let id = result.atIndex(1)?.stringValue, !id.isEmpty {
                value = ["active": true, "id": id,
                    "title": String((result.atIndex(2)?.stringValue ?? "").prefix(240)),
                    "artist": String((result.atIndex(3)?.stringValue ?? "").prefix(240)),
                    "album": String((result.atIndex(4)?.stringValue ?? "").prefix(240)),
                    "playing": result.atIndex(5)?.booleanValue ?? false,
                    "duration": max(0, result.atIndex(6)?.doubleValue ?? 0),
                    "position": max(0, result.atIndex(7)?.doubleValue ?? 0),
                    "actions": ["play", "pause", "next", "previous", "seek", "shuffle", "repeat"],
                    "shuffle": result.atIndex(9)?.booleanValue ?? false,
                    "repeat": result.atIndex(10)?.stringValue ?? "off"]
            }
            if value["active"] as? Bool == true, let data = result?.atIndex(8)?.data,
               let cover = MediaArtwork.encode(data) {
                value["artwork"] = cover
            }
            var playbackQueue: MusicPlaybackQueue?
            if value["active"] as? Bool == true, epoch == self.epoch, let raw {
                playbackQueue = MusicPlaybackQueue(raw, snapshot: value)
                if let playbackQueue {
                    value["queueRevision"] = playbackQueue.revision
                    value["actions"] = (value["actions"] as? [String] ?? []) + ["queue"]
                    value["_queue"] = playbackQueue.event
                }
            }
            let message = denied ? "Allow Music in System Settings → Privacy & Security → Automation" :
                (error != nil ? "Apple Music metadata unavailable (\(error?[NSAppleScript.errorNumber] ?? "unknown"))" : "Apple Music connected")
            self.publish(value, queue: playbackQueue, native: false, epoch: epoch, status: message, completion: completion)
        }
    }
    private func publish(_ value: [String: Any], queue: MusicPlaybackQueue?, native: Bool, epoch: Int,
                         status: String, completion: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            self.busy = false
            guard epoch == self.epoch else { return }
            self.playbackQueue = queue; self.nativePlayback = native
            self.snapshot = MediaSnapshot(value); self.status = status
            completion(value)
        }
    }

    func command(_ event: [String: Any]) {
        guard let snapshot, snapshot.fresh(),
              MediaSnapshot.validCommand(event, target: snapshot.id, actions: snapshot.actions),
              snapshot.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return }
        if event["action"] as? String == "queue" {
            guard let request = playbackQueue?.selection(event) else { return }
            let epoch = self.epoch
            queue.async {
                guard self.epoch == epoch, snapshot.fresh() else { return }
                self.queueAccess.select(request)
            }
            return
        }
        if nativePlayback {
            guard let request = playbackQueue?.control(event) else { return }
            let epoch = self.epoch
            queue.async {
                guard self.epoch == epoch, snapshot.fresh() else { return }
                self.queueAccess.select(request)
            }
            return
        }
        let operation: String
        switch event["action"] as? String {
        case "play": operation = "play"
        case "pause": operation = "pause"
        case "next": operation = "next track"
        case "previous": operation = "previous track"
        case "shuffle":
            guard let enabled = event["enabled"] as? Bool else { return }
            operation = "set shuffle enabled to \(enabled ? "true" : "false")"
        case "repeat":
            guard let mode = event["mode"] as? String, ["off", "one", "all"].contains(mode) else { return }
            operation = "set song repeat to \(mode)"
        case "seek":
            guard let position = event["position"] as? Double else { return }
            operation = "set player position to \(min(snapshot.duration > 0 ? snapshot.duration : 604800, position))"
        default: return
        }
        // Only fixed commands, a validated hex identifier and a finite number
        // enter the script. Recheck the track in Music before applying controls.
        let source = """
        if application id "com.apple.Music" is not running then return
        tell application id "com.apple.Music"
            if player state is stopped then return
            if persistent ID of current track is not "\(snapshot.id)" then return
            \(operation)
        end tell
        """
        let epoch = self.epoch
        queue.async {
            guard self.epoch == epoch, snapshot.fresh() else { return }
            _ = NSAppleScript(source: source)?.executeAndReturnError(nil)
        }
    }
}

/// Covers travel separately in bounded, pull-based chunks on authenticated BLE.
/// Missing or invalid artwork always clears the previous track's cover.
enum MediaArtwork {
    static let maximumBytes = 65536
    static func encode(_ data: Data) -> String? {
        guard data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        for size in [512, 384, 256] {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: size, kCGImageSourceCreateThumbnailWithTransform: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let bitmap = NSBitmapImageRep(cgImage: image)
            if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
               jpeg.count <= maximumBytes { return jpeg.base64EncodedString() }
        }
        return nil
    }
    static func decode(_ value: Any?) -> NSImage? {
        guard let text = value as? String, text.utf8.count <= 87384,
              let data = Data(base64Encoded: text), data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...512).contains(width), (1...512).contains(height) else { return nil }
        return NSImage(data: data)
    }
}

/// One cover per direction. Pulling one chunk at a time bounds BLE queue pressure.
/// The snapshot's digest binds completed bytes to a cover; old replies cannot mix tracks.
final class MediaArtworkTransfer {
    static let chunkSize = 4096
    static let maximumLength = 87384
    private var outgoing = ""
    private var outgoingID = ""
    private var incomingID = ""
    private var expectedLength = 0
    private var incoming = ""
    private var requestedAt = Date.distantPast
    private(set) var completed: String?
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func prepare(_ value: [String: Any]) -> [String: Any] {
        var event = value
        outgoing = event.removeValue(forKey: "artwork") as? String ?? ""
        if outgoing.utf8.count > Self.maximumLength { outgoing = "" }
        outgoingID = outgoing.isEmpty ? "" : Self.digest(outgoing)
        if !outgoingID.isEmpty {
            event["artworkID"] = outgoingID; event["artworkLength"] = outgoing.utf8.count
        }
        return event
    }
    func observe(_ event: [String: Any]) {
        let id = event["artworkID"] as? String ?? ""
        let length = event["artworkLength"] as? Int ?? 0
        guard id.utf8.count == 64, id.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              (1...Self.maximumLength).contains(length) else { resetIncoming(); return }
        if incomingID != id || expectedLength != length {
            resetIncoming(); incomingID = id; expectedLength = length
        }
    }
    func request(now: Date = Date()) -> [String: Any]? {
        guard !incomingID.isEmpty, completed == nil, now.timeIntervalSince(requestedAt) >= 1 else { return nil }
        requestedAt = now
        return ["type": "mediaArtworkRequest", "artworkID": incomingID, "offset": incoming.utf8.count]
    }
    func reply(_ event: [String: Any]) -> [String: Any]? {
        guard !outgoingID.isEmpty, event["artworkID"] as? String == outgoingID,
              let offset = event["offset"] as? Int, offset >= 0, offset < outgoing.utf8.count,
              offset % Self.chunkSize == 0 else { return nil }
        let bytes = Array(outgoing.utf8)
        return ["type": "mediaArtworkChunk", "artworkID": outgoingID, "offset": offset,
                "data": String(decoding: bytes[offset..<min(offset + Self.chunkSize, bytes.count)], as: UTF8.self)]
    }
    @discardableResult func receive(_ event: [String: Any]) -> Bool {
        guard !incomingID.isEmpty, completed == nil, event["artworkID"] as? String == incomingID,
              event["offset"] as? Int == incoming.utf8.count, let data = event["data"] as? String,
              data.utf8.count == min(Self.chunkSize, expectedLength - incoming.utf8.count),
              data.utf8.allSatisfy({ $0 < 128 }) else { return false }
        incoming += data; requestedAt = .distantPast
        if incoming.utf8.count == expectedLength {
            if Self.digest(incoming) == incomingID { completed = incoming }
            else { resetIncoming() }
        }
        return true
    }
    private func resetIncoming() {
        incomingID = ""; incoming = ""; expectedLength = 0; completed = nil; requestedAt = .distantPast
    }
    func clear() { resetIncoming(); outgoing = ""; outgoingID = "" }
}
