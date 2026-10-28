import Foundation

/// Optional, asynchronous artwork fallback for native Music snapshots that omit
/// image bytes. Only a numeric catalog ID goes to Apple's public lookup service.
/// Metadata and commands never wait for either network request.
final class MusicCatalogArtwork {
    private let lock = NSLock()
    private let session: URLSession
    private var generation = 0
    private var currentID = ""
    private var encoded: String?
    private var task: URLSessionDataTask?
    private var retryAt = Date.distantPast

    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    static func catalogID(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 20,
              text.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(text), number > 0 else { return nil }
        return String(number)
    }
    static func imageURL(_ value: Any?) -> URL? {
        guard let text = value as? String, let url = URL(string: text),
              url.scheme == "https", let host = url.host?.lowercased(), host.hasSuffix(".mzstatic.com"),
              url.user == nil, url.password == nil, url.port == nil,
              url.lastPathComponent == "100x100bb.jpg" else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent("512x512bb.jpg")
    }
    func cover(for value: Any?) -> String? {
        guard let id = Self.catalogID(value) else { clear(); return nil }
        lock.lock()
        if currentID != id {
            generation += 1; task?.cancel(); task = nil
            currentID = id; encoded = nil; retryAt = .distantPast
        }
        let cover = encoded
        if cover != nil || task != nil || Date() < retryAt { lock.unlock(); return cover }
        retryAt = Date().addingTimeInterval(30)
        let epoch = generation
        var request = URLRequest(url: URL(string: "https://itunes.apple.com/lookup?id=" + id)!)
        request.timeoutInterval = 6
        let lookup = session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            guard let data, data.count <= 1048576, (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let entry = results.first(where: { ($0["trackId"] as? NSNumber)?.stringValue == id }),
                  let url = Self.imageURL(entry["artworkUrl100"]) else { self.finish(nil, epoch: epoch); return }
            var imageRequest = URLRequest(url: url); imageRequest.timeoutInterval = 6
            let imageTask = self.session.dataTask(with: imageRequest) { [weak self] data, response, _ in
                guard let self else { return }
                guard let data, data.count <= 2097152, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    self.finish(nil, epoch: epoch); return
                }
                self.finish(MediaArtwork.encode(data), epoch: epoch)
            }
            self.lock.lock()
            guard self.generation == epoch else { self.lock.unlock(); return }
            self.task = imageTask
            self.lock.unlock()
            imageTask.resume()
        }
        task = lookup
        lock.unlock()
        lookup.resume()
        return cover
    }
    private func finish(_ cover: String?, epoch: Int) {
        lock.lock(); defer { lock.unlock() }
        guard generation == epoch else { return }
        encoded = cover; task = nil
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        generation += 1; task?.cancel(); task = nil
        currentID = ""; encoded = nil; retryAt = .distantPast
    }
}
