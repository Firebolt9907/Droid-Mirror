import Foundation

@main struct NotificationConversationTests {
    static func main() {
        var state = NotificationConversationState()
        let first: [String: Any] = ["sender": "Alice", "text": "Hello", "timestamp": 1000]
        let second: [String: Any] = ["sender": "Alice", "text": "Next", "timestamp": 2000]
        var event: [String: Any] = ["id": "thread", "version": "v1", "isMessage": true, "messages": [first]]
        let original = state.update(event, phone: "phone").first!
        let outgoing = state.reply(phone: "phone", card: original, request: "request1", text: "My reply")!
        func body(_ card: String) -> String {
            NotificationConversationContent.body(state.event(phone: "phone", card: card) ?? [:])
        }
        precondition(body(original) == "Alice: Hello", "Resending the replied-to card must preserve its original message")
        precondition(body(outgoing) == "You (sending…): My reply")
        precondition(state.siblings("thread").count == 2, "A reply must create its own card")
        precondition(state.status(request: "request1", .sent) == outgoing)
        precondition(body(outgoing) == "You: My reply")
        precondition(state.event(phone: "phone", card: outgoing)?["fromMe"] as? Bool == true)
        event["version"] = "v2"
        event["messages"] = [first, ["sender": "Me", "text": "My reply", "timestamp": 1500, "outgoing": true], second]
        let all = state.update(event, phone: "phone")
        precondition(all.count == 3, "An incoming message adds a card; an Android reply echo must not duplicate the You card")
        let new = all.first { $0 != original && $0 != outgoing }!
        precondition(body(new) == "Alice: Next")
        precondition(body(original) == "Alice: Hello" && body(outgoing) == "You: My reply")
        precondition(state.event(phone: "phone", card: original)?["version"] as? String == "v2", "Old cards use current action tokens")
        precondition(state.update(event, phone: "phone").count == 3, "Repeated snapshots must not create duplicate cards")
        state.dismiss(original)
        precondition(state.update(event, phone: "phone").count == 2, "A dismissed message must not return on a token refresh")
        let another = state.reply(phone: "phone", card: new, request: "request2", text: "Again")!
        precondition(state.status(request: "request2", .failed) == another)
        precondition(body(another) == "You (not sent): Again")
        _ = state.status(request: "request2", .unconfirmed)
        precondition(body(another) == "You (unconfirmed): Again")
        var restarted = NotificationConversationState()
        let saved = state.event(phone: "phone", card: outgoing)!
        restarted.adopt(phone: "phone", card: outgoing, source: "thread", event: saved,
            message: saved["cardMessage"] as? [String: Any], replies: saved["cardReplies"] as? [[String: Any]] ?? [])
        precondition(NotificationConversationContent.body(restarted.event(phone: "phone", card: outgoing)!) == "You: My reply")
        precondition(state.remove("thread").count == 3)
        precondition(state.event(phone: "phone", card: new) == nil, "Phone removal must cancel delayed restorations of every card")
        _ = state.update(event, phone: "other")
        precondition(state.event(phone: "phone", card: new) == nil)
        var identical = NotificationConversationState()
        event["messages"] = [first, first]
        precondition(identical.update(event, phone: "phone").count == 2, "Two identical messages in one snapshot remain distinct")
        precondition(identical.update(event, phone: "phone").count == 2)
        var formatted = NotificationConversationState()
        event["app"] = "OpenBubbles"; event["title"] = "Friends"; event["subtitle"] = "Alice"
        event["messages"] = [first, second]
        let formattedCards = formatted.update(event, phone: "phone")
        for (index, card) in formattedCards.enumerated() {
            let content = formatted.event(phone: "phone", card: card)!
            precondition(NotificationConversationContent.title(content) == "Friends (OpenBubbles)")
            precondition(NotificationConversationContent.subtitle(content) == "Alice")
            precondition(NotificationConversationContent.body(content) == (index == 0 ? "Hello" : "Next"))
        }
        print("Separate incoming and You cards, original-message retention, reply statuses, echo deduplication, token refresh, dismissal and restart passed")
    }
}
