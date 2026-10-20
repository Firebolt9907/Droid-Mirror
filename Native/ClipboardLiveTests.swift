import AppKit
import Darwin
import CryptoKit

enum ClipboardLiveFailure: Error { case failed(String) }
@main struct ClipboardLiveTests {
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        guard CommandLine.arguments.count == 4 else { throw ClipboardLiveFailure.failed("Pass ADB serial, installed APK path, and adb executable") }
        let board = NSPasteboard.general
        let original = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let prefs = UserDefaults(suiteName: "app.droidmirror.mac")!
        let wasEnabled = prefs.bool(forKey: "DroidMirror.clipboard.enabled")
        guard wasEnabled else { throw ClipboardLiveFailure.failed("Enable clipboard mirroring before this live test") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[3])
        process.arguments = ["-s", CommandLine.arguments[1], "shell", "env",
            "CLASSPATH=/data/local/tmp/droidmirror-clipboard-probe.jar:" + CommandLine.arguments[2], "app_process", "/", "ClipboardDeviceProbe"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
        try process.run()
        func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func line() throws -> String {
            var data = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte.first == 10 { return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                data.append(byte)
            }
            throw ClipboardLiveFailure.failed("Device probe exited")
        }
        func exchange(_ command: String) throws -> String {
            try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
            return try line()
        }
        func configure(_ enabled: Bool) {
            prefs.set(enabled, forKey: "DroidMirror.clipboard.enabled"); prefs.synchronize()
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("app.droidmirror.clipboardConfiguration"), object: nil, userInfo: nil, deliverImmediately: true)
        }
        let prefix = "DroidMirror-test-" + UUID().uuidString
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 127, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = bitmap.representation(using: .png, properties: [:])!
        var testImages = [png]
        func isTestImage() -> Bool {
            if let data = board.data(forType: .png), testImages.contains(data) { return true }
            guard let path = board.string(forType: .fileURL), let url = URL(string: path), url.isFileURL else { return false }
            guard let data = try? Data(contentsOf: url) else { return false }
            return testImages.contains(data)
        }
        defer {
            configure(false); pause(1)
            _ = try? exchange("restore")
            try? input.fileHandleForWriting.close()
            // Restore only if the clipboard still belongs to the test; preserve concurrent user copies.
            if board.string(forType: .string)?.hasPrefix(prefix) == true || isTestImage() {
                board.clearContents()
                let items = original.map { values -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                board.writeObjects(items)
            }
            configure(wasEnabled)
        }
        guard try line() == "READY" else { throw ClipboardLiveFailure.failed("Device probe did not become ready") }
        let mac = prefix + "-Mac-😀"
        board.clearContents(); board.setString(mac, forType: .string)
        var matched = false
        for _ in 0..<12 {
            pause(0.5)
            if try exchange("check " + mac) == "MATCH" { matched = true; break }
        }
        guard matched else { throw ClipboardLiveFailure.failed("Mac to Android timed out") }
        print("PASS: Mac → Android over authenticated BLE")
        let phone = prefix + "-Android-😀"
        guard try exchange("set " + phone) == "SET" else { throw ClipboardLiveFailure.failed("Could not set device test text") }
        matched = false
        for _ in 0..<12 {
            pause(0.5)
            if board.string(forType: .string) == phone { matched = true; break }
        }
        guard matched else { throw ClipboardLiveFailure.failed("Android to Mac timed out") }
        print("PASS: Android → Mac over authenticated BLE")
        board.clearContents(); board.setData(png, forType: .png)
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        matched = false
        for _ in 0..<24 {
            pause(0.5)
            if try exchange("check-image DroidMirror-test-" + digest) == "MATCH" { matched = true; break }
        }
        guard matched else { throw ClipboardLiveFailure.failed("Mac image to Android timed out") }
        print("PASS: Mac → Android image bytes over authenticated BLE")
        // Establish a new text clipboard first so the return trip must deliver pixels.
        let separator = prefix + "-image-return"
        board.clearContents(); board.setString(separator, forType: .string)
        matched = false
        for _ in 0..<12 {
            pause(0.5)
            if try exchange("check " + separator) == "MATCH" { matched = true; break }
        }
        guard matched else { throw ClipboardLiveFailure.failed("Image return baseline timed out") }
        guard try exchange("set-image " + prefix) == "SET" else { throw ClipboardLiveFailure.failed("Could not copy phone image") }
        matched = false
        for _ in 0..<24 {
            pause(0.5)
            if isTestImage(), board.data(forType: .png) != nil, board.data(forType: .tiff) != nil { matched = true; break }
        }
        guard matched else { throw ClipboardLiveFailure.failed("Android image to Mac timed out") }
        print("PASS: Android → Mac image pixels and original file over authenticated BLE")
        // Incompressible pixels produce a PNG around the reported 66 KB size.
        let screenshot = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied, bytesPerRow: 0, bitsPerPixel: 0)!
        var random: UInt32 = 0x12345678
        for index in 0..<(screenshot.bytesPerRow * screenshot.pixelsHigh) {
            random ^= random << 13; random ^= random >> 17; random ^= random << 5
            screenshot.bitmapData![index] = UInt8(truncatingIfNeeded: random)
        }
        let screenshotPNG = screenshot.representation(using: .png, properties: [:])!
        precondition(screenshotPNG.count > 60_000 && screenshotPNG.count < 75_000)
        testImages.append(screenshotPNG)
        let screenshotDigest = SHA256.hash(data: screenshotPNG).map { String(format: "%02x", $0) }.joined()
        let started = ProcessInfo.processInfo.systemUptime
        board.clearContents(); board.setData(screenshotPNG, forType: .png)
        matched = false
        for _ in 0..<30 {
            pause(0.5)
            if try exchange("check-image DroidMirror-test-" + screenshotDigest) == "MATCH" { matched = true; break }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        guard matched else { throw ClipboardLiveFailure.failed("66 KB screenshot exceeded the 15-second transfer budget") }
        print(String(format: "PASS: Mac → Android %d-byte PNG in %.2f seconds (exact SHA-256 match)", screenshotPNG.count, elapsed))

    }
}
