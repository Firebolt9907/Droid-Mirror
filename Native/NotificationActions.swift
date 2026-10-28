import Foundation

// Replies and notification buttons use BLE directly. Only opening the source
// app needs the mirroring window. A queued write is not an Android receipt.
struct NotificationActionQueue {
    struct Pending {
        let phone: String
        var command: [String: Any]
        let activitySpec: [String: Any]?
        var expires: Date
        var sent = false
        var needsMirror: Bool { command["action"] as? String == "open" || command["opensApp"] as? Bool == true }
    }
    private(set) var pending = [String: Pending]()

    mutating func enqueue(phone: String, command: [String: Any], activitySpec: [String: Any]? = nil, now: Date = Date()) {
        guard let request = command["request"] as? String else { return }
        pending[request] = Pending(phone: phone, command: command, activitySpec: activitySpec, expires: now.addingTimeInterval(45))
    }

    /// While waiting for video, accept a fresh token only for the same advertised operation.
    mutating func refreshActivity(phone: String, event: [String: Any]) -> Bool {
        guard let id = event["id"] as? String, let version = event["version"] as? String else { return false }
        var cancelled = false
        for (request, var action) in pending where action.phone == phone && !action.sent &&
            action.command["id"] as? String == id {
            guard let expected = action.activitySpec else { continue }
            let key = action.command["action"] as? String ?? ""
            let current: [String: Any]? = key == "open" ?
                (event["canOpen"] as? Bool == true ? ["id": "open"] : nil) :
                (event["actions"] as? [[String: Any]])?.first { $0["id"] as? String == key }
            guard let current, NSDictionary(dictionary: expected).isEqual(to: current) else {
                pending.removeValue(forKey: request); cancelled = true; continue
            }
            action.command["version"] = version
            pending[request] = action
        }
        return cancelled
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

    mutating func sent(_ request: String, now: Date = Date()) {
        guard var action = pending[request] else { return }
        action.sent = true
        // Android may wait up to 30 seconds for unlock. Connection startup
        // must not consume that receipt window or cause a premature failure.
        if action.needsMirror { action.expires = max(action.expires, now.addingTimeInterval(35)) }
        pending[request] = action
    }
    @discardableResult mutating func acknowledge(_ request: String) -> Bool {
        pending.removeValue(forKey: request) != nil
    }
    mutating func removed(id: String) {
        // An Android reply may itself remove the notification before its receipt.
        pending = pending.filter { $0.value.sent || $0.value.command["id"] as? String != id }
    }
}
