import Combine
import CoreBluetooth
import Foundation
import Darwin

final class BLEController: NSObject, ObservableObject {
    private static let serviceID = CBUUID(string: "7E57B000-9A6B-4C5D-8E7F-102030405060")
    private static let endpointID = CBUUID(string: "7E57B001-9A6B-4C5D-8E7F-102030405060")
    private static let inputServiceID = CBUUID(string: "C356A44E-6F2B-4DA9-85E5-397991B8A610")
    var onEvent: (([String: Any]) -> Void)?
    var onAuthenticated: (() -> Void)?
    var onDisconnected: (() -> Void)?
    private let requests = BLERequests()
    private var outbound = BLEOutboundQueue()
    private var supportsSessionHealth = false
    private var clockSync = ActivityClockSync()
    private var activityTransitMilliseconds: Int?
    private var heartbeatPending = false
    private var writeStartedAt: TimeInterval?
    // ADB is an explicit legacy action, independent of the idle BLE session.
    static let automaticADBKey = "DroidMirror.BLE.automaticADB"
    private var wantsADB = false
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var receivedFrames = 0
    private var assembledMessages = 0
    private var staleFrames = 0
    private var acknowledgedWrites = 0
    var diagnostics: String { "rx=\(receivedFrames) assembled=\(assembledMessages) stale=\(staleFrames) written=\(acknowledgedWrites) queued=\(writes.count) messages=\(outbound.count) requests=\(requests.count) clockRTT=\(clockSync.roundTripMilliseconds.map(String.init) ?? "unknown")ms activityTransit=\(activityTransitMilliseconds.map(String.init) ?? "unknown")ms" }
    private var session: BLESecureSession?
    private var activityDeltas = ActivityDeltaReceiver()
    private var lastActivityResync: TimeInterval = -.infinity
    private var fragments = BLEFragments()
    private var writes = [Data]()
    private var writing = false
    private var messageID: UInt32 = 1
    private var rejectedPeers = [UUID: Date]()
    private(set) var supportsClipboard = false
    private(set) var supportsClipboardFiles = false
    private(set) var supportsWearCompanion = false
    private(set) var supportsChangePush = false
    private(set) var supportsActivityImages = false
    private(set) var supportsMedia = false
    private(set) var supportsTaskURLs = false
    private(set) var supportsAppLibrary = false
    private(set) var supportsAppLibraryIroh = false
    private(set) var supportsHotspot = false
    private(set) var supportsLinkSharing = false
    var authenticated: Bool { session?.authenticated == true }

    @Published var status = "Starting Bluetooth…"
    @Published var tailscaleIP: String {
        didSet { NotificationRuntime.preferences.set(tailscaleIP, forKey: Self.savedIPKey) }
    }
    @Published var port: Int?
    @Published var adbStatus = "Wireless ADB off"
    @Published var adbOutput = ""
    @Published var isADBConnected = false
    @Published var lastEndpointReceived: Date?

    private var central: CBCentralManager!
    private var phone: CBPeripheral?
    private var endpointCharacteristic: CBCharacteristic?
    private var notificationSubscription = BLENotificationSubscription()
    private var serviceCandidates = BLEServiceCandidates<CBService>()
    private var adbTaskRunning = false
    private var connectedEndpoint: String?
    private var healthTimer: DispatchSourceTimer?
    private var endpointTimer: DispatchSourceTimer?
    private var pendingADBConnect = false
    private var bleAttemptStartedAt: Date?
    private var lastEndpointResponseAt: Date?
    private var pendingRequestID: UInt64?
    private var pendingRequestStartedAt: Date?
    private var nextRequestID: UInt64 = 1
    private static let savedIPKey = "DroidMirror.BLE.host"
    private var presenceRadio: PresenceBeaconAdvertiser?
    private var stopped = false

    override init() {
        tailscaleIP = NotificationRuntime.preferences.string(forKey: Self.savedIPKey)
            ?? UserDefaults(suiteName: "dev.bleadb.bridge.macos")?.string(forKey: "tailscaleIP") ?? ""
        wantsADB = NotificationRuntime.preferences.bool(forKey: Self.automaticADBKey)
        if wantsADB { adbStatus = "Waiting for Android endpoint…" }
        super.init()
        if !tailscaleIP.isEmpty { NotificationRuntime.preferences.set(tailscaleIP, forKey: Self.savedIPKey) }
        presenceRadio = PresenceBeaconAdvertiser()
        central = CBCentralManager(delegate: self, queue: nil)
        startHealthMonitor()
        startEndpointMonitor()
    }

    deinit {
        presenceRadio?.stop()
        healthTimer?.cancel()
        endpointTimer?.cancel()
    }

    func scan() {
        guard !stopped else { return }
        guard let key = BLETrust.key() else { status = "Choose DroidMirror → Pair Bluetooth… to pair mirroring and notifications"; return }
        guard central.state == .poweredOn else {
            status = "Bluetooth is not ready"
            return
        }
        guard phone == nil else { return }
        // Mirroring may already own the physical BLE link. Such a phone need
        // not advertise again, so scanning alone can wait forever.
        let candidates = central.retrieveConnectedPeripherals(withServices: [Self.serviceID])
            + central.retrieveConnectedPeripherals(withServices: [Self.inputServiceID])
        let remembered = BLEDiscovery.remembered(key: key)
        for peripheral in candidates {
            guard peripheral.identifier == remembered else { continue }
            if let until = rejectedPeers[peripheral.identifier], until > Date() { continue }
            connect(peripheral)
            return
        }
        guard !central.isScanning else { return }
        status = "Scanning for Android…"
        central.scanForPeripherals(withServices: [CBUUID(nsuuid: BLEDiscovery.uuid(key: key))])
    }

    private func connect(_ peripheral: CBPeripheral) {
        central.stopScan()
        serviceCandidates.reset()
        phone = peripheral
        bleAttemptStartedAt = Date()
        lastEndpointResponseAt = nil
        pendingRequestID = nil
        pendingRequestStartedAt = nil
        peripheral.delegate = self
        status = "Connecting to Android…"
        central.connect(peripheral)
    }

    func requestEndpoint() {
        guard !stopped else { return }
        guard let phone,
              phone.state == .connected,
              endpointCharacteristic != nil,
              pendingRequestID == nil, authenticated
        else { return }
        let requestID = nextRequestID
        nextRequestID &+= 1
        pendingRequestID = requestID
        pendingRequestStartedAt = Date()
        send(["type": "get", "request": requestID])
    }

    func configureADB() {
        tailscaleIP = NotificationRuntime.preferences.string(forKey: Self.savedIPKey) ?? ""
        wantsADB = NotificationRuntime.preferences.bool(forKey: Self.automaticADBKey)
        if wantsADB { requestEndpoint(); connectADB(force: true) }
        else { pendingADBConnect = false; adbStatus = "Wireless ADB off" }
    }

    func connectADB(force: Bool = false) {
        guard !stopped else { return }
        wantsADB = true
        guard let port, !tailscaleIP.trimmingCharacters(in: .whitespaces).isEmpty else {
            adbStatus = port == nil ? "Waiting for Android endpoint…" : "Enter the fixed Tailscale IP"
            return
        }
        let endpoint = "\(tailscaleIP.trimmingCharacters(in: .whitespaces)):\(port)"
        guard !adbTaskRunning else {
            pendingADBConnect = true
            return
        }
        if !force, isADBConnected, connectedEndpoint == endpoint { return }
        guard let adb = Self.findADB() else {
            adbStatus = "adb not found"
            adbOutput = "Install Android platform-tools or place adb in PATH."
            return
        }
        adbTaskRunning = true
        pendingADBConnect = false
        isADBConnected = false
        adbStatus = "Connecting ADB to \(endpoint)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = adb
            task.arguments = ["connect", endpoint]
            do {
                let text = try Self.runBounded(task, timeout: 10)
                DispatchQueue.main.async {
                    guard !self.stopped else { return }
                    self.adbTaskRunning = false
                    guard self.wantsADB else { return }
                    self.adbOutput = text
                    let lower = text.lowercased()
                    let connected = task.terminationStatus == 0 &&
                        (lower.contains("connected to ") || lower.contains("already connected to "))
                    self.isADBConnected = connected
                    self.connectedEndpoint = connected ? endpoint : nil
                    self.adbStatus = connected ? "Connected to \(endpoint)" : "Unable to connect"
                    self.reportADBState(connected)
                    if self.pendingADBConnect || self.desiredEndpoint() != endpoint {
                        self.pendingADBConnect = false
                        self.connectADB(force: true)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard !self.stopped else { return }
                    self.adbTaskRunning = false
                    guard self.wantsADB else { return }
                    self.isADBConnected = false
                    self.connectedEndpoint = nil
                    self.adbOutput = error.localizedDescription
                    self.adbStatus = "Could not launch adb"
                    self.reportADBState(false)
                    if self.pendingADBConnect {
                        self.pendingADBConnect = false
                        self.connectADB(force: true)
                    }
                }
            }
        }
    }

    static func findADB() -> URL? {
        var candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/adb").path,
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSString(string: "~/Library/Android/sdk/platform-tools/adb").expandingTildeInPath
        ]
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        candidates.append(contentsOf: pathEntries.map { "\($0)/adb" })
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    private func startHealthMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10, repeating: 20, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.pollADBState() }
        timer.resume()
        healthTimer = timer
    }

    private func startEndpointMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 10, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.maintainBLESession() }
        timer.resume()
        endpointTimer = timer
    }

    private func maintainBLESession() {
        guard !stopped else { return }
        requests.expire(now: uptime)
        guard let phone else {
            scan()
            return
        }

        if let started = writeStartedAt, uptime - started > 15 {
            rebuildBLESession(phone)
            return
        }

        if let started = pendingRequestStartedAt,
           Date().timeIntervalSince(started) > 12 {
            if authenticated, let last = lastEndpointResponseAt, Date().timeIntervalSince(last) <= 25 {
                // An endpoint reply can also sit behind notification fragments.
                // Retry discovery without discarding a healthy authenticated session.
                pendingRequestID = nil
                pendingRequestStartedAt = nil
            } else {
                rebuildBLESession(phone)
                return
            }
        }

        let reference = lastEndpointResponseAt ?? bleAttemptStartedAt ?? Date()
        if Date().timeIntervalSince(reference) > 25 {
            // A connected input peripheral can expose stale/missing discovery
            // services. Give advertisements and other candidates a chance.
            if !authenticated { rejectedPeers[phone.identifier] = Date().addingTimeInterval(30) }
            rebuildBLESession(phone)
            return
        }

        if wantsADB && !supportsChangePush { requestEndpoint() }
        if authenticated && supportsSessionHealth {
            guard !heartbeatPending else { return }
            heartbeatPending = true
            request(["type": "ping"], expecting: "pong", timeout: 12) { [weak self] _ in
                guard let self else { return }
                self.heartbeatPending = false
                // A large authenticated notification can take longer than a ping deadline.
                // The existing 25-second authenticated-traffic watchdog decides whether
                // the link is stale; a delayed pong alone must not disable every activity.
            }
        } else {
            // Older companions answer endpoint requests even without an ADB endpoint.
            requestEndpoint()
        }
    }

    private func rebuildBLESession(_ peripheral: CBPeripheral) {
        // A reconnect otherwise selects the same stale cached service forever.
        // Each candidate gets a fresh handshake, queues and sequence counters.
        if !stopped, phone === peripheral, serviceCandidates.current != nil,
           tryNextService(peripheral) { return }
        status = "Refreshing Bluetooth connection…"
        serviceCandidates.reset()
        endpointCharacteristic = nil
        phone = nil
        bleAttemptStartedAt = nil
        lastEndpointResponseAt = nil
        pendingRequestID = nil
        pendingRequestStartedAt = nil
        resetSecurity()
        central.cancelPeripheralConnection(peripheral)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.scan()
        }
    }

    @discardableResult
    private func tryNextService(_ peripheral: CBPeripheral) -> Bool {
        let previous = endpointCharacteristic
        endpointCharacteristic = nil
        pendingRequestID = nil; pendingRequestStartedAt = nil
        lastEndpointResponseAt = nil
        resetSecurity()
        if let previous, previous.isNotifying { peripheral.setNotifyValue(false, for: previous) }
        guard let service = serviceCandidates.next() else { return false }
        bleAttemptStartedAt = Date()
        status = "Discovering notification characteristic…"
        peripheral.discoverCharacteristics([Self.endpointID], for: service)
        return true
    }

    private func desiredEndpoint() -> String? {
        guard let port else { return nil }
        let ip = tailscaleIP.trimmingCharacters(in: .whitespaces)
        return ip.isEmpty ? nil : "\(ip):\(port)"
    }

    private func pollADBState() {
        guard !stopped, wantsADB, isADBConnected,
              !adbTaskRunning,
              let endpoint = connectedEndpoint,
              let adb = Self.findADB()
        else { return }

        let task = Process()
        task.executableURL = adb
        task.arguments = ["-s", endpoint, "get-state"]
        adbTaskRunning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output = (try? Self.runBounded(task, timeout: 5)) ?? "ADB check failed"
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.adbTaskRunning = false
                guard self.wantsADB else { return }
                if self.pendingADBConnect {
                    self.pendingADBConnect = false
                    self.connectADB(force: true)
                    return
                }
                guard output != "device" else { return }
                self.isADBConnected = false
                self.connectedEndpoint = nil
                self.adbStatus = "Phone offline — waiting for Android"
                self.adbOutput = output
                self.reportADBState(false)
                self.connectADB(force: true)
            }
        }

    }

    // File-backed output avoids inheriting a pipe in the persistent ADB server.
    // Deadlines also cover unreachable Tailscale endpoints without blocking UI.
    static func runBounded(_ task: Process, timeout: TimeInterval, input: Data? = nil) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        task.standardOutput = handle
        task.standardError = handle
        let pipe = input == nil ? nil : Pipe()
        if let pipe { task.standardInput = pipe }
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        try task.run()
        if let pipe, let input { try pipe.fileHandleForWriting.write(contentsOf: input); try pipe.fileHandleForWriting.close() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut && task.isRunning {
                kill(task.processIdentifier, SIGKILL)
            }
            return "ADB connection timed out"
        }
        return String(data: (try? Data(contentsOf: url)) ?? Data(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func stop() {
        presenceRadio?.stop(); presenceRadio = nil
        stopped = true
        resetSecurity()
        healthTimer?.cancel()
        endpointTimer?.cancel()
        reportADBState(false)
        central.stopScan()
        if let phone { central.cancelPeripheralConnection(phone) }
        phone = nil
        endpointCharacteristic = nil
        serviceCandidates.reset()
    }

    private func accept(_ data: Data) {
        guard !stopped else { return }
        do {
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let object else { adbStatus = "Invalid Android endpoint response"; return }
            // Ignore delayed replies from a previous request, but accept pushed updates.
            if let request = object["request"] as? UInt64,
               let pendingRequestID, request != pendingRequestID { return }
            let receivedAt = Date()
            lastEndpointResponseAt = receivedAt
            lastEndpointReceived = receivedAt
            pendingRequestID = nil
            pendingRequestStartedAt = nil
            if let error = object["error"] as? String {
                port = nil
                isADBConnected = false
                connectedEndpoint = nil
                if wantsADB { adbStatus = "Android: \(error)" }
                return
            }
            guard let newPort = object["port"] as? Int, (1...65_535).contains(newPort) else {
                adbStatus = "Android sent an invalid endpoint response"
                return
            }
            let changed = port != nil && port != newPort
            port = newPort
            if changed {
                isADBConnected = false
                connectedEndpoint = nil
            }
            // Tailscale addresses are stable. Learn it once, then preserve the
            // user's saved value instead of replacing it on every BLE response.
            if tailscaleIP.isEmpty, let ip = object["ip"] as? String { tailscaleIP = ip }
            if wantsADB { connectADB(force: changed) }
        } catch {
            adbStatus = "Could not decode Android endpoint response"
        }
    }

    private func reportADBState(_ connected: Bool) {
        send(["type": "state", "connected": connected])
    }

    private func resetSecurity() {
        let hadSession = session != nil
        supportsChangePush = false; supportsWearCompanion = false; supportsLinkSharing = false; supportsMedia = false; supportsClipboard = false
        supportsClipboardFiles = false; supportsTaskURLs = false; supportsAppLibrary = false; supportsAppLibraryIroh = false; supportsHotspot = false
        supportsActivityImages = false
        supportsSessionHealth = false; heartbeatPending = false
        clockSync = ActivityClockSync(); activityTransitMilliseconds = nil
        activityDeltas = ActivityDeltaReceiver(); lastActivityResync = -.infinity
        session = nil; fragments = BLEFragments(); writes.removeAll(); outbound.reset()
        writing = false; writeStartedAt = nil
        requests.reset()
        if hadSession { onDisconnected?() }
    }

    /// True means accepted into the bounded queue, not performed on the phone.
    @discardableResult func send(_ object: [String: Any]) -> Bool {
        enqueue(object, deadline: uptime + 60)
    }
    private func enqueue(_ object: [String: Any], deadline: TimeInterval) -> Bool {
        guard !stopped, authenticated, endpointCharacteristic != nil,
              outbound.append(object, deadline: deadline) else { return false }
        drain()
        return true
    }

    /// Change-only state is connection-scoped; action tickets still have short deadlines.
    @discardableResult func sendCompanion(_ object: [String: Any]) -> Bool {
        let state = object["type"] as? String == "watchMacState" && object["changeOnly"] as? Bool == true
        return enqueue(object, deadline: uptime + (state ? 60 : 5))
    }

    /// Replies are correlated by UUID and type. No automatic retry of side effects.
    @discardableResult func request(_ object: [String: Any], expecting reply: String,
                                   timeout: TimeInterval = 15, id: String = UUID().uuidString,
                                   completion: @escaping (BLERequestOutcome) -> Void) -> String? {
        guard !stopped, authenticated, timeout.isFinite, timeout > 0 else { completion(.notQueued); return nil }
        let deadline = uptime + timeout
        guard requests.add(id: id, reply: reply, deadline: deadline, completion: completion) else {
            completion(.notQueued); return nil
        }
        var command = object; command["request"] = id
        guard enqueue(command, deadline: deadline) else {
            requests.finish(id, outcome: .notQueued); return nil
        }
        return id
    }
    private func queue(_ value: Data, startWriting: Bool = true) throws {
        guard let phone, endpointCharacteristic != nil else { throw BLECryptoError.invalid }
        // Avoid ATT long/prepared writes: fragments fit a single negotiated PDU.
        let writeType: CBCharacteristicWriteType = authenticated && endpointCharacteristic?.properties.contains(.writeWithoutResponse) == true ? .withoutResponse : .withResponse
        let maximum = min(phone.maximumWriteValueLength(for: writeType), phone.maximumWriteValueLength(for: .withoutResponse))
        let frames = BLEFragments.split(value, id: messageID, maximum: maximum)
        guard !frames.isEmpty, writes.reduce(0, { $0 + $1.count }) + frames.reduce(0, { $0 + $1.count }) <= 262144 else { throw BLECryptoError.invalid }
        messageID &+= 1; writes.append(contentsOf: frames)
        if startWriting { drain() }
    }
    private func drain() {
        guard !writing, let phone, let endpointCharacteristic else { return }
        // Stream authenticated messages while Core Bluetooth has buffer space.
        // Old companions and the authentication handshake retain ATT responses.
        let streaming = authenticated && endpointCharacteristic.properties.contains(.writeWithoutResponse)
        repeat {
            if writes.isEmpty {
                if streaming && !phone.canSendWriteWithoutResponse {
                    if writeStartedAt == nil { writeStartedAt = uptime }
                    return
                }
                guard authenticated, let session, let message = outbound.next(now: uptime) else { return }
                if message.object["type"] as? String == "ping", let id = message.object["request"] as? String {
                    clockSync.begin(id, now: ActivityClock.now)
                }
                do { try queue(session.seal(message.object), startWriting: false) }
                catch { rebuildBLESession(phone); return }
            }
            if streaming {
                guard phone.canSendWriteWithoutResponse else {
                    if writeStartedAt == nil { writeStartedAt = uptime }
                    return
                }
                phone.writeValue(writes.removeFirst(), for: endpointCharacteristic, type: .withoutResponse)
                writeStartedAt = nil
            } else {
                writing = true
                writeStartedAt = uptime
                phone.writeValue(writes.removeFirst(), for: endpointCharacteristic, type: .withResponse)
                return
            }
        } while true
    }

    private func receive(_ value: Data) {
        guard let data = fragments.accept(value) else { return }
        assembledMessages += 1
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let session else { throw BLECryptoError.invalid }
            if object["type"] as? String == "challenge" {
                status = "Verifying phone authentication challenge…"
                try queue(JSONSerialization.data(withJSONObject: session.challenge(object))); return
            }
            var plain = try session.open(object)
            // Local timing metadata is attached only after authentication and overwrites wire input.
            plain["_activityReceivedAt"] = fragments.lastMessageStartedAt ?? ActivityClock.now
            lastEndpointResponseAt = Date()
            let first = fragments.lastMessageStartedAt ?? ActivityClock.now
            plain.removeValue(forKey: "_activitySourceAt")
            if plain["type"] as? String == "pong", clockSync.accept(plain, receivedAt: first) {
                for refreshed in activityDeltas.reanchor(using: clockSync) { onEvent?(refreshed) }
            }
            if let stamp = plain["clockSentElapsedMs"] as? NSNumber,
               let source = clockSync.localTime(phoneMilliseconds: stamp.doubleValue) {
                // An offset estimate can be ahead by its uncertainty; never anchor in the future.
                plain["_activitySourceAt"] = min(first, source)
                if plain["type"] as? String != "pong" { activityTransitMilliseconds = Int(max(0, first-source) * 1000) }
            }
            guard let reconstructed = activityDeltas.receive(plain) else {
                if activityDeltas.needsSnapshot && uptime - lastActivityResync >= 10 {
                    lastActivityResync = uptime
                    send(["type": "subscribe", "activityDeltas": 1])
                }
                return
            }
            plain = reconstructed
            requests.receive(plain, now: uptime)
            switch plain["type"] as? String {
            case "ready":
                if let phone, let key = BLETrust.key() { BLEDiscovery.remember(phone.identifier, key: key) }
                supportsActivityImages = plain["activityImages"] as? Int == 1
                supportsSessionHealth = plain["sessionHealth"] as? Int == 1
                supportsClipboard = plain["clipboard"] as? Int == 1
                supportsClipboardFiles = plain["clipboardFiles"] as? Int == 1
                supportsChangePush = plain["changePush"] as? Int == 1
                supportsWearCompanion = plain["watchCompanion"] as? Int == 1
                supportsMedia = plain["media"] as? Int == 1
                supportsTaskURLs = plain["taskUrls"] as? Int == 1
                supportsAppLibrary = plain["appLibrary"] as? Int == 1
                supportsAppLibraryIroh = plain["appLibraryIroh"] as? Int == 1
                supportsHotspot = (plain["hotspot"] as? Int ?? 0) >= 2
                supportsLinkSharing = plain["linkSharing"] as? Int == 1
                status = "Authenticated phone connected"
                if wantsADB || !supportsSessionHealth { requestEndpoint() }
                if supportsSessionHealth { request(["type": "ping"], expecting: "pong", timeout: 12) { _ in } }
                send(["type": "subscribe", "activityDeltas": 1]); onAuthenticated?()
            case "pong", "activityImageManifest", "activityImageChunk", "appCatalogResult", "appIconResult", "appLaunchResult", "appLibraryOfferResult": break
            case "appCatalogChanged", "haptic", "watchTicketRequest", "watchPhoneBattery", "watchFindMac", "shareLink", "openLinkResult", "mediaState", "mediaCommand", "mediaArtworkRequest", "mediaArtworkChunk", "mediaStatus", "notification", "activitiesReset", "removed", "actionResult", "dismissResult", "minimizeMirror", "clipboard", "clipboardStatus", "clipboardResult", "clipboardFileBegin", "clipboardFileChunk", "clipboardFileAck", "clipboardFileCancel", "taskContinuation", "hotspotResult": onEvent?(plain)
            default: accept(try JSONSerialization.data(withJSONObject: plain))
            }
        } catch {
            NSLog("DroidMirror BLE response rejected: %@", error.localizedDescription)
            status = "BLE authentication failed"
            if let phone { rejectedPeers[phone.identifier] = Date().addingTimeInterval(60); rebuildBLESession(phone) }
        }
    }
}

extension BLEController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !stopped else { return }
        if central.state != .poweredOn {
            serviceCandidates.reset()
            phone = nil; endpointCharacteristic = nil
            bleAttemptStartedAt = nil; lastEndpointResponseAt = nil
            pendingRequestID = nil; pendingRequestStartedAt = nil
            resetSecurity()
        }
        switch central.state {
        case .poweredOn:
            status = "Bluetooth ready"
            scan()
        case .poweredOff: status = "Turn Bluetooth on"
        case .unauthorized: status = "Allow Bluetooth in System Settings"
        case .unsupported: status = "Bluetooth LE is unsupported"
        default: status = "Bluetooth unavailable"
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard !stopped, phone == nil, let key = BLETrust.key() else { return }
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .compactMap { UUID(uuidString: $0.uuidString) }
        guard BLEDiscovery.permits(peripheral.identifier, remembered: BLEDiscovery.remembered(key: key),
                                   advertised: advertised, discovery: BLEDiscovery.uuid(key: key)) else { return }
        if let until = rejectedPeers[peripheral.identifier], until > Date() { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard phone?.identifier == peripheral.identifier else { return }
        status = "Discovering service…"
        peripheral.discoverServices([Self.serviceID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard phone?.identifier == peripheral.identifier else { return }
        serviceCandidates.reset()
        resetSecurity()
        status = error?.localizedDescription ?? "Connection failed"
        if phone?.identifier == peripheral.identifier { phone = nil }
        endpointCharacteristic = nil
        bleAttemptStartedAt = nil
        lastEndpointResponseAt = nil
        pendingRequestID = nil
        pendingRequestStartedAt = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scan() }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard phone?.identifier == peripheral.identifier else { return }
        serviceCandidates.reset()
        phone = nil
        endpointCharacteristic = nil
        bleAttemptStartedAt = nil
        lastEndpointResponseAt = nil
        pendingRequestID = nil
        pendingRequestStartedAt = nil
        status = "Looking for Android over BLE…"
        resetSecurity()
        scan()
    }
}

extension BLEController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard !stopped, phone?.identifier == peripheral.identifier,
              invalidatedServices.contains(where: { $0.uuid == Self.serviceID }) else { return }
        // Companion updates/restarts replace GATT handles while the input
        // connection can remain alive. Never keep writing to stale handles.
        status = "Rediscovering Bluetooth services…"
        endpointCharacteristic = nil
        pendingRequestID = nil
        pendingRequestStartedAt = nil
        lastEndpointResponseAt = nil
        bleAttemptStartedAt = Date()
        resetSecurity()
        serviceCandidates.reset()
        peripheral.discoverServices([Self.serviceID])
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard phone?.identifier == peripheral.identifier, !stopped else { return }
        let services = peripheral.services?.filter { $0.uuid == Self.serviceID } ?? []
        guard error == nil, !services.isEmpty
        else {
            status = error?.localizedDescription ?? "BLE service was not found"
            rejectedPeers[peripheral.identifier] = Date().addingTimeInterval(30)
            rebuildBLESession(peripheral)
            return
        }
        serviceCandidates.reset(services)
        tryNextService(peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard phone?.identifier == peripheral.identifier, !stopped,
              service === serviceCandidates.current else { return }
        guard error == nil,
              let item = service.characteristics?.first(where: { $0.uuid == Self.endpointID })
        else {
            status = error?.localizedDescription ?? "Endpoint characteristic was not found"
            rejectedPeers[peripheral.identifier] = Date().addingTimeInterval(30)
            rebuildBLESession(peripheral)
            return
        }
        endpointCharacteristic = item
        status = "Enabling phone notification updates…"
        // A surviving physical link can retain Core Bluetooth's subscription
        // cache after Android replaces its GATT server. Clear it before enabling
        // again so the new server receives an actual descriptor write.
        let action = notificationSubscription.begin(alreadyNotifying: item.isNotifying)
        peripheral.setNotifyValue(action == .enable, for: item)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard phone?.identifier == peripheral.identifier, !stopped else { return }
        writeStartedAt = nil
        drain()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard phone?.identifier == peripheral.identifier, characteristic === endpointCharacteristic, !stopped else { return }
        if let error {
            NSLog("DroidMirror BLE write failed: %@", error.localizedDescription)
            status = error.localizedDescription
            rebuildBLESession(peripheral)
            return
        }
        acknowledgedWrites += 1
        if !authenticated { status = "Waiting for phone authentication response…" }
        writing = false; writeStartedAt = nil; drain()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard phone?.identifier == peripheral.identifier, characteristic === endpointCharacteristic, !stopped else { return }
        if let error { status = error.localizedDescription; rebuildBLESession(peripheral); return }
        let action = notificationSubscription.updated(notifying: characteristic.isNotifying)
        if action == .enable {
            peripheral.setNotifyValue(true, for: characteristic)
            return
        }
        guard action == .authenticate else { return }
        do {
            resetSecurity()
            status = "Authenticating notification connection…"
            guard let key = BLETrust.key() else { throw BLECryptoError.invalid }
            session = try BLESecureSession(key: key, nonce: BLETrust.random())
            try queue(JSONSerialization.data(withJSONObject: session!.hello))
        } catch { rebuildBLESession(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        receivedFrames += 1
        guard phone?.identifier == peripheral.identifier, characteristic === endpointCharacteristic, !stopped else { staleFrames += 1; return }
        if let error {
            status = error.localizedDescription
            return
        }
        if let value = characteristic.value { receive(value) }
    }
}
