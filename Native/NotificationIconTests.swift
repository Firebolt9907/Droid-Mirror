import AppKit

@main
struct NotificationIconTests {
    static func main() throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = bitmap.representation(using: .png, properties: [:])!
        precondition(NotificationIconAttachment.validatedData(data.base64EncodedString()) == data)
        precondition(NotificationIconAttachment.validatedData(nil) == nil)
        precondition(NotificationIconAttachment.validatedData("not an image") == nil)
        precondition(NotificationIconAttachment.validatedData(Data(repeating: 0, count: 3000).base64EncodedString()) == nil)
        var invalid = data; invalid[16] = 255
        precondition(NotificationIconAttachment.validatedData(invalid.base64EncodedString()) == nil)
        if let icon = NotificationIconAttachment.make(data.base64EncodedString()) {
            precondition(icon.attachment.type == "public.png")
            try? FileManager.default.removeItem(at: icon.directory)
        } else { fatalError("Valid app icon must create a notification attachment") }
        print("Notification icon validation and attachment tests passed")
    }
}
