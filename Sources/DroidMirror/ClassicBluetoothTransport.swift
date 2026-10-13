import Foundation

@MainActor
final class ClassicBluetoothTransport {
    private var process: Process?
    private var outputHandle: FileHandle?
    private var outputURL: URL?
    private var generation = UUID()

    static var helperPath: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DroidMirrorBluetooth")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }

    static func pairedDevices() async throws -> [AndroidDevice] {
        guard let helperPath else { throw RunnerError.failed("Bluetooth helper missing. Rebuild DroidMirror with build-app.sh.") }
        let text = try await ProcessRunner.output(helperPath, ["--list"], timeout: 5)
        struct Peer: Decodable { let address: String; let name: String }
        return try JSONDecoder().decode([Peer].self, from: Data(text.utf8)).map {
            AndroidDevice(id: $0.address, state: "device", model: $0.name, product: "", transport: "bluetooth-classic")
        }
    }

    func connect(address: String) async throws -> UInt16 {
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
        outputURL = url; outputHandle = handle; process = child
        do {
            try child.run()
            for _ in 0..<200 {
                guard token == generation else { throw CancellationError() }
                let data = (try? Data(contentsOf: url)) ?? Data()
                guard data.count <= 16_384 else { throw RunnerError.failed("Bluetooth helper returned too much output") }
                let text = String(decoding: data, as: UTF8.self)
                if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("READY ") }),
                   let port = UInt16(line.dropFirst(6)), port != 0, child.isRunning { return port }
                if !child.isRunning { throw RunnerError.failed(text.nilIfEmpty ?? "Bluetooth connection failed") }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw RunnerError.failed("Bluetooth connection timed out. Start capture on Android and select the paired Mac there.")
        } catch {
            if token == generation { stop() }
            throw error
        }
    }

    func stop() {
        generation = UUID()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        try? outputHandle?.close(); outputHandle = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
    }
}
