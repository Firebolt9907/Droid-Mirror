import Foundation
import Intents
import Security
import UserNotifications

enum NotificationCommunicationContent {
    static let available: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task,
            "com.apple.developer.usernotifications.communication" as CFString, nil) as? Bool == true
    }()

    private static var cleanedIdentities = Set<String>()
    private static func intent(_ content: UNMutableNotificationContent, event: [String: Any], identity: String) -> INSendMessageIntent? {
        guard event["isMessage"] as? Bool == true, event["fromMe"] as? Bool != true,
              let id = event["id"] as? String else { return nil }
        let name = (event["sender"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (event["title"] as? String) ?? content.title
        let senderID = identity + ":" + (event["senderID"] as? String ?? id)
        let imageData = NotificationIconAttachment.validatedData(event["contactImage"] as? String, photo: true)
            ?? NotificationIconAttachment.validatedData(event["appIcon"] as? String)
        let image = imageData.map { INImage(imageData: $0) }
        let sender = INPerson(personHandle: INPersonHandle(value: senderID, type: .unknown),
            nameComponents: nil, displayName: name, image: image,
            contactIdentifier: nil, customIdentifier: senderID)
        let group = (event["conversation"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText,
            content: content.body, speakableGroupName: group.map { INSpeakableString(spokenPhrase: $0) },
            conversationIdentifier: identity + ":" + id, serviceName: event["app"] as? String,
            sender: sender, attachments: nil)
    }

    private static func update(_ content: UNMutableNotificationContent, intent: INSendMessageIntent) -> UNNotificationContent {
        do {
            // The returned content contains the native sender avatar. Do not
            // mutate it afterwards or turn that avatar into a media attachment.
            return try content.updating(from: intent)
        } catch {
            NSLog("DroidMirror sender-avatar presentation unavailable: %@", error.localizedDescription)
            return content
        }
    }

    static func make(_ content: UNMutableNotificationContent, event: [String: Any], identity: String) -> UNNotificationContent {
        guard let intent = intent(content, event: event, identity: identity) else { return content }
        return update(content, intent: intent)
    }

    static func prepare(_ content: UNMutableNotificationContent, event: [String: Any], identity: String,
                        completion: @escaping (UNNotificationContent) -> Void) {
        guard available else {
            // Updating content can succeed without this entitlement while macOS
            // silently keeps the app icon. Keep ordinary presentation until a
            // matching provisioning profile enables the native avatar capability.
            if cleanedIdentities.insert(identity).inserted {
                INInteraction.delete(with: identity, completion: nil)
            }
            completion(content)
            return
        }
        guard let intent = intent(content, event: event, identity: identity) else { completion(content); return }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.identifier = identity + ":" + (event["id"] as? String ?? "") + ":" + (event["version"] as? String ?? "")
        interaction.groupIdentifier = identity
        // Donation lets Intents persist the sender image before Notification
        // Center renders it. Bound the wait so text delivery cannot get stuck.
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            completion(update(content, intent: intent))
        }
        interaction.donate { error in
            DispatchQueue.main.async {
                if let error { NSLog("DroidMirror avatar registration failed: %@", error.localizedDescription) }
                finish()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: finish)
    }

}
