import AppKit
import Darwin

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
        defer {
            configure(false); pause(1)
            _ = try? exchange("restore")
            try? input.fileHandleForWriting.close()
            // Restore only if the clipboard still belongs to the test; preserve concurrent user copies.
            if board.string(forType: .string)?.hasPrefix(prefix) == true {
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
    }
}
