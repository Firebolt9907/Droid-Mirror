import Foundation

@main
struct NotificationPresentationTests {
    static func main() {
        for text in ["Your verification code is 012345", "Use 4821 as your security code", "Your OTP: A1B2C3"] {
            precondition(NotificationVerificationCode.detect(["body": text]) != nil)
        }
        for text in ["Your parcel 123456 is arriving", "Call 1234567890 to verify", "Verification code 123456 or 654321"] {
            precondition(NotificationVerificationCode.detect(["body": text]) == nil)
        }
        let otp: [String: Any] = ["body": "Your verification code is 012345"]
        precondition(NotificationVerificationCode.detect(otp) == "012345")
        for flag in ["snapshot", "silent", "fromMe"] {
            var stale = otp; stale[flag] = true
            precondition(NotificationVerificationCode.detect(stale) == nil)
        }
        precondition(NotificationVerificationCode.detect(["messages": [
            ["text": "Verification code 123456"], ["text": "Hello"]]]) == nil,
            "Old conversation codes must not be copied")
        precondition(NotificationVerificationCode.detect(["messages": [
            ["text": "Verification code 123456", "outgoing": true]]]) == nil)
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
        let card: [String: Any] = ["app": "OpenBubbles", "title": "Brian Liu, Peter Yu, Tatha Pandey",
            "messages": [["sender": "Tatha Pandey", "text": "Hello"]]]
        precondition(NotificationConversationContent.title(card) == "Brian Liu, Peter Yu, Tatha Pandey (OpenBubbles)")
        precondition(NotificationConversationContent.subtitle(card) == "Tatha Pandey")
        precondition(NotificationConversationContent.body(card) == "Hello")
        var supplied = card
        supplied["subtitle"] = "App-provided subtitle"
        precondition(NotificationConversationContent.subtitle(supplied) == "App-provided subtitle")
        precondition(NotificationConversationContent.body(supplied) == "Hello")
        supplied["title"] = "Tatha Pandey"; supplied.removeValue(forKey: "subtitle")
        precondition(NotificationConversationContent.subtitle(supplied).isEmpty)
        precondition(NotificationConversationContent.body(supplied) == "Hello")
        precondition(NotificationConversationContent.title(["app": "Chat"]) == "Chat")
        precondition(NotificationConversationContent.title(["app": "Chat", "title": "Chat"]) == "Chat")
        precondition(NotificationConversationContent.title(["title": "Alert"]) == "Alert (Android)")
        var changed: [String: Any] = ["id": "subtitle", "title": "Title", "subtitle": "First"]
        precondition(!policy.quiet(identity: "phone", event: changed))
        changed["subtitle"] = "Second"
        precondition(!policy.quiet(identity: "phone", event: changed))
        print("Snapshot, duplicate weather, and fresh message presentation tests passed")
    }
}
