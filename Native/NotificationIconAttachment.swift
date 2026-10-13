import AppKit
import UserNotifications

enum NotificationIconAttachment {
    static func validatedData(_ encoded: String?) -> Data? {
        guard let encoded, encoded.utf8.count <= 2800,
              let data = Data(base64Encoded: encoded), (24...2048).contains(data.count),
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return nil }
        let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (1...48).contains(width), (1...48).contains(height),
              let bitmap = NSBitmapImageRep(data: data),
              (1...48).contains(bitmap.pixelsWide), (1...48).contains(bitmap.pixelsHigh) else { return nil }
        return data
    }
    static func make(_ encoded: String?) -> (attachment: UNNotificationAttachment, directory: URL)? {
        guard let data = validatedData(encoded) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DroidMirror-icon-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("app.png")
            try data.write(to: file, options: [.atomic])
            let attachment = try UNNotificationAttachment(identifier: "android-app-icon", url: file, options: [
                UNNotificationAttachmentOptionsThumbnailHiddenKey: false])
            return (attachment, directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }
}
