import AppKit

@main
struct AndroidActivityMenuTests {
    static func main() {
        let embedded = "🏃 Starts in 02:06; elapsed 03:00"
        let embeddedEvent: [String: Any] = ["_activityReceivedAt": 1000.0, "embeddedTimers": [
            ["hash": ActivityEmbeddedText.hash(embedded), "start": 13, "end": 18, "token": "02:06", "seconds": 118.0, "down": true, "width": 2],
            ["hash": ActivityEmbeddedText.hash(embedded), "start": 28, "end": 33, "token": "03:00", "seconds": 188.0, "down": false, "width": 2]]]
        precondition(ActivityEmbeddedText.render(embedded, event: embeddedEvent, now: 1006) == "🏃 Starts in 01:52; elapsed 03:14")
        precondition(ActivityEmbeddedText.render("Truncated", event: embeddedEvent, now: 1006) == "Truncated")
        precondition(ActivityEmbeddedText.render(embedded, event: embeddedEvent, now: 1200).contains("00:00"))
        let tickOne = ActivityEmbeddedText.runs(embedded, event: embeddedEvent, now: 1001)
        let tickTwo = ActivityEmbeddedText.runs(embedded, event: embeddedEvent, now: 1002)
        precondition(tickOne.map(\.id) == tickTwo.map(\.id))
        precondition(tickOne.filter { !$0.numeric }.map(\.text) == tickTwo.filter { !$0.numeric }.map(\.text))
        precondition(tickOne.filter(\.timer).map(\.text) == ["01:57", "03:09"])
        precondition(tickTwo.filter(\.timer).map(\.text) == ["01:56", "03:10"])
        let ordinaryNumbers = ActivityEmbeddedText.runs("1 runner left · 42%", event: [:], now: 1000)
        precondition(ordinaryNumbers.filter(\.numeric).map(\.text) == ["1", "42"])
        precondition(ordinaryNumbers.allSatisfy { !$0.timer })
        precondition(ordinaryNumbers.map(\.text).joined() == "1 runner left · 42%")
        precondition(abs(ActivityClock.nextTick(after: 1000.75, anchor: 1030.25)-1001.252) < 0.0001)
        var schedule = ActivityTimerSchedule.Entries(initial: Date(timeIntervalSince1970: 1000), nextDates: [1000.2,1000.7])
        precondition(schedule.next()!.timeIntervalSince1970 == 1000)
        for expected in [1000.2,1000.7,1001.2,1001.7] {
            precondition(abs(schedule.next()!.timeIntervalSince1970-expected) < 0.0001)
        }
        let pausedWatch = AndroidActivityPresentation(event: ["clockPausedMs": 45500, "chronometer": false], clockAnchor: 0)
        precondition(pausedWatch.clock(now: 1000) == "00:46" && pausedWatch.clock(now: 2000) == "00:46")
        let pausedTimer = AndroidActivityPresentation(event: ["clockPausedMs": 45500, "chronometer": false, "countDown": true], clockAnchor: 0)
        precondition(pausedTimer.clock(now: 1000) == "00:45" && pausedTimer.clock(now: 2000) == "00:45")
        precondition(AndroidActivityMenu.clock(16.75, countDown: true) == "00:16", "Match Android Chronometer countdown rounding")
        precondition(AndroidActivityMenu.clock(16.75, countDown: false) == "00:17", "Match Android Chronometer count-up rounding")
        let metricTimer = AndroidActivityPresentation(event: ["chronometer": true, "countDown": true], clockAnchor: 1030)
        precondition(metricTimer.clock(now: 1000) == "00:30")
        precondition(metricTimer.clock(now: 1001) == "00:29")
        precondition(metricTimer.clock(now: 1040) == "00:00")
        let runningWatch = AndroidActivityPresentation(event: ["chronometer": true, "countDown": false], clockAnchor: 1000)
        precondition(runningWatch.clock(now: 1065) == "01:05")
        _ = NSApplication.shared
        let manager = AndroidActivityMenu()
        var sent = [String]()
        manager.onAction = { _, action in sent.append(action) }
        func event(_ id: String, _ version: String = "v1") -> [String: Any] {
            ["id": id, "version": version, "app": "Same app", "title": "Activity",
             "activity": true, "canOpen": true, "progressMax": 100, "progressValue": 42,
             "actions": [["id": "0", "title": "Pause"], ["id": "1", "title": "Reply", "reply": true]]]
        }
        manager.update(event("one")); manager.update(event("two"))
        manager.prepareCard("one")
        let item = manager.itemIdentity("one")
        let controller = manager.controllerIdentity("one")
        let statusLabel = manager.statusIdentity("one")
        for index in 0..<20 {
            manager.reconcile(["one", "two"])
            var update = event("one", "refresh-\(index)")
            update["status"] = "\(20 - index) min"
            manager.update(update)
            manager.prepareCard("one")
            precondition(manager.itemIdentity("one") == item, "Snapshots must preserve the status item")
            precondition(manager.statusIdentity("one") == statusLabel, "Numeric menu-bar labels must retain their SwiftUI identity")
            precondition(manager.controllerIdentity("one") == controller, "Updates must preserve the hosting controller and numeric transition identity")
        }
        manager.update(event("one"))
        manager.suspend(now: 100)
        manager.perform(id: "one", version: "v1", action: "0")
        precondition(sent.isEmpty, "Retained controls cannot execute during a reconnect")
        manager.tick(now: 129)
        precondition(manager.count == 2, "Brief disconnects retain items instead of flickering")
        manager.suspend(now: 129)
        manager.update(event("one"))
        manager.tick(now: 130)
        precondition(manager.count == 1, "Repeated disconnects cannot extend the stale-item deadline")
        precondition(manager.itemIdentity("one") == item, "Fresh authenticated data reuses the retained item")
        manager.update(event("two"))
        var membership = ActivitySnapshotMembership()
        precondition(membership.accept(["ids": ["one"], "snapshot": "a", "part": 0, "parts": 2], now: 1) == nil)
        precondition(membership.accept(["ids": ["two"], "snapshot": "a", "part": 1, "parts": 2], now: 2) == Set(["one", "two"]))
        precondition(membership.accept(["ids": ["one"], "snapshot": "b", "part": 0, "parts": 2], now: 1) == nil)
        precondition(membership.accept(["ids": ["two"], "snapshot": "b", "part": 1, "parts": 2], now: 32) == nil, "Expired partial snapshots cannot prune items")
        precondition(membership.accept(["ids": Array(repeating: "one", count: 65)]) == nil)
        manager.reconcile(["one"])
        precondition(manager.count == 1, "An authoritative snapshot removes missing activities")
        manager.update(event("two"))
        precondition(manager.count == 2, "Separate notifications from the same app get separate items")
        let presentation = AndroidActivityPresentation(event: event("one"), clockAnchor: 100)
        precondition(presentation.layout == .progress && presentation.progress == 0.42)
        precondition(presentation.actions.count == 1, "Reply requires a text-entry flow")
        manager.perform(id: "one", version: "v1", action: "0")
        precondition(sent == ["0"])
        manager.perform(id: "one", version: "v1", action: "1")
        manager.perform(id: "one", version: "v1", action: "invented")
        precondition(sent.count == 1, "Cards cannot invoke unadvertised controls or replies")
        manager.update(event("one", "v2"))
        precondition(manager.count == 2, "An update replaces the existing item")
        manager.perform(id: "one", version: "v1", action: "0")
        precondition(sent.count == 1, "An old card cannot execute a rotated token")
        manager.perform(id: "one", version: "v2", action: "open")
        precondition(sent == ["0", "open"])
        manager.removeDisallowed { $0["id"] as? String == "two" }
        precondition(manager.count == 1, "Disabling an activity removes its item immediately")
        manager.clear(); precondition(manager.count == 0)
        manager.perform(id: "two", version: "v1", action: "open")
        precondition(sent.count == 2, "Disconnect invalidates controls from an open card")
        precondition(AndroidActivityMenu.isActivity(["ongoing": true]))
        precondition(AndroidActivityMenu.isActivity(["persistent": true]))
        precondition(!AndroidActivityMenu.isActivity(["progress": true]))
        precondition(!AndroidActivityMenu.isActivity(["ongoing": true, "category": "transport"]))
        for layout in ["standard", "bigText", "bigPicture", "inbox", "messaging", "call", "progress", "custom"] {
            let p = AndroidActivityPresentation(event: ["layout": layout], clockAnchor: 0)
            precondition(p.layout.rawValue == layout)
        }
        let clock = AndroidActivityPresentation(event: ["chronometer": true, "countDown": true], clockAnchor: 105)
        precondition(clock.clock(now: 100) == "00:05")
        precondition(clock.clock(now: 110) == "00:00")
        precondition(AndroidActivityMenu.clock(0.1, countDown: true) == "00:00")
        precondition(AndroidActivityMenu.clock(3661.9, countDown: false) == "1:01:02")
        // Eight seconds queued on Android plus six seconds of fragment delivery:
        // the old receipt-relative countdown showed 2:20 rather than 2:06.
        let timerEvent: [String: Any] = ["chronometer": true, "countDown": true,
            "clockOffsetMs": 132000, "_activityReceivedAt": 1000.0]
        let synced = AndroidActivityPresentation(event: timerEvent,
            clockAnchor: ActivityClock.anchor(event: timerEvent, now: 1006))
        precondition(synced.clock(now: 1006) == "02:06", "Queueing and reassembly must not extend the countdown")
        precondition(synced.clock(now: 1036) == "01:36", "The deadline continues without another notification update")
        let elapsedEvent: [String: Any] = ["chronometer": true, "clockOffsetMs": -28000, "_activityReceivedAt": 1000.0]
        let elapsed = AndroidActivityPresentation(event: elapsedEvent,
            clockAnchor: ActivityClock.anchor(event: elapsedEvent, now: 1006))
        precondition(elapsed.clock(now: 1006) == "00:34", "Elapsed timers include time spent in transport")
        precondition(ActivityClock.anchor(event: ["clockOffsetMs": 5000], now: 100) == 105,
            "Old companions retain receipt-relative compatibility")
        print("Android activity menu and timer synchronization tests passed")
    }
}
