import Foundation
import Darwin

/// Continuously drain diagnostics so a noisy child cannot block on a full pipe.
final class ProcessDiagnostics: @unchecked Sendable {
    private let pipe = Pipe()
    private let lock = NSLock()
    private var bytes = Data()

    func attach(to process: Process, captureOutput: Bool = false) {
        process.standardError = pipe
        if captureOutput { process.standardOutput = pipe }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] _ in self?.drain() }
    }

    // A stream-ended notification can arrive before the readability callback.
    // Drain nonblocking here too, so the final phone-use marker is never lost.
    private func drain() {
        lock.lock(); defer { lock.unlock() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                bytes.append(contentsOf: buffer.prefix(count))
                if bytes.count > 8192 { bytes.removeFirst(bytes.count - 8192) }
            } else if count < 0 && errno == EINTR {
                continue
            } else { break }
        }
    }
    func reset() { drain(); lock.lock(); bytes.removeAll(); lock.unlock() }
    func snapshot() -> String {
        drain()
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
    func finish() -> String {
        pipe.fileHandleForReading.readabilityHandler = nil
        return snapshot()
    }

}

enum ToolLocator {
    static func find(_ name: String) -> String? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path,
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum ToolProcessEnvironment {
    static func clean(_ inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited
        environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        environment.removeValue(forKey: "DROIDMIRROR_HOST_PID")
        return environment
    }
}

enum ProcessRunner {
    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var retainedProcess: Process?

        func retain(_ process: Process) {
            lock.lock()
            retainedProcess = process
            lock.unlock()
        }

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            completed = true
            retainedProcess = nil
            return true
        }
    }

    static func output(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        input: Data? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let gate = CompletionGate()
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("DroidMirror-command-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
                continuation.resume(throwing: RunnerError.failed("Could not create command output file"))
                return
            }
            process.environment = ToolProcessEnvironment.clean()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let inputPipe = input == nil ? nil : Pipe()
            if let inputPipe { process.standardInput = inputPipe }
            else { process.standardInput = FileHandle.nullDevice }
            process.standardOutput = outputHandle
            process.standardError = outputHandle
            gate.retain(process)
            process.terminationHandler = { process in
                guard gate.claim() else { return }
                try? outputHandle.close()
                let data = (try? Data(contentsOf: outputURL)) ?? Data()
                try? FileManager.default.removeItem(at: outputURL)
                let text = String(decoding: data, as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: RunnerError.failed(text.nilIfEmpty ?? "Command failed"))
                }
            }
            do {
                try process.run()
                if let input, let inputPipe {
                    try inputPipe.fileHandleForWriting.write(contentsOf: input)
                    try inputPipe.fileHandleForWriting.close()
                }
            } catch {
                try? inputPipe?.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                if gate.claim() {
                    try? outputHandle.close()
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: error)
                }
                return
            }
            if let timeout {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    guard gate.claim() else { return }
                    if process.isRunning { process.terminate() }
                    try? outputHandle.close()
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: RunnerError.timedOut)
                }
            }
        }
    }
}

enum RunnerError: LocalizedError {
    case failed(String)
    case timedOut
    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        case .timedOut: "Command timed out"
        }
    }
}
