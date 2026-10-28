import Foundation
import Darwin

/// A sleep-aware monotonic timebase shared by fragment receipt and activity deadlines.
enum ActivityClock {
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
    static func nextTick(after now: TimeInterval, anchor: TimeInterval) -> TimeInterval {
        anchor + floor(now - anchor) + 1 + 0.002
    }
    static var now: TimeInterval { Double(mach_continuous_time()) * secondsPerTick }

    static func anchor(event: [String: Any], now: TimeInterval = Self.now) -> TimeInterval {
        let offset = (event["clockOffsetMs"] as? NSNumber)?.doubleValue ?? 0
        let firstFragment = (event["_clockReceivedAt"] as? NSNumber)?.doubleValue ?? (event["_activityReceivedAt"] as? NSNumber)?.doubleValue ?? now
        let receipt = firstFragment.isFinite && firstFragment <= now ? firstFragment : now
        return receipt + (offset.isFinite ? offset / 1000 : 0)
    }
}

/// Spans use UTF-16 offsets and Java's String hash so truncation or redaction cannot retarget a timer.
enum ActivityEmbeddedText {
    static func hash(_ text: String) -> Int32 {
        text.utf16.reduce(Int32(0)) { ($0 &* 31) &+ Int32($1) }
    }
    static func spans(_ text: String, event: [String: Any]) -> [[String: Any]] {
        Array((event["embeddedTimers"] as? [[String: Any]] ?? []).prefix(6)).filter {
            ($0["hash"] as? NSNumber)?.int32Value == hash(text)
        }
    }
    struct Run: Identifiable {
        let id: Int
        let text: String
        let timer: Bool
        let down: Bool
        let numeric: Bool
        var newline: Bool { text == "\n" }
    }
    private static let words = try! NSRegularExpression(pattern: "[0-9]+(?:[:.,][0-9]+)*|[^\\s0-9]+|\\n|[^\\S\\n]+")
    /// Stable literal runs and independent timer runs preserve wrapping without animating prose.
    static func runs(_ text: String, event: [String: Any], now: TimeInterval) -> [Run] {
        let original = text as NSString
        var runs = [Run]()
        var cursor = 0
        func literal(_ start: Int, _ end: Int) {
            guard end > start else { return }
            let part = original.substring(with: NSRange(location: start, length: end-start)) as NSString
            for match in words.matches(in: part as String, range: NSRange(location: 0, length: part.length)) {
                runs.append(Run(id: start+match.range.location, text: part.substring(with: match.range), timer: false, down: false, numeric: part.substring(with: match.range).first?.isNumber == true))
            }
        }
        for span in spans(text, event: event).sorted(by: { ($0["start"] as? Int ?? -1) < ($1["start"] as? Int ?? -1) }) {
            guard let start = span["start"] as? Int, let end = span["end"] as? Int,
                  start >= cursor, end > start, end <= original.length,
                  original.substring(with: NSRange(location: start, length: end-start)) == span["token"] as? String else { continue }
            var single = event; single["embeddedTimers"] = [span]
            let projected = render(text, event: single, now: now) as NSString
            let length = projected.length - original.length + end-start
            guard length > 0, start+length <= projected.length else { continue }
            literal(cursor, start)
            runs.append(Run(id: start, text: projected.substring(with: NSRange(location: start, length: length)), timer: true, down: span["down"] as? Bool == true, numeric: true))
            cursor = end
        }
        literal(cursor, original.length)
        return runs
    }
    static func tickAnchors(_ text: String, event: [String: Any], now: TimeInterval) -> [TimeInterval] {
        let receipt = (event["_timersReceivedAt"] as? NSNumber)?.doubleValue ?? (event["_activityReceivedAt"] as? NSNumber)?.doubleValue ?? now
        guard receipt.isFinite else { return [] }
        return spans(text, event: event).compactMap { span in
            guard let seconds = (span["seconds"] as? NSNumber)?.doubleValue, seconds.isFinite else { return nil }
            let down = span["down"] as? Bool == true
            return receipt + (down ? seconds : -seconds)
        }
    }
    static func render(_ text: String, event: [String: Any], now: TimeInterval) -> String {
        let receipt = (event["_timersReceivedAt"] as? NSNumber)?.doubleValue ?? (event["_activityReceivedAt"] as? NSNumber)?.doubleValue ?? now
        guard receipt.isFinite, now >= receipt else { return text }
        let elapsed = now - receipt
        let original = text as NSString
        let result = NSMutableString(string: text)
        var boundary = original.length
        for span in spans(text, event: event).sorted(by: { ($0["start"] as? Int ?? -1) > ($1["start"] as? Int ?? -1) }) {
            guard let start = span["start"] as? Int, let end = span["end"] as? Int,
                  start >= 0, end > start, end <= boundary,
                  let token = span["token"] as? String,
                  original.substring(with: NSRange(location: start, length: end-start)) == token,
                  let seconds = (span["seconds"] as? NSNumber)?.doubleValue, seconds.isFinite,
                  seconds >= 0, seconds < 360_000_000 else { continue }
            let down = span["down"] as? Bool == true
            let value = max(0, min(360_000_000, seconds + (down ? -elapsed : elapsed)))
            let android = span["rounding"] as? String == "android"
            let total = Int(android ? floor(value + (down ? 0.001 : 0.5)) : (down ? ceil(value) : floor(value)))
            let width = min(3, max(1, span["width"] as? Int ?? 2))
            let formatted: String
            if span["hours"] as? Bool == true {
                formatted = String(format: "%0*d:%02d:%02d", width, total/3600, total/60%60, total%60)
            } else {
                formatted = String(format: "%0*d:%02d", width, total/60, total%60)
            }
            result.replaceCharacters(in: NSRange(location: start, length: end-start), with: formatted)
            boundary = start
        }
        return result as String
    }
}

/// Reconstruct only against the exact authenticated baseline. Reconnects never reuse it.
struct ActivityDeltaReceiver {
    private var baselines = [String: [String: Any]]()
    private var order = [String]()
    private mutating func remember(_ id: String, _ event: [String: Any]) {
        order.removeAll { $0 == id }
        order.append(id)
        baselines[id] = event
        if order.count > 128 { baselines.removeValue(forKey: order.removeFirst()) }
    }
    mutating func reanchor(using sync: ActivityClockSync) -> [[String: Any]] {
        var refreshed = [[String: Any]]()
        for id in order {
            guard var full = baselines[id] else { continue }
            for (source, target) in [("_clockSourceElapsedMs", "_clockReceivedAt"), ("_timersSourceElapsedMs", "_timersReceivedAt")] {
                if let stamp = full[source] as? NSNumber, let local = sync.localTime(phoneMilliseconds: stamp.doubleValue) { full[target] = local }
            }
            baselines[id] = full
            refreshed.append(full)
        }
        return refreshed
    }
    private(set) var needsSnapshot = false
    mutating func receive(_ event: [String: Any]) -> [String: Any]? {
        needsSnapshot = false
        let type = event["type"] as? String
        if type == "activitiesReset", event["ids"] == nil || (event["part"] as? Int ?? 0) == 0 {
            baselines.removeAll(); order.removeAll()
        }
        guard let id = event["id"] as? String else { return event }
        if type == "removed" { baselines.removeValue(forKey: id); order.removeAll { $0 == id } }
        if type == "notification" {
            if event["activity"] as? Bool == true {
                var full = event
                full["_clockReceivedAt"] = event["_activitySourceAt"] ?? event["_activityReceivedAt"]
                full["_timersReceivedAt"] = event["_activitySourceAt"] ?? event["_activityReceivedAt"]
                full["_clockSourceElapsedMs"] = event["clockSentElapsedMs"]
                full["_timersSourceElapsedMs"] = event["clockSentElapsedMs"]
                remember(id, full)
                return full
            } else { baselines.removeValue(forKey: id); order.removeAll { $0 == id } }
            return event
        }
        guard type == "activityPatch" else { return event }
        guard var full = baselines[id], let base = event["base"] as? String,
              full["version"] as? String == base,
              let fields = event["set"] as? [String: Any], let unset = event["unset"] as? [String],
              fields.count <= 80, unset.count <= 80,
              fields["type"] == nil, fields["id"] == nil,
              !fields.keys.contains(where: { $0.hasPrefix("_") }),
              !unset.contains(where: { $0 == "type" || $0 == "id" || $0.hasPrefix("_") }) else {
            needsSnapshot = true
            return nil
        }
        for key in unset { full.removeValue(forKey: key) }
        for (key, value) in fields { full[key] = value }
        guard full["version"] is String else { needsSnapshot = true; return nil }
        full["_activityReceivedAt"] = event["_activityReceivedAt"]
        if fields["clockOffsetMs"] != nil {
            full["_clockReceivedAt"] = event["_activitySourceAt"] ?? event["_activityReceivedAt"]
            full["_clockSourceElapsedMs"] = event["clockSentElapsedMs"]
        }
        if fields["embeddedTimers"] != nil {
            full["_timersReceivedAt"] = event["_activitySourceAt"] ?? event["_activityReceivedAt"]
            full["_timersSourceElapsedMs"] = event["clockSentElapsedMs"]
        }
        remember(id, full)
        return full
    }
}

/// Four-timestamp monotonic calibration; server queue time is excluded from network RTT.
struct ActivityClockSync {
    private struct Sample { let offset: Double; let rtt: Double; let at: Double }
    private var pending = [String: Double]()
    private var samples = [Sample]()
    private var best: Sample? { samples.min { $0.rtt < $1.rtt } }
    var roundTripMilliseconds: Int? { best.map { Int(($0.rtt * 1000).rounded()) } }
    mutating func begin(_ id: String, now: Double) {
        pending = pending.filter { now >= $0.value && now - $0.value < 30 }
        if pending.count < 4 { pending[id] = now }
    }
    @discardableResult mutating func accept(_ event: [String: Any], receivedAt: Double) -> Bool {
        guard let id = event["request"] as? String, let t0 = pending.removeValue(forKey: id),
              let received = event["clockReceivedElapsedMs"] as? NSNumber,
              let sent = event["clockSentElapsedMs"] as? NSNumber else { return false }
        let t1 = received.doubleValue / 1000, t2 = sent.doubleValue / 1000, t3 = receivedAt
        guard [t0,t1,t2,t3].allSatisfy(\.isFinite), t1 >= 0, t2 >= t1, t3 >= t0, t3-t0 < 30 else { return false }
        let rtt = (t3-t0) - (t2-t1)
        guard rtt >= -0.005, rtt <= 5 else { return false }
        let offset = ((t0-t1)+(t3-t2))/2
        let old = best?.offset
        samples.removeAll { t3-$0.at > 300 }
        samples.append(Sample(offset: offset, rtt: max(0,rtt), at: t3))
        if samples.count > 8 { samples.removeFirst() }
        return old == nil || abs((best?.offset ?? offset)-(old ?? offset)) > 0.001
    }
    func localTime(phoneMilliseconds: Double) -> Double? {
        guard phoneMilliseconds.isFinite, phoneMilliseconds >= 0, let best else { return nil }
        return phoneMilliseconds / 1000 + best.offset
    }
}
