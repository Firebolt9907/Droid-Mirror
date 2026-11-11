import Foundation

/// Legacy snapshots expire quickly; negotiated timelines live only within their connection.
struct MediaSnapshot {
    let id: String
    let title: String
    let artist: String
    let album: String
    let externalAudio: Bool
    /// The phone can adjust this session's output volume.
    let volumeControl: Bool
    let playing: Bool
    let rate: Double
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
        volumeControl = value["volumeControl"] as? Bool ?? false
        let rate = (value["playbackRate"] as? Double) ?? (playing ? 1 : 0)
        guard rate.isFinite, (0...4).contains(rate) else { return nil }
        self.rate = playing ? rate : 0
        let age = (value["_mediaPositionAge"] as? Double) ?? 0
        let adjusted = position + self.rate * (age.isFinite ? min(60, max(0, age)) : 0)
        self.playing = playing; self.duration = duration; self.position = duration > 0 ? min(duration, adjusted) : adjusted
        self.actions = Set(actions); receivedAt = now; self.sessionScoped = sessionScoped; receivedUptime = uptime
    }
    func fresh(now: Date = Date()) -> Bool { sessionScoped || now.timeIntervalSince(receivedAt) < 8 }
    /// Identifies what would be published to Now Playing. The system advances
    /// elapsed time from the rate, so nothing is republished until this changes.
    var publicationKey: String {
        [id, title, artist, album, "\(duration)", "\(position)", "\(rate)", "\(playing)",
         actions.sorted().joined(separator: ","), "\(receivedUptime)"].joined(separator: "\u{1F}")
    }
    func elapsed(now: Date? = nil, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        let elapsed = now.map { $0.timeIntervalSince(receivedAt) } ?? (uptime - receivedUptime)
        let value = position + rate * max(0, elapsed)
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

/// When to read Apple Music. Reads no longer have to find changes on their own:
/// Music announces play, pause and track changes, and those request one at once.
/// The timer picks up what it does not announce, such as seeks and queue edits.
struct MusicPollSchedule {
    private var nextAt = -Double.infinity
    private var inFlightSince: TimeInterval?
    private(set) var soon = false
    /// Peers without a local timeline rely on a heartbeat inside their 8-second lease.
    static func interval(localTimeline: Bool, playing: Bool, screenAwake: Bool) -> TimeInterval {
        guard localTimeline else { return 2 }
        return playing ? (screenAwake ? 10 : 30) : 60
    }
    func due(now: TimeInterval) -> Bool {
        // The read path can drop a completion when it is already busy, so an
        // in-flight read stops blocking new ones once it exceeds its own deadlines.
        if let inFlightSince, now - inFlightSince < 8 { return false }
        return soon || now >= nextAt
    }
    mutating func begin(now: TimeInterval) { soon = false; inFlightSince = now }
    mutating func finish(now: TimeInterval, interval: TimeInterval) { inFlightSince = nil; nextAt = now + interval }
    mutating func requestSoon() { soon = true }
    mutating func reset() { self = MusicPollSchedule() }
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
    private var rate = 0.0
    private var duration = 0.0

    mutating func refreshTiming() { signature = nil }
    /// A peer retransmits its full snapshot until this side echoes the revision.
    var needsAcknowledgment: Bool {
        guard let revision = incoming?["stateRevision"] as? String else { return false }
        return revision != acknowledgedIncoming
    }

    mutating func prepare(_ input: [String: Any], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [String: Any]? {
        let value = MediaPositionTiming.advance(input, now: now)
        var description = value
        description.removeValue(forKey: "position")
        if let actions = description["actions"] as? [String] { description["actions"] = actions.sorted() }
        description.removeValue(forKey: "_positionSampleUptime")
        let next = try? JSONSerialization.data(withJSONObject: description, options: [.sortedKeys])
        let currentPosition = value["position"] as? Double ?? 0
        let projected = position + rate * max(0, now - positionAt)
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
            compact["_positionSampleUptime"] = value["_positionSampleUptime"]
            compact["_positionRate"] = MediaPositionTiming.rate(value)
            compact["_positionDuration"] = value["duration"]
            compact["receivedStateRevision"] = incoming?["stateRevision"]
            return compact
        }
        if changed || revision.isEmpty {
            revision = UUID().uuidString
            position = currentPosition; positionAt = now
            rate = MediaPositionTiming.rate(value)
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
            for key in ["_mediaPositionAge", "positionSampleElapsedMs"] {
                full.removeValue(forKey: key); full[key] = event[key]
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

/// Position samples retain their source time through artwork processing and BLE queueing.
enum MediaPositionTiming {
    static func rate(_ value: [String: Any]) -> Double {
        if value["unchanged"] as? Bool == true { return value["_positionRate"] as? Double ?? 0 }
        guard value["playing"] as? Bool == true else { return 0 }
        let rate = value["playbackRate"] as? Double ?? 1
        return rate.isFinite && (0...4).contains(rate) ? rate : 0
    }
    static func advance(_ input: [String: Any], now: TimeInterval) -> [String: Any] {
        var value = input
        guard value["active"] as? Bool == true || value["unchanged"] as? Bool == true, let position = value["position"] as? Double else { return value }
        let sample = value["_positionSampleUptime"] as? Double ?? now
        let age = sample.isFinite ? min(60, max(0, now - sample)) : 0
        let duration = value["duration"] as? Double ?? value["_positionDuration"] as? Double ?? 0
        let advanced = max(0, position + rate(value) * age)
        value["position"] = duration > 0 ? min(duration, advanced) : advanced
        value["_positionSampleUptime"] = now
        return value
    }
    static func sending(_ input: [String: Any], now: TimeInterval, phoneSampleMilliseconds: Double?) -> [String: Any] {
        var value = advance(input, now: now)
        value.removeValue(forKey: "_positionSampleUptime")
        value.removeValue(forKey: "_positionRate"); value.removeValue(forKey: "_positionDuration")
        if value["active"] as? Bool == true || value["unchanged"] as? Bool == true {
            value["positionSampleElapsedMs"] = phoneSampleMilliseconds
        }
        return value
    }
}
