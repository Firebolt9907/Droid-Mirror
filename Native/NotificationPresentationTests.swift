import Foundation

@main
struct NotificationPresentationTests {
    static func main() {
        var policy = NotificationPresentationPolicy()
        var weather: [String: Any] = ["id": "weather", "app": "Google", "body": "Weather", "snapshot": true]
        precondition(policy.quiet(identity: "phone", event: weather))
        weather["snapshot"] = false
        precondition(policy.quiet(identity: "phone", event: weather), "Repeated weather must not alert")
        var message: [String: Any] = ["id": "conversation", "app": "Beeper", "body": "First message"]
        precondition(!policy.quiet(identity: "phone", event: message))
        precondition(policy.quiet(identity: "phone", event: message))
        message["body"] = "Second message"
        precondition(!policy.quiet(identity: "phone", event: message), "Fresh messages must alert")
        message["version"] = "new action token"
        precondition(policy.quiet(identity: "phone", event: message), "Action token refresh must be quiet")
        weather["body"] = "Updated weather"; weather["silent"] = true
        precondition(policy.quiet(identity: "phone", event: weather), "Android silent updates must remain quiet")
        var conversation: [String: Any] = ["id": "thread", "app": "Beeper", "title": "Thread: Tatha",
            "conversation": "Thread", "body": "Second message", "messages": [
                ["sender": "Tatha", "text": "First message", "timestamp": 1],
                ["sender": "Tatha", "text": "Second message", "timestamp": 2]]]
        precondition(NotificationConversationContent.subtitle(conversation) == "Thread")
        precondition(NotificationConversationContent.body(conversation) == "Tatha: First message\nTatha: Second message")
        precondition(!policy.quiet(identity: "phone", event: conversation))
        precondition(policy.quiet(identity: "phone", event: conversation))
        conversation["messages"] = [["sender": "Tatha", "text": "Second message", "timestamp": 2],
                                    ["sender": "Tatha", "text": "Second message", "timestamp": 3]]
        precondition(!policy.quiet(identity: "phone", event: conversation), "A repeated new message must alert even when EXTRA_TEXT is unchanged")
        precondition(NotificationConversationContent.body(conversation) == "Tatha: Second message\nTatha: Second message")
        conversation["messagesOmitted"] = 3
        precondition(NotificationConversationContent.body(conversation).hasPrefix("… 3 earlier messages\n"))
        precondition(NotificationConversationContent.body(["body": "Legacy message"]) == "Legacy message")
        precondition(NotificationConversationContent.body(["messages": [["sender": "A"]], "body": "Fallback"]) == "Fallback")
        print("Snapshot, duplicate weather, and fresh message presentation tests passed")
    }
}
