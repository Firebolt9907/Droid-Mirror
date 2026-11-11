import Foundation

@main struct MediaStateWireTests {
    static func main() {
        var sender = MediaStateWire(), receiver = MediaStateWire()
        var value: [String: Any] = ["type": "mediaState", "active": true, "id": "track",
            "title": "Song", "artist": "Artist", "album": "Album", "duration": 600.0,
            "position": 20.0, "playing": true, "actions": ["pause", "seek"]]
        var delayed = value
        delayed["position"] = 60.0; delayed["_positionSampleUptime"] = 96.0
        let processed = MediaPositionTiming.advance(delayed, now: 100)
        precondition(processed["position"] as? Double == 64)
        let sent = MediaPositionTiming.sending(processed, now: 102, phoneSampleMilliseconds: 5000)
        precondition(sent["position"] as? Double == 66)
        precondition(sent["_positionSampleUptime"] == nil && sent["positionSampleElapsedMs"] as? Double == 5000)
        var received = sent; received["_mediaPositionAge"] = 2.0
        let timed = MediaSnapshot(received, uptime: 200)!
        precondition(timed.position == 68 && timed.elapsed(uptime: 203) == 71)
        delayed["playing"] = false
        precondition(MediaPositionTiming.advance(delayed, now: 100)["position"] as? Double == 60)
        delayed["playing"] = true; delayed["playbackRate"] = 0.5
        precondition(MediaPositionTiming.advance(delayed, now: 100)["position"] as? Double == 62)
        let compact: [String: Any] = ["type": "mediaState", "unchanged": true, "position": 60.0,
            "_positionSampleUptime": 96.0, "_positionRate": 1.0, "_positionDuration": 600.0]
        let queuedCompact = MediaPositionTiming.sending(compact, now: 100, phoneSampleMilliseconds: 5000)
        precondition(queuedCompact["position"] as? Double == 64 && queuedCompact["_positionRate"] == nil)
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
        var reordering = value
        reordering["actions"] = ["seek", "pause"]
        precondition(sender.prepare(reordering, now: 120) == nil, "Action order must not resend descriptions")
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
        var calibrated = sender
        _ = receiver.receive(calibrated.prepare(value, now: 1000)!)
        _ = calibrated.receive(receiver.prepare(other, now: 1000)!)
        _ = receiver.receive(calibrated.prepare(value, now: 1000)!)
        precondition(calibrated.prepare(value, now: 1000) == nil)
        calibrated.refreshTiming()
        let correction = calibrated.prepare(value, now: 1000)!
        precondition(correction["unchanged"] == nil, "Better clock calibration must send one full corrected anchor")
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
