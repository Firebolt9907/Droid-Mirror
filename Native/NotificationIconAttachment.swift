import AppKit
import ImageIO
import UserNotifications

enum NotificationIconAttachment {
    static func validatedData(_ encoded: String?, photo: Bool = false, content: Bool = false) -> Data? {
        let maximumBytes = (photo || content) ? 4096 : 2048
        let maximumDimension = content ? 256 : photo ? 96 : 48
        guard let encoded, encoded.utf8.count <= (maximumBytes + 2) / 3 * 4,
              let data = Data(base64Encoded: encoded), (24...maximumBytes).contains(data.count) else { return nil }
        let png = data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        let jpeg = data.starts(with: [255, 216, 255])
        guard png || ((photo || content) && jpeg),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maximumDimension).contains(width), (1...maximumDimension).contains(height),
              let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide == width, bitmap.pixelsHigh == height else { return nil }
        return data
    }

    // Only message media belongs in the trailing attachment area. Sender and
    // app icons are used by NotificationCommunicationContent on the leading side.
    static func makeContent(_ encoded: String?) -> (attachment: UNNotificationAttachment, directory: URL)? {
        guard let data = validatedData(encoded, content: true) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DroidMirror-icon-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let isJPEG = data.starts(with: [255, 216, 255])
            let file = directory.appendingPathComponent(isJPEG ? "content.jpg" : "content.png")
            try data.write(to: file, options: [.atomic])
            let attachment = try UNNotificationAttachment(identifier: "android-content-image", url: file, options: [
                UNNotificationAttachmentOptionsThumbnailHiddenKey: false])
            return (attachment, directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }
}
