import AppKit
import CryptoKit
import ImageIO
import CoreServices
import UserNotifications

struct PhoneLibraryApp: Codable, Equatable {
    let component: String
    let label: String
    let version: String
    static func parse(_ value: [String: Any]) -> Self? {
        guard let component = value["component"] as? String, component.count <= 512,
              component.range(of: #"^[A-Za-z0-9_.$]+/[A-Za-z0-9_.$]+$"#, options: .regularExpression) != nil,
              let label = value["label"] as? String, !label.isEmpty, label.count <= 160,
              let version = value["version"] as? String, !version.isEmpty, version.count <= 128 else { return nil }
        return Self(component: component, label: label, version: version)
    }
}

/// User-owned app bundles, metadata first. Artwork never gates Spotlight launchability.
final class PhoneAppLibrary {
    weak var controller: BLEController?
    private let root: URL
    private let cache: URL
    private let launcherSource: URL
    private let hostURL: URL
    private let registerLaunchers: Bool
    private let io = DispatchQueue(label: "app.droidmirror.library-files", qos: .utility)
    private var generation = UUID()
    private var phone = ""
    private var apps = [PhoneLibraryApp]()
    private var busy = false
    private var bulk: LibraryBulkChannel?
    var makeBulkChannel: () -> LibraryBulkChannel = { LibraryIrohChannel() }
    private var nextBulkAttempt = Date.distantPast
    private var catalogChanges = 0
    private var bulkReads = 0
    var prepareReveal: (String) -> Void = ShortcutReveal.prepare
    var finishReveal: (String, Int64?) -> Void = ShortcutReveal.finish
    private var revealToken: String?
    private var launchStarted: Date?
    private var launchStatus = "idle"
    static func shouldUseBulk(changes: Int) -> Bool { changes >= 12 }
    var diagnostics: String {
        if controller?.authenticated != true { return "Waiting for authenticated phone" }
        if controller?.supportsAppLibrary != true { return "Phone app-library update required" }
        return "apps=\(apps.count) transport=\(bulk?.ready == true ? "iroh" : "ble") busy=\(busy) irohReads=\(bulkReads) launch=\(launchStatus)"
    }
    private var nextScan = Date.distantPast
    private var pushedSnapshot: String?
    private var catalogPushSerial = 0
    private var scanPushSerial = 0
    private func nextCatalogScan() -> Date {
        guard pushedSnapshot != nil else { return Date().addingTimeInterval(15) }
        return catalogPushSerial == scanPushSerial ? .distantFuture : .distantPast
    }
    func catalogChanged(_ event: [String: Any]) {
        guard controller?.authenticated == true, controller?.supportsChangePush == true,
              event["success"] as? Bool == true, let revision = event["snapshot"] as? String,
              revision.count == 64 else { return }
        if pushedSnapshot != revision { catalogPushSerial += 1 }
        pushedSnapshot = revision
        nextScan = revision == catalogSnapshot && !repairOnConnect ? .distantFuture : .distantPast
        tick()
    }
    private var catalogSnapshot: String?
    private var repairOnConnect = true
    private var nextIcon = Date.distantPast
    private var attempted = Set<String>()
    private var retries = [String: Date]()
    private var pending: (component: String, phone: String, deadline: Date)?
    private var mirrorSeen = Date.distantPast
    private var mirrorPID: Int32?
    private var mirrorHeartbeat = Date.distantPast
    private var observers = [NSObjectProtocol]()
    private var stopped = false
    private struct Stored: Codable { let phone: String; let apps: [PhoneLibraryApp]; let snapshot: String? }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Droidmirror"),
         cache: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/app.droidmirror.mac/AppLibrary"),
         launcherSource: URL? = nil, hostURL: URL? = nil, registerLaunchers: Bool = true) {
        self.root = root; self.cache = cache; self.registerLaunchers = registerLaunchers
        self.launcherSource = launcherSource ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("PhoneAppLauncher")
        self.hostURL = hostURL ?? Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let bytes = try? Data(contentsOf: cache.appendingPathComponent("catalog.json")),
           let stored = try? JSONDecoder().decode(Stored.self, from: bytes) {
            phone = stored.phone
            catalogSnapshot = stored.snapshot
            apps = stored.apps.filter { PhoneLibraryApp.parse(["component": $0.component, "label": $0.label, "version": $0.version]) != nil }
        }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("app.droidmirror.mirrorVisible"), object: nil, queue: .main) { [weak self] event in
            guard let value = event.object as? String, let pid = Int32(value), NotificationRuntime.isHost(pid: pid) else { return }
            self?.mirrorVisible(pid: pid)
        })
        observers.append(center.addObserver(forName: Notification.Name("app.droidmirror.sessionState"), object: nil, queue: .main) { [weak self] event in
            guard let pid = event.userInfo?["pid"] as? Int, let valid = Int32(exactly: pid), NotificationRuntime.isHost(pid: valid) else { return }
            self?.sessionState(pid: valid, active: event.userInfo?["active"] as? Bool == true)
        })
    }
    func sessionState(pid: Int32, active: Bool) {
        guard NotificationRuntime.isHost(pid: pid) else { return }
        mirrorPID = pid
        mirrorHeartbeat = active ? Date() : .distantPast
        if !active { mirrorSeen = .distantPast }
    }
    func mirrorVisible(pid: Int32) {
        guard NotificationRuntime.isHost(pid: pid) else { return }
        mirrorPID = pid; mirrorSeen = Date(); tick()
    }
    private var hasActiveMirror: Bool {
        Date().timeIntervalSince(mirrorHeartbeat) < 3 && mirrorPID.map { NotificationRuntime.isHost(pid: $0) } == true
    }
    private func requestMirror() {
        // The renderer focuses itself through its PID-addressed notification.
        // Avoid synchronous LaunchServices activation of the exec-based host.
        if !hasActiveMirror { NotificationRuntime.requestMirror(activate: false) }
        if let mirrorPID {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("app.droidmirror.focusMirror"),
                object: String(mirrorPID), userInfo: nil, deliverImmediately: true)
        }
    }
    func stop() {
        if let revealToken { finishReveal(revealToken, nil); self.revealToken = nil }
        stopped = true; disconnected(); pending = nil
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }; observers.removeAll()
    }
    func connected() {
        generation = UUID(); busy = false; attempted.removeAll(); repairOnConnect = true; nextScan = .distantPast
        pushedSnapshot = nil
        if controller?.supportsChangePush == true {
            controller?.request(["type": "appCatalogSubscribe"], expecting: "appCatalogChanged", timeout: 12) { [weak self] outcome in
                if case .response(let event) = outcome { self?.catalogChanged(event) }
            }
        }
        tick()
    }
    func disconnected() { pushedSnapshot = nil; generation = UUID(); busy = false; mirrorSeen = .distantPast; mirrorHeartbeat = .distantPast; bulk?.close(); bulk = nil; nextBulkAttempt = .distantPast }
    func open(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "droidmirror-app", parts.host == "launch",
              let identity = parts.queryItems?.first(where: { $0.name == "phone" })?.value,
              identity == BLETrust.identity,
              let component = parts.queryItems?.first(where: { $0.name == "component" })?.value,
              phone == identity, apps.contains(where: { $0.component == component }) else {
            report("This app shortcut belongs to a different phone or is no longer available. Connect your paired phone to refresh the app library.")
            return
        }
        let token = UUID().uuidString
        revealToken = token; prepareReveal(token)
        launchStarted = Date(); recordLaunch("waiting for mirror")
        pending = (component, identity, Date().addingTimeInterval(60))
        let warm = mirrorSeen != .distantPast && hasActiveMirror
        mirrorSeen = warm ? Date() : .distantPast
        // One connection/focus request per click; waiting must not restart a
        // disconnected session or steal focus from another Mac application.
        requestMirror()
        if !warm { controller?.requestEndpoint(); controller?.connectADB() }
        tick()
    }
    func tick(now: Date = Date()) {
        guard !stopped else { return }
        if let launch = pending {
            if Date() >= launch.deadline || BLETrust.identity != launch.phone {
                if let revealToken { finishReveal(revealToken, nil); self.revealToken = nil }
                pending = nil; report("Couldn’t open the phone app. Connect and unlock your phone, then try again.")
            } else if controller?.authenticated == true, controller?.supportsAppLibrary != true {
                if let revealToken { finishReveal(revealToken, nil); self.revealToken = nil }
                pending = nil; report("Update DroidMirror on your phone to open apps from Spotlight.")
            } else if controller?.authenticated == true, controller?.supportsAppLibrary == true,
                      mirrorSeen.timeIntervalSinceNow > -3 {
                let presentationToken = revealToken
                recordLaunch("sending to phone")
                pending = nil // Side effects are never replayed after timeout/disconnection.
                controller?.request(["type": "appLaunch", "component": launch.component], expecting: "appLaunchResult", timeout: 32) { [weak self] outcome in
                    if let presentationToken {
                        let stamp: Int64?
                        if case .response(let result) = outcome { stamp = (result["displayedAtUs"] as? NSNumber)?.int64Value } else { stamp = nil }
                        self?.finishReveal(presentationToken, stamp)
                    }
                    if self?.revealToken == presentationToken { self?.revealToken = nil }
                    if case .response(let result) = outcome, result["success"] as? Bool == true { self?.recordLaunch("opened"); return }
                    self?.recordLaunch("unconfirmed")
                    self?.report("The phone didn’t confirm opening the app. Unlock your phone and check the mirror before trying again.")
                }
            }
        }
        guard !busy, controller?.authenticated == true, controller?.supportsAppLibrary == true,
              let identity = BLETrust.identity else { return }
        for (key, deadline) in retries where Date() >= deadline { attempted.remove(key); retries.removeValue(forKey: key) }
        if now >= nextScan {
            busy = true; catalogChanges = 0; scanPushSerial = catalogPushSerial
            fetchCatalog(offset: 0, snapshot: phone == identity ? catalogSnapshot : nil, accumulated: [], identity: identity, token: generation)
        } else if pending == nil && Date() >= nextIcon { pumpIcons(identity: identity) }
    }
    private func recordLaunch(_ stage: String) {
        let elapsed = Int(Date().timeIntervalSince(launchStarted ?? Date()) * 1000)
        launchStatus = "\(stage) at \(elapsed)ms"
        NSLog("DroidMirror app launch: %@", launchStatus)
    }
    private func requestRead(_ command: [String: Any], expecting: String, completion: @escaping (BLERequestOutcome) -> Void) {
        guard let bulk, bulk.ready else {
            controller?.request(command, expecting: expecting, timeout: 12, completion: completion); return
        }
        let token = generation
        bulk.request(command) { [weak self] result in
            guard let self, self.generation == token else { return }
            if let result { self.bulkReads += 1; completion(.response(result)) }
            else {
                bulk.close(); self.bulk = nil
                if command["type"] as? String == "appCatalogRequest" {
                    self.controller?.request(command, expecting: expecting, timeout: 12, completion: completion)
                } else { completion(.notQueued) }
            }
        }
    }
    private func maybeUpgrade(changes: Int, resume: @escaping () -> Void) {
        guard Self.shouldUseBulk(changes: changes), controller?.supportsAppLibraryIroh == true,
              bulk == nil, Date() >= nextBulkAttempt, let key = BLETrust.key() else { resume(); return }
        nextBulkAttempt = Date().addingTimeInterval(60)
        let epoch = generation
        let capability = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        controller?.request(["type": "appLibraryOffer", "token": capability], expecting: "appLibraryOfferResult", timeout: 5) { [weak self] outcome in
            guard let self, self.generation == epoch else { return }
            guard case .response(let response) = outcome, response["success"] as? Bool == true,
                  let addresses = response["addresses"] as? [String], !addresses.isEmpty, addresses.count <= 32 else { resume(); return }
            let channel = self.makeBulkChannel(); self.bulk = channel
            channel.connect(key: key, token: capability, addresses: addresses) { [weak self] success in
                guard let self, self.generation == epoch else { channel.close(); return }
                if !success { channel.close(); self.bulk = nil }
                NSLog("DroidMirror app library: Iroh upgrade %@", success ? "ready" : "unavailable; using BLE")
                resume()
            }
        }
    }
    private func considerArtworkUpgrade() {
        guard bulk == nil, controller?.supportsAppLibraryIroh == true, Date() >= nextBulkAttempt else { tick(); return }
        let current = apps, identity = phone, epoch = generation
        busy = true
        io.async { [self] in
            let missing = current.filter { !FileManager.default.fileExists(atPath: iconURL($0, identity: identity, size: 256).path) }.count
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == epoch else { return }
                self.maybeUpgrade(changes: missing) { [weak self] in self?.busy = false; self?.tick() }
            }
        }
    }
    private func fetchCatalog(offset: Int, snapshot: String?, accumulated: [PhoneLibraryApp], identity: String, token: UUID) {
        var command: [String: Any] = ["type": "appCatalogRequest", "offset": offset]
        if let snapshot { command["snapshot"] = snapshot }
        requestRead(command, expecting: "appCatalogResult") { [weak self] outcome in
            guard let self, self.generation == token, BLETrust.identity == identity else { return }
            if case .response(let response) = outcome, offset == 0, snapshot != nil,
               response["success"] as? Bool == true, response["unchanged"] as? Bool == true,
               response["snapshot"] as? String == snapshot {
                if self.repairOnConnect { self.publish(self.apps, identity: identity, complete: true); self.repairOnConnect = false }
                self.busy = false; self.nextScan = self.nextCatalogScan(); self.considerArtworkUpgrade(); return
            }
            guard case .response(let response) = outcome, response["success"] as? Bool == true,
                  response["offset"] as? Int == offset,
                  let revision = response["snapshot"] as? String, revision.count == 64,
                  offset == 0 || snapshot == revision,
                  let total = response["total"] as? Int, (0...4096).contains(total),
                  let raw = response["apps"] as? [[String: Any]], raw.count <= 8 else { self.catalogFailed(); return }
            let page = raw.compactMap(PhoneLibraryApp.parse)
            let all = accumulated + page
            guard page.count == raw.count, all.count <= total, Set(all.map(\.component)).count == all.count,
                  !page.isEmpty || all.count == total else { self.catalogFailed(); return }
            // Publish each page immediately; remove stale apps only after a complete snapshot.
            if offset == 0 { self.catalogChanges = self.phone != identity || self.apps.isEmpty ? total : max(0, self.apps.count - total) }
            self.catalogChanges += page.filter { app in !self.apps.contains(app) }.count
            self.publish(page, identity: identity, complete: false)
            if all.count < total {
                self.maybeUpgrade(changes: self.catalogChanges) { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.fetchCatalog(offset: all.count, snapshot: revision, accumulated: all, identity: identity, token: token)
                }
            } else {
                self.catalogSnapshot = revision; self.repairOnConnect = false
                self.publish(all, identity: identity, complete: true)
                self.busy = false; self.nextScan = self.nextCatalogScan()
                self.considerArtworkUpgrade()
            }
        }
    }
    private func catalogFailed() { busy = false; nextScan = Date().addingTimeInterval(15) }
    private func publish(_ incoming: [PhoneLibraryApp], identity: String, complete: Bool) {
        if phone != identity { apps = []; phone = identity; attempted.removeAll() }
        if complete { apps = incoming }
        else { for app in incoming { apps.removeAll { $0.component == app.component }; apps.append(app) } }
        let current = apps
        let revision = catalogSnapshot
        io.async { [self] in
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                for app in incoming { try writeLauncher(app, identity: identity) }
                if complete {
                    let valid = Set(current.map { launcherURL($0, identity: identity).lastPathComponent })
                    // Never remove folders we didn't create, including user-added applications.
                    for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where url.pathExtension == "app" {
                        let plist = url.appendingPathComponent("Contents/Info.plist")
                        if let data = try? Data(contentsOf: plist), let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                           info["DroidMirrorGenerated"] as? Bool == true, info["DroidMirrorAppKey"] as? String != nil, !valid.contains(url.lastPathComponent) {
                            try FileManager.default.removeItem(at: url)
                        }
                    }
                    try JSONEncoder().encode(Stored(phone: identity, apps: current, snapshot: revision)).write(to: cache.appendingPathComponent("catalog.json"), options: .atomic)
                    try pruneCache(current, identity: identity)
                }
            } catch { NSLog("DroidMirror app library: %@", error.localizedDescription) }
        }
    }
    private func pruneCache(_ current: [PhoneLibraryApp], identity: String) throws {
        let fm = FileManager.default
        let valid = Set(current.flatMap { app in [48, 256].map { iconURL(app, identity: identity, size: $0).lastPathComponent } })
        var retained = [(url: URL, size: Int, modified: Date)]()
        for url in try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) where url.pathExtension == "png" {
            if !valid.contains(url.lastPathComponent) { try fm.removeItem(at: url); continue }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            retained.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        var bytes = retained.reduce(0) { $0 + $1.size }
        // Keep previews preferentially; old high resolution artwork can be fetched again.
        for entry in retained.filter({ $0.url.lastPathComponent.hasSuffix("-256.png") }).sorted(by: { $0.modified < $1.modified }) where bytes > 64 * 1024 * 1024 {
            try fm.removeItem(at: entry.url); bytes -= entry.size
        }
    }
    private func launcherStem(_ app: PhoneLibraryApp) -> String {
        var safe = String(app.label.components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " -_().")).inverted).joined().prefix(100))
        while safe.utf8.count > 180 { safe.removeLast() }
        return safe.isEmpty ? "Android App" : safe
    }
    private func launcherURL(_ app: PhoneLibraryApp, identity: String) -> URL {
        let stem = launcherStem(app)
        let key = Self.digest(identity + ":" + app.component)
        // Keep opaque identities exclusively in metadata. Only actual name
        // collisions receive an ordinary, readable numeric disambiguator.
        var number = 1
        while true {
            let name = number == 1 ? stem : "\(stem) (\(number))"
            let url = root.appendingPathComponent(name + ".app")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            if let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
               let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               info["DroidMirrorGenerated"] as? Bool == true, info["DroidMirrorAppKey"] as? String == key { return url }
            number += 1
        }
    }
    private func iconURL(_ app: PhoneLibraryApp, identity: String, size: Int) -> URL {
        cache.appendingPathComponent(Self.digest(identity + ":" + app.component + ":" + app.version) + "-\(size).png")
    }
    private func writeLauncher(_ app: PhoneLibraryApp, identity: String) throws {
        let fm = FileManager.default
        let bundle = launcherURL(app, identity: identity)
        let key = Self.digest(identity + ":" + app.component)
        let legacy = root.appendingPathComponent("\(launcherStem(app)) · \(key.prefix(8)).app")
        var migrated = false
        if !fm.fileExists(atPath: bundle.path), let data = try? Data(contentsOf: legacy.appendingPathComponent("Contents/Info.plist")),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           info["DroidMirrorGenerated"] as? Bool == true, info["DroidMirrorAppKey"] as? String == key {
            try fm.moveItem(at: legacy, to: bundle); migrated = true
        }
        if fm.fileExists(atPath: bundle.path) {
            guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  info["DroidMirrorAppKey"] as? String == key, info["DroidMirrorGenerated"] as? Bool == true else { return }
        }
        let isNew = !fm.fileExists(atPath: bundle.path)
        let working = isNew ? root.appendingPathComponent(".droidmirror-" + UUID().uuidString + ".app") : bundle
        defer { if isNew { try? fm.removeItem(at: working) } }
        let contents = working.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/PhoneAppLauncher")
        let source = launcherSource
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let resources = contents.appendingPathComponent("Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: executable.path) { try fm.copyItem(at: source, to: executable) }
        var link = URLComponents(); link.scheme = "droidmirror-app"; link.host = "launch"
        link.queryItems = [URLQueryItem(name: "phone", value: identity), URLQueryItem(name: "component", value: app.component)]
        let host = hostURL
        let info: [String: Any] = ["CFBundleIdentifier": "app.droidmirror.phone." + key,
            "CFBundleExecutable": "PhoneAppLauncher", "CFBundleName": app.label, "CFBundleDisplayName": app.label,
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSUIElement": true,
            "CFBundleIconFile": "PhoneApp.icns", "DroidMirrorGenerated": true, "DroidMirrorAppKey": key,
            "DroidMirrorAppVersion": app.version, "DroidMirrorLaunchURL": link.url!.absoluteString, "DroidMirrorHostPath": host.path]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        let target = contents.appendingPathComponent("Info.plist")
        let changed = (try? Data(contentsOf: target)) != plist
        if changed { try plist.write(to: target, options: .atomic) }
        let icon = resources.appendingPathComponent("PhoneApp.icns")
        if changed || !fm.fileExists(atPath: icon.path) {
            let high = iconURL(app, identity: identity, size: 256)
            let low = iconURL(app, identity: identity, size: 48)
            if let data = (try? Data(contentsOf: high)) ?? (try? Data(contentsOf: low)) { try writeIcon(data, to: icon) }
            else {
                let fallback = host.appendingPathComponent("Contents/Resources/DroidMirror.icns")
                if !fm.fileExists(atPath: icon.path), fm.fileExists(atPath: fallback.path) { try fm.copyItem(at: fallback, to: icon) }
            }
        }
        if isNew { try fm.moveItem(at: working, to: bundle) }
        if changed || migrated {
            if registerLaunchers { LSRegisterURL(bundle as CFURL, true) }
            DispatchQueue.main.async { NSWorkspace.shared.noteFileSystemChanged(bundle.path) }
        }
    }
    private func writeIcon(_ data: Data, to url: URL) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width <= 256, image.height <= 256 else { return }
        // Use CoreGraphics on the file queue, without AppKit graphics state.
        guard let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        guard let scaled = context.makeImage() else { return }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        var output = Data("icns".utf8)
        func number(_ value: Int) -> Data { var n = UInt32(value).bigEndian; return withUnsafeBytes(of: &n) { Data($0) } }
        output.append(number(png.count + 16)); output.append(Data("ic08".utf8)); output.append(number(png.count + 8)); output.append(png as Data)
        try output.write(to: url, options: .atomic)
    }
    private func pumpIcons(identity: String) {
        // All missing previews precede high resolution work, even after long offline gaps.
        for size in [48, 256] {
            if let app = apps.first(where: { !attempted.contains(Self.digest(identity + $0.component + $0.version) + ":\(size)") }) {
                let key = Self.digest(identity + app.component + app.version) + ":\(size)"
                attempted.insert(key); busy = true
                let file = iconURL(app, identity: identity, size: size)
                let token = generation
                io.async { [weak self] in
                    let exists = FileManager.default.fileExists(atPath: file.path) ||
                        (size == 48 && FileManager.default.fileExists(atPath: self?.iconURL(app, identity: identity, size: 256).path ?? ""))
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { return }
                        if exists { self.busy = false; self.tick() }
                        else { self.fetchIcon(app, identity: identity, size: size, bytes: Data(), total: nil, hash: nil, token: token) }
                    }
                }
                return
            }
        }
        bulk?.close(); bulk = nil
    }
    private func iconFailed(_ app: PhoneLibraryApp, identity: String, size: Int) {
        busy = false; nextIcon = Date().addingTimeInterval(2)
        retries[Self.digest(identity + app.component + app.version) + ":\(size)"] = Date().addingTimeInterval(60)
    }
    private func fetchIcon(_ app: PhoneLibraryApp, identity: String, size: Int, bytes: Data, total: Int?, hash: String?, token: UUID) {
        let fast = bulk?.ready == true
        requestRead(["type": "appIconRequest", "component": app.component, "version": app.version,
            "size": size, "offset": bytes.count], expecting: "appIconResult") { [weak self] outcome in
            guard let self, self.generation == token, BLETrust.identity == identity else { return }
            if fast, self.bulk?.ready != true {
                self.fetchIcon(app, identity: identity, size: size, bytes: Data(), total: nil, hash: nil, token: token); return
            }
            let limit = fast ? 32768 : 768
            guard case .response(let result) = outcome, result["success"] as? Bool == true,
                  result["component"] as? String == app.component, result["version"] as? String == app.version,
                  result["size"] as? Int == size, result["offset"] as? Int == bytes.count,
                  let count = result["total"] as? Int, (1...262144).contains(count), total == nil || total == count,
                  let digest = result["hash"] as? String, digest.count == 64, hash == nil || hash == digest,
                  let encoded = result["data"] as? String, encoded.count <= (limit + 2) / 3 * 4,
                  let chunk = Data(base64Encoded: encoded), !chunk.isEmpty, chunk.count <= limit,
                  bytes.count + chunk.count <= count, chunk.count == limit || bytes.count + chunk.count == count else {
                self.iconFailed(app, identity: identity, size: size)
                return
            }
            var joined = bytes; joined.append(chunk)
            if joined.count < count {
                // One in-flight chunk, a short yield between chunks; controls outrank artwork on the phone.
                DispatchQueue.main.asyncAfter(deadline: .now() + (fast ? 0.002 : 0.04)) { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.fetchIcon(app, identity: identity, size: size, bytes: joined, total: count, hash: digest, token: token)
                }
            } else {
                guard SHA256.hash(data: joined).map({ String(format: "%02x", $0) }).joined() == digest,
                      let source = CGImageSourceCreateWithData(joined as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      properties[kCGImagePropertyPixelWidth] as? Int == size,
                      properties[kCGImagePropertyPixelHeight] as? Int == size else { self.iconFailed(app, identity: identity, size: size); return }
                let file = self.iconURL(app, identity: identity, size: size)
                self.io.async { [self] in
                    do {
                        try FileManager.default.createDirectory(at: self.cache, withIntermediateDirectories: true)
                        try joined.write(to: file, options: .atomic)
                        let bundle = self.launcherURL(app, identity: identity)
                        try self.writeIcon(joined, to: bundle.appendingPathComponent("Contents/Resources/PhoneApp.icns"))
                        DispatchQueue.main.async { NSWorkspace.shared.noteFileSystemChanged(bundle.path) }
                    } catch { NSLog("DroidMirror app icon: %@", error.localizedDescription) }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.busy = false; self.nextIcon = Date().addingTimeInterval(0.1)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.tick() }
                    }
                }
            }
        }
    }
    var report: (String) -> Void = { message in
        let content = UNMutableNotificationContent(); content.title = "DroidMirror apps"; content.body = message
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "DroidMirror.appLaunch", content: content, trigger: nil))
    }
}
