import AppKit
import SwiftUI

/// Android notification styles share a header and action row; only their body layout changes.
struct AndroidActivityPresentation {
    enum Layout: String { case standard, bigText, bigPicture, inbox, messaging, call, progress, custom }
    let event: [String: Any]
    let clockAnchor: TimeInterval
    var layout: Layout {
        if let raw = event["layout"] as? String, let supplied = Layout(rawValue: raw) { return supplied }
        if event["indeterminate"] as? Bool == true || number("progressMax") > 0 { return .progress }
        return .standard
    }
    func text(_ key: String) -> String { event[key] as? String ?? "" }
    func number(_ key: String) -> Double { (event[key] as? NSNumber)?.doubleValue ?? 0 }
    var actions: [[String: Any]] {
        Array((event["actions"] as? [[String: Any]] ?? []).prefix(3)).filter { $0["reply"] as? Bool != true }
    }
    var progress: Double? { number("progressMax") > 0 ? min(1, max(0, number("progressValue") / number("progressMax"))) : nil }
    var lines: [String] { Array((event["lines"] as? [String] ?? []).prefix(7)) }
    var messages: [[String: Any]] { Array((event["messages"] as? [[String: Any]] ?? []).suffix(5)) }
    var customNodes: [[String: Any]] { Array((event["customNodes"] as? [[String: Any]] ?? []).prefix(32)) }
    var dark: Bool { event["dark"] as? Bool ?? true }
    var accent: Color { accent(dark: dark) }
    /// Android accents are chosen for the phone's surface, not this popup's. Keep them legible against the
    /// Mac appearance actually rendering the card: near-gray accents (e.g. ChatGPT's black) become the primary
    /// label color, and saturated ones are lightened/darkened until they clear a minimum contrast.
    func accent(dark: Bool) -> Color {
        let value = UInt32(truncatingIfNeeded: Int64(number("accentColor")))
        guard value & 0x00ffffff != 0 else { return dark ? Color(red: 0.67, green: 0.78, blue: 1) : Color(red: 0.2, green: 0.35, blue: 0.65) }
        var r = Double((value >> 16) & 255) / 255, g = Double((value >> 8) & 255) / 255, b = Double(value & 255) / 255
        if max(r, g, b) - min(r, g, b) < 0.12 { return .primary }
        func luminance() -> Double {
            func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        // Approximate popup surfaces: dark ≈ #1e1e1e, light ≈ #f5f5f5; require ~4.5:1.
        let surface = dark ? 0.013 : 0.91
        for _ in 0..<12 {
            let l = luminance()
            let contrast = dark ? (l + 0.05) / (surface + 0.05) : (surface + 0.05) / (l + 0.05)
            if contrast >= 4.5 { break }
            let toward = dark ? 1.0 : 0.0
            r += (toward - r) * 0.2; g += (toward - g) * 0.2; b += (toward - b) * 0.2
        }
        return Color(red: r, green: g, blue: b)
    }
    func image(_ key: String) -> NSImage? { Self.image(event[key] as? String) }
    static func image(_ encoded: String?) -> NSImage? {
        guard let encoded, encoded.count <= 174764, let data = Data(base64Encoded: encoded), data.count <= 131072 else { return nil }
        return NSImage(data: data)
    }
    func clock(now: TimeInterval) -> String? {
        if event["clockPausedMs"] is NSNumber { return AndroidActivityMenu.clock(number("clockPausedMs") / 1000, countDown: event["countDown"] as? Bool == true) }
        guard event["chronometer"] as? Bool == true else { return nil }
        let down = event["countDown"] as? Bool == true
        return AndroidActivityMenu.clock(down ? clockAnchor - now : now - clockAnchor, countDown: down)
    }
}

/// Sample saturated logo pixels so transparent padding and white outlines do not
/// turn every team's tint gray. Cache decoded palettes across score updates.
private enum ActivityTeamPalette {
    static let cache: NSCache<NSString, NSColor> = {
        let cache = NSCache<NSString, NSColor>(); cache.countLimit = 64; return cache
    }()
    static func color(_ encoded: String?) -> Color? {
        guard let encoded, encoded.count <= 174764 else { return nil }
        if let cached = cache.object(forKey: encoded as NSString) { return Color(nsColor: cached) }
        guard let data = Data(base64Encoded: encoded), data.count <= 131072,
              let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return nil }
        var weights = [Double](repeating: 0, count: 36)
        var reds = weights, greens = weights, blues = weights
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 32)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 32)) {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      pixel.alphaComponent >= 0.5, pixel.saturationComponent >= 0.2,
                      pixel.brightnessComponent >= 0.12 else { continue }
                let bucket = min(35, Int(pixel.hueComponent * 36))
                let weight = Double(pixel.alphaComponent * pixel.saturationComponent)
                weights[bucket] += weight
                reds[bucket] += Double(pixel.redComponent) * weight
                greens[bucket] += Double(pixel.greenComponent) * weight
                blues[bucket] += Double(pixel.blueComponent) * weight
            }
        }
        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }), weights[best] > 0 else { return nil }
        let color = NSColor(srgbRed: reds[best] / weights[best], green: greens[best] / weights[best],
                            blue: blues[best] / weights[best], alpha: 1)
        cache.setObject(color, forKey: encoded as NSString)
        return Color(nsColor: color)
    }
}

/// Recognize a two-column ESPN scoreboard only when both scores and team labels exist.
/// Never interpret records (6-1), kickoff times, or a lone possession/yard marker as scores.
struct ActivityScoreboard {
    struct Team {
        let name: String
        let score: String
        let image: String?
        let color: UInt32?
        var tint: Color { ActivityTeamPalette.color(image) ?? scoreColor ?? .gray }
        func ink(dark: Bool) -> Color {
            let base = NSColor(scoreColor ?? tint).usingColorSpace(.deviceRGB) ?? .gray
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let background = dark ? 0.03 : 0.9
            for step in 0...20 {
                let lift = Double(step) / 20
                let target = dark ? 1.0 : 0.0
                let r = Double(base.redComponent) * (1 - lift) + target * lift
                let g = Double(base.greenComponent) * (1 - lift) + target * lift
                let b = Double(base.blueComponent) * (1 - lift) + target * lift
                let light = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
                if (max(light, background) + 0.05) / (min(light, background) + 0.05) >= 4.5 {
                    return Color(red: r, green: g, blue: b)
                }
            }
            return .primary
        }
        var scoreColor: Color? {
            guard let color else { return nil }
            let r = Double((color >> 16) & 255) / 255
            let g = Double((color >> 8) & 255) / 255
            let b = Double(color & 255) / 255
            guard max(r, g, b) - min(r, g, b) >= 0.12 else { return nil }
            return Color(red: r, green: g, blue: b)
        }
    }
    struct Turn: Equatable {
        enum Kind: String { case possession, serving, batting }
        let side: Int
        let kind: Kind
        var label: String {
            switch kind {
            case .possession: return "Has possession"
            case .serving: return "Serving"
            case .batting: return "Batting"
            }
        }
        // A neutral turn badge also applies to volleyball and other serving sports.
        var symbol: String { "circle.fill" }
    }
    let turn: Turn?
    let left: Team
    let right: Team
    let details: [String]
    let footerStart: Double
    let primaryStatus: String
    let secondaryStatus: String
    let basesImage: String?
    let setScores: [(team: Int?, text: String)]
    let gameClockText: String?
    let lastPlay: ActivityFootballPlay?
    /// Observed movement since the current team gained possession (drive start → ball).
    let drive: ActivityFootballPlay?
    /// Synthesized by ActivitySportsHistory when a score arrives without a spot.
    let scoring: ActivityFootballScore?

    static func isESPN(_ event: [String: Any]) -> Bool {
        event["package"] as? String == "com.espn.score_center" || (event["app"] as? String)?.uppercased() == "ESPN"
    }
    static func hasLoadedLogos(_ event: [String: Any]) -> Bool {
        let nodes = event["customNodes"] as? [[String: Any]] ?? []
        let game = ActivityScoreboard(event: event)
        let images = [1, 2].map { side -> String? in
            if let node = nodes.first(where: {
                ($0["sportsTeam"] as? NSNumber)?.intValue == side && $0["sportsField"] as? String == "logo"
            }) { return node["image"] as? String }
            return side == 1 ? game?.left.image : game?.right.image
        }
        return images.allSatisfy { AndroidActivityPresentation.image($0)?.isValid == true }
    }
    init?(event: [String: Any]) {
        guard Self.isESPN(event), let nodes = event["customNodes"] as? [[String: Any]] else { return nil }
        func number(_ n: [String: Any], _ key: String) -> Double { (n[key] as? NSNumber)?.doubleValue ?? 0 }
        func center(_ n: [String: Any]) -> Double { number(n, "x") + number(n, "width") / 2 }
        func text(_ n: [String: Any]) -> String { (n["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func side(_ right: Bool) -> (Team, Double, Double)? {
            let side = right ? 2 : 1
            func tagged(_ node: [String: Any], _ field: String) -> Bool {
                number(node, "sportsTeam") == Double(side) && node["sportsField"] as? String == field
            }
            let column = nodes.filter {
                if let team = $0["sportsTeam"] as? NSNumber { return team.intValue == side }
                return right ? center($0) > 0.67 : center($0) < 0.33
            }
            let scores = column.filter {
                $0["sportsField"] as? String != "setScore" &&
                (text($0).range(of: "^(?:[0-9]{1,3}|AD|A)$", options: .regularExpression) != nil) &&
                    (tagged($0, "score") || (number($0, "y") < 0.65 && ($0["size"] == nil || number($0, "size") >= 20)))
            }
            let score = scores.first(where: { tagged($0, "score") }) ?? scores.max(by: { number($0, "size") < number($1, "size") })
            let explicitLogo = nodes.first(where: { tagged($0, "logo") })
            let labels = column.filter {
                !text($0).isEmpty && !["setScore", "statusPrimary", "statusSecondary", "gameClock", "broadcast", "note"].contains($0["sportsField"] as? String ?? "") && (tagged($0, "name") ||
                    (text($0).range(of: "^[A-Z][A-Z .&-]{1,11}$", options: .regularExpression) != nil &&
                     number($0, "y") < 0.65 && (score == nil || abs(number($0, "y") - number(score!, "y")) <= 0.25)))
            }
            let label = labels.first(where: { tagged($0, "name") }) ?? labels.min(by: { abs(number($0, "y") - (score.map { number($0, "y") } ?? 0)) < abs(number($1, "y") - (score.map { number($0, "y") } ?? 0)) })
            guard label != nil || explicitLogo != nil else { return nil }
            guard score != nil || explicitLogo != nil || labels.contains(where: { tagged($0, "name") }) else { return nil }
            let logo = explicitLogo ?? column.filter {
                $0["kind"] as? String == "image" && $0["sportsField"] as? String != "bases" &&
                    number($0, "y") <= (score.map { number($0, "y") } ?? 0.6) + 0.025
            }.max(by: { number($0, "y") < number($1, "y") })
            let bottom = max(score.map { number($0, "y") + number($0, "height") } ?? 0,
                             label.map { number($0, "y") + number($0, "height") } ?? 0.5)
            return (Team(name: label.map(text) ?? "", score: score.map(text) ?? "", image: logo?["image"] as? String,
                         color: (score?["color"] as? NSNumber)?.uint32Value), score.map { number($0, "y") } ?? 0, bottom)
        }
        guard let l = side(false), let r = side(true), abs(l.1 - r.1) < 0.12 else { return nil }
        left = l.0; right = r.0
        let markers = nodes.compactMap { node -> Turn? in
            guard let side = (node["sportsTeam"] as? NSNumber)?.intValue, (1...2).contains(side),
                  let raw = node["sportsField"] as? String, let kind = Turn.Kind(rawValue: raw) else { return nil }
            return Turn(side: side, kind: kind)
        }
        let terminal = ([event["status"], event["body"]].compactMap { $0 as? String } + nodes.compactMap { $0["text"] as? String })
            .contains { $0.range(of: "\\b(final(?:[ /-]*score)?|full[ /-]?time|ft|ended|postgame)\\b", options: [.regularExpression, .caseInsensitive]) != nil }
        turn = !terminal && !left.score.isEmpty && !right.score.isEmpty && !markers.isEmpty && markers.allSatisfy({ $0.side == markers[0].side }) ? markers[0] : nil
        let cutoff = min(1, max(l.2, r.2) + 0.025)
        footerStart = cutoff
        let statusFields = ["gameClock", "statusPrimary", "statusSecondary"]
        let explicitStatus = statusFields.flatMap { field in nodes.filter { $0["sportsField"] as? String == field } }
        let geometricStatus = nodes.filter {
            center($0) >= 0.33 && center($0) <= 0.67 && number($0, "y") < cutoff &&
                $0["sportsRow"] == nil && !["note", "setScore", "broadcast"].contains($0["sportsField"] as? String ?? "") && !text($0).isEmpty
        }.sorted { number($0, "y") < number($1, "y") }
        let primary = nodes.filter { ["gameClock", "statusPrimary"].contains($0["sportsField"] as? String ?? "") }.map(text)
        primaryStatus = primary.isEmpty ? (geometricStatus.first.map(text) ?? "") : primary.joined(separator: " ")
        secondaryStatus = nodes.first(where: { $0["sportsField"] as? String == "statusSecondary" }).map(text) ?? ""
        gameClockText = nodes.first(where: { $0["sportsField"] as? String == "gameClock" }).map(text)
        basesImage = nodes.first(where: { $0["sportsField"] as? String == "bases" })?["image"] as? String
        setScores = nodes.filter { $0["sportsField"] as? String == "setScore" && !text($0).isEmpty }.map {
            ((($0["sportsTeam"] as? NSNumber)?.intValue).flatMap { (1...2).contains($0) ? $0 : nil }, text($0))
        }
        if let raw = event["_sportsPlay"] as? [String: Any], let from = raw["from"] as? Double,
           let to = raw["to"] as? Double, let team = raw["team"] as? Int, (0...100).contains(from), (0...100).contains(to), (1...2).contains(team) {
            lastPlay = ActivityFootballPlay(from: from, to: to, team: team)
        } else { lastPlay = nil }
        if let raw = event["_sportsDrive"] as? [String: Any], let from = raw["from"] as? Double,
           let to = raw["to"] as? Double, let team = raw["team"] as? Int, (0...100).contains(from), (0...100).contains(to), (1...2).contains(team) {
            drive = ActivityFootballPlay(from: from, to: to, team: team)
        } else { drive = nil }
        if let raw = event["_sportsScore"] as? [String: Any], let team = raw["team"] as? Int, (1...2).contains(team),
           let label = raw["label"] as? String {
            scoring = ActivityFootballScore(team: team, label: label)
        } else { scoring = nil }
        let extra = secondaryStatus.isEmpty ? (event["_sportsContext"] as? String ?? "") : ""
        let broadcast = left.score.isEmpty && right.score.isEmpty ? nodes.filter { $0["sportsField"] as? String == "broadcast" }.map(text) : []
        var seen = Set<String>()
        details = ((explicitStatus + geometricStatus).map(text) + [extra] + broadcast).flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.uppercased() != "ESPN" && seen.insert($0).inserted }
    }
    var summary: String {
        let score = "\(left.name) \(left.score) – \(right.score) \(right.name)"
        guard let turn else { return score }
        return score + " · " + (turn.side == 1 ? left.name : right.name) + ": " + turn.label
    }
}

struct ActivityFootballField: Equatable {
    let sourceText: String
    let yards: Double
    let target: Double?
    let attackingTeam: Int?
}
struct ActivityFootballScore: Equatable {
    let team: Int
    let label: String
    /// Team 1 attacks toward yard 100, team 2 toward yard 0 (a safety lands in the
    /// defending team's own end zone, which is also the scorer's attacking end).
    var endZone: Double { team == 1 ? 100 : 0 }
    static func label(points: Int) -> String {
        switch points {
        case 6...8: return "Touchdown"
        case 3: return "Field goal"
        case 2: return "Safety"
        case 1: return "Extra point"
        default: return "Score"
        }
    }
}
struct ActivityFootballPlay: Equatable {
    let from: Double
    let to: Double
    let team: Int
    var gain: Int { Int((to - from) * (team == 1 ? 1 : -1)) }
}

extension ActivityScoreboard {
    var isFinal: Bool { details.joined(separator: " ").range(of: "\\b(final|full[ -]?time|ft|ended|postgame)\\b", options: [.regularExpression, .caseInsensitive]) != nil }
    var field: ActivityFootballField? {
        guard !isFinal else { return nil }
        // Score panels replace down & distance with the play text (or briefly keep the
        // stale pre-score spot); keep the graph up with the ball in the scoring team's
        // end zone and no first-down marker until a new spot arrives.
        if let scoring { return ActivityFootballField(sourceText: "", yards: scoring.endZone, target: nil, attackingTeam: scoring.team) }
        return parsedField
    }
    /// Center status lines; a stale down & distance/spot is hidden during a scoring play.
    var displayDetails: [String] {
        guard scoring != nil else { return details.filter { $0 != field?.sourceText } }
        let spot = parsedField?.sourceText
        return details.filter { $0 != spot && $0.range(of: "\\b[1-4](?:st|nd|rd|th)\\s*(?:&|and)\\s*(?:\\d{1,2}|goal)\\b", options: [.regularExpression, .caseInsensitive]) == nil }
    }
    private var parsedField: ActivityFootballField? {
        let status = details.joined(separator: "\n")
        guard let regex = try? NSRegularExpression(pattern: "\\b[1-4](?:st|nd|rd|th)\\s*(?:&|and)\\s*(\\d{1,2}|goal)\\b", options: .caseInsensitive),
              let down = regex.firstMatch(in: status, range: NSRange(status.startIndex..., in: status)),
              let range = Range(down.range(at: 1), in: status) else { return nil }
        let distance = Double(status[range])
        for line in details {
            let parts = line.split(separator: " ")
            guard let last = parts.last, last.range(of: "^[0-9]{1,2}$", options: .regularExpression) != nil,
                  let yard = Double(last) else { continue }
            let name = parts.dropLast().joined(separator: " ")
            let position: Double
            if yard == 50 && (name.isEmpty || name.lowercased() == "midfield") { position = 50 }
            else if (1...50).contains(yard), !name.isEmpty && name.caseInsensitiveCompare(left.name) == .orderedSame { position = yard }
            else if (1...50).contains(yard), !name.isEmpty && name.caseInsensitiveCompare(right.name) == .orderedSame { position = 100 - yard }
            else { continue }
            let attack = turn?.kind == .possession ? turn?.side : nil
            let target: Double?
            if attack == 1 { target = distance.map { min(100, position + $0) } ?? 100 }
            else if attack == 2 { target = distance.map { max(0, position - $0) } ?? 0 }
            else { target = nil }
            return ActivityFootballField(sourceText: line, yards: position, target: target, attackingTeam: attack)
        }
        return nil
    }
    var outs: Int? {
        let text = details.joined(separator: " ")
        guard let regex = try? NSRegularExpression(pattern: "\\b([0-3])\\s+outs?\\b", options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}

/// Notification-local context only. Rotating panels cannot renew the two-minute
/// lifetime, cross a period/score/team change, or invent a new possession.
final class ActivitySportsHistory {
    private struct Entry {
        let game: String
        let phase: String
        let scores: String
        let context: String
        let contextAt: TimeInterval
        let version: String
        let field: ActivityFootballField?
        let play: ActivityFootballPlay?
        /// Drive start survives quarter changes and missing possession panels, but a
        /// score, team change, halftime/final or new attacking team starts a new drive.
        let driveStart: Double?
        let driveTeam: Int?
        /// Most recent real spot in this game/score, retained across spotless panels.
        let lastSpot: Double?
        let scoring: Scoring?
    }
    private struct Scoring {
        let team: Int
        let base: (Int, Int)
        let from: Double?
        /// The pre-score spot; ESPN may keep showing it on the score panel.
        let staleSpot: Double?
        let driveFrom: Double?
        let points: Int
    }
    private var entries = [String: Entry]()
    func remove(_ id: String) { entries.removeValue(forKey: id) }
    func clear() { entries.removeAll() }
    func reconcile(_ ids: Set<String>) { entries = entries.filter { ids.contains($0.key) } }
    func observe(_ event: [String: Any], now: TimeInterval = ActivityClock.now) -> [String: Any] {
        guard let id = event["id"] as? String else { return event }
        guard let score = ActivityScoreboard(event: event) else { remove(id); return event }
        var result = event
        let game = [score.left.name, score.right.name].map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
        let scores = score.left.score + "\n" + score.right.score
        let phase = score.primaryStatus.replacingOccurrences(of: "\\b\\d{1,3}:\\d{2}(?::\\d{2})?(?:[.,]\\d+)?\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\\s–—-]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let terminal = phase.range(of: "\\b(final|halftime|half time|intermission|postponed|cancelled|canceled|suspended|delayed|pregame|scheduled)\\b", options: .regularExpression) != nil
        if terminal { remove(id); return event }
        let previous = entries[id].flatMap { $0.game == game && $0.phase == phase && $0.scores == scores ? $0 : nil }
        var context = score.secondaryStatus
        var contextAt = now
        // Source clock ticks rotate action tokens but are not new context observations.
        let version = (event["postedAt"] as? NSNumber)?.stringValue ?? event["version"] as? String ?? ""
        if context.isEmpty, let previous, now >= previous.contextAt, now - previous.contextAt <= 120 {
            context = previous.context; contextAt = previous.contextAt
            if !context.isEmpty { result["_sportsContext"] = context }
        } else if let previous, previous.version == version, previous.context == context { contextAt = previous.contextAt }
        let enriched = ActivityScoreboard(event: result) ?? score
        let field = enriched.field
        var play: ActivityFootballPlay?
        if let field, let attack = field.attackingTeam, let old = previous?.field, old.attackingTeam == attack {
            play = old.yards == field.yards ? previous?.play : ActivityFootballPlay(from: old.yards, to: field.yards, team: attack)
        }
        let sameGame = entries[id].flatMap { $0.game == game ? $0 : nil }
        if let prior = sameGame, let scoring = Self.scoring(prior: prior, scores: scores),
           field == nil || field?.yards == scoring.staleSpot {
            let team = scoring.team, end = team == 1 ? 100.0 : 0.0
            result["_sportsScore"] = ["team": team, "label": ActivityFootballScore.label(points: scoring.points)]
            if let from = scoring.from { result["_sportsPlay"] = ["from": from, "to": end, "team": team] }
            if let from = scoring.driveFrom ?? scoring.from { result["_sportsDrive"] = ["from": from, "to": end, "team": team] }
            // The next real spot always starts a new drive.
            entries[id] = Entry(game: game, phase: phase, scores: scores, context: context, contextAt: contextAt, version: version, field: nil, play: nil,
                                driveStart: nil, driveTeam: nil, lastSpot: nil, scoring: scoring)
            return result
        }
        if let play { result["_sportsPlay"] = ["from": play.from, "to": play.to, "team": play.team] }
        let sameDrive = sameGame.flatMap { $0.scores == scores ? $0 : nil }
        var driveStart = sameDrive?.driveStart, driveTeam = sameDrive?.driveTeam
        if let field, let attack = field.attackingTeam {
            if driveTeam != attack || driveStart == nil { driveStart = field.yards; driveTeam = attack }
            if let start = driveStart { result["_sportsDrive"] = ["from": start, "to": field.yards, "team": attack] }
        }
        entries[id] = Entry(game: game, phase: phase, scores: scores, context: context, contextAt: contextAt, version: version, field: field, play: play,
                            driveStart: driveStart, driveTeam: driveTeam, lastSpot: field?.yards ?? sameDrive?.lastSpot, scoring: nil)
        if entries.count > 128, let victim = entries.keys.first(where: { $0 != id }) { entries.removeValue(forKey: victim) }
        return result
    }
    private static func points(_ scores: String) -> (Int, Int)? {
        let parts = scores.split(separator: "\n", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 2, let l = parts[0], let r = parts[1] else { return nil }
        return (l, r)
    }
    /// A spotless panel whose score rose for exactly one team, in a game already showing
    /// a football field, starts (or continues, e.g. TD then extra point) a scoring play.
    private static func scoring(prior: Entry, scores: String) -> Scoring? {
        guard let now = points(scores) else { return nil }
        if let s = prior.scoring {
            let delta = (now.0 - s.base.0, now.1 - s.base.1)
            let mine = s.team == 1 ? delta.0 : delta.1, other = s.team == 1 ? delta.1 : delta.0
            guard mine > 0, other == 0 else { return nil }
            return Scoring(team: s.team, base: s.base, from: s.from, staleSpot: s.staleSpot, driveFrom: s.driveFrom, points: mine)
        }
        guard prior.scores != scores, prior.lastSpot != nil || prior.driveTeam != nil,
              let before = points(prior.scores) else { return nil }
        let delta = (now.0 - before.0, now.1 - before.1)
        guard delta.0 >= 0, delta.1 >= 0, (delta.0 > 0) != (delta.1 > 0) else { return nil }
        let team = delta.0 > 0 ? 1 : 2
        // A defensive score (pick-six, safety) trails from the turnover spot, not the drive start.
        return Scoring(team: team, base: before, from: prior.lastSpot, staleSpot: prior.lastSpot,
                       driveFrom: prior.driveTeam == team ? prior.driveStart : nil, points: max(delta.0, delta.1))
    }
}

/// Interpolates the ball spot and first-down marker so a new ESPN update slides
/// the ball along the field (trail growing behind it) instead of jumping.
private struct ActivityFootballTrack: View, Animatable {
    let game: ActivityScoreboard
    let field: ActivityFootballField
    var ball: Double
    var target: Double
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(ball, target) }
        set { ball = newValue.first; target = newValue.second }
    }
    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 5
            let width = max(0, size.width - 2 * inset)
            func x(_ yard: Double) -> CGFloat { inset + width * min(100, max(0, yard)) / 100 }
            let y = size.height / 2
            context.fill(Path(roundedRect: CGRect(x: inset, y: y - 3, width: width, height: 6), cornerRadius: 3), with: .color(.primary.opacity(0.18)))
            for yard in stride(from: 10, through: 90, by: 10) {
                var tick = Path(); tick.move(to: CGPoint(x: x(Double(yard)), y: y - 2)); tick.addLine(to: CGPoint(x: x(Double(yard)), y: y + 2))
                context.stroke(tick, with: .color(.primary.opacity(0.4)), lineWidth: 1)
            }
            // A zero-length drive (fresh possession) draws nothing, so a turnover's ball
            // slide never paints a phantom trail from the new spot.
            func trail(_ segment: ActivityFootballPlay?, opacity: Double) {
                guard let segment, abs(segment.to - segment.from) > 0.01, abs(ball - segment.from) > 0.01 else { return }
                var path = Path(); path.move(to: CGPoint(x: x(segment.from), y: y)); path.addLine(to: CGPoint(x: x(ball), y: y))
                context.stroke(path, with: .color((segment.team == 1 ? game.left.tint : game.right.tint).opacity(opacity)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }
            trail(game.drive, opacity: 0.35)
            trail(game.lastPlay, opacity: 0.6)
            if let scoring = game.scoring, field.target == nil {
                let tint = scoring.team == 1 ? game.left.tint : game.right.tint
                let zone = scoring.team == 1 ? CGRect(x: x(92), y: y - 4, width: x(100) - x(92) + 4, height: 8)
                                             : CGRect(x: x(0) - 4, y: y - 4, width: x(8) - x(0) + 4, height: 8)
                context.fill(Path(roundedRect: zone, cornerRadius: 4), with: .color(tint.opacity(0.55)))
            }
            if field.target != nil {
                var line = Path(); line.move(to: CGPoint(x: x(target), y: y - 5)); line.addLine(to: CGPoint(x: x(target), y: y + 5))
                context.stroke(line, with: .color(.orange), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            let accent = field.attackingTeam == 1 ? game.left.tint : field.attackingTeam == 2 ? game.right.tint : .primary
            context.fill(Path(ellipseIn: CGRect(x: x(ball) - 4.5, y: y - 4.5, width: 9, height: 9)), with: .color(.primary))
            context.fill(Path(ellipseIn: CGRect(x: x(ball) - 3.5, y: y - 3.5, width: 7, height: 7)), with: .color(accent))
        }
    }
}

private struct ActivitySportsContextView: View {
    let game: ActivityScoreboard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 4) {
            if let field = game.field {
                ActivityFootballTrack(game: game, field: field, ball: field.yards, target: field.target ?? field.yards)
                    .frame(height: 18)
                    .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.82), value: field)
                    .accessibilityLabel((game.scoring.map { ($0.team == 1 ? game.left.name : game.right.name) + " " + $0.label.lowercased() } ?? "Ball at " + field.sourceText)
                        + (field.target == nil ? "" : ", first-down target shown") + (game.drive.map { ", drive \($0.gain) yards" } ?? "") + (game.lastPlay.map { ", last observed movement \($0.gain) yards" } ?? ""))
                if let scoring = game.scoring {
                    Text((scoring.team == 1 ? game.left.name : game.right.name) + " · " + scoring.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(scoring.team == 1 ? game.left.tint : game.right.tint)
                        .accessibilityHidden(true)
                }
            } else if let image = AndroidActivityPresentation.image(game.basesImage) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 56, height: 32)
                    .accessibilityLabel("Base occupancy from scoreboard")
                if let outs = game.outs {
                    HStack(spacing: 5) { ForEach(0..<3, id: \.self) { i in Circle().fill(i < outs ? Color.primary : Color.primary.opacity(0.2)).frame(width: 4, height: 4) } }
                        .accessibilityElement(children: .ignore).accessibilityLabel("\(outs) outs")
                }
            }
            if let turn = game.turn, turn.kind != .possession || game.field == nil {
                Text((turn.side == 1 ? game.left.name : game.right.name) + " · " + turn.label)
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !game.setScores.isEmpty {
                Text("Sets: " + game.setScores.map { set in
                    let name = set.team == 1 ? game.left.name : set.team == 2 ? game.right.name : ""
                    return [name, set.text].filter { !$0.isEmpty }.joined(separator: " ")
                }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


/// Player fields retain their source row identity; source pixel boxes never constrain Mac text.
struct ActivitySportsFooter {
    struct Player {
        let name: String
        let stats: String
        let portrait: String?
        var side: Int?
    }
    let title: String
    let notes: [String]
    let players: [Player]
    init(nodes: [[String: Any]], start: Double) {
        func text(_ n: [String: Any]) -> String { (n["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func y(_ n: [String: Any]) -> Double { (n["y"] as? NSNumber)?.doubleValue ?? 0 }
        let footer = nodes.enumerated().filter {
            let field = $0.element["sportsField"] as? String
            return !["statusPrimary", "statusSecondary", "gameClock", "setScore", "broadcast", "bases"].contains(field ?? "") &&
                (y($0.element) >= start || $0.element["sportsRow"] != nil || field == "note")
        }
        var used = Set<Int>(), parsed = [Player]()
        let rows = Set(footer.compactMap { ($0.element["sportsRow"] as? NSNumber)?.intValue }).sorted()
        for row in rows {
            let fields = footer.filter { ($0.element["sportsRow"] as? NSNumber)?.intValue == row }
            guard let name = fields.first(where: { $0.element["sportsField"] as? String == "playerName" }),
                  let stats = fields.first(where: { $0.element["sportsField"] as? String == "playerStats" }) else { continue }
            let portrait = fields.first { $0.element["sportsField"] as? String == "portrait" }
            parsed.append(Player(name: text(name.element), stats: text(stats.element), portrait: portrait?.element["image"] as? String,
                                 side: (name.element["sportsTeam"] as? NSNumber)?.intValue))
            used.formUnion(fields.map(\.offset))
        }
        // Compatibility with older companions: group aligned labels/stats without
        // reproducing their narrow Android text widths or fixed row heights.
        if parsed.isEmpty {
            for stats in footer where text(stats.element).range(of: "\\b(REC|YDS|TD|PTS|REB|AST|RBI|HITS|IP|K)\\b", options: .regularExpression) != nil {
                guard !used.contains(stats.offset) else { continue }
                let candidates = footer.filter {
                    $0.offset != stats.offset && !used.contains($0.offset) && !text($0.element).isEmpty &&
                        abs(y($0.element) - y(stats.element)) < 0.07 &&
                        text($0.element).range(of: "\\b(REC|YDS|TD|PTS|REB|AST|RBI|HITS|IP|K)\\b", options: .regularExpression) == nil
                }
                guard let name = candidates.min(by: { abs(y($0.element) - y(stats.element)) < abs(y($1.element) - y(stats.element)) }) else { continue }
                let portrait = footer.first { $0.element["kind"] as? String == "image" && abs(y($0.element) - y(stats.element)) < 0.07 }
                parsed.append(Player(name: text(name.element), stats: text(stats.element), portrait: portrait?.element["image"] as? String, side: nil))
                used.formUnion([name.offset, stats.offset])
            }
        }
        if parsed.count == 2 && parsed.enumerated().allSatisfy({ $0.element.side == nil || $0.element.side == $0.offset + 1 }) {
            for i in parsed.indices { parsed[i].side = i + 1 }
        }
        players = parsed
        let remaining = footer.filter { !used.contains($0.offset) && !text($0.element).isEmpty }.map { text($0.element) }
        title = (remaining.first ?? "").replacingOccurrences(of: "\\bLeaders\\b", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        notes = Array(remaining.dropFirst())
    }
    var isEmpty: Bool { title.isEmpty && notes.isEmpty && players.isEmpty }
}

/// Stable observable state keeps the hosting controller and SwiftUI identity across updates.
final class AndroidActivityCardModel: ObservableObject {
    @Published var presentation: AndroidActivityPresentation
    @Published var enabled = true
    init(_ presentation: AndroidActivityPresentation) { self.presentation = presentation }
}

struct AndroidActivityHostedCard: View {
    @ObservedObject var model: AndroidActivityCardModel
    let onAction: (String, String) -> Void
    var body: some View {
        let current = model.presentation
        VStack(alignment: .leading, spacing: 0) {
            if !model.enabled {
                Text("Reconnecting to phone…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.top, 12)
            }
            AndroidActivityCard(presentation: current) { action in
                onAction(current.text("version"), action)
            }.disabled(!model.enabled)
        }
        .frame(width: 380, alignment: .center)
        // Leave the content transparent so NSPopover owns the native glass surface.
        .background(Color.clear)
    }
}

/// Wake at the clocks' actual digit boundaries, independent of when the card opens.
struct ActivityTimerSchedule: TimelineSchedule {
    let anchors: [TimeInterval]
    struct Entries: Sequence, IteratorProtocol {
        var initial: Date?
        var nextDates: [TimeInterval]
        mutating func next() -> Date? {
            if let first = initial { initial = nil; return first }
            guard let next = nextDates.min() else { return nil }
            for i in nextDates.indices where nextDates[i] <= next + 0.0001 { nextDates[i] += 1 }
            return Date(timeIntervalSince1970: next)
        }
    }
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        let wall = Date().timeIntervalSince1970
        let mono = ActivityClock.now
        let start = startDate.timeIntervalSince1970
        let dates = anchors.filter(\.isFinite).map { anchor in
            let localStart = mono + start - wall
            return wall + ActivityClock.nextTick(after: localStart, anchor: anchor) - mono
        }
        return Entries(initial: startDate, nextDates: dates)
    }
}

private struct ActivityTimerEventKey: EnvironmentKey {
    static let defaultValue: [String: Any] = [:]
}
extension EnvironmentValues {
    fileprivate var activityTimerEvent: [String: Any] {
        get { self[ActivityTimerEventKey.self] }
        set { self[ActivityTimerEventKey.self] = newValue }
    }
}

struct AndroidActivityNumericText: View {
    let text: String
    var countsDown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activityTimerEvent) private var event
    @Environment(\.lineLimit) private var lineLimit
    var body: some View {
        if ActivityEmbeddedText.spans(text, event: event).isEmpty {
            inline(now: ActivityClock.now)
        } else {
            TimelineView(ActivityTimerSchedule(anchors: ActivityEmbeddedText.tickAnchors(text, event: event, now: ActivityClock.now))) { _ in inline(now: ActivityClock.now) }
        }
    }
    private func inline(now: TimeInterval) -> some View {
        let runs = ActivityEmbeddedText.runs(text, event: event, now: now)
        return ActivityTimerFlow(lineLimit: lineLimit) {
            ForEach(runs) { run in
                Group {
                    if run.numeric { digitLabel(run.text, down: run.timer ? run.down : countsDown).monospacedDigit() }
                    else { Text(run.newline ? " " : run.text) }
                }
                .layoutValue(key: ActivityTimerLineBreak.self, value: run.newline)
                .layoutValue(key: ActivityTimerWhitespace.self, value: !run.newline && run.text.allSatisfy(\.isWhitespace))
            }
        }.clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ActivityEmbeddedText.render(text, event: event, now: now))
    }
    private func digitLabel(_ value: String, down: Bool) -> some View {
        Text(value)
            .contentTransition(.numericText(countsDown: down))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: value)
    }
}

private struct ActivityTimerLineBreak: LayoutValueKey { static let defaultValue = false }
private struct ActivityTimerWhitespace: LayoutValueKey { static let defaultValue = false }

/// Flow individual words/timers using the inherited font, preserving explicit line breaks.
private struct ActivityTimerFlow: Layout {
    var lineLimit: Int?
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (CGSize, [Int: (CGPoint, CGSize)]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var row = 0
        var positions = [Int: (CGPoint, CGSize)]()
        for index in subviews.indices {
            guard row < (lineLimit ?? Int.max) else { break }
            let view = subviews[index]
            if x == 0 && view[ActivityTimerWhitespace.self] { continue }
            let ideal = view.sizeThatFits(.unspecified)
            if view[ActivityTimerLineBreak.self] {
                y += max(rowHeight, ideal.height); x = 0; rowHeight = 0; row += 1
                continue
            }
            let size = ideal.width > width ? view.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
            if x > 0 && x + size.width > width {
                y += rowHeight; x = 0; rowHeight = 0; row += 1
                if row >= (lineLimit ?? Int.max) { break }
            }
            positions[index] = (CGPoint(x: x, y: y), size)
            x += size.width; usedWidth = max(usedWidth, x); rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), positions)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? 10000).0
    }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline || guide == .lastTextBaseline else { return nil }
        let positions = arrange(subviews, width: bounds.width).1
        let candidates = positions.map { index, placement in
            placement.0.y + subviews[index].dimensions(in: ProposedViewSize(placement.1))[guide]
        }
        return guide == .firstTextBaseline ? candidates.min() : candidates.max()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(subviews, width: bounds.width).1
        for index in subviews.indices {
            if let (point, size) = positions[index] {
                subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(size))
            } else { subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY - 100000), proposal: .zero) }
        }
    }
}

/// Center status lines (clock, period, down & distance) tick to their new value
/// rather than swapping instantly. Game clocks roll downward.
private struct ActivityScoreboardDetailText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var countsDown: Bool { text.range(of: "\\b\\d{1,2}:\\d{2}\\b", options: .regularExpression) != nil }
    var body: some View {
        Text(text).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.center)
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: countsDown))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: text)
    }
}

/// Only a genuine score increase rolls the digits. Corrections and routine
/// refreshes replace text silently, retaining the same view and score baseline.
struct ActivityScoreText: View {
    let value: String
    @State private var displayed: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(value: String) { self.value = value; _displayed = State(initialValue: value) }
    static func increases(from old: String, to new: String) -> Bool {
        guard let before = Int(old), let after = Int(new) else { return false }
        return after > before
    }
    var body: some View {
        Text(displayed).contentTransition(.numericText(countsDown: false))
            .onChange(of: value) { old, new in
                if !reduceMotion && Self.increases(from: old, to: new) {
                    withAnimation(.easeInOut(duration: 0.3)) { displayed = new }
                } else {
                    var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                    withTransaction(transaction) { displayed = new }
                }
            }
    }
}

final class AndroidActivityStatusModel: ObservableObject {
    @Published var event: [String: Any] = [:]
    @Published var text = ""
    @Published var image: NSImage?
    @Published var enabled = true
}

/// Measure the displayed scores so SwiftUI and the AppKit status item stay in
/// sync without leaving empty digit slots around short scores.
struct ActivityCompactScoreLayout {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
    static let separatorWidth: CGFloat = 6
    static func scoreWidth(_ score: String) -> CGFloat {
        ceil((score as NSString).size(withAttributes: [.font: font]).width) + 2
    }
    static func contentWidth(_ game: ActivityScoreboard) -> CGFloat {
        if game.left.score.isEmpty && game.right.score.isEmpty { return 55 }
        return scoreWidth(game.left.score) + scoreWidth(game.right.score) + separatorWidth + 36 + 26
    }
    static func itemWidth(_ game: ActivityScoreboard) -> CGFloat { contentWidth(game) + 12 }
}

struct AndroidActivityStatusLabel: View {
    @ObservedObject var model: AndroidActivityStatusModel
    var body: some View {
        HStack(spacing: 4) {
            if let game = ActivityScoreboard(event: model.event) {
                HStack(spacing: 5) {
                    scoreLogo(game.left, size: 18).overlay(alignment: .bottomTrailing) {
                        if let turn = game.turn, turn.side == 1 { sportsTurn(turn, compact: true).offset(x: 3, y: 1) }
                    }
                    if !game.left.score.isEmpty || !game.right.score.isEmpty {
                    HStack(spacing: 1) {
                        ActivityScoreText(value: game.left.score)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: ActivityCompactScoreLayout.scoreWidth(game.left.score))
                        Text("-").opacity(0.65).frame(width: ActivityCompactScoreLayout.separatorWidth)
                        ActivityScoreText(value: game.right.score)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: ActivityCompactScoreLayout.scoreWidth(game.right.score))
                    }.font(.system(size: 12, weight: .bold)).monospacedDigit()
                    }
                    scoreLogo(game.right, size: 18).overlay(alignment: .bottomLeading) {
                        if let turn = game.turn, turn.side == 2 { sportsTurn(turn, compact: true).offset(x: -3, y: 1) }
                    }
                }.foregroundStyle(.primary).padding(.horizontal, 7)
                    .frame(width: ActivityCompactScoreLayout.contentWidth(game), height: 22)
                    .fixedSize(horizontal: true, vertical: false)
                    .background {
                        Capsule().fill(LinearGradient(colors: [game.left.tint.opacity(0.45), game.right.tint.opacity(0.45)],
                                                      startPoint: .leading, endPoint: .trailing))
                    }
            } else {
                if let image = model.image { Image(nsImage: image).resizable().scaledToFit().frame(width: 18, height: 18) }
                if !model.text.isEmpty {
                    AndroidActivityNumericText(text: model.text).font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.activityTimerEvent, model.event)
            .opacity(model.enabled ? 1 : 0.5).accessibilityHidden(true)
    }
}

private func sportsTurn(_ turn: ActivityScoreboard.Turn, compact: Bool) -> some View {
    Image(systemName: turn.symbol)
        .font(.system(size: compact ? 4 : 8, weight: .bold))
        .foregroundStyle(.white)
        .padding(1).background(.black.opacity(0.75), in: Circle())
        .accessibilityLabel(turn.label)
}

@ViewBuilder private func scoreLogo(_ team: ActivityScoreboard.Team, size: CGFloat) -> some View {
    if let image = AndroidActivityPresentation.image(team.image) {
        Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
            // Gold/cream marks otherwise disappear into their own team-color fade.
            // Follow the image alpha, preserving the logo and the translucent surface.
            .shadow(color: .black.opacity(size <= 24 ? 0.85 : 0), radius: 0.75, x: 0, y: 0.35)
    } else {
        // Reserve the logo slot while the authenticated asset channel hydrates it.
        Color.clear.frame(width: size, height: size)
    }
}

/// Keep AppKit's status button as the click/accessibility target beneath its SwiftUI label.
final class AndroidActivityStatusHostingView: NSHostingView<AndroidActivityStatusLabel> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Interpolate the whole progress presentation so its numeric labels and track share
/// one value. Never extrapolate beyond the latest progress reported by the phone.
struct AndroidActivityCard: View {
    let presentation: AndroidActivityPresentation
    let onAction: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AndroidActivityInterpolatedCard(presentation: presentation,
            fraction: presentation.progress ?? 0, onAction: onAction)
            .animation(reduceMotion || presentation.event["indeterminate"] as? Bool == true
                ? nil : .linear(duration: 0.35), value: presentation.progress)
    }
}

private struct AndroidActivityInterpolatedCard: View, Animatable {
    let presentation: AndroidActivityPresentation
    var fraction: Double
    let onAction: (String) -> Void
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        var event = presentation.event
        if let target = presentation.progress, presentation.event["indeterminate"] as? Bool != true {
            let displayed = min(target, max(0, fraction))
            event["progressValue"] = displayed * presentation.number("progressMax")
            // Keep percentage labels supplied in the title/status in step with the bar.
            // Other numbers (sizes, times, etc.) retain their original meaning.
            let reportedPercent = Int((target * 100).rounded())
            let percent = Int((displayed * 100).rounded())
            let pattern = "(?<![0-9])" + String(reportedPercent) + "%"
            for key in ["title", "subtitle", "body", "status"] {
                if let text = event[key] as? String {
                    event[key] = text.replacingOccurrences(of: pattern,
                        with: "\(percent)%", options: .regularExpression)
                }
            }
        }
        return AndroidActivityCardContent(presentation:
            AndroidActivityPresentation(event: event, clockAnchor: presentation.clockAnchor), onAction: onAction)
    }
}

private struct AndroidActivityCardContent: View {
    @Environment(\.colorScheme) private var scheme
    let presentation: AndroidActivityPresentation
    let onAction: (String) -> Void
    private var foreground: Color { .primary }
    private var accent: Color { presentation.accent(dark: scheme == .dark) }
    private var secondary: Color { foreground.opacity(0.88) }

    var body: some View {
        VStack(alignment: .leading, spacing: presentation.layout == .progress ? 12 : 14) {
            if let game = ActivityScoreboard(event: presentation.event) {
                scoreboard(game)
            } else if presentation.layout == .progress {
                progressHeader
                progressTrack
            } else {
                header
                content
                if !presentation.text("subtitle").isEmpty {
                    AndroidActivityNumericText(text: presentation.text("subtitle")).font(.system(size: 12)).foregroundStyle(secondary)
                }
            }
            if !presentation.actions.isEmpty { actions }
        }
        .padding(presentation.layout == .progress ? 16 : 20)
        .frame(width: 380, alignment: .leading)
        .foregroundStyle(foreground)
        .environment(\.activityTimerEvent, presentation.event)
        // NSPopover supplies the material, arrow, clipping and appearance as one surface.
        .background(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if presentation.event["canOpen"] as? Bool == true { onAction("open") }
        }
        .accessibilityAction(named: "Open in Mirroring") {
            if presentation.event["canOpen"] as? Bool == true { onAction("open") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.text("app") + " notification")
    }

    private func scoreboard(_ game: ActivityScoreboard) -> some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                scoreTeam(game.left, turn: game.turn?.side == 1 ? game.turn : nil)
                VStack(spacing: 5) {
                    ForEach(Array(game.displayDetails.enumerated()), id: \.offset) { _, detail in
                        // The game clock advances only when ESPN reports a new value.
                        ActivityScoreboardDetailText(text: detail)
                    }
                    ActivitySportsContextView(game: game)
                    Text(presentation.text("app")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                scoreTeam(game.right, turn: game.turn?.side == 2 ? game.turn : nil)
            }.frame(minHeight: 110)
            let footer = ActivitySportsFooter(nodes: presentation.customNodes, start: game.footerStart)
            if !footer.isEmpty { sportsFooter(footer) }
        }.foregroundStyle(.primary)
            .accessibilityElement(children: .contain).accessibilityLabel(game.summary)
    }

    private func sportsFooter(_ footer: ActivitySportsFooter) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
                if !footer.title.isEmpty {
                    Text(footer.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                    Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
                }
            }
            ForEach(Array(footer.notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if !footer.players.isEmpty && footer.players.allSatisfy({ $0.side == 1 || $0.side == 2 }) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(1...2, id: \.self) { side in
                        VStack(spacing: 6) {
                            ForEach(Array(footer.players.filter { $0.side == side }.enumerated()), id: \.offset) { _, player in
                                sportsPlayer(player, trailing: side == 2)
                            }
                        }.frame(maxWidth: .infinity, alignment: side == 2 ? .trailing : .leading)
                    }
                }
            } else {
                ForEach(Array(footer.players.enumerated()), id: \.offset) { _, player in
                    HStack(spacing: 6) {
                        sportsPortrait(player.portrait)
                        Text(player.name).font(.system(size: 11, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.7).frame(width: 100, alignment: .leading)
                        Text(player.stats).font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: .infinity, alignment: .trailing)
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func sportsPlayer(_ player: ActivitySportsFooter.Player, trailing: Bool) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            HStack(spacing: 4) {
                if !trailing { sportsPortrait(player.portrait) }
                Text(player.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
                if trailing { sportsPortrait(player.portrait) }
            }
            Text(player.stats).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
        }.fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func sportsPortrait(_ encoded: String?) -> some View {
        if let image = AndroidActivityPresentation.image(encoded) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 18, height: 18)
        }
    }

    private func scoreTeam(_ team: ActivityScoreboard.Team, turn: ActivityScoreboard.Turn?) -> some View {
        VStack(spacing: 6) {
            scoreLogo(team, size: 44).overlay(alignment: turn?.side == 2 ? .bottomLeading : .bottomTrailing) {
                if let turn { sportsTurn(turn, compact: false) }
            }
            if !team.score.isEmpty {
                ActivityScoreText(value: team.score).font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(team.ink(dark: scheme == .dark))
            }
            HStack(spacing: 5) {
                Text(team.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(team.ink(dark: scheme == .dark))
            }
        }.frame(width: 72)
    }

    // Android's ProgressStyle uses an app-icon column beside title/time and text,
    // with a full-width track and equally sized outlined actions below it.
    private var progressHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            if let icon = presentation.image("appIcon") ?? presentation.image("activityIcon") {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 40, height: 40)
                    .clipShape(Circle()).accessibilityHidden(true)
            } else {
                Image(systemName: "app.fill").resizable().scaledToFit().frame(width: 40, height: 40)
                    .foregroundStyle(accent).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    heading
                    if presentation.event["chronometer"] as? Bool == true || presentation.event["clockPausedMs"] is NSNumber {
                        Text("·").foregroundStyle(secondary)
                        inlineClock
                    }
                    Spacer(minLength: 0)
                }
                if !presentation.text("subtitle").isEmpty {
                    AndroidActivityNumericText(text: presentation.text("subtitle"))
                        .font(.system(size: 14)).foregroundStyle(secondary)
                }
                if !presentation.text("body").isEmpty { textBody.padding(.top, 8) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var inlineClock: some View {
        TimelineView(ActivityTimerSchedule(anchors: presentation.event["chronometer"] as? Bool == true ? [presentation.clockAnchor] : [])) { _ in
            AndroidActivityNumericText(text: presentation.clock(now: ActivityClock.now) ?? "",
                countsDown: presentation.event["countDown"] as? Bool == true)
                .font(.system(size: 14)).monospacedDigit().foregroundStyle(secondary)
                .fixedSize()
        }
    }

    @ViewBuilder private var progressTrack: some View {
        if presentation.event["indeterminate"] as? Bool == true {
            ProgressView().progressViewStyle(.linear).tint(accent).frame(height: 24)
        } else if let progress = presentation.progress {
            AndroidActivityProgress(presentation: presentation, fraction: progress)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = presentation.image("activityIcon") ?? presentation.image("appIcon") {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
            Text(presentation.text("app")).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if !presentation.text("status").isEmpty {
                Text("·").foregroundStyle(secondary)
                AndroidActivityNumericText(text: presentation.text("status")).font(.system(size: 12)).foregroundStyle(secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .foregroundStyle(accent)
    }

    @ViewBuilder private var heading: some View {
        if !presentation.text("title").isEmpty {
            AndroidActivityNumericText(text: presentation.text("title")).font(.system(size: 16, weight: .semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private var textBody: some View {
        if !presentation.text("body").isEmpty {
            AndroidActivityNumericText(text: presentation.text("body")).font(.system(size: 14)).foregroundStyle(secondary)
                .lineLimit(12).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var textContent: some View {
        VStack(alignment: .leading, spacing: 5) { heading; textBody }
    }

    @ViewBuilder private var content: some View {
        switch presentation.layout {
        case .bigPicture:
            textContent
            if let picture = presentation.image("contentImage") {
                Image(nsImage: picture).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 16)).accessibilityLabel("Notification picture")
            }
        case .inbox:
            heading
            if presentation.lines.isEmpty { textBody }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(presentation.lines.enumerated()), id: \.offset) { _, line in
                    AndroidActivityNumericText(text: line).font(.system(size: 14)).lineLimit(2)
                }
            }
        case .messaging:
            heading
            ForEach(Array(presentation.messages.enumerated()), id: \.offset) { _, message in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(accent.opacity(0.22)).frame(width: 30, height: 30)
                        .overlay(Text(String((message["sender"] as? String ?? "?").prefix(1))).font(.system(size: 13, weight: .medium)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(message["sender"] as? String ?? "").font(.system(size: 12, weight: .semibold))
                        AndroidActivityNumericText(text: message["text"] as? String ?? "").font(.system(size: 14)).foregroundStyle(secondary).lineLimit(4)
                    }
                }
            }
            if presentation.messages.isEmpty { textBody }
        case .call:
            HStack(alignment: .center, spacing: 14) {
                if let image = presentation.image("contactImage") ?? presentation.image("appIcon") {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: presentation.layout == .call ? 32 : 12))
                }
                textContent
            }
            clock
        case .progress:
            progressHeader
            progressTrack
        case .custom:
            if !presentation.customNodes.isEmpty { customContent } else { textContent }
            clock
        case .standard, .bigText:
            HStack(alignment: .top, spacing: 12) {
                textContent.frame(maxWidth: .infinity, alignment: .leading)
                if let image = presentation.image("contactImage") {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            clock
        }
    }

    @ViewBuilder private var clock: some View {
        if presentation.event["chronometer"] as? Bool == true || presentation.event["clockPausedMs"] is NSNumber {
            TimelineView(ActivityTimerSchedule(anchors: presentation.event["chronometer"] as? Bool == true ? [presentation.clockAnchor] : [])) { _ in
                AndroidActivityNumericText(text: presentation.clock(now: ActivityClock.now) ?? "",
                    countsDown: presentation.event["countDown"] as? Bool == true)
                    .font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(accent)
            }
        }
    }

    private var customContent: some View {
        let height = min(380, max(40, presentation.number("customHeight")))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(presentation.customNodes.enumerated()), id: \.offset) { _, node in
                customNode(node, height: height)
            }
        }.frame(width: 340, height: height, alignment: .topLeading)
    }
    @ViewBuilder private func customNode(_ node: [String: Any], height: Double) -> some View {
        let x = (node["x"] as? Double ?? 0) * 340
        let y = (node["y"] as? Double ?? 0) * height
        let width = max(1, (node["width"] as? Double ?? 1) * 340)
        let nodeHeight = max(1, (node["height"] as? Double ?? 0.1) * height)
        if node["kind"] as? String == "progress" {
            ProgressView(value: min(1, max(0, node["progress"] as? Double ?? 0)))
                .tint(accent).frame(width: width, height: nodeHeight).offset(x: x, y: y)
        } else if let text = node["text"] as? String, !text.isEmpty {
            AndroidActivityNumericText(text: text).font(.system(size: min(32, max(10, node["size"] as? Double ?? 14)),
                weight: node["bold"] as? Bool == true ? .semibold : .regular))
                .foregroundStyle(nodeColor(node)).lineLimit(6)
                .frame(width: width, height: nodeHeight, alignment: .topLeading).offset(x: x, y: y)
        } else if let image = AndroidActivityPresentation.image(node["image"] as? String) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: width, height: nodeHeight).offset(x: x, y: y)
        }
    }
    private func nodeColor(_ node: [String: Any]) -> Color {
        guard let color = node["color"] as? NSNumber else { return foreground }
        let value = color.uint32Value
        let r = Double((value >> 16) & 255) / 255
        let g = Double((value >> 8) & 255) / 255
        let b = Double(value & 255) / 255
        // Android's neutral text ink must follow the Mac surface's appearance too.
        if max(r, g, b) - min(r, g, b) < 0.12 { return foreground }
        return Color(red: r, green: g, blue: b)
    }

    private var actions: some View {
        HStack(spacing: presentation.layout == .progress ? 8 : 12) {
            ForEach(Array(presentation.actions.enumerated()), id: \.offset) { _, spec in
                if let id = spec["id"] as? String, let title = spec["title"] as? String {
                    Button { onAction(id) } label: {
                        Text(title).font(.system(size: presentation.layout == .progress ? 15 : 13, weight: .semibold)).lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, presentation.layout == .progress ? 8 : 9)
                            .frame(maxWidth: presentation.layout == .progress ? .infinity : nil,
                                minHeight: presentation.layout == .progress ? 40 : nil)
                            .background(presentation.layout == .progress ? Color.clear : accent.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(presentation.layout == .progress ? foreground.opacity(0.35) : .clear, lineWidth: 1))
                    }.buttonStyle(.plain).foregroundStyle(presentation.layout == .progress ? foreground : accent)
                        .frame(maxWidth: presentation.layout == .progress ? .infinity : nil)
                }
            }
        }.padding(.top, 2)
    }
}

private struct AndroidActivityProgress: View {
    @Environment(\.colorScheme) private var scheme
    let presentation: AndroidActivityPresentation
    let fraction: Double
    private var accent: Color { presentation.accent(dark: scheme == .dark) }
    private var segments: [[String: Any]] { Array((presentation.event["progressSegments"] as? [[String: Any]] ?? []).prefix(12)) }
    private func segmentColor(_ segment: [String: Any]) -> Color {
        guard let number = segment["color"] as? NSNumber, number.uint32Value & 0x00ffffff != 0 else { return accent }
        let value = number.uint32Value
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    var body: some View {
        HStack(spacing: 8) {
            if let image = presentation.image("progressStartIcon") {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 20, height: 20)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(accent.opacity(0.2)).frame(height: 6)
                    if segments.isEmpty {
                        Capsule().fill(accent).frame(width: max(6, geometry.size.width * fraction), height: 6)
                    } else {
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                            let start = segments.prefix(index).reduce(0.0) { $0 + (($1["fraction"] as? NSNumber)?.doubleValue ?? 0) }
                            let length = min(1 - min(1, start), max(0, (segment["fraction"] as? NSNumber)?.doubleValue ?? 0))
                            Capsule().fill(segmentColor(segment).opacity(start <= fraction ? 1 : 0.3))
                                .frame(width: max(0, geometry.size.width * length - 2), height: 6)
                                .offset(x: geometry.size.width * min(1, start))
                        }
                    }
                    ForEach(Array((presentation.event["progressPoints"] as? [Double] ?? []).prefix(12).enumerated()), id: \.offset) { _, point in
                        Circle().fill(accent).frame(width: 8, height: 8)
                            .offset(x: min(geometry.size.width - 8, max(0, geometry.size.width * point)))
                    }
                    if let tracker = presentation.image("progressTrackerIcon") {
                        Image(nsImage: tracker).resizable().scaledToFit().frame(width: 22, height: 22)
                            .offset(x: max(0, min(geometry.size.width - 22, geometry.size.width * fraction - 11)))
                    } else {
                        Circle().fill(accent).frame(width: 12, height: 12)
                            .offset(x: max(0, min(geometry.size.width - 12, geometry.size.width * fraction - 6)))
                    }
                }.frame(height: 24)
            }.frame(height: 24)
            if let image = presentation.image("progressEndIcon") {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 20, height: 20)
            }
        }
    }
}
