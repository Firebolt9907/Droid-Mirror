import Foundation

// Replies and notification buttons use BLE directly. Only opening the source
// app needs the mirroring window. A queued write is not an Android receipt.
struct NotificationActionQueue {
    struct Pending {
        let phone: String
        let command: [String: Any]
        let expires: Date
        var sent = false
        var needsMirror: Bool { command["action"] as? String == "open" }
    }
    private(set) var pending = [String: Pending]()

    mutating func enqueue(phone: String, command: [String: Any], now: Date = Date()) {
        guard let request = command["request"] as? String else { return }
        pending[request] = Pending(phone: phone, command: command, expires: now.addingTimeInterval(45))
    }

    mutating func expire(phone: String?, now: Date = Date()) -> [Pending] {
        let expired = pending.values.filter { $0.phone == phone && $0.expires <= now }
        pending = pending.filter { $0.value.phone == phone && $0.value.expires > now }
        return expired
    }

    func due(phone: String, mirrorVisible: Bool) -> [Pending] {
        pending.values.filter { $0.phone == phone && !$0.sent && (!$0.needsMirror || mirrorVisible) }
            .sorted { $0.expires < $1.expires }
    }

    func needsMirror(phone: String) -> Bool {
        pending.values.contains { $0.phone == phone && !$0.sent && $0.needsMirror }
    }

    mutating func sent(_ request: String) { pending[request]?.sent = true }
    @discardableResult mutating func acknowledge(_ request: String) -> Bool {
        pending.removeValue(forKey: request) != nil
    }
    mutating func removed(id: String) {
        // An Android reply may itself remove the notification before its receipt.
        pending = pending.filter { $0.value.sent || $0.value.command["id"] as? String != id }
    }
}
