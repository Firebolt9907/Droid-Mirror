import Foundation

@main
struct WiFiAwareReadinessTests {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let report = try JSONDecoder().decode(WiFiAwareTransport.Readiness.self, from: data)
        precondition(!report.streamImplemented, "A capability probe must never enable streaming")
        precondition(!report.message.isEmpty)
        if report.discoveryStatus == "rejected" {
            precondition(report.discoveryError != nil)
            precondition(report.message.contains("rejected"))
        }
        if report.authorizationStatus == "missingEntitlement" {
            precondition(report.message.contains("entitlement"))
        }
        if !report.capabilitiesAvailable {
            precondition(!report.supportsDataTransfer && report.maxDatapaths == 0)
        }
        // Saving a third transport must not alter the default or break older preferences.
        precondition(MirrorPreferences().transport == .bluetoothClassic)
        let old = try JSONDecoder().decode(MirrorPreferences.self, from: Data("{}".utf8))
        precondition(old.transport == .bluetoothClassic)
        var preferences = old
        preferences.transport = .wifiAware
        let restored = try JSONDecoder().decode(MirrorPreferences.self, from: JSONEncoder().encode(preferences))
        precondition(restored.transport == .wifiAware)
        print("Wi-Fi Aware report decoding and preference compatibility passed")
    }
}
