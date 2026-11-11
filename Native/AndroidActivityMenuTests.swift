import AppKit

@main
struct AndroidActivityMenuTests {
    static func main() {
        ActivitySportsContextTests.run()
        let scoreNodes: [[String: Any]] = [
            ["kind": "image", "x": 0.05, "y": 0.02, "width": 0.15, "height": 0.2],
            ["kind": "text", "text": "24", "size": 28, "x": 0.05, "y": 0.24, "width": 0.15, "height": 0.12],
            ["kind": "text", "text": "TENN", "x": 0.05, "y": 0.4, "width": 0.15, "height": 0.08],
            ["kind": "text", "text": "17", "size": 28, "x": 0.8, "y": 0.24, "width": 0.15, "height": 0.12],
            ["kind": "text", "text": "SC", "x": 0.8, "y": 0.4, "width": 0.15, "height": 0.08],
            ["kind": "text", "text": "2:15 - 4th", "x": 0.35, "y": 0.15, "width": 0.3, "height": 0.1],
            ["kind": "text", "text": "1st & 15", "x": 0.35, "y": 0.28, "width": 0.3, "height": 0.1],
            ["kind": "text", "text": "Receiving Leaders", "x": 0.0, "y": 0.6, "width": 0.7, "height": 0.1]]
        let sportsEvent: [String: Any] = ["app": "ESPN", "customNodes": scoreNodes]
        let game = ActivityScoreboard(event: sportsEvent)!
        precondition(game.summary == "TENN 24 – 17 SC")
        precondition(game.details == ["2:15 - 4th", "1st & 15"])
        precondition(game.footerStart < 0.6)
        precondition(ActivityScoreboard(event: ["app": "Recorder", "customNodes": scoreNodes]) == nil)
        var kickoff = scoreNodes
        kickoff[1]["text"] = "6-1"; kickoff[3]["text"] = "12:00 PM"
        precondition(ActivityScoreboard(event: ["app": "ESPN", "customNodes": kickoff]) == nil)
        var update = scoreNodes
        update[1]["text"] = "31"
        precondition(ActivityScoreboard(event: ["app": "ESPN", "customNodes": update])?.left.score == "31")
        // Logos need not be above scores, nor confined to narrow geometric columns.
        var semanticNodes = scoreNodes
        semanticNodes[0].merge(["sportsTeam": 1, "sportsField": "logo", "x": 0.0, "y": 0.3, "width": 0.8, "image": "left-logo"]) { _, new in new }
        semanticNodes.append(["kind": "image", "sportsTeam": 2, "sportsField": "logo", "x": 0.2,
                              "y": 0.4, "width": 0.8, "image": "right-logo"])
        let semanticEvent: [String: Any] = ["app": "ESPN", "customNodes": semanticNodes]
        let semanticGame = ActivityScoreboard(event: semanticEvent)!
        precondition(semanticGame.left.image == "left-logo")
        precondition(semanticGame.right.image == "right-logo")
        precondition(semanticGame.summary == "TENN 24 – 17 SC")
        semanticNodes[0].removeValue(forKey: "image")
        precondition(ActivityScoreboard(event: ["app": "ESPN", "customNodes": semanticNodes])?.left.image == nil)
        semanticNodes[0]["image"] = "hydrated-left-logo"
        precondition(ActivityScoreboard(event: ["app": "ESPN", "customNodes": semanticNodes])?.left.image == "hydrated-left-logo")
        let footerNodes: [[String: Any]] = [
            ["sportsField": "note", "kind": "text", "text": "Receiving\nLeaders", "y": 0.6],
            ["sportsRow": 1, "sportsField": "playerName", "kind": "text", "text": "D. Vinson", "y": 0.75, "width": 0.03, "height": 0.01],
            ["sportsRow": 1, "sportsField": "playerStats", "kind": "text", "text": "1 REC, 45 YDS, 0 TD", "y": 0.8],
            ["sportsRow": 1, "sportsField": "portrait", "kind": "image", "image": "portrait-one", "y": 0.7],
            ["sportsRow": 2, "sportsField": "playerName", "kind": "text", "text": "A. Vander Zee", "y": 0.9],
            ["sportsRow": 2, "sportsField": "playerStats", "kind": "text", "text": "3 REC, 72 YDS, 1 TD", "y": 0.95]]
        let footer = ActivitySportsFooter(nodes: footerNodes, start: 0.5)
        precondition(footer.title == "Receiving" && footer.notes.isEmpty)
        precondition(footer.players.map(\.name) == ["D. Vinson", "A. Vander Zee"])
        precondition(footer.players.map(\.side) == [1, 2])
        precondition(footer.players[0].portrait == "portrait-one")
        precondition(footer.players[1].stats == "3 REC, 72 YDS, 1 TD")
        var explicitSides = footerNodes
        explicitSides[1]["sportsTeam"] = 2; explicitSides[4]["sportsTeam"] = 1
        precondition(ActivitySportsFooter(nodes: explicitSides, start: 0.5).players.map(\.side) == [2, 1])
        let singlePlayer = ActivitySportsFooter(nodes: Array(footerNodes.prefix(4)), start: 0.5)
        precondition(singlePlayer.players.count == 1 && singlePlayer.players[0].side == nil)
        // Turns are explicit, unambiguous source markers; yard lines are not possession.
        var turnNodes = scoreNodes
        turnNodes.append(["kind": "indicator", "sportsTeam": 1, "sportsField": "possession"])
        var turnEvent: [String: Any] = ["app": "ESPN", "customNodes": turnNodes]
        precondition(ActivityScoreboard(event: turnEvent)?.turn == .init(side: 1, kind: .possession))
        turnNodes[turnNodes.count - 1]["sportsTeam"] = 2
        turnEvent["customNodes"] = turnNodes
        precondition(ActivityScoreboard(event: turnEvent)?.turn?.side == 2)
        turnNodes[turnNodes.count - 1]["sportsField"] = "serving"
        turnEvent["customNodes"] = turnNodes
        precondition(ActivityScoreboard(event: turnEvent)?.turn?.kind == .serving)
        turnNodes[turnNodes.count - 1]["sportsField"] = "batting"
        turnEvent["customNodes"] = turnNodes
        precondition(ActivityScoreboard(event: turnEvent)?.turn?.kind == .batting)
        turnEvent["status"] = "Final/OT"
        precondition(ActivityScoreboard(event: turnEvent)?.turn == nil)
        turnEvent.removeValue(forKey: "status")
        turnNodes.append(["kind": "indicator", "sportsTeam": 1, "sportsField": "possession"])
        turnEvent["customNodes"] = turnNodes
        precondition(ActivityScoreboard(event: turnEvent)?.turn == nil, "Conflicting markers must not pick a side")
        precondition(ActivityScoreboard(event: sportsEvent)?.turn == nil)
        var statusNodes = scoreNodes
        statusNodes[5]["sportsField"] = "statusPrimary"
        statusNodes[6]["sportsField"] = "statusSecondary"
        statusNodes[6]["text"] = "2nd & Goal\nWIS 8"
        statusNodes[6]["x"] = 0.05; statusNodes[6]["y"] = 0.75
        let fullStatus = ActivityScoreboard(event: ["app": "ESPN", "customNodes": statusNodes])!
        precondition(fullStatus.details == ["2:15 - 4th", "2nd & Goal", "WIS 8"],
                     "Status fields must survive source positions below the team labels")
        let statusFooter = ActivitySportsFooter(nodes: statusNodes, start: fullStatus.footerStart)
        precondition(!statusFooter.notes.contains("2nd & Goal\nWIS 8"))
        statusNodes[6]["text"] = "2nd & Goal\nWIS 8\nWIS 8"
        precondition(ActivityScoreboard(event: ["app": "ESPN", "customNodes": statusNodes])?.details == fullStatus.details)
        precondition(ActivityScoreText.increases(from: "0", to: "7"))
        precondition(ActivityScoreText.increases(from: "9", to: "10"))
        precondition(!ActivityScoreText.increases(from: "7", to: "7"))
        precondition(!ActivityScoreText.increases(from: "7", to: "6"))
        precondition(!ActivityScoreText.increases(from: "", to: "0"))
        precondition(!ActivityScoreText.increases(from: "AD", to: "40"))
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
        let sportsManager = AndroidActivityMenu()
        var liveGame = sportsEvent
        liveGame["id"] = "game"; liveGame["version"] = "v1"; liveGame["activity"] = true
        sportsManager.update(liveGame)
        precondition(sportsManager.count == 0, "ESPN stays hidden before team artwork loads")
        let logo = NSImage(size: NSSize(width: 4, height: 4))
        logo.lockFocus(); NSColor.orange.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); logo.unlockFocus()
        let logoPNG = NSBitmapImageRep(data: logo.tiffRepresentation!)!.representation(using: .png, properties: [:])!.base64EncodedString()
        var readyNodes = semanticNodes
        readyNodes[0]["image"] = logoPNG
        liveGame["customNodes"] = readyNodes
        sportsManager.update(liveGame)
        precondition(sportsManager.count == 0, "One real logo and one invalid image must stay hidden")
        readyNodes[readyNodes.count - 1]["image"] = logoPNG
        liveGame["customNodes"] = readyNodes
        sportsManager.update(liveGame)
        precondition(sportsManager.count == 1, "Reveal only after both logos decode")
        sportsManager.prepareCard("game")
        let gameItem = sportsManager.itemIdentity("game")
        let gameStatus = sportsManager.statusIdentity("game")
        let gameCard = sportsManager.controllerIdentity("game")
        readyNodes[1]["text"] = "31"
        liveGame["customNodes"] = readyNodes; liveGame["version"] = "v2"
        sportsManager.update(liveGame)
        precondition(sportsManager.itemIdentity("game") == gameItem)
        precondition(sportsManager.statusIdentity("game") == gameStatus)
        precondition(sportsManager.controllerIdentity("game") == gameCard)
        readyNodes[0].removeValue(forKey: "image")
        liveGame["customNodes"] = readyNodes
        sportsManager.update(liveGame)
        precondition(sportsManager.count == 1, "Artwork refreshes retain the last complete card")
        precondition(sportsManager.itemIdentity("game") == gameItem)
        precondition(sportsManager.statusIdentity("game") == gameStatus)
        precondition(sportsManager.controllerIdentity("game") == gameCard)
        var openedVersion: String?
        sportsManager.onAction = { event, _ in openedVersion = event["version"] as? String }
        liveGame["version"] = "v3"; liveGame["canOpen"] = true
        sportsManager.update(liveGame)
        sportsManager.perform(id: "game", version: "v2", action: "open")
        precondition(openedVersion == nil, "A retained presentation cannot authorize an old token")
        sportsManager.perform(id: "game", version: "v3", action: "open")
        precondition(openedVersion == "v3")
        readyNodes[0]["image"] = logoPNG
        readyNodes[1]["text"] = "6-1"; readyNodes[3]["text"] = "12:00 PM"
        liveGame["customNodes"] = readyNodes
        sportsManager.update(liveGame)
        precondition(sportsManager.count == 1, "Pregame cards can appear once their semantic team logos load")
        sportsManager.clear()
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
