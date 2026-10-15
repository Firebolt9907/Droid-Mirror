import Foundation

@MainActor
final class ClassicBluetoothTransport {
    private var process: Process?
    private var outputHandle: FileHandle?
    private var outputURL: URL?
    private var generation = UUID()
    private var monitor: Task<Void, Never>?
    private var consumedLines = 0
    var onEvent: ((Event) -> Void)?
    enum Event: String {
        case phoneOn = "PHONE_ON", sessionEnded = "SESSION_ENDED", phoneLocalUse = "PHONE_LOCAL_USE"
        case streamStarted = "STREAM_STARTED", captureFailed = "CAPTURE_FAILED"
    }
    private func pollEvents() {
        guard let outputURL, let data = try? Data(contentsOf: outputURL), data.count <= 16_384 else { return }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let completed = max(0, lines.count - 1)
        if completed > consumedLines {
            for line in lines[consumedLines..<completed] {
                if line.hasPrefix("EVENT "), let event = Event(rawValue: String(line.dropFirst(6))) { onEvent?(event) }
            }
            consumedLines = completed
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
    }

    func connect(address: String) async throws -> Ports {
        stop()
        guard let helper = Self.helperPath else { throw RunnerError.failed("Bluetooth helper missing. Rebuild DroidMirror with build-app.sh.") }
        let token = generation
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DroidMirror-Bluetooth-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: helper)
        child.arguments = [address]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = handle
        child.standardError = handle
        outputURL = url; outputHandle = handle; process = child; consumedLines = 0
        do {
            try child.run()
            for _ in 0..<200 {
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
                        throw RunnerError.failed("Privileged capture unavailable. Authorize Shizuku and enable Mac connections once on Android.")
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
        generation = UUID()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        try? outputHandle?.close(); outputHandle = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }
}
