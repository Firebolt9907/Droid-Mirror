import Foundation

/// Legacy snapshots expire quickly; negotiated timelines live only within their connection.
struct MediaSnapshot {
    let id: String
    let title: String
    let artist: String
    let album: String
    let externalAudio: Bool
    let playing: Bool
    let duration: Double
    let position: Double
    let actions: Set<String>
    let receivedAt: Date
    let sessionScoped: Bool
    let receivedUptime: TimeInterval

    init?(_ value: [String: Any], now: Date = Date(), sessionScoped: Bool = false, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
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
        externalAudio = value["externalAudio"] as? Bool ?? false
        self.playing = playing; self.duration = duration; self.position = position
        self.actions = Set(actions); receivedAt = now; self.sessionScoped = sessionScoped; receivedUptime = uptime
    }
    func fresh(now: Date = Date()) -> Bool { sessionScoped || now.timeIntervalSince(receivedAt) < 8 }
    func elapsed(now: Date? = nil, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        let elapsed = now.map { $0.timeIntervalSince(receivedAt) } ?? (uptime - receivedUptime)
        let value = position + (playing ? max(0, elapsed) : 0)
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

/// A pause lease belongs to an observed session, never to a retained Android notification.
struct PhoneMediaKeyLease {
    private var previous: MediaSnapshot?
    private var pausedAt: TimeInterval?
    mutating func observe(_ snapshot: MediaSnapshot?, now: TimeInterval) {
        if snapshot?.id != previous?.id { pausedAt = nil }
        if let snapshot, !snapshot.playing, let previous,
           previous.id == snapshot.id, previous.playing, previous.fresh() { pausedAt = now }
        if snapshot == nil || snapshot?.playing == true { pausedAt = nil }
        previous = snapshot
    }
    mutating func invalidate() { previous = nil; pausedAt = nil }
    func allows(_ snapshot: MediaSnapshot, now: TimeInterval) -> Bool {
        snapshot.externalAudio || (snapshot.id == previous?.id && pausedAt.map { now >= $0 && now - $0 < 600 } == true)
    }
}

/// Negotiated wire compression: descriptions change rarely; lease/position updates do not.
struct MediaStateWire {
    private var signature: Data?
    private var revision = ""
    private var confirmedRevision = ""
    private var incoming: [String: Any]?
    private(set) var peerSupportsCompact = false
    private(set) var peerSupportsLocalTimeline = false
    private var acknowledgedIncoming = ""
    private var position = 0.0
    private var positionAt = 0.0
    private var playing = false
    private var duration = 0.0

    mutating func prepare(_ value: [String: Any], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [String: Any]? {
        var description = value
        description.removeValue(forKey: "position")
        let next = try? JSONSerialization.data(withJSONObject: description, options: [.sortedKeys])
        let currentPosition = value["position"] as? Double ?? 0
        let projected = position + (playing ? max(0, now - positionAt) : 0)
        let expected = duration > 0 ? min(duration, projected) : projected
        let positionChanged = abs(currentPosition - expected) > 1.0
        let incomingRevision = incoming?["stateRevision"] as? String ?? ""
        let changed = signature != next || (peerSupportsLocalTimeline && positionChanged)
        if peerSupportsLocalTimeline, !changed, confirmedRevision == revision,
           !revision.isEmpty, acknowledgedIncoming == incomingRevision { return nil }
        acknowledgedIncoming = incomingRevision
        if peerSupportsCompact, !changed, confirmedRevision == revision, !revision.isEmpty {
            var compact: [String: Any] = ["type": "mediaState", "stateRevision": revision, "unchanged": true]
            compact["position"] = value["position"]
            compact["receivedStateRevision"] = incoming?["stateRevision"]
            return compact
        }
        if changed || revision.isEmpty {
            revision = UUID().uuidString
            position = currentPosition; positionAt = now
            playing = value["playing"] as? Bool ?? false
            duration = value["duration"] as? Double ?? 0
        }
        signature = next
        var full = value
        full["stateRevision"] = revision
        full["supportsCompactState"] = true
        full["supportsLocalTimeline"] = true
        full["receivedStateRevision"] = incoming?["stateRevision"]
        return full
    }
    mutating func receive(_ event: [String: Any]) -> [String: Any]? {
        if event["receivedStateRevision"] as? String == revision { confirmedRevision = revision }
        if event["unchanged"] as? Bool == true {
            guard var full = incoming, let revision = event["stateRevision"] as? String,
                  revision == full["stateRevision"] as? String else { return nil }
            if full["active"] as? Bool == true {
                guard let position = event["position"] as? Double, position.isFinite,
                      position >= 0, position <= 604800 else { return nil }
                full["position"] = position
            }
            return full
        }
        guard event["active"] as? Bool == false || MediaSnapshot(event) != nil else { return nil }
        peerSupportsCompact = event["supportsCompactState"] as? Bool == true
        peerSupportsLocalTimeline = event["supportsLocalTimeline"] as? Bool == true
        incoming = event
        acknowledgedIncoming = "" // A repeated full snapshot retries a potentially lost acknowledgment.
        return event
    }
}
