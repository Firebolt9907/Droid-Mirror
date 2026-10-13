import AppKit

@MainActor
final class ToolbarWindowRegistry {
    static let shared = ToolbarWindowRegistry()
    weak var window: NSWindow?
    private init() {}
}
