import Foundation

@main struct MediaStateWireTests {
    static func main() {
        var sender = MediaStateWire(), receiver = MediaStateWire()
        var value: [String: Any] = ["type": "mediaState", "active": true, "id": "track",
            "title": "Song", "artist": "Artist", "album": "Album", "duration": 600.0,
            "position": 20.0, "playing": true, "actions": ["pause", "seek"]]
        let first = sender.prepare(value, now: 0)!
        precondition(receiver.receive(first)?["title"] as? String == "Song")
        precondition(sender.prepare(value, now: 0) != nil) // Retry until confirmed.
        _ = sender.receive(receiver.prepare(value, now: 0)!)
        _ = receiver.receive(sender.prepare(value, now: 0)!) // Acknowledge the other direction once.
        for seconds in stride(from: 2, through: 120, by: 2) {
            value["position"] = 20.0 + Double(seconds)
            precondition(sender.prepare(value, now: Double(seconds)) == nil)
            precondition(receiver.prepare(value, now: Double(seconds)) == nil)
        }
        // Losing the final acknowledgment cannot leave one side retrying forever.
        _ = receiver.receive(first)
        let retryAck = receiver.prepare(value, now: 120)!
        precondition(retryAck["unchanged"] as? Bool == true)
        _ = sender.receive(retryAck)
        precondition(receiver.prepare(value, now: 120) == nil)
        value["position"] = 50.0 // Seek, despite unchanged description and playing state.
        let seek = sender.prepare(value, now: 122)!
        precondition(seek["unchanged"] == nil)
        precondition(receiver.receive(seek)?["position"] as? Double == 50)
        precondition(sender.prepare(value, now: 122) != nil) // Lost acknowledgment retries.
        var other = value; other["position"] = 142.0
        _ = sender.receive(receiver.prepare(other, now: 122)!)
        value["position"] = 52.0
        precondition(sender.prepare(value, now: 124) == nil)
        value["playing"] = false
        let paused = sender.prepare(value, now: 124)!
        _ = receiver.receive(paused)
        other["position"] = 144.0
        _ = sender.receive(receiver.prepare(other, now: 124)!)
        precondition(sender.prepare(value, now: 1000) == nil) // Paused progress needs no traffic.
        for key in ["title", "artist", "album", "artworkID", "queueRevision"] {
            value[key] = "changed"
            precondition(sender.prepare(value, now: 1000) != nil)
        }
        let scoped = MediaSnapshot(value, now: Date(timeIntervalSince1970: 0), sessionScoped: true)!
        precondition(scoped.fresh(now: Date(timeIntervalSince1970: 100)))
        precondition(scoped.elapsed(now: Date(timeIntervalSince1970: 100)) == 52)
        value["playing"] = true
        let advancing = MediaSnapshot(value, now: Date(timeIntervalSince1970: 0), sessionScoped: true)!
        precondition(advancing.elapsed(now: Date(timeIntervalSince1970: 100)) == 152)
        precondition(!MediaSnapshot(value, now: Date(timeIntervalSince1970: 0))!.fresh(now: Date(timeIntervalSince1970: 100)))
        var legacy = MediaStateWire()
        for seconds in 0...20 { precondition(legacy.prepare(value, now: Double(seconds)) != nil) }
        var compactPeer = MediaStateWire()
        var old = first; old.removeValue(forKey: "supportsLocalTimeline")
        _ = compactPeer.receive(old)
        precondition(compactPeer.prepare(value, now: 0) != nil)
        var disconnected = MediaStateWire()
        precondition(disconnected.receive(["unchanged": true, "stateRevision": first["stateRevision"]!]) == nil)
        print("PASS: local timeline, silent progress/paused state, seeks, retries, metadata changes, legacy fallback and session reset")
    }
}
