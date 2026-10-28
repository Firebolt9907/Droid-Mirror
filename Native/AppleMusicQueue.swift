import Foundation
import CryptoKit

/// Stable native identities stay on the Mac. Android receives bounded descriptions
/// and revision-scoped numeric IDs understood by MediaSession and watch clients.
struct MusicPlaybackQueue {
    struct Item {
        let key: String
        let id: Int64
        let title: String
        let artist: String
    }
    let owner: Int
    let queueID: String
    let current: String
    let keys: [String]
    let revision: String
    let items: [Item]
    let trackID: String
    let receivedAt: Date

    init?(_ raw: [String: Any], snapshot: [String: Any], now: Date = Date()) {
        guard raw["available"] as? Bool == true, let owner = raw["owner"] as? Int, owner > 0,
              let queueID = raw["queueID"] as? String, !queueID.isEmpty, queueID.utf8.count <= 512,
              let current = raw["current"] as? String,
              let entries = raw["entries"] as? [[String: Any]], (1...32).contains(entries.count),
              let trackID = snapshot["id"] as? String,
              entries.first?["key"] as? String == current,
              entries.first?["title"] as? String == snapshot["title"] as? String,
              entries.first?["artist"] as? String == snapshot["artist"] as? String else { return nil }
        let keys = entries.compactMap { $0["key"] as? String }
        guard keys.count == entries.count, Set(keys).count == keys.count,
              keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else { return nil }
        let identity: [String: Any] = ["owner": owner, "queueID": queueID, "current": current, "keys": keys, "descriptions": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]) else { return nil }
        let revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var items = [Item]()
        for entry in entries {
            guard let key = entry["key"] as? String, let title = entry["title"] as? String,
                  let artist = entry["artist"] as? String else { return nil }
            let hash = SHA256.hash(data: Data((revision + ":" + key).utf8))
            let id = hash.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } & UInt64(Int64.max)
            items.append(Item(key: key, id: Int64(id), title: String(title.prefix(80)), artist: String(artist.prefix(80))))
        }
        guard Set(items.map(\.id)).count == items.count else { return nil }
        self.owner = owner; self.queueID = queueID; self.current = current; self.keys = keys
        self.revision = revision; self.items = items; self.trackID = trackID; self.receivedAt = now
    }
    static func nativeSnapshot(_ raw: [String: Any]) -> [String: Any]? {
        guard raw["available"] as? Bool == true, let owner = raw["owner"] as? Int, owner > 0,
              let current = raw["current"] as? String, !current.isEmpty,
              var value = raw["playback"] as? [String: Any] else { return nil }
        value["id"] = "MR" + MediaArtworkTransfer.digest("\(owner):\(current)")
        value["active"] = true
        guard MediaSnapshot(value) != nil else { return nil }
        return value
    }
    func control(_ event: [String: Any], now: Date = Date()) -> [String: Any]? {
        guard now >= receivedAt, now.timeIntervalSince(receivedAt) < 8,
              event["id"] as? String == trackID, let action = event["action"] as? String,
              ["play", "pause", "next", "previous", "seek", "shuffle", "repeat"].contains(action) else { return nil }
        var request: [String: Any] = ["action": "control", "control": action, "owner": owner, "queueID": queueID,
            "current": current, "keys": keys, "target": current, "expires": receivedAt.addingTimeInterval(8).timeIntervalSince1970]
        for key in ["position", "enabled", "mode"] { request[key] = event[key] }
        return request
    }
    var event: [String: Any] {
        var entries = items.map { ["queueItemId": $0.id, "title": $0.title, "artist": $0.artist] as [String: Any] }
        while entries.count > 1, (try? JSONSerialization.data(withJSONObject: entries).count) ?? Int.max > 4400 { entries.removeLast() }
        return ["type": "mediaQueue", "id": trackID, "revision": revision,
                "currentItemId": items[0].id, "items": entries]
    }
    func selection(_ event: [String: Any], now: Date = Date()) -> [String: Any]? {
        guard now >= receivedAt, now.timeIntervalSince(receivedAt) < 8,
              event["id"] as? String == trackID, event["queueRevision"] as? String == revision,
              let id = event["queueItemId"] as? Int64,
              let advertised = self.event["items"] as? [[String: Any]],
              advertised.contains(where: { $0["queueItemId"] as? Int64 == id }),
              let target = items.first(where: { $0.id == id }) else { return nil }
        return ["action": "select", "owner": owner, "queueID": queueID, "current": current,
                "keys": keys, "target": target.key, "expires": receivedAt.addingTimeInterval(8).timeIntervalSince1970]
    }
}

protocol MusicQueueAccess: AnyObject {
    func read() -> [String: Any]?
    func select(_ request: [String: Any])
    func cancel()
}

/// Process isolation contains private-API exceptions, hangs and OS changes. Perl's
/// MediaRemote compatibility technique is also used by mediaremote-adapter:
/// https://github.com/ungive/mediaremote-adapter (no third-party code is bundled).
final class LocalMusicQueueAccess: MusicQueueAccess {
    private let lock = NSLock()
    private var generation = 0
    private var lastReadGeneration: Int?
    private var running: Process?
    private let library: URL?
    init(library: URL? = nil) {
        let bundle = Bundle.main.bundleURL
        // The background receiver is itself a nested .app inside Contents/Helpers.
        let root = bundle.deletingLastPathComponent().lastPathComponent == "Helpers"
            ? bundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() : bundle
        self.library = library ?? root.appendingPathComponent("Contents/Helpers/libDroidMirrorMusicQueue.dylib")
    }
    func read() -> [String: Any]? { run(["action": "read"]) }
    func select(_ request: [String: Any]) { _ = run(request) }
    func cancel() {
        lock.lock(); generation += 1; lastReadGeneration = nil
        if let running, running.isRunning { running.terminate() }
        lock.unlock()
    }
    // Called only on AppleMusicSync's serial worker, never on the UI thread.
    private func run(_ request: [String: Any]) -> [String: Any]? {
        guard let library, FileManager.default.fileExists(atPath: library.path),
              let input = try? JSONSerialization.data(withJSONObject: request), input.count <= 16384 else { return nil }
        let process = Process(), output = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-MDynaLoader", "-e", "DynaLoader::dl_load_file($ARGV[0],0) or die DynaLoader::dl_error()", library.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = stdin; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        lock.lock()
        let epoch = generation
        if request["action"] as? String != "read", lastReadGeneration != epoch { lock.unlock(); return nil }
        do { try process.run(); running = process } catch { lock.unlock(); return nil }
        lock.unlock()
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeout)
        // The helper caps output at 512 KB and exits within 3.3 seconds. Read before
        // waitUntilExit so even a full pipe cannot deadlock child and parent.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        lock.lock(); running = nil; let valid = epoch == generation
        if valid, request["action"] as? String == "read" { lastReadGeneration = epoch }
        lock.unlock()
        guard valid, process.terminationStatus == 0, data.count <= 524288 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
