import Foundation

@MainActor
final class ClassicBluetoothTransport {
    private var process: Process?
    private var outputHandle: FileHandle?
    private var outputURL: URL?
    private var generation = UUID()
    private var monitor: Task<Void, Never>?
    private var consumedLines = 0
    private var commands: FileHandle?
    private var upgradeTask: Task<Void, Never>?
    private var wirelessActive = false
    private var forwards: [String: String] = [:]
    var onEvent: ((Event) -> Void)?
    enum Event: String {
        case phoneOn = "PHONE_ON", sessionEnded = "SESSION_ENDED", phoneLocalUse = "PHONE_LOCAL_USE"
        case streamStarted = "STREAM_STARTED", captureFailed = "CAPTURE_FAILED"
        case wirelessActive = "WIFI_ACTIVE", bluetoothActive = "BLUETOOTH_ACTIVE"
    }
    private func pollEvents() {
        guard let outputURL, let data = try? Data(contentsOf: outputURL), data.count <= 16_384 else { return }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let completed = max(0, lines.count - 1)
        if completed > consumedLines {
            for line in lines[consumedLines..<completed] {
                if line.hasPrefix("EVENT "), let event = Event(rawValue: String(line.dropFirst(6))) {
                    if event == .streamStarted { attemptWirelessUpgrade() }
                    if event == .wirelessActive { wirelessActive = true; upgradeTask?.cancel(); upgradeTask=nil }
                    if event == .bluetoothActive { wirelessActive=false; attemptWirelessUpgrade() }
                    onEvent?(event)
                }
            }
            consumedLines = completed
        }
    }

    private func attemptWirelessUpgrade() {
        guard upgradeTask == nil, let adb = ToolLocator.find("adb") else { return }
        let token = generation
        upgradeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                guard let self, token == self.generation, !self.wirelessActive, self.process?.isRunning == true else { return }
                // ADB auto-connects previously paired wireless-debugging services.
                // Never use USB or a model-name match to select an upgrade target.
                let devices = (try? await ProcessRunner.output(adb, ["devices"], timeout: 3)) ?? ""
                guard token == self.generation, !Task.isCancelled else { return }
                // ADB discards forwards when a wireless device disconnects. Drop
                // stale ports so the next connection can allocate a working one.
                if let listing = try? await ProcessRunner.output(adb, ["forward", "--list"], timeout: 3) {
                    guard token == self.generation, !Task.isCancelled else { return }
                    let active = Set(listing.split(separator: "\n").map {
                        $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    })
                    self.forwards = self.forwards.filter { serial, port in
                        active.contains("\(serial) tcp:\(port) localabstract:droidmirror_video_upgrade")
                    }
                }
                for line in devices.split(separator: "\n") {
                    let fields = line.split(whereSeparator: { $0.isWhitespace })
                    guard fields.count >= 2, fields[1] == "device" else { continue }
                    let serial = String(fields[0])
                    guard serial.contains(":") || serial.hasSuffix("._adb-tls-connect._tcp") else { continue }
                    var port = self.forwards[serial]
                    if port == nil, self.forwards.count < 32 {
                        port = try? await ProcessRunner.output(adb, ["-s", serial, "forward", "tcp:0", "localabstract:droidmirror_video_upgrade"], timeout: 3)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if let port, UInt16(port) != nil {
                            if token != self.generation || Task.isCancelled {
                                _ = try? await ProcessRunner.output(adb, ["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 3)
                                return
                            }
                            self.forwards[serial] = port
                        }
                    }
                    guard token == self.generation, !Task.isCancelled, !self.wirelessActive, self.process?.isRunning == true else { return }
                    if let port, let value = UInt16(port), value > 0 {
                        try? self.commands?.write(contentsOf: Data("UPGRADE \(value)\n".utf8))
                        try? await Task.sleep(for: .seconds(3))
                    }
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
    private func monitorEvents() {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.pollEvents()
                if self.process?.isRunning != true { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    static var helperPath: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DroidMirrorBluetooth")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }

    var diagnostic: String {
        guard let outputURL, let data = try? Data(contentsOf: outputURL), data.count <= 16_384 else { return "" }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(4).joined(separator: "\n")
    }
    static func pairedDevices() async throws -> [AndroidDevice] {
        guard let helperPath else { throw RunnerError.failed("Bluetooth helper missing. Rebuild DroidMirror with build-app.sh.") }
        let text = try await ProcessRunner.output(helperPath, ["--list"], timeout: 5)
        struct Peer: Decodable { let address: String; let name: String }
        return try JSONDecoder().decode([Peer].self, from: Data(text.utf8)).map {
            AndroidDevice(id: $0.address, state: "device", model: $0.name, product: "", transport: "bluetooth-classic")
        }
    }

    struct Ports { let video: UInt16; let control: UInt16 }

    static func pair(address: String, code: String) async throws {
        guard let key = Data(base64Encoded: code.trimmingCharacters(in: .whitespacesAndNewlines)), key.count == 32 else {
            throw RunnerError.failed("Paste the full BLE pairing code shown in the Android companion.")
        }
        guard let helper = helperPath else { throw RunnerError.failed("Bluetooth helper missing. Rebuild DroidMirror.") }
        _ = try await ProcessRunner.output(helper, ["--pair", address], timeout: 60, input: key)
        UserDefaults.standard.set(true, forKey: "DroidMirror.BLE.enabled")
        UserDefaults.standard.synchronize()
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.droidmirror.receiverConfiguration"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    func connect(address: String, wirelessMaxSize: Int = 1920, wirelessFPS: Int = 60, wirelessBitRate: Int = 12_000_000) async throws -> Ports {
        stop()
        guard let helper = Self.helperPath else { throw RunnerError.failed("Bluetooth helper missing. Rebuild DroidMirror with build-app.sh.") }
        let token = generation
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DroidMirror-Bluetooth-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: helper)
        child.arguments = [address]
        var environment = ToolProcessEnvironment.clean()
        environment["DROIDMIRROR_WIFI_MAX_SIZE"] = String(wirelessMaxSize)
        environment["DROIDMIRROR_WIFI_FPS"] = String(wirelessFPS)
        environment["DROIDMIRROR_WIFI_BIT_RATE"] = String(wirelessBitRate)
        child.environment = environment
        let input = Pipe()
        child.standardInput = input
        commands = input.fileHandleForWriting
        wirelessActive = false
        child.standardOutput = handle
        child.standardError = handle
        outputURL = url; outputHandle = handle; process = child; consumedLines = 0
        do {
            try child.run()
            // Baseband, L2CAP and BLE each have a bounded startup phase.
            for _ in 0..<500 {
                guard token == generation else { throw CancellationError() }
                let data = (try? Data(contentsOf: url)) ?? Data()
                guard data.count <= 16_384 else { throw RunnerError.failed("Bluetooth helper returned too much output") }
                let text = String(decoding: data, as: UTF8.self)
                if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("READY ") }),
                   child.isRunning {
                    let fields = line.split(separator: " ")
                    guard fields.count == 3, let video = UInt16(fields[1]), let control = UInt16(fields[2]),
                          video != 0, control != 0 else { throw RunnerError.failed("Bluetooth input helper requires an updated app.") }
                    monitorEvents(); return Ports(video: video, control: control)
                }
                if !child.isRunning {
                    if text.contains("EVENT CAPTURE_FAILED") {
                        throw RunnerError.failed("HEVC capture unavailable. Authorize Shizuku, enable Mac connections, and check this phone's HEVC encoder support.")
                    }
                    throw RunnerError.failed(text.nilIfEmpty ?? "Bluetooth connection failed")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw RunnerError.failed("Bluetooth connection timed out. Enable Mac connections once in Android setup and keep Shizuku running.")
        } catch {
            if token == generation { stop() }
            throw error
        }
    }

    func stop() {
        pollEvents()
        monitor?.cancel(); monitor = nil
        upgradeTask?.cancel(); upgradeTask = nil
        try? commands?.close(); commands = nil
        let oldForwards = forwards; forwards.removeAll()
        if !oldForwards.isEmpty, let adb = ToolLocator.find("adb") {
            Task {
                for (serial, port) in oldForwards {
                    _ = try? await ProcessRunner.output(adb, ["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 3)
                }
            }
        }
        generation = UUID()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        try? outputHandle?.close(); outputHandle = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }
}
