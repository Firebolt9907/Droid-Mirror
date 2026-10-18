import Foundation
import CryptoKit

// One retained Mac card per incoming message; Android still owns the source
// notification and current action tokens. Reply echoes belong only to their card.
struct NotificationConversationState {
    enum Status: String { case sending, sent, failed, unconfirmed }
    private struct Reply {
        let request: String, text: String
        var status: Status
    }
    private struct Card {
        let source: String
        let message: [String: Any]?
        var replies = [Reply]()
    }
    private var phone: String?
    private var sources = [String: [String: Any]]()
    private var cards = [String: Card]()
    private var seen = Set<String>()
    private var seenOrder = [String]()
    private var order = [String]()

    private mutating func select(_ identity: String) {
        if phone != identity { self = NotificationConversationState(); phone = identity }
    }
    private static func key(source: String, message: [String: Any], occurrence: Int) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: Data((source + ":" + String(occurrence)).utf8) + data)
            .map { String(format: "%02x", $0) }.joined()
    }
    mutating func update(_ event: [String: Any], phone: String) -> [String] {
        select(phone)
        guard let source = event["id"] as? String else { return [] }
        sources[source] = event
        let isMessage = event["isMessage"] as? Bool == true
        var messages = event["messages"] as? [[String: Any]] ?? []
        if isMessage && messages.isEmpty {
            messages = [["sender": event["sender"] as? String ?? event["title"] as? String ?? "",
                "text": event["body"] as? String ?? "", "timestamp": event["postedAt"] ?? 0]]
        }
        if !isMessage {
            cards[source] = Card(source: source, message: nil)
            if !order.contains(source) { order.append(source) }
        } else {
            var occurrences = [String: Int]()
            for message in messages where message["outgoing"] as? Bool != true {
                let signature = Self.key(source: source, message: message, occurrence: 0)
                let occurrence = occurrences[signature, default: 0]
                occurrences[signature] = occurrence + 1
                let key = Self.key(source: source, message: message, occurrence: occurrence)
                guard seen.insert(key).inserted else { continue }
                seenOrder.append(key)
                cards[key] = Card(source: source, message: message)
                order.append(key)
            }
        }
        while order.count > 256 { cards.removeValue(forKey: order.removeFirst()) }
        while seenOrder.count > 4096 { seen.remove(seenOrder.removeFirst()) }
        let activeSources = Set(cards.values.map { $0.source })
        sources = sources.filter { activeSources.contains($0.key) }
        return order.filter { cards[$0]?.source == source }
    }
    // Rehydrate a visible card after receiver restart, without replaying its alert.
    mutating func adopt(phone: String, card: String, source: String, event: [String: Any], message: [String: Any]?, replies: [[String: Any]]) {
        select(phone)
        if sources[source] == nil { sources[source] = event }
        guard cards[card] == nil else { return }
        var value = Card(source: source, message: message)
        value.replies = replies.suffix(12).compactMap {
            guard let request = $0["request"] as? String, let text = $0["text"] as? String else { return nil }
            return Reply(request: request, text: text, status: Status(rawValue: $0["status"] as? String ?? "") ?? .unconfirmed)
        }
        cards[card] = value; order.append(card)
        if seen.insert(card).inserted { seenOrder.append(card) }
    }
    mutating func reply(phone: String, card: String, request: String, text: String) -> String? {
        select(phone)
        guard let original = cards[card] else { return nil }
        let outgoing = "reply." + request
        var value = Card(source: original.source, message: ["sender": "You", "text": text, "outgoing": true, "localReply": true])
        value.replies = [Reply(request: request, text: text, status: .sending)]
        cards[outgoing] = value
        order.append(outgoing)
        return outgoing
    }
    mutating func status(request: String, _ status: Status) -> String? {
        for card in order {
            guard let index = cards[card]?.replies.firstIndex(where: { $0.request == request }) else { continue }
            cards[card]?.replies[index].status = status
            return card
        }
        return nil
    }
    func event(phone: String, card: String) -> [String: Any]? {
        guard phone == self.phone, let value = cards[card], var event = sources[value.source] else { return nil }
        event["card"] = card
        event["cardReplies"] = value.replies.map { ["request": $0.request, "text": $0.text, "status": $0.status.rawValue] }
        guard let message = value.message else { return event }
        event["cardMessage"] = message
        let fromMe = message["localReply"] as? Bool == true
        event["fromMe"] = fromMe
        var messages = fromMe ? [] : [message]
        messages += value.replies.map { reply in
            let label: String
            switch reply.status {
            case .sending: label = "You (sending…)"
            case .sent: label = "You"
            case .failed: label = "You (not sent)"
            case .unconfirmed: label = "You (unconfirmed)"
            }
            return ["sender": label, "text": reply.text, "outgoing": true, "localReply": true] as [String: Any]
        }
        event["messages"] = messages
        event["messagesOmitted"] = 0
        event["body"] = message["text"] ?? ""
        event["sender"] = message["sender"] ?? event["sender"]
        // Android supplies media for its latest message only.
        let original = sources[value.source]?["messages"] as? [[String: Any]] ?? []
        if let latest = original.last, Self.key(source: value.source, message: latest, occurrence: 0) != Self.key(source: value.source, message: message, occurrence: 0) {
            event.removeValue(forKey: "contentImage"); event.removeValue(forKey: "contactImage")
        }
        if fromMe { event.removeValue(forKey: "contentImage"); event.removeValue(forKey: "contactImage") }
        return event
    }
    func currentSource(phone: String, id: String) -> [String: Any]? { phone == self.phone ? sources[id] : nil }
    func source(_ card: String) -> String? { cards[card]?.source }
    func siblings(_ source: String) -> [String] { order.filter { cards[$0]?.source == source } }
    mutating func dismiss(_ card: String) {
        cards.removeValue(forKey: card); order.removeAll { $0 == card }
    }
    mutating func remove(_ source: String) -> [String] {
        let removed = siblings(source)
        for card in removed { dismiss(card) }
        sources.removeValue(forKey: source)
        return removed
    }
}
