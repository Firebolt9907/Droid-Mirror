import Foundation

/// Experimental transport readiness. No ADB or Bluetooth fallback: a missing NAN
/// data path must never appear to be a successful direct Wi-Fi connection.
enum WiFiAwareTransport {
    struct Readiness: Decodable, Sendable {
        let frameworkPresent: Bool
        let privateFrameworkPresent: Bool
        let capabilitiesAvailable: Bool
        let supportsDataTransfer: Bool
        let maxDatapaths: Int
        let streamImplemented: Bool
        let message: String
    }

    static func probe() async throws -> Readiness {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DroidMirrorWiFiAware")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw RunnerError.failed("Wi-Fi Aware helper missing. Rebuild DroidMirror with build-app.sh.")
        }
        let output = try await ProcessRunner.output(helper.path, ["--probe"], timeout: 8)
        return try JSONDecoder().decode(Readiness.self, from: Data(output.utf8))
    }
}
