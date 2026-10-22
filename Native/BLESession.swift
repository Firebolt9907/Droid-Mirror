import Foundation

/// One authentication hello per subscription, even if Core Bluetooth repeats
/// its notification-state callback while a disable/enable cycle is completing.
struct BLENotificationSubscription {
    enum Action { case none, disable, enable, authenticate }
    private enum Phase { case idle, disabling, enabling, authenticating }
    private var phase = Phase.idle

    mutating func begin(alreadyNotifying: Bool) -> Action {
        phase = alreadyNotifying ? .disabling : .enabling
        return alreadyNotifying ? .disable : .enable
    }
    mutating func updated(notifying: Bool) -> Action {
        switch phase {
        case .idle: return .none
        case .disabling:
            guard !notifying else { return .none }
            phase = .enabling
            return .enable
        case .enabling:
            guard notifying else { return .none }
            phase = .authenticating
            return .authenticate
        case .authenticating:
            guard !notifying else { return .none }
            phase = .enabling
            return .enable
        }
    }
}

/// Core Bluetooth can retain multiple instances of one service UUID after a
/// companion update. Try each instance once; UUID equality cannot identify it.
struct BLEServiceCandidates<Candidate: AnyObject> {
    private var remaining = [Candidate]()
    private(set) var current: Candidate?
    mutating func reset(_ candidates: [Candidate] = []) {
        var seen = Set<ObjectIdentifier>()
        remaining = candidates.filter { seen.insert(ObjectIdentifier($0)).inserted }
        current = nil
    }
    mutating func next() -> Candidate? {
        current = remaining.isEmpty ? nil : remaining.removeFirst()
        return current
    }
}

/// Outcomes describe an application reply, not merely an ATT write acknowledgment.
enum BLERequestOutcome {
    case response([String: Any])
    case timedOut
    case disconnected
    case notQueued
}

/// Main-queue owned. Requests are never replayed automatically across sessions.
final class BLERequests {
    private struct Pending {
        let reply: String
        let deadline: TimeInterval
        let completion: (BLERequestOutcome) -> Void
    }
    private var pending = [String: Pending]()
    var count: Int { pending.count }
    func add(id: String, reply: String, deadline: TimeInterval, completion: @escaping (BLERequestOutcome) -> Void) -> Bool {
        guard pending[id] == nil, pending.count < 128 else { return false }
        pending[id] = Pending(reply: reply, deadline: deadline, completion: completion)
        return true
    }
    func finish(_ id: String, outcome: BLERequestOutcome) {
        pending.removeValue(forKey: id)?.completion(outcome)
    }
    func receive(_ event: [String: Any], now: TimeInterval) {
        guard let id = event["request"] as? String, let request = pending[id],
              event["type"] as? String == request.reply else { return }
        finish(id, outcome: now < request.deadline ? .response(event) : .timedOut)
    }
    func expire(now: TimeInterval) {
        let expired = pending.filter { $0.value.deadline <= now }.map(\.key)
        expired.forEach { finish($0, outcome: .timedOut) }
    }
    func reset() {
        let previous = pending
        pending.removeAll()
        previous.values.forEach { $0.completion(.disconnected) }
    }
}

/// Schedule plaintext BEFORE sealing: encrypted messages must keep sequence order,
/// and fragments of one message must never be interleaved with another message.
struct BLEOutboundQueue {
    struct Message {
        let object: [String: Any]
        let deadline: TimeInterval
        let cost: Int
        let bulk: Bool
        let urgent: Bool
    }
    private var messages = [Message]()
    private var controlBurst = 0
    private(set) var bytes = 0
    var count: Int { messages.count }
    static let limit = 262144
    mutating func append(_ object: [String: Any], deadline: TimeInterval) -> Bool {
        guard JSONSerialization.isValidJSONObject(object),
              let json = try? JSONSerialization.data(withJSONObject: object), json.count <= 5800 else { return false }
        // Reserve envelope, Base64 and framing overhead, including MTU 23.
        let cost = json.count * 3 + 512
        guard bytes + cost <= Self.limit else { return false }
        let bulk = object["type"] as? String == "clipboardFileChunk"
        messages.append(Message(object: object, deadline: deadline, cost: cost, bulk: bulk,
                                urgent: object["type"] as? String == "ping"))
        bytes += cost
        return true
    }
    mutating func next(now: TimeInterval) -> Message? {
        messages.removeAll { message in
            if message.deadline <= now { bytes -= message.cost; return true }
            return false
        }
        guard !messages.isEmpty else { return nil }
        let index: Int
        if let urgent = messages.firstIndex(where: { $0.urgent }) { index = urgent }
        else if controlBurst >= 4, let bulk = messages.firstIndex(where: { $0.bulk }) { index = bulk }
        else { index = messages.firstIndex(where: { !$0.bulk }) ?? 0 }
        let message = messages.remove(at: index)
        bytes -= message.cost
        controlBurst = message.bulk ? 0 : min(controlBurst + 1, 4)
        return message
    }
    mutating func reset() { messages.removeAll(); bytes = 0; controlBurst = 0 }
}
