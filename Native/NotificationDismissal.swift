import Foundation
import UserNotifications

struct NotificationDismissalQueue {
    private struct Pending {
        let phone: String, id: String, version: String, request: String
        let expires: Date
        var sent: Date?
    }
    private var pending = [String: Pending]()

    mutating func enqueue(phone: String, id: String, version: String, now: Date = Date()) {
        let key = phone + ":" + id
        if pending[key]?.version == version { return }
        pending = pending.filter { $0.value.expires > now }
        if pending.count >= 256, let oldest = pending.min(by: { $0.value.expires < $1.value.expires })?.key {
            pending.removeValue(forKey: oldest)
        }
        pending[key] = Pending(phone: phone, id: id, version: version, request: UUID().uuidString,
            expires: now.addingTimeInterval(300))
    }

    mutating func due(phone: String, now: Date = Date()) -> [[String: Any]] {
        // A queued dismissal belongs only to the phone the user dismissed it for.
        pending = pending.filter { $0.value.phone == phone && $0.value.expires > now }
        return pending.values.filter { $0.sent.map { now.timeIntervalSince($0) >= 5 } ?? true }
            .sorted { $0.expires < $1.expires }.prefix(8).map {
                ["type": "dismiss", "id": $0.id, "version": $0.version, "request": $0.request]
            }
    }

    mutating func sent(_ request: String, now: Date = Date()) {
        guard let key = pending.first(where: { $0.value.request == request })?.key else { return }
        pending[key]?.sent = now
    }

    mutating func acknowledged(_ request: String) {
        pending = pending.filter { $0.value.request != request }
    }

    mutating func removed(id: String) { pending = pending.filter { $0.value.id != id } }
}

enum NotificationDismissalCategory {
    static func make(identifier: String, actions: [UNNotificationAction]) -> UNNotificationCategory {
        UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [], options: [.customDismissAction])
    }
}
