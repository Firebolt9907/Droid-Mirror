import Foundation

@main struct NotificationActionTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1000)
        var queue = NotificationActionQueue()
        func command(_ request: String, _ action: String) -> [String: Any] {
            ["type": "action", "id": "notification", "version": "v1", "request": request,
             "action": action, "text": "Synthetic reply"]
        }
        queue.enqueue(phone: "phone", command: command("reply", "0"), now: now)
        queue.enqueue(phone: "phone", command: command("open", "open"), now: now)
        precondition(queue.due(phone: "phone", mirrorVisible: false).map { $0.command["request"] as! String } == ["reply"],
                     "Replies must send without a mirror window or ADB")
        precondition(queue.due(phone: "phone", mirrorVisible: true).count == 2)
        precondition(queue.due(phone: "other", mirrorVisible: true).isEmpty)
        precondition(queue.needsMirror(phone: "phone"))
        queue.sent("reply")
        precondition(queue.due(phone: "phone", mirrorVisible: false).isEmpty,
                     "A lost receipt must not cause duplicate messages")
        queue.removed(id: "notification")
        precondition(queue.pending.count == 1, "Reply-induced removal must preserve its pending receipt")
        precondition(!queue.acknowledge("unrelated"))
        precondition(queue.acknowledge("reply"))
        precondition(queue.pending.isEmpty)
        queue.enqueue(phone: "phone", command: command("offline", "0"), now: now)
        precondition(queue.expire(phone: "phone", now: now.addingTimeInterval(44)).isEmpty)
        precondition(queue.expire(phone: "phone", now: now.addingTimeInterval(45)).first?.sent == false)
        queue.enqueue(phone: "phone", command: command("unconfirmed", "0"), now: now)
        queue.sent("unconfirmed")
        precondition(queue.expire(phone: "phone", now: now.addingTimeInterval(45)).first?.sent == true)
        queue.enqueue(phone: "phone", command: command("old-pairing", "0"), now: now)
        precondition(queue.expire(phone: "new-phone", now: now).isEmpty)
        precondition(queue.pending.isEmpty)
        queue.enqueue(phone: "phone", command: command("unlock", "open"), now: now)
        queue.sent("unlock", now: now.addingTimeInterval(40))
        precondition(queue.expire(phone: "phone", now: now.addingTimeInterval(45)).isEmpty,
                     "Slow connection setup must leave time for unlocking")
        precondition(queue.expire(phone: "phone", now: now.addingTimeInterval(74)).isEmpty)
        precondition(queue.expire(phone: "phone", now: now.addingTimeInterval(75)).first?.sent == true)
        var opening = command("map", "1")
        opening["opensApp"] = true
        let spec: [String: Any] = ["id": "1", "title": "Map", "opensApp": true, "reply": false]
        queue.enqueue(phone: "phone", command: opening, activitySpec: spec, now: now)
        precondition(queue.due(phone: "phone", mirrorVisible: false).isEmpty, "App-opening buttons must wait for a rendered stream")
        precondition(queue.needsMirror(phone: "phone"))
        precondition(!queue.refreshActivity(phone: "phone", event: ["id": "notification", "version": "v2", "actions": [spec]]))
        precondition(queue.due(phone: "phone", mirrorVisible: true).first?.command["version"] as? String == "v2")
        var changed = spec; changed["title"] = "Leave"
        precondition(queue.refreshActivity(phone: "phone", event: ["id": "notification", "version": "v3", "actions": [changed]]))
        precondition(queue.pending.isEmpty, "A changed operation must not execute after video startup")
        print("Direct replies, mirror-only opens, acknowledgments, duplicate prevention, expiry and phone isolation passed")
    }
}
