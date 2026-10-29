import AppKit
import CryptoKit

// Protocol harness exercises real pagination, filesystem publication and launch gating.
enum BLERequestOutcome { case response([String: Any]), notQueued, timedOut, disconnected }
enum BLETrust { static var keyValue: Data?; static func key() -> Data? { keyValue }; static var identity: String? = "test-phone" }
enum NotificationRuntime {
    static var starts = 0
    static let preferences = UserDefaults.standard
    static func post(_ name: String) {}
    static func isHost(pid: Int32) -> Bool { pid == 123 }
    static func requestMirror(activate: Bool = true) { starts += 1 }
}
final class BLEController {
    var supportsChangePush = false
    var authenticated = true
    var supportsAppLibrary = true
    var supportsAppLibraryIroh = false
    var handle: (([String: Any], @escaping (BLERequestOutcome) -> Void) -> Void)!
    func requestEndpoint() {}
    func connectADB() {}
    @discardableResult func request(_ command: [String: Any], expecting: String, timeout: TimeInterval,
                                   completion: @escaping (BLERequestOutcome) -> Void) -> String? {
        handle(command, completion); return "request"
    }
}
final class FakeLibraryBulk: LibraryBulkChannel {
    var ready = false
    var succeeds = true
    var closed = false
    var commands = [String]()
    var reply: (([String: Any]) -> [String: Any]?)!
    func connect(key: Data, token: String, addresses: [String], completion: @escaping (Bool) -> Void) {
        precondition(key.count == 32 && token.count == 64)
        ready = succeeds; completion(succeeds)
    }
    func request(_ command: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        commands.append(command["type"] as! String)
        let result = reply(command)
        if result == nil { ready = false }
        completion(result)
    }
    func close() { ready = false; closed = true }
}
@main enum PhoneLibraryTests {
    static func wait(_ label: String = "wait", _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(6)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(condition(), "Timed out: \(label)")
    }
    static func main() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("phone-library-tests-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let root = work.appendingPathComponent("Apps")
        let cache = work.appendingPathComponent("Cache")
        let executable = work.appendingPathComponent("launcher")
        try Data("test-launcher".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let label = String(repeating: "地", count: 100) + "/ Maps"
        let app: [String: Any] = ["component": "com.example.one/com.example.one.Main", "label": label, "version": "1:2"]
        let other: [String: Any] = ["component": "com.example.two/com.example.two.Main", "label": label, "version": "3:4"]
        precondition(PhoneLibraryApp.parse(["component": "../../etc", "label": "bad", "version": "1"]) == nil)
        var secondPage: ((BLERequestOutcome) -> Void)?
        var launches = 0
        var iconSizes = [Int]()
        func png(_ size: Int) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let pixels = rep.bitmapData!
            for y in 0..<size { for x in 0..<size {
                let at = y * rep.bytesPerRow + x * 4
                pixels[at] = UInt8(x % 48 * 5); pixels[at + 1] = UInt8(y % 48 * 5)
                pixels[at + 2] = 100; pixels[at + 3] = 255
            } }
            return rep.representation(using: .png, properties: [:])!
        }
        let images = [48: png(48), 256: png(256)]
        let controller = BLEController()
        controller.handle = { command, reply in
            switch command["type"] as? String {
            case "appCatalogRequest":
                if command["offset"] as? Int == 0 {
                    reply(.response(["success": true, "snapshot": String(repeating: "a", count: 64), "offset": 0, "total": 2, "apps": [app]]))
                } else { secondPage = reply }
            case "appLaunch": launches += 1; reply(.timedOut)
            case "appIconRequest":
                let size = command["size"] as! Int
                let offset = command["offset"] as! Int
                if offset == 0 { iconSizes.append(size) }
                let bytes = images[size]!
                reply(.response(["success": true, "component": command["component"]!, "version": command["version"]!,
                    "size": size, "offset": offset, "total": bytes.count,
                    "hash": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                    "data": bytes.subdata(in: offset..<min(offset + 768, bytes.count)).base64EncodedString()]))
            default: reply(.response(["success": false]))
            }
        }
        let library = PhoneAppLibrary(root: root, cache: cache, launcherSource: executable, hostURL: work, registerLaunchers: false)
        var reveals = [String](), releasedReveals = [String]()
        library.prepareReveal = { reveals.append($0) }
        library.finishReveal = { token, _ in releasedReveals.append(token) }
        library.report = { _ in }
        library.controller = controller
        library.connected()
        func bundles() -> [URL] { (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }) ?? [] }
        wait("one bundle") { bundles().count == 1 }
        precondition(!fm.fileExists(atPath: cache.appendingPathComponent("catalog.json").path), "Incomplete catalog must not remove stale apps")
        precondition(secondPage != nil)
        secondPage?(.response(["success": true, "snapshot": String(repeating: "a", count: 64), "offset": 1, "total": 2, "apps": [other]]))
        wait("complete catalog") { bundles().count == 2 && fm.fileExists(atPath: cache.appendingPathComponent("catalog.json").path) }
        wait("progressive artwork") {
            library.tick()
            return ((try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "png" }.count == 4
        }
        precondition(iconSizes == [48, 48, 256, 256], "Every preview must precede high resolution artwork")
        precondition(bundles().allSatisfy { $0.lastPathComponent.utf8.count <= 240 }, "Unicode labels must respect filesystem byte limits")
        precondition(bundles().allSatisfy { !$0.lastPathComponent.contains(" · ") }, "Opaque IDs must not appear in filenames")
        precondition(bundles().contains { $0.lastPathComponent.hasSuffix(" (2).app") }, "Duplicate labels need readable names")
        let first = bundles().first!
        let icon = try Data(contentsOf: first.appendingPathComponent("Contents/Resources/PhoneApp.icns"))
        precondition(String(data: icon.prefix(4), encoding: .utf8) == "icns")
        precondition(NSImage(data: icon) != nil, "Generated ICNS must decode")
        let data = try Data(contentsOf: first.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        precondition(info["CFBundleDisplayName"] as? String == label)
        precondition(fm.isExecutableFile(atPath: first.appendingPathComponent("Contents/MacOS/PhoneAppLauncher").path))
        let url = URL(string: info["DroidMirrorLaunchURL"] as! String)!
        controller.authenticated = false
        library.open(url)
        let startsBeforeOpen = NotificationRuntime.starts
        precondition(launches == 0 && startsBeforeOpen == 1,
                     "One shortcut click must request exactly one connection")
        // Cross the old three-second retry interval, including BLE reconnects
        // and inactive host heartbeats while the original action is pending.
        library.sessionState(pid: 123, active: false)
        library.disconnected(); library.connected()
        let retryDeadline = Date().addingTimeInterval(3.2)
        while Date() < retryDeadline {
            library.tick()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(NotificationRuntime.starts == startsBeforeOpen,
                     "Pending shortcuts must never reconnect or refocus automatically")
        controller.authenticated = true
        library.tick()
        precondition(launches == 0, "Authenticated BLE alone must not launch without a visible mirror")
        library.mirrorVisible(pid: 456)
        precondition(launches == 0, "Unknown hosts cannot signal mirror readiness")
        library.mirrorVisible(pid: 123)
        wait("launch") { launches == 1 }
        precondition(releasedReveals == reveals, "A completed or failed command must release its own presentation cover")
        library.sessionState(pid: 123, active: true)
        let startsBeforeWarmClick = NotificationRuntime.starts
        library.open(url)
        precondition(NotificationRuntime.starts == startsBeforeWarmClick, "A live mirror must receive focus only, never a generic reconnect/start request")
        precondition(launches == 2, "A warm verified stream must dispatch without waiting for another visible-frame event")
        library.disconnected(); library.connected(); library.tick()
        precondition(launches == 2, "Unconfirmed launch must never replay")
        library.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        // A complete empty snapshot prunes generated bundles, preserving user-owned apps.
        let custom = root.appendingPathComponent("My App.app")
        try fm.createDirectory(at: custom, withIntermediateDirectories: true)
        let existing = bundles().first { !$0.lastPathComponent.hasSuffix(" (2).app") }!
        let existingInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: existing.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        let appKey = existingInfo["DroidMirrorAppKey"] as! String
        let cleanStem = existing.deletingPathExtension().lastPathComponent
        let legacy = root.appendingPathComponent(cleanStem + " · " + appKey.prefix(8) + ".app")
        try fm.moveItem(at: existing, to: legacy)
        let restored = PhoneAppLibrary(root: root, cache: cache, launcherSource: executable, hostURL: work, registerLaunchers: false)
        var unexpectedArtwork = 0
        controller.handle = { command, reply in
            if command["type"] as? String == "appCatalogRequest" {
                reply(.response(["success": true, "unchanged": true, "snapshot": String(repeating: "a", count: 64)]))
            } else { unexpectedArtwork += 1; reply(.response(["success": false])) }
        }
        restored.report = { _ in }; restored.controller = controller; restored.connected()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3)); restored.tick()
        precondition(unexpectedArtwork == 0, "Reconnect must reuse completed icons")
        wait("legacy name migration") { !fm.fileExists(atPath: legacy.path) && bundles().count == 3 }
        precondition(bundles().allSatisfy { !$0.lastPathComponent.contains(" · ") })
        controller.handle = { command, reply in
            reply(.response(["success": true, "snapshot": String(repeating: "b", count: 64), "offset": 0, "total": 0, "apps": [[String: Any]]()]))
        }
        restored.report = { _ in }; restored.controller = controller; restored.connected()
        wait("cleanup") { bundles().count == 1 }
        precondition(fm.fileExists(atPath: custom.path))
        restored.stop()
        precondition(!PhoneAppLibrary.shouldUseBulk(changes: 11) && PhoneAppLibrary.shouldUseBulk(changes: 12))
        BLETrust.keyValue = Data(repeating: 7, count: 32)
        let many = (0..<16).map { index in ["component": "com.bulk.a\(index)/com.bulk.a\(index).Main", "label": "App \(index)", "version": "1"] }
        let revision = String(repeating: "c", count: 64)
        func page(_ offset: Int) -> [String: Any] {
            ["success": true, "snapshot": revision, "offset": offset, "total": 16, "apps": Array(many.dropFirst(offset).prefix(8))]
        }
        let fast = FakeLibraryBulk()
        var usedBLECatalog = 0, offers = 0, iconFallback = false
        fast.reply = { command in
            if command["type"] as? String == "appCatalogRequest" { return page(command["offset"] as! Int) }
            if command["type"] as? String == "appIconRequest", command["offset"] as? Int == 0 {
                return ["success": true, "component": command["component"]!, "version": command["version"]!,
                    "size": command["size"]!, "offset": 0, "total": 65536, "hash": String(repeating: "f", count: 64),
                    "data": Data(repeating: 1, count: 32768).base64EncodedString()]
            }
            return nil // A mid-icon drop must restart at BLE's different chunk alignment.
        }
        controller.supportsAppLibraryIroh = true
        controller.handle = { command, reply in
            switch command["type"] as? String {
            case "appCatalogRequest": usedBLECatalog += 1; reply(.response(page(command["offset"] as! Int)))
            case "appLibraryOffer": offers += 1; reply(.response(["success": true, "addresses": ["test-hint"]]))
            case "appIconRequest": iconFallback = true; precondition(command["offset"] as? Int == 0); reply(.response(["success": false]))
            default: preconditionFailure("Unexpected command")
            }
        }
        let bulkRoot = work.appendingPathComponent("BulkApps"), bulkCache = work.appendingPathComponent("BulkCache")
        let bulkLibrary = PhoneAppLibrary(root: bulkRoot, cache: bulkCache, launcherSource: executable, hostURL: work, registerLaunchers: false)
        bulkLibrary.makeBulkChannel = { fast }; bulkLibrary.controller = controller
        bulkLibrary.connected()
        wait("bulk fallback") { iconFallback && fm.fileExists(atPath: bulkCache.appendingPathComponent("catalog.json").path) }
        precondition(usedBLECatalog == 1 && offers == 1, "Large catalogs must upgrade after their first BLE page")
        precondition(fast.commands.contains("appCatalogRequest") && fast.commands.contains("appIconRequest") && fast.closed)
        precondition(!fast.commands.contains("appLaunch"), "Side effects must stay on BLE")
        bulkLibrary.stop()
        // Failed dial must continue metadata immediately on BLE.
        let failed = FakeLibraryBulk(); failed.succeeds = false
        let failedRoot = work.appendingPathComponent("FailedApps"), failedCache = work.appendingPathComponent("FailedCache")
        let fallback = PhoneAppLibrary(root: failedRoot, cache: failedCache, launcherSource: executable, hostURL: work, registerLaunchers: false)
        fallback.makeBulkChannel = { failed }; fallback.controller = controller
        let before = usedBLECatalog
        fallback.connected()
        wait("failed dial fallback") { fm.fileExists(atPath: failedCache.appendingPathComponent("catalog.json").path) }
        precondition(usedBLECatalog == before + 2 && failed.closed)
        fallback.stop(); BLETrust.keyValue = nil
        // Change-only catalog subscription: one baseline, then invalidation-driven reads.
        controller.supportsChangePush = true; controller.supportsAppLibraryIroh = false
        var currentRevision = String(repeating: "d", count: 64)
        var catalogs = 0, subscriptions = 0
        controller.handle = { command, reply in
            switch command["type"] as? String {
            case "appCatalogSubscribe":
                subscriptions += 1
                reply(.response(["success": true, "snapshot": currentRevision]))
            case "appCatalogRequest":
                catalogs += 1
                reply(.response(["success": true, "snapshot": currentRevision, "offset": 0, "total": 0, "apps": [[String: Any]]()]))
            default: preconditionFailure("Unexpected idle catalog command")
            }
        }
        let pushedLibrary = PhoneAppLibrary(root: work.appendingPathComponent("PushApps"), cache: work.appendingPathComponent("PushCache"), launcherSource: executable, hostURL: work, registerLaunchers: false)
        pushedLibrary.controller = controller; pushedLibrary.connected()
        precondition(subscriptions == 1 && catalogs == 1)
        for _ in 0..<100 { pushedLibrary.tick(now: Date().addingTimeInterval(3600)) }
        precondition(catalogs == 1, "Unchanged catalogs must not poll")
        currentRevision = String(repeating: "e", count: 64)
        pushedLibrary.catalogChanged(["success": true, "snapshot": currentRevision])
        precondition(catalogs == 2, "A package change must refresh metadata")
        pushedLibrary.catalogChanged(["success": true, "snapshot": currentRevision])
        precondition(catalogs == 2, "Duplicate invalidations must not refetch")
        pushedLibrary.disconnected(); pushedLibrary.connected()
        precondition(subscriptions == 2 && catalogs == 3, "Reconnection must establish a new baseline")
        pushedLibrary.stop()
        print("PASS: bulk threshold, dedicated catalog routing, dropped-channel icon fallback, failed-dial BLE fallback")
        print("PASS: incremental catalog, safe names, duplicate labels, cached launch routing, mirror gating, no replay, progressive chunked artwork, valid ICNS, owned cleanup")
    }
}
