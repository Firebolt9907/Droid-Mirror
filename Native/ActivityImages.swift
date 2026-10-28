import Foundation
import CryptoKit
import ImageIO

/// One optional asset request at a time; wire activity baselines remain untouched.
final class ActivityImages {
    var request: (([String: Any], @escaping ([String: Any]?) -> Void) -> Void)?
    var onUpdate: (([String: Any]) -> Void)?
    private var events = [String: [String: Any]]()
    private var signatures = [String: String]()
    private var manifests = [String: [String: String]]()
    private var attempted = [String: String]()
    private var retryVersions = [String: String]()
    private var attemptedAssets = Set<String>()
    private var cache = [String: Data]()
    private var encodedCache = [String: String]()
    var cachedAssetCount: Int { cache.count }
    private var order = [String]()
    private var cacheBytes = 0
    private var busy: UUID?
    private var suspended = false
    private(set) var transferredBytes = 0
    static func validField(_ field: String) -> Bool {
        if ["appIcon", "activityIcon", "contactImage", "contentImage", "progressStartIcon", "progressEndIcon", "progressTrackerIcon"].contains(field) { return true }
        let pieces = field.split(separator: "/")
        return pieces.count == 3 && pieces[0] == "customNodes" && pieces[2] == "image" && Int(pieces[1]).map { (0..<24).contains($0) } == true
    }
    private static func image(_ field: String, in event: [String: Any]) -> String? {
        if !field.contains("/") { return event[field] as? String }
        let parts = field.split(separator: "/")
        guard parts.count == 3, let index = Int(parts[1]), let nodes = event["customNodes"] as? [[String: Any]], nodes.indices.contains(index) else { return nil }
        return nodes[index]["image"] as? String
    }
    private static func set(_ field: String, image: String, in event: inout [String: Any]) {
        if !field.contains("/") { event[field] = image; return }
        let parts = field.split(separator: "/")
        guard let index = Int(parts[1]), var nodes = event["customNodes"] as? [[String: Any]], nodes.indices.contains(index) else { return }
        nodes[index]["image"] = image; event["customNodes"] = nodes
    }
    private static func signature(_ event: [String: Any]) -> String {
        let fields = ["appIcon", "activityIcon", "contactImage", "contentImage", "progressStartIcon", "progressEndIcon", "progressTrackerIcon"] + (0..<24).map { "customNodes/\($0)/image" }
        let joined = (event["activityImageRevision"] as? String ?? "") + fields.map { $0 + ":" + (image($0, in: event) ?? "") }.joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func observe(_ event: [String: Any]) -> [String: Any] {
        guard let id = event["id"] as? String else { return event }
        let signature = Self.signature(event)
        if signatures[id] != signature { manifests.removeValue(forKey: id); attempted.removeValue(forKey: id) }
        if let retry = retryVersions[id], retry != event["version"] as? String {
            attempted.removeValue(forKey: id); retryVersions.removeValue(forKey: id)
        }
        signatures[id] = signature; events[id] = event
        if events.count > 128, let victim = events.keys.first(where: { $0 != id }) { remove(victim) }
        suspended = false
        // Defer until after the caller renders text and controls.
        DispatchQueue.main.async { [weak self] in self?.pump() }
        return rendered(id) ?? event
    }
    func rendered(_ id: String) -> [String: Any]? {
        guard var event = events[id] else { return nil }
        for (field, hash) in manifests[id] ?? [:] {
            if let encoded = encodedCache[hash] { Self.set(field, image: encoded, in: &event) }
        }
        return event
    }
    func remove(_ id: String) { events.removeValue(forKey: id); signatures.removeValue(forKey: id); manifests.removeValue(forKey: id); attempted.removeValue(forKey: id); retryVersions.removeValue(forKey: id) }
    func reconcile(_ ids: Set<String>) { for id in Array(events.keys) where !ids.contains(id) { remove(id) } }
    func suspend() { suspended = true; busy = nil; attempted.removeAll(); retryVersions.removeAll(); attemptedAssets.removeAll() }
    func reset() { suspend(); events.removeAll(); signatures.removeAll(); manifests.removeAll(); cache.removeAll(); encodedCache.removeAll(); order.removeAll(); cacheBytes = 0 }
    private func pump() {
        guard !suspended, busy == nil, let request else { return }
        for id in events.keys.sorted() {
            guard let event = events[id], let signature = signatures[id] else { continue }
            if attempted[id] != signature {
                attempted[id] = signature
                let token = UUID(); busy = token
                request(["type": "activityImageManifestRequest", "id": id, "version": event["version"] ?? "", "imageRevision": event["activityImageRevision"] ?? ""]) { [weak self] response in
                    guard let self, self.busy == token else { return }
                    self.busy = nil
                    if response?["stale"] as? Bool == true {
                        if self.events[id]?["version"] as? String != event["version"] as? String { self.attempted.removeValue(forKey: id) }
                        else { self.retryVersions[id] = event["version"] as? String }
                    }
                    if self.signatures[id] == signature, response?["success"] as? Bool == true,
                       (event["activityImageRevision"] == nil || response?["imageRevision"] as? String == event["activityImageRevision"] as? String),
                       let images = response?["images"] as? [String: String], images.count <= 31 {
                        self.manifests[id] = images.filter { Self.validField($0.key) && $0.value.count == 64 && $0.value.allSatisfy { "0123456789abcdef".contains($0) } }
                        if let updated = self.rendered(id) { self.onUpdate?(updated) }
                    }
                    self.pump()
                }
                return
            }
            if let asset = manifests[id]?.values.sorted().first(where: { cache[$0] == nil && !attemptedAssets.contains($0) }) {
                let token = UUID(); busy = token; attemptedAssets.insert(asset)
                if attemptedAssets.count > 4096 { attemptedAssets.formIntersection(Set(manifests.values.flatMap { $0.values })) }
                fetch(id: id, signature: signature, asset: asset, bytes: Data(), total: nil, token: token)
                return
            }
        }
    }
    private func fetch(id: String, signature: String, asset: String, bytes: Data, total: Int?, token: UUID) {
        guard busy == token, !suspended, signatures[id] == signature, let request else { finish(token); return }
        request(["type": "activityImageRequest", "id": id, "asset": asset, "offset": bytes.count]) { [weak self] response in
            guard let self, self.busy == token else { return }
            guard self.signatures[id] == signature, response?["success"] as? Bool == true,
                  response?["asset"] as? String == asset, response?["offset"] as? Int == bytes.count,
                  let size = response?["total"] as? Int, (1...131072).contains(size), total == nil || total == size,
                  let encoded = response?["data"] as? String, encoded.count <= 1024,
                  let chunk = Data(base64Encoded: encoded), !chunk.isEmpty, chunk.count <= 768,
                  bytes.count + chunk.count <= size, chunk.count == 768 || bytes.count + chunk.count == size else {
                self.failed(id: id, asset: asset, token: token); return
            }
            var joined = bytes; joined.append(chunk); self.transferredBytes += chunk.count
            if joined.count < size { self.fetch(id: id, signature: signature, asset: asset, bytes: joined, total: size, token: token); return }
            let digest = SHA256.hash(data: joined).map { String(format: "%02x", $0) }.joined()
            guard digest == asset, Self.validImage(joined) else { self.failed(id: id, asset: asset, token: token); return }
            self.cache[asset] = joined; self.encodedCache[asset] = joined.base64EncodedString()
            self.order.append(asset); self.cacheBytes += joined.count
            var evicted = Set<String>()
            while self.cacheBytes > 8 * 1024 * 1024 || self.order.count > 128 {
                let removed = self.order.removeFirst(); self.cacheBytes -= self.cache.removeValue(forKey: removed)?.count ?? 0
                self.encodedCache.removeValue(forKey: removed); evicted.insert(removed)
            }
            for key in self.events.keys where self.manifests[key]?.values.contains(where: { $0 == asset || evicted.contains($0) }) == true {
                if let updated = self.rendered(key) { self.onUpdate?(updated) }
            }
            self.finish(token)
        }
    }
    private static func validImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0 && width <= 2048 && height <= 2048 && width * height <= 2097152
    }
    private func failed(id: String, asset: String, token: UUID) {
        // Optional artwork failure leaves the preview; never retry-loop or reset BLE.
        manifests[id] = manifests[id]?.filter { $0.value != asset }
        finish(token)
    }
    private func finish(_ token: UUID) { if busy == token { busy = nil; DispatchQueue.main.async { [weak self] in self?.pump() } } }
}
