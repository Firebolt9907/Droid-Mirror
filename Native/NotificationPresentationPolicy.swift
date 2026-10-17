import Foundation
import CryptoKit

struct NotificationPresentationPolicy {
    private var fingerprints = [String: String]()
    mutating func quiet(identity: String, event: [String: Any]) -> Bool {
        guard let id = event["id"] as? String else { return true }
        let key = identity + ":" + id
        // No text is retained; icon/transport/action-version changes alone do
        // not turn an existing notification into a new alert.
        let messages = event["messages"] as? [[String: Any]] ?? []
        let fields: [String: Any] = ["app": event["app"] ?? "", "title": event["title"] ?? "",
            "body": messages.isEmpty ? event["body"] ?? "" : "", "actions": event["actions"] ?? [],
            "conversation": event["conversation"] ?? "", "messages": messages.filter { $0["outgoing"] as? Bool != true }]
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let duplicate = fingerprints[key] == fingerprint
        if fingerprints.count >= 256 && fingerprints[key] == nil { fingerprints.removeAll() }
        fingerprints[key] = fingerprint
        return event["snapshot"] as? Bool == true || event["silent"] as? Bool == true || duplicate || messages.last?["outgoing"] as? Bool == true
    }
}


// macOS expands a multiline notification body; retain the conversation rather
// than flattening Android's MessagingStyle to EXTRA_TEXT (the final message).
enum NotificationConversationContent {
    static func subtitle(_ event: [String: Any]) -> String {
        let conversation = event["conversation"] as? String ?? ""
        return String((conversation.isEmpty ? event["title"] as? String ?? "" : conversation).prefix(240))
    }

    static func body(_ event: [String: Any]) -> String {
        guard let messages = event["messages"] as? [[String: Any]], !messages.isEmpty else {
            return String((event["body"] as? String ?? "").prefix(1200))
        }
        var lines = messages.suffix(12).compactMap { message -> String? in
            guard let text = message["text"] as? String, !text.isEmpty else { return nil }
            let name = message["outgoing"] as? Bool == true && message["localReply"] as? Bool != true ? "You" : message["sender"] as? String ?? ""
            let sender = String(name.prefix(120))
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            return sender.isEmpty ? text : sender + ": " + text
        }
        guard !lines.isEmpty else { return String((event["body"] as? String ?? "").prefix(1200)) }
        var omitted = (event["messagesOmitted"] as? Int ?? 0) + max(0, messages.count - 12)
        // Keep the newest reply visible even when local echoes add more text
        // than the Android wire budget. Drop old lines before clipping new ones.
        while lines.count > 1 && lines.joined(separator: "\n").count > 3900 {
            lines.removeFirst(); omitted += 1
        }
        if omitted > 0 { lines.insert("… \(omitted) earlier messages", at: 0) }
        return String(lines.joined(separator: "\n").prefix(4000))
    }
}
