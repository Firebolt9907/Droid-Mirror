import Foundation

/// Bounds side effects to a recently advertised ticket from this authenticated connection.
struct WearCompanionCommandGate {
    private(set) var id = UUID().uuidString
    private var tickets = [String: TimeInterval]()
    private var requests = [String: TimeInterval]()
    mutating func reset() { self = Self() }
    mutating func ticket(now: TimeInterval) -> String {
        tickets = tickets.filter { now - $0.value >= 0 && now - $0.value < 35 }
        let value = UUID().uuidString
        tickets[value] = now
        return value
    }
    mutating func accept(_ event: [String: Any], now: TimeInterval) -> Bool {
        requests = requests.filter { now - $0.value >= 0 && now - $0.value < 35 }
        guard event["id"] as? String == id,
              let ticket = event["ticket"] as? String, let issued = tickets[ticket],
              now - issued >= 0, now - issued < 35,
              let request = event["request"] as? String, UUID(uuidString: request) != nil,
              requests.count < 256, requests[request] == nil else { return false }
        requests[request] = now
        return true
    }
}
