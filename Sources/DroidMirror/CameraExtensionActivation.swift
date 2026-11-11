import Foundation
import Combine
import SystemExtensions

final class CameraExtensionActivation: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    /// Builds signed without a paid Apple Developer team omit the extension.
    static let bundled = FileManager.default.fileExists(atPath: Bundle.main.bundleURL
        .appendingPathComponent("Contents/Library/SystemExtensions/app.droidmirror.camera.systemextension").path)
    @Published var status = bundled
        ? "Approve the camera extension once, then connect your phone over BLE."
        : "Not included in this build. Phone Camera requires signing with a paid Apple Developer team (set DROIDMIRROR_TEAM_ID)."
    func activate() {
        guard Self.bundled else { return }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: "app.droidmirror.camera", queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Approve DroidMirror in System Settings → General → Login Items & Extensions → Camera Extensions."
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        status = result == .completed ? "Camera extension enabled. Arm Phone Camera in Android Bridge Settings." : "Restart your Mac to finish enabling the camera extension."
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) { status = error.localizedDescription }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
}
