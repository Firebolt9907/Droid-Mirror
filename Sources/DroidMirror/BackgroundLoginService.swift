import ServiceManagement
import SwiftUI

/// Registers only the existing receiver, never the mirroring host.
@MainActor
final class BackgroundLoginService: ObservableObject {
    private let service = SMAppService.agent(plistName: "app.droidmirror.background.plist")
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var message = ""

    init() { refresh() }

    func refresh() {
        enabled = service.status == .enabled || service.status == .requiresApproval
        needsApproval = service.status == .requiresApproval
    }

    func setEnabled(_ value: Bool) {
        do {
            if value { try service.register() }
            else { try service.unregister() }
            message = ""
        } catch {
            message = "Could not change background startup: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}
