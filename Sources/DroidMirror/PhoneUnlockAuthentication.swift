import AppKit
import Foundation
import LocalAuthentication

/// Authorizes only the next capture startup; never caches biometric success.
@MainActor
final class PhoneUnlockAuthentication {
    static let preferenceKey = "DroidMirror.unlock.requireTouchID"
    private var context: LAContext?

    static var available: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            && context.biometryType == .touchID
    }

    /// Bluetooth helpers fall back to manual unlock after 30 seconds and the
    /// ADB start gate expires after 60, so an unanswered prompt closes first.
    nonisolated static let promptTimeout: Duration = .seconds(25)

    func authorize(timeout: Duration = PhoneUnlockAuthentication.promptTimeout) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        context.localizedCancelTitle = "Unlock manually"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil),
              context.biometryType == .touchID else { return false }
        self.context = context
        let expiry = Task { [weak context] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { context?.invalidate() }
        }
        defer {
            expiry.cancel()
            context.invalidate()
            if self.context === context { self.context = nil }
        }
        // The host is a background (LSUIElement) app, usually behind the
        // renderer's phone window. An inactive app's sheet ignores the sensor
        // until clicked, so take activation for the prompt itself.
        NSApp.activate(ignoringOtherApps: true)
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock your Android phone using its saved PIN.")
        } catch { return false }
    }

    func cancel() { context?.invalidate() }
}
