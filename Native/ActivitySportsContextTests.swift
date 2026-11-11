import Foundation

/// Ported behavior cases from dynamic-island's sport-context/history regressions.
enum ActivitySportsContextTests {
    static func event(_ context: String = "1st & 10\nIOWA 29", attack: Int? = 2, phase: String = "1st 5:18", left: String = "0", right: String = "3", version: String = "v1") -> [String: Any] {
        var nodes: [[String: Any]] = [
            ["kind": "image", "sportsTeam": 1, "sportsField": "logo"],
            ["kind": "image", "sportsTeam": 2, "sportsField": "logo"],
            ["kind": "text", "sportsTeam": 1, "sportsField": "name", "text": "WIS"],
            ["kind": "text", "sportsTeam": 2, "sportsField": "name", "text": "Iowa"],
            ["kind": "text", "sportsTeam": 1, "sportsField": "score", "text": left],
            ["kind": "text", "sportsTeam": 2, "sportsField": "score", "text": right],
            ["kind": "text", "sportsField": "statusPrimary", "text": phase]]
        if !context.isEmpty { nodes.append(["kind": "text", "sportsField": "statusSecondary", "text": context]) }
        if let attack { nodes.append(["kind": "indicator", "sportsTeam": attack, "sportsField": "possession"]) }
        return ["app": "ESPN", "id": "game", "version": version, "customNodes": nodes]
    }
    static func run() {
        func model(_ context: String, attack: Int? = 2, phase: String = "1st 5:18") -> ActivityScoreboard {
            ActivityScoreboard(event: event(context, attack: attack, phase: phase))!
        }
        precondition(model("1st & 10\nIOWA 29").field?.yards == 71)
        precondition(model("1st & 10\nIOWA 29").field?.target == 61)
        precondition(model("2nd & 7\nIowa 29", attack: 1).field?.target == 78)
        precondition(model("1st & 10\nWIS 29", attack: 1).field?.yards == 29)
        precondition(model("3rd & 4\nIowa 29", attack: nil).field?.target == nil)
        precondition(model("3rd & 4\nIowa 29", attack: nil).field?.yards == 71)
        precondition(model("1st & Goal\nIowa 5", attack: 1).field?.target == 100)
        precondition(model("2nd & Goal\nWIS 5", attack: 2).field?.target == 0)
        precondition(model("4th & 1\nMidfield 50", attack: 1).field?.yards == 50)
        for unsupported in ["Iowa 29", "1st & 10\nUnknown 29", "1st & 10\nIowa 65"] {
            precondition(model(unsupported).field == nil)
        }
        precondition(model("1st & 10\nIowa 29", phase: "Final").field == nil)
        precondition(model("Top 3rd · 2 Outs").outs == 2)
        precondition(model("1 out").outs == 1)
        precondition(model("0 outs").outs == 0)
        precondition(model("Top 3rd").outs == nil)
        precondition(model("4 outs").outs == nil)

        let history = ActivitySportsHistory()
        _ = history.observe(event("1st & 10\nWIS 45", attack: 1), now: 0)
        let gain = ActivityScoreboard(event: history.observe(event("1st & 10\nIowa 48", attack: 1, version: "v2"), now: 1))!
        precondition(gain.lastPlay?.gain == 7)
        let tick = ActivityScoreboard(event: history.observe(event("1st & 10\nIowa 48", attack: 1, phase: "1st 5:12", version: "v3"), now: 2))!
        precondition(tick.lastPlay == gain.lastPlay)
        let loss = ActivityScoreboard(event: history.observe(event("1st & 10\nWIS 49", attack: 1, version: "v4"), now: 3))!
        precondition(loss.lastPlay?.gain == -3)
        precondition(ActivityScoreboard(event: history.observe(event("1st & 10\nWIS 40", attack: 2, version: "v5"), now: 4))?.lastPlay == nil)
        precondition(ActivityScoreboard(event: history.observe(event("1st & 10\nWIS 30", attack: 2, phase: "2nd 15:00", version: "v6"), now: 5))?.lastPlay == nil)
        history.clear()
        _ = history.observe(event("1st & 10\nIowa 29", attack: 2), now: 0)
        precondition(ActivityScoreboard(event: history.observe(event("1st & 10\nIowa 39", attack: 2, version: "v2"), now: 1))?.lastPlay?.gain == 10)

        // The drive trail spans every observed play since possession changed, survives
        // quarter changes and possession-less panels, and resets on turnover or score.
        history.clear()
        _ = history.observe(event("1st & 10\nWIS 25", attack: 1), now: 0)
        _ = history.observe(event("1st & 10\nWIS 40", attack: 1, version: "v2"), now: 1)
        let drive = ActivityScoreboard(event: history.observe(event("2nd & 4\nWIS 46", attack: 1, version: "v3"), now: 2))!
        precondition(drive.drive?.gain == 21 && drive.lastPlay?.gain == 6)
        _ = history.observe(event("2nd & 4\nWIS 46", attack: nil, version: "v4"), now: 3)
        let nextQuarter = ActivityScoreboard(event: history.observe(event("1st & 10\nIowa 45", attack: 1, phase: "2nd 15:00", version: "v5"), now: 4))!
        precondition(nextQuarter.drive?.from == 25 && nextQuarter.drive?.gain == 30 && nextQuarter.lastPlay == nil)
        let turnover = ActivityScoreboard(event: history.observe(event("1st & 10\nIowa 40", attack: 2, phase: "2nd 14:20", version: "v6"), now: 5))!
        precondition(turnover.drive?.gain == 0)
        _ = history.observe(event("1st & 10\nWIS 30", attack: 2, phase: "2nd 12:00", version: "v7"), now: 6)
        let scored = ActivityScoreboard(event: history.observe(event("1st & 10\nWIS 30", attack: 2, phase: "2nd 12:00", right: "10", version: "v8"), now: 7))!
        precondition(scored.scoring?.team == 2 && scored.drive?.from == 60 && scored.field?.yards == 0)
        let afterScore = ActivityScoreboard(event: history.observe(event("1st & 10\nWIS 25", attack: 1, phase: "2nd 11:50", right: "10", version: "v9"), now: 8))!
        precondition(afterScore.scoring == nil && afterScore.drive?.gain == 0)

        // A touchdown panel without a spot keeps the field, sliding the ball into the
        // scorer's end zone; the extra point continues it; the next real spot clears it.
        history.clear()
        _ = history.observe(event("1st & 10\nWIS 30", attack: 1, left: "21", right: "12"), now: 0)
        _ = history.observe(event("2nd & 2\nIowa 22", attack: 1, left: "21", right: "12", version: "v2"), now: 1)
        let td = ActivityScoreboard(event: history.observe(event("", attack: nil, left: "27", right: "12", version: "v3"), now: 2))!
        precondition(td.scoring == ActivityFootballScore(team: 1, label: "Touchdown"))
        precondition(td.field?.yards == 100 && td.field?.target == nil && td.lastPlay?.from == 78 && td.drive?.from == 30)
        let xp = ActivityScoreboard(event: history.observe(event("", attack: nil, left: "28", right: "12", version: "v4"), now: 3))!
        precondition(xp.scoring?.label == "Touchdown" && xp.field?.yards == 100 && xp.drive?.from == 30)
        let held = ActivityScoreboard(event: history.observe(event("", attack: nil, phase: "1st 5:10", left: "28", right: "12", version: "v5"), now: 4))!
        precondition(held.scoring?.team == 1)
        let kickoff = ActivityScoreboard(event: history.observe(event("1st & 10\nIowa 25", attack: 2, phase: "1st 5:02", left: "28", right: "12", version: "v6"), now: 5))!
        precondition(kickoff.scoring == nil && kickoff.field?.yards == 75 && kickoff.drive?.gain == 0)
        // Team 2 field goal and a defensive safety (team 1 has the ball, team 2 scores).
        _ = history.observe(event("4th & 3\nWIS 20", attack: 2, phase: "1st 2:00", left: "28", right: "12", version: "v7"), now: 6)
        let fg = ActivityScoreboard(event: history.observe(event("", attack: nil, phase: "1st 1:55", left: "28", right: "15", version: "v8"), now: 7))!
        precondition(fg.scoring == ActivityFootballScore(team: 2, label: "Field goal") && fg.field?.yards == 0)
        _ = history.observe(event("1st & 10\nWIS 3", attack: 1, phase: "1st 1:00", left: "28", right: "15", version: "v9"), now: 8)
        let safety = ActivityScoreboard(event: history.observe(event("", attack: nil, phase: "1st 0:50", left: "28", right: "17", version: "v10"), now: 9))!
        precondition(safety.scoring == ActivityFootballScore(team: 2, label: "Safety") && safety.field?.yards == 0 && safety.drive?.from == 3)
        // A score panel that still shows the stale pre-score down & spot is a scoring
        // play too: no first-down marker, and the stale lines leave the center status.
        history.clear()
        _ = history.observe(event("1st & Goal\nIowa 3", attack: 1, left: "7", right: "0"), now: 0)
        let stale = ActivityScoreboard(event: history.observe(event("1st & Goal\nIowa 3", attack: 1, left: "13", right: "0", version: "v2"), now: 1))!
        precondition(stale.scoring?.team == 1 && stale.field?.target == nil && stale.field?.yards == 100)
        precondition(!stale.displayDetails.contains("1st & Goal") && !stale.displayDetails.contains("Iowa 3"))
        let staleXP = ActivityScoreboard(event: history.observe(event("1st & Goal\nIowa 3", attack: 1, left: "14", right: "0", version: "v3"), now: 2))!
        precondition(staleXP.scoring?.team == 1 && staleXP.field?.target == nil)
        let newSpot = ActivityScoreboard(event: history.observe(event("1st & 10\nIowa 25", attack: 2, left: "14", right: "0", version: "v4"), now: 3))!
        precondition(newSpot.scoring == nil && newSpot.field?.target == 65)
        // No football context (e.g. no spot ever seen) never synthesizes a field.
        history.clear()
        _ = history.observe(event("", attack: nil, left: "0", right: "0"), now: 0)
        precondition(ActivityScoreboard(event: history.observe(event("", attack: nil, left: "7", right: "0", version: "v2"), now: 1))?.field == nil)

        history.clear()
        _ = history.observe(event("1st & 10\nWIS 20"), now: 0)
        let retained = history.observe(event("", phase: "1st 5:12", version: "v2"), now: 60)
        precondition(ActivityScoreboard(event: retained)?.details.contains("WIS 20") == true)
        // Artwork callbacks and repeated omitted panels cannot extend the original TTL.
        _ = history.observe(event("", phase: "1st 5:11", version: "v3"), now: 119)
        precondition(ActivityScoreboard(event: history.observe(event("", phase: "1st 5:10", version: "v4"), now: 121))?.details.contains("WIS 20") == false)
        history.clear()
        _ = history.observe(event("1st & 10\nWIS 20"), now: 0)
        // A score never carries the stale spot text; the field becomes a synthesized
        // scoring play (here a defensive TD by team 1 while team 2 had the ball).
        let scoreChange = ActivityScoreboard(event: history.observe(event("", left: "7", version: "score-change"), now: 1))!
        precondition(!scoreChange.details.contains("WIS 20") && scoreChange.field?.yards == 100 && scoreChange.scoring?.team == 1)
        history.clear()
        _ = history.observe(event("1st & 10\nWIS 20"), now: 0)
        precondition(ActivityScoreboard(event: history.observe(event("", phase: "Halftime", version: "break"), now: 1))?.field == nil)
        history.remove("game")
        precondition(ActivityScoreboard(event: history.observe(event("", version: "fresh"), now: 2))?.field == nil)

        // Source-owned clock ticks change wire versions, but are not fresh context.
        history.clear()
        var clockSource = event("1st & 10\nWIS 20")
        clockSource["postedAt"] = 12345
        _ = history.observe(clockSource, now: 0)
        clockSource["version"] = "clock-tick-v2"
        _ = history.observe(clockSource, now: 100)
        var clockPanel = event("", phase: "1st 5:10", version: "clock-panel-v3")
        clockPanel["postedAt"] = 12345
        precondition(ActivityScoreboard(event: history.observe(clockPanel, now: 121))?.field == nil)
        var sourceClock = event("", attack: nil, phase: "14:53 - 2nd")
        var clockNodes = sourceClock["customNodes"] as! [[String: Any]]
        clockNodes[6]["sportsField"] = "gameClock"
        sourceClock["customNodes"] = clockNodes
        precondition(ActivityScoreboard(event: sourceClock)?.gameClockText == "14:53 - 2nd")

        var sets = event("Serving", attack: nil, left: "AD", right: "40")
        var nodes = sets["customNodes"] as! [[String: Any]]
        nodes += [["kind": "text", "sportsTeam": 1, "sportsField": "setScore", "text": "6 7 4"],
                  ["kind": "text", "sportsTeam": 2, "sportsField": "setScore", "text": "4 5 3"],
                  ["kind": "indicator", "sportsTeam": 1, "sportsField": "serving"]]
        sets["customNodes"] = nodes
        let tennis = ActivityScoreboard(event: sets)!
        precondition(tennis.left.score == "AD" && tennis.right.score == "40")
        precondition(tennis.setScores.count == 2 && tennis.setScores[0].text == "6 7 4")
        precondition(tennis.turn?.kind == .serving)
        precondition(ActivitySportsFooter(nodes: nodes, start: tennis.footerStart).notes.allSatisfy { !$0.contains("6 7 4") })

        var pregame = event("", attack: nil, phase: "12:00 PM", left: "", right: "")
        var preNodes = pregame["customNodes"] as! [[String: Any]]
        preNodes.append(["kind": "text", "sportsField": "broadcast", "text": "ABC"])
        pregame["customNodes"] = preNodes
        let scheduled = ActivityScoreboard(event: pregame)!
        precondition(scheduled.left.score.isEmpty && scheduled.right.score.isEmpty && scheduled.turn == nil)
        precondition(scheduled.details.contains("ABC"))
        precondition(ActivityCompactScoreLayout.contentWidth(scheduled) == 55)

        var baseball = event("Top 3rd · 2 Outs", attack: nil)
        var baseNodes = baseball["customNodes"] as! [[String: Any]]
        baseNodes.append(["kind": "image", "sportsField": "bases", "image": "occupancy-png"])
        baseNodes.append(["kind": "indicator", "sportsTeam": 2, "sportsField": "batting"])
        baseball["customNodes"] = baseNodes
        precondition(ActivityScoreboard(event: baseball)?.basesImage == "occupancy-png")
        precondition(ActivityScoreboard(event: baseball)?.turn?.kind == .batting)
        print("Sports field, first-down, play history, bounded context, pregame, sets, bases and turn regressions passed")
    }
}
