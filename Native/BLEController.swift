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
    private var session: BLESecureSession?
    private var fragments = BLEFragments()
    private var writes = [Data]()
    private var writing = false
    private var messageID: UInt32 = 1
    private var rejectedPeers = [UUID: Date]()
    var authenticated: Bool { session?.authenticated == true }

    @Published var status = "Starting Bluetooth…"
    @Published var tailscaleIP: String {
        didSet { NotificationRuntime.preferences.set(tailscaleIP, forKey: Self.savedIPKey) }
    }
    @Published var port: Int?
    @Published var adbOutput = ""
    @Published var isADBConnected = false
    @Published var lastEndpointReceived: Date?

    private var central: CBCentralManager!
    private var phone: CBPeripheral?
    private var endpointCharacteristic: CBCharacteristic?
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
    private var stopped = false

    override init() {
        tailscaleIP = NotificationRuntime.preferences.string(forKey: Self.savedIPKey)
            ?? UserDefaults(suiteName: "dev.bleadb.bridge.macos")?.string(forKey: "tailscaleIP") ?? ""
        super.init()
        if !tailscaleIP.isEmpty { NotificationRuntime.preferences.set(tailscaleIP, forKey: Self.savedIPKey) }
        central = CBCentralManager(delegate: self, queue: nil)
        startHealthMonitor()
        startEndpointMonitor()
    }

    deinit {
        healthTimer?.cancel()
        endpointTimer?.cancel()
    }

    func scan() {
        guard !stopped else { return }
        guard BLETrust.key() != nil else { status = "Choose DroidMirror → Pair Bluetooth… to pair mirroring and notifications"; return }
        guard central.state == .poweredOn else {
            status = "Bluetooth is not ready"
            return
        }
        guard phone == nil else { return }
        // Mirroring may already own the physical BLE link. Such a phone need
        // not advertise again, so scanning alone can wait forever.
        let candidates = central.retrieveConnectedPeripherals(withServices: [Self.serviceID])
            + central.retrieveConnectedPeripherals(withServices: [Self.inputServiceID])
        for peripheral in candidates {
            if let until = rejectedPeers[peripheral.identifier], until > Date() { continue }
            connect(peripheral)
            return
        }
        guard !central.isScanning else { return }
        status = "Scanning for Android…"
        central.scanForPeripherals(withServices: [Self.serviceID])
    }

    private func connect(_ peripheral: CBPeripheral) {
        central.stopScan()
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

    func connectADB(force: Bool = false) {
        guard !stopped else { return }
        guard let port, !tailscaleIP.trimmingCharacters(in: .whitespaces).isEmpty else {
            status = port == nil ? "Waiting for Android endpoint…" : "Enter the fixed Tailscale IP"
            return
        }
        let endpoint = "\(tailscaleIP.trimmingCharacters(in: .whitespaces)):\(port)"
        guard !adbTaskRunning else {
            pendingADBConnect = true
            return
        }
        if !force, isADBConnected, connectedEndpoint == endpoint { return }
        guard let adb = Self.findADB() else {
            status = "adb not found"
            adbOutput = "Install Android platform-tools or place adb in PATH."
            return
        }
        adbTaskRunning = true
        pendingADBConnect = false
        isADBConnected = false
        status = "Connecting ADB to \(endpoint)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = adb
            task.arguments = ["connect", endpoint]
            do {
                let text = try Self.runBounded(task, timeout: 10)
                DispatchQueue.main.async {
                    guard !self.stopped else { return }
                    self.adbOutput = text
                    self.adbTaskRunning = false
                    let lower = text.lowercased()
                    let connected = task.terminationStatus == 0 &&
                        (lower.contains("connected to ") || lower.contains("already connected to "))
                    self.isADBConnected = connected
                    self.connectedEndpoint = connected ? endpoint : nil
                    self.status = connected ? "Connected to \(endpoint)" : "Unable to connect"
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
                    self.isADBConnected = false
                    self.connectedEndpoint = nil
                    self.adbOutput = error.localizedDescription
                    self.status = "Could not launch adb"
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
        guard let phone else {
            scan()
            return
        }

        if let started = pendingRequestStartedAt,
           Date().timeIntervalSince(started) > 12 {
            rebuildBLESession(phone)
            return
        }

        let reference = lastEndpointResponseAt ?? bleAttemptStartedAt ?? Date()
        if Date().timeIntervalSince(reference) > 25 {
            // A connected input peripheral can expose stale/missing discovery
            // services. Give advertisements and other candidates a chance.
            if !authenticated { rejectedPeers[phone.identifier] = Date().addingTimeInterval(30) }
            rebuildBLESession(phone)
            return
        }

        requestEndpoint()
    }

    private func rebuildBLESession(_ peripheral: CBPeripheral) {
        resetSecurity()
        status = "Refreshing Bluetooth connection…"
        endpointCharacteristic = nil
        phone = nil
        bleAttemptStartedAt = nil
        lastEndpointResponseAt = nil
        pendingRequestID = nil
        pendingRequestStartedAt = nil
        central.cancelPeripheralConnection(peripheral)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.scan()
        }
    }

    private func desiredEndpoint() -> String? {
        guard let port else { return nil }
        let ip = tailscaleIP.trimmingCharacters(in: .whitespaces)
        return ip.isEmpty ? nil : "\(ip):\(port)"
    }

    private func pollADBState() {
        guard !stopped, isADBConnected,
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
                if self.pendingADBConnect {
                    self.pendingADBConnect = false
                    self.connectADB(force: true)
                    return
                }
                guard output != "device" else { return }
                self.isADBConnected = false
                self.connectedEndpoint = nil
                self.status = "Phone offline — waiting for Android"
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
        stopped = true
        healthTimer?.cancel()
        endpointTimer?.cancel()
        reportADBState(false)
        central.stopScan()
        if let phone { central.cancelPeripheralConnection(phone) }
        phone = nil
        endpointCharacteristic = nil
    }

    private func accept(_ data: Data) {
        guard !stopped else { return }
        do {
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let object else { status = "Invalid Android response"; return }
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
                status = "Android: \(error)"
                return
            }
            guard let newPort = object["port"] as? Int, (1...65_535).contains(newPort) else {
                status = "Android sent an invalid response"
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
            status = "Endpoint available"
            connectADB(force: changed)
        } catch {
            status = "Could not decode Android response"
        }
    }

    private func reportADBState(_ connected: Bool) {
        send(["type": "state", "connected": connected])
    }

    private func resetSecurity() { session = nil; fragments = BLEFragments(); writes.removeAll(); writing = false }
    @discardableResult func send(_ object: [String: Any]) -> Bool {
        guard authenticated, let session else { return false }
        do { try queue(session.seal(object)); return true }
        catch { if let phone { rebuildBLESession(phone) }; return false }
    }
    private func queue(_ value: Data) throws {
        guard let phone, endpointCharacteristic != nil else { throw BLECryptoError.invalid }
        // Avoid ATT long/prepared writes: fragments fit a single negotiated PDU.
        let maximum = min(phone.maximumWriteValueLength(for: .withResponse), phone.maximumWriteValueLength(for: .withoutResponse))
        let frames = BLEFragments.split(value, id: messageID, maximum: maximum)
        guard !frames.isEmpty, writes.reduce(0, { $0 + $1.count }) + frames.reduce(0, { $0 + $1.count }) <= 262144 else { throw BLECryptoError.invalid }
        messageID &+= 1; writes.append(contentsOf: frames); drain()
    }
    private func drain() {
        guard !writing, !writes.isEmpty, let phone, let endpointCharacteristic else { return }
        writing = true
        phone.writeValue(writes.removeFirst(), for: endpointCharacteristic, type: .withResponse)
    }
    private func receive(_ value: Data) {
        guard let data = fragments.accept(value) else { return }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let session else { throw BLECryptoError.invalid }
            if object["type"] as? String == "challenge" {
                try queue(JSONSerialization.data(withJSONObject: session.challenge(object))); return
            }
            let plain = try session.open(object)
            lastEndpointResponseAt = Date()
            switch plain["type"] as? String {
            case "ready":
                status = "Authenticated phone connected"
                requestEndpoint(); send(["type": "subscribe"]); onAuthenticated?()
            case "notification", "removed", "actionResult", "minimizeMirror": onEvent?(plain)
            default: accept(try JSONSerialization.data(withJSONObject: plain))
            }
        } catch {
            status = "BLE authentication failed"
            if let phone { rejectedPeers[phone.identifier] = Date().addingTimeInterval(60); rebuildBLESession(phone) }
        }
    }
}

extension BLEController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
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
        guard phone == nil else { return }
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
        resetSecurity()
        phone = nil
        endpointCharacteristic = nil
        bleAttemptStartedAt = nil
        lastEndpointResponseAt = nil
        pendingRequestID = nil
        pendingRequestStartedAt = nil
        if !isADBConnected { status = "Looking for Android over BLE…" }
        scan()
    }
}

extension BLEController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard phone?.identifier == peripheral.identifier,
              invalidatedServices.contains(where: { $0.uuid == Self.serviceID }) else { return }
        // Companion updates/restarts replace GATT handles while the input
        // connection can remain alive. Never keep writing to stale handles.
        resetSecurity()
        endpointCharacteristic = nil
        pendingRequestID = nil
        pendingRequestStartedAt = nil
        lastEndpointResponseAt = nil
        bleAttemptStartedAt = Date()
        peripheral.discoverServices([Self.serviceID])
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard phone?.identifier == peripheral.identifier, !stopped else { return }
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID })
        else {
            status = error?.localizedDescription ?? "BLE service was not found"
            rejectedPeers[peripheral.identifier] = Date().addingTimeInterval(30)
            rebuildBLESession(peripheral)
            return
        }
        status = "Discovering notification characteristic…"
        peripheral.discoverCharacteristics([Self.endpointID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard phone?.identifier == peripheral.identifier, !stopped else { return }
        guard error == nil,
              let item = service.characteristics?.first(where: { $0.uuid == Self.endpointID })
        else {
            status = error?.localizedDescription ?? "Endpoint characteristic was not found"
            rejectedPeers[peripheral.identifier] = Date().addingTimeInterval(30)
            rebuildBLESession(peripheral)
            return
        }
        endpointCharacteristic = item
        peripheral.setNotifyValue(true, for: item)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard phone?.identifier == peripheral.identifier, characteristic === endpointCharacteristic, !stopped else { return }
        if let error {
            status = error.localizedDescription
            rebuildBLESession(peripheral)
            return
        }
        writing = false; drain()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard phone?.identifier == peripheral.identifier, characteristic === endpointCharacteristic, !stopped else { return }
        if let error { status = error.localizedDescription; rebuildBLESession(peripheral); return }
        guard characteristic.isNotifying else { rebuildBLESession(peripheral); return }
        do {
            guard let key = BLETrust.key() else { throw BLECryptoError.invalid }
            session = try BLESecureSession(key: key, nonce: BLETrust.random())
            try queue(JSONSerialization.data(withJSONObject: session!.hello))
        } catch { rebuildBLESession(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard phone?.identifier == peripheral.identifier, characteristic === endpointCharacteristic, !stopped else { return }
        if let error {
            status = error.localizedDescription
            return
        }
        if let value = characteristic.value { receive(value) }
    }
}
