import Foundation

@main struct ActivityDeltasTests {
    static func main() throws {
        var sync = ActivityClockSync()
        sync.begin("probe", now: 999)
        precondition(sync.accept(["request": "probe", "clockReceivedElapsedMs": 99010, "clockSentElapsedMs": 99510], receivedAt: 999.52))
        precondition(abs(sync.localTime(phoneMilliseconds: 100000)! - 1000) < 0.0001)
        precondition(sync.roundTripMilliseconds == 20, "Exclude phone queue time from network RTT")
        sync.begin("congested", now: 1010)
        precondition(!sync.accept(["request": "congested", "clockReceivedElapsedMs": 110010, "clockSentElapsedMs": 110010], receivedAt: 1014.01))
        precondition(abs(sync.localTime(phoneMilliseconds: 100000)! - 1000) < 0.0001)
        precondition(!sync.accept(["request": "probe", "clockReceivedElapsedMs": 99010, "clockSentElapsedMs": 99510], receivedAt: 999.52))
        var delayed = ActivityDeltaReceiver()
        let delayedEvent: [String: Any] = ["type": "notification", "activity": true, "id": "delay", "version": "v1",
            "chronometer": true, "countDown": true, "clockOffsetMs": 30000, "clockSentElapsedMs": 100000, "_activityReceivedAt": 1002.0,
            "body": "Clock 00:30", "embeddedTimers": [["hash": ActivityEmbeddedText.hash("Clock 00:30"), "start": 6, "end": 11, "token": "00:30", "seconds": 30.0, "down": true, "width": 2]]]
        let uncalibrated = delayed.receive(delayedEvent)!
        precondition(ActivityClock.anchor(event: uncalibrated, now: 1002) == 1032)
        let calibrated = delayed.reanchor(using: sync).first!
        precondition(abs(ActivityClock.anchor(event: calibrated, now: 1002)-1030) < 0.0001, "Remove two seconds of first-fragment transit delay")
        precondition(ActivityEmbeddedText.render("Clock 00:30", event: calibrated, now: 1002) == "Clock 00:28")
        var patch = ["type": "activityPatch", "id": "delay", "base": "v1", "set": ["version": "v2"], "unset": [] as [String]] as [String: Any]
        patch["_activityReceivedAt"] = 1060.0
        let retained = delayed.receive(patch)!
        precondition(abs(ActivityClock.anchor(event: retained, now: 1060)-1030) < 0.0001)
        var legacy = ActivityClockSync()
        legacy.begin("legacy", now: 1000)
        precondition(!legacy.accept(["request": "legacy"], receivedAt: 1001))
        precondition(legacy.localTime(phoneMilliseconds: 100000) == nil)
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let events = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        var receiver = ActivityDeltaReceiver()
        func stamped(_ event: [String: Any], _ now: Double) -> [String: Any] {
            var copy = event; copy["_activityReceivedAt"] = now; return copy
        }
        let first = receiver.receive(stamped(events[0], 1000))!
        precondition(ActivityClock.anchor(event: first, now: 1000) == 1126)
        let second = receiver.receive(stamped(events[1], 1001))!
        precondition(second["appIcon"] as? String == first["appIcon"] as? String)
        precondition(second["version"] as? String == "v2")
        precondition(ActivityClock.anchor(event: second, now: 1001) == 1126)
        let later = receiver.receive(stamped(events[2], 1061))!
        precondition(ActivityClock.anchor(event: later, now: 1061) == 1126, "Retained timer anchors must survive more than 30 seconds")
        precondition(ActivityEmbeddedText.render(later["body"] as! String, event: later, now: 1061) == "Starts in 01:05")
        let fixed = receiver.receive(stamped(events[3], 1062))!
        precondition(ActivityClock.anchor(event: fixed, now: 1062) == 1122)
        precondition(ActivityEmbeddedText.render(fixed["body"] as! String, event: fixed, now: 1062) == "Starts in 01:00")
        let bad: [String: Any] = ["type": "activityPatch", "id": "runner", "base": "stale", "set": ["version": "wrong"], "unset": [] as [String]]
        precondition(receiver.receive(bad) == nil && receiver.needsSnapshot)
        let clear: [String: Any] = ["type": "activityPatch", "id": "runner", "base": "v4", "set": ["version": "v5", "chronometer": false], "unset": ["embeddedTimers", "body"]]
        let cleared = receiver.receive(stamped(clear, 1063))!
        precondition(cleared["body"] == nil && cleared["embeddedTimers"] == nil)
        _ = receiver.receive(["type": "removed", "id": "runner"])
        precondition(receiver.receive(clear) == nil && receiver.needsSnapshot)
        _ = receiver.receive(stamped(events[0], 2000))
        _ = receiver.receive(["type": "activitiesReset", "ids": [], "part": 0])
        precondition(receiver.receive(events[1]) == nil && receiver.needsSnapshot)
        print("PASS: Android-produced deltas reconstructed on Swift, retained timer anchors, corrections, field deletion, missing bases and reset")
    }
}
