import Foundation
import UserNotifications

@main struct NotificationCommunicationTests {
    static func main() throws {
        let content = UNMutableNotificationContent()
        content.title = "Chat app"
        content.subtitle = "Sender"
        content.body = "Message body"
        content.categoryIdentifier = "reply-actions"
        content.userInfo = ["phone": "phone", "id": "conversation", "version": "v1", "quiet": true]
        content.interruptionLevel = .passive
        let ordinary = NotificationCommunicationContent.make(content, event: ["id": "system"], identity: "phone")
        precondition(ordinary === content, "System notifications must retain normal presentation")
        let own = NotificationCommunicationContent.make(content, event: ["id": "conversation", "isMessage": true, "fromMe": true], identity: "phone")
        precondition(own === content, "You cards must not inherit the remote sender's communication identity")
        let message = NotificationCommunicationContent.make(content, event: ["id": "conversation", "isMessage": true,
            "sender": "Sender", "senderID": "sender-opaque", "app": "Chat app"], identity: "phone")
        precondition(message !== content, "Messages must be enriched with native communication metadata")
        precondition(message.attachments.isEmpty, "An avatar must not become a trailing attachment")
        precondition(message.categoryIdentifier == content.categoryIdentifier)
        precondition(message.userInfo["version"] as? String == "v1")
        precondition(message.interruptionLevel == .passive, "Snapshots must stay passive")
        if !NotificationCommunicationContent.available {
            var called = false
            NotificationCommunicationContent.prepare(content, event: ["id": "test", "isMessage": true], identity: "test") { result in
                called = true
                precondition(result === content, "Unprovisioned builds must preserve app identity and ordinary presentation")
            }
            precondition(called, "Missing capability must not delay delivery")
        }
        print("Communication metadata, capability fallback, action preservation, and text-only layout tests passed")
    }
}
