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
        print("Snapshot, duplicate weather, and fresh message presentation tests passed")
    }
}
