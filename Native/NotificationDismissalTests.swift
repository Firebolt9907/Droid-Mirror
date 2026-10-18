import Foundation
import UserNotifications

@main struct NotificationDismissalTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1000)
        var queue = NotificationDismissalQueue()
        queue.enqueue(phone: "phone", id: "message", version: "v1", now: now)
        queue.enqueue(phone: "phone", id: "message", version: "v1", now: now)
        let command = queue.due(phone: "phone", now: now).only
        precondition(command["type"] as? String == "dismiss")
        precondition(command["version"] as? String == "v1")
        let request = command["request"] as! String
        precondition(queue.due(phone: "phone", now: now).count == 1, "A failed transport send must stay queued")
        queue.sent(request, now: now)
        precondition(queue.due(phone: "phone", now: now.addingTimeInterval(4)).isEmpty)
        precondition(queue.due(phone: "phone", now: now.addingTimeInterval(5)).only["request"] as? String == request,
                     "Reconnect retry must keep the same idempotent request")
        queue.acknowledged("unrelated")
        precondition(queue.due(phone: "phone", now: now.addingTimeInterval(6)).count == 1)
        queue.acknowledged(request)
        precondition(queue.due(phone: "phone", now: now.addingTimeInterval(6)).isEmpty)
        queue.enqueue(phone: "phone", id: "message", version: "v1", now: now)
        queue.enqueue(phone: "phone", id: "message", version: "v2", now: now)
        precondition(queue.due(phone: "phone", now: now).only["version"] as? String == "v2")
        queue.removed(id: "message")
        precondition(queue.due(phone: "phone", now: now).isEmpty, "A phone removal must stop retries, not echo another dismissal")
        queue.enqueue(phone: "phone", id: "message", version: "v1", now: now)
        precondition(queue.due(phone: "different-phone", now: now).isEmpty, "Never send a dismissal to a newly paired phone")
        queue.enqueue(phone: "phone", id: "message", version: "v1", now: now)
        precondition(queue.due(phone: "phone", now: now.addingTimeInterval(301)).isEmpty)
        let action = UNNotificationAction(identifier: "reply", title: "Reply", options: [])
        for actions in [[], [action]] {
            let category = NotificationDismissalCategory.make(identifier: "test", actions: actions)
            precondition(category.options.contains(.customDismissAction))
            precondition(category.actions.count == actions.count)
        }
        print("Dismissal callbacks, offline retry, acknowledgments, version updates, expiry and phone-isolation tests passed")
    }
}

private extension Array {
    var only: Element { precondition(count == 1); return self[0] }
}
