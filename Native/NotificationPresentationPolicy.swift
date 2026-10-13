import Foundation
import CryptoKit

struct NotificationPresentationPolicy {
    private var fingerprints = [String: String]()
    mutating func quiet(identity: String, event: [String: Any]) -> Bool {
        guard let id = event["id"] as? String else { return true }
        let key = identity + ":" + id
        // No text is retained; icon/transport/action-version changes alone do
        // not turn an existing notification into a new alert.
        let fields: [String: Any] = ["app": event["app"] ?? "", "title": event["title"] ?? "",
            "body": event["body"] ?? "", "actions": event["actions"] ?? []]
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let duplicate = fingerprints[key] == fingerprint
        if fingerprints.count >= 256 && fingerprints[key] == nil { fingerprints.removeAll() }
        fingerprints[key] = fingerprint
        return event["snapshot"] as? Bool == true || event["silent"] as? Bool == true || duplicate
    }
}
