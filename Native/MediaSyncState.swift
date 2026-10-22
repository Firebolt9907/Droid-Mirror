import Foundation

/// A remote snapshot is a short lease, never a durable command destination.
struct MediaSnapshot {
    let id: String
    let title: String
    let artist: String
    let album: String
    let playing: Bool
    let duration: Double
    let position: Double
    let actions: Set<String>
    let receivedAt: Date

    init?(_ value: [String: Any], now: Date = Date()) {
        guard value["active"] as? Bool == true,
              let id = value["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
              let title = value["title"] as? String, title.utf8.count <= 1024,
              let artist = value["artist"] as? String, artist.utf8.count <= 1024,
              let album = value["album"] as? String, album.utf8.count <= 1024,
              let playing = value["playing"] as? Bool,
              let duration = value["duration"] as? Double, duration.isFinite, duration >= 0,
              let position = value["position"] as? Double, position.isFinite, position >= 0,
              let actions = value["actions"] as? [String], actions.count <= 8,
              Set(actions).isSubset(of: ["play", "pause", "next", "previous", "seek", "shuffle", "repeat", "queue"]) else { return nil }
        self.id = id; self.title = title; self.artist = artist; self.album = album
        self.playing = playing; self.duration = duration; self.position = position
        self.actions = Set(actions); receivedAt = now
    }
    func fresh(now: Date = Date()) -> Bool { now.timeIntervalSince(receivedAt) < 8 }
    func elapsed(now: Date = Date()) -> Double {
        let value = position + (playing ? max(0, now.timeIntervalSince(receivedAt)) : 0)
        return duration > 0 ? min(duration, value) : value
    }
    static func validCommand(_ event: [String: Any], target: String, actions: Set<String>) -> Bool {
        guard event["id"] as? String == target,
              let action = event["action"] as? String, actions.contains(action) else { return false }
        if action == "seek" {
            guard let position = event["position"] as? Double, position.isFinite,
                  position >= 0, position <= 604800 else { return false }
        }
        if action == "shuffle", !(event["enabled"] is Bool) { return false }
        if action == "repeat", !["off", "one", "all"].contains(event["mode"] as? String ?? "") { return false }
        if action == "queue" {
            guard let revision = event["queueRevision"] as? String, revision.utf8.count == 64,
                  let id = event["queueItemId"] as? Int64, id >= 0 else { return false }
        }
        return true
    }
}
