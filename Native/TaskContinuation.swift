import AppKit

struct TaskContinuationState {
    private(set) var url: URL?
    private(set) var package = ""
    private var receivedAt = Date.distantPast
    static let lifetime: TimeInterval = 8

    static func browserURL(_ value: String) -> URL? {
        guard !value.isEmpty, value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              let parts = URLComponents(string: value),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              let url = parts.url else { return nil }
        return url
    }

    mutating func receive(_ event: [String: Any], authenticated: Bool, now: Date = Date()) {
        clear()
        guard authenticated, event["type"] as? String == "taskContinuation",
              let raw = event["url"] as? String, let url = Self.browserURL(raw),
              let package = event["package"] as? String, !package.isEmpty, package.count <= 256 else { return }
        self.url = url
        self.package = package
        receivedAt = now
    }
    func currentURL(authenticated: Bool, now: Date = Date()) -> URL? {
        guard authenticated, now.timeIntervalSince(receivedAt) < Self.lifetime else { return nil }
        return url
    }
    mutating func clear() { url = nil; package = ""; receivedAt = .distantPast }
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
        controller?.send(["type": "taskSubscribe", "enabled": true])
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
            let image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Continue from phone")
            image?.isTemplate = true
            item.button?.image = image
            item.button?.target = self
            item.button?.action = #selector(openTask)
            item.button?.setAccessibilityLabel("Continue from phone in browser")
            self.item = item
        }
        let app = state.package == "com.google.android.apps.docs.editors.docs" ? "Google Docs" : "phone"
        item?.button?.toolTip = "Continue from \(app) in your browser — \(url.host ?? "")"
    }
    @objc private func openTask() {
        guard let url = state.currentURL(authenticated: controller?.authenticated == true) else { refresh(); return }
        openBrowser(url)
    }
    func stop() { timer?.invalidate(); timer = nil; state.clear(); refresh() }
}
