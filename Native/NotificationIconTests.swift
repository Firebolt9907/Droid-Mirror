import AppKit

@main
struct NotificationIconTests {
    static func main() throws {
        func image(_ size: Int, jpeg: Bool = false) -> Data {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<size { for x in 0..<size {
                bitmap.setColor(NSColor(deviceRed: 0.2, green: 0.6, blue: 0.9, alpha: 1), atX: x, y: y)
            } }
            return bitmap.representation(using: jpeg ? .jpeg : .png, properties: [.compressionFactor: 0.75])!
        }
        let app = image(32)
        precondition(NotificationIconAttachment.validatedData(app.base64EncodedString()) == app)
        precondition(NotificationIconAttachment.validatedData(nil) == nil)
        precondition(NotificationIconAttachment.validatedData("not an image") == nil)
        precondition(NotificationIconAttachment.validatedData(Data(repeating: 0, count: 5000).base64EncodedString(), content: true) == nil)
        var invalid = app; invalid[16] = 255
        precondition(NotificationIconAttachment.validatedData(invalid.base64EncodedString()) == nil)
        let photo = image(64, jpeg: true)
        precondition(NotificationIconAttachment.validatedData(photo.base64EncodedString()) == nil)
        precondition(NotificationIconAttachment.validatedData(photo.base64EncodedString(), photo: true) == photo)
        let media = image(256, jpeg: true)
        precondition(NotificationIconAttachment.validatedData(media.base64EncodedString(), photo: true) == nil)
        precondition(NotificationIconAttachment.validatedData(media.base64EncodedString(), content: true) == media)
        precondition(NotificationIconAttachment.validatedData(image(257, jpeg: true).base64EncodedString(), content: true) == nil)
        precondition(NotificationIconAttachment.makeContent(nil) == nil, "Text-only notifications must have no trailing image")
        let attachment = NotificationIconAttachment.makeContent(media.base64EncodedString())!
        precondition(attachment.attachment.type == "public.jpeg")
        precondition(attachment.attachment.identifier == "android-content-image")
        try? FileManager.default.removeItem(at: attachment.directory)
        print("Avatar/media image validation, size limits, and content-only attachment tests passed")
    }
}
