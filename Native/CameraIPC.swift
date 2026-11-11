import Foundation
import Security

// Anonymous XPC endpoints are published only inside the signed application group.
// No camera data or demand is accepted through distributed notifications.
@objc protocol CameraExtensionIPC {
    func updatePresence(_ connected: Bool, reply: @escaping (Bool) -> Void)
    func clearFrame()
    func submitFrame(_ bytes: Data, width: Int, height: Int, reply: @escaping () -> Void)
}
enum CameraIPC {
    static var group: String? { signingTeam.map { $0 + ".app.droidmirror.camera" } }
    static let identifier = "app.droidmirror.camera"
    private static var signingTeam: String? {
        var code: SecCode?
        var information: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]+$", options: .regularExpression) != nil else { return nil }
        return team
    }
    static func requirement(for identifier: String) -> String? {
        guard let team = signingTeam else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }
    static var endpointURL: URL? {
        guard let group else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("camera.endpoint")
    }
}
