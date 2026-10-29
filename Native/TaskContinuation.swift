import AppKit

struct TaskContinuationState {
    private(set) var url: URL?
    private(set) var package = ""
    private(set) var appIcon: Data?
    private var connectionScoped = false
    private var receivedAt = Date.distantPast
    static let lifetime: TimeInterval = 8

    static func browserURL(_ value: String) -> URL? { BrowserURL.browserURL(value) }

    mutating func receive(_ event: [String: Any], authenticated: Bool, now: Date = Date()) {
        clear()
        guard authenticated, event["type"] as? String == "taskContinuation",
              let raw = event["url"] as? String, let url = Self.browserURL(raw),
              let package = event["package"] as? String, !package.isEmpty, package.count <= 256 else { return }
        connectionScoped = event["changeOnly"] as? Bool == true
        self.url = url
        self.package = package
        appIcon = NotificationIconAttachment.validatedData(event["appIcon"] as? String)
        receivedAt = now
    }
    func currentURL(authenticated: Bool, now: Date = Date()) -> URL? {
        guard authenticated, (connectionScoped || now.timeIntervalSince(receivedAt) < Self.lifetime) else { return nil }
        return url
    }
    mutating func clear() { url = nil; package = ""; appIcon = nil; connectionScoped = false; receivedAt = .distantPast }
}

/// Only the background receiver owns this item, so there is one icon across hosts.
final class TaskContinuation: NSObject {
    weak var controller: BLEController?
    private var state = TaskContinuationState()
    private(set) var item: NSStatusItem?
    private var timer: Timer?
    private let openBrowser: (URL) -> Void

    init(openBrowser: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
        self.openBrowser = openBrowser
        super.init()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func connected() {
        clear()
        guard controller?.supportsTaskURLs == true else { return }
        controller?.send(["type": "taskSubscribe", "enabled": true, "changeOnly": true])
    }
    func receive(_ event: [String: Any]) {
        state.receive(event, authenticated: controller?.authenticated == true)
        refresh()
    }
    func clear() { state.clear(); refresh() }
    private func refresh() {
        guard let url = state.currentURL(authenticated: controller?.authenticated == true) else {
            if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
            return
        }
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(openTask)
            item.button?.setAccessibilityLabel("Continue from phone in browser")
            self.item = item
        }
        let image: NSImage?
        if let data = state.appIcon, let icon = NSImage(data: data) {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = false
            image = icon
        } else {
            image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Continue from phone")
            image?.isTemplate = true
        }
        item?.button?.image = image
        let app = state.package == "com.google.android.apps.docs.editors.docs" ? "Google Docs" : "phone"
        item?.button?.toolTip = "Continue from \(app) in your browser — \(url.host ?? "")"
    }
    @objc private func openTask() {
        guard let url = state.currentURL(authenticated: controller?.authenticated == true) else { refresh(); return }
        openBrowser(url)
    }
    func stop() { timer?.invalidate(); timer = nil; state.clear(); refresh() }
}
