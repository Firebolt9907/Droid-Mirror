import AppKit
import SwiftUI

/// Snapshot membership is bounded and assembled before pruning any visible items.
struct ActivitySnapshotMembership {
    private var token: String?
    private var next = 0
    private var total = 0
    private var ids = Set<String>()
    private var expires: TimeInterval = 0
    mutating func accept(_ event: [String: Any], now: TimeInterval = ActivityClock.now) -> Set<String>? {
        guard let values = event["ids"] as? [String], values.count <= 64,
              values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) else { return nil }
        let parts = event["parts"] as? Int ?? 1
        let part = event["part"] as? Int ?? 0
        guard (1...2).contains(parts), (0..<parts).contains(part) else { return nil }
        if parts == 1 { self = Self(); return Set(values) }
        guard let incoming = event["snapshot"] as? String, incoming.utf8.count <= 64 else { return nil }
        if part == 0 {
            token = incoming; next = 0; total = parts; ids = []; expires = now + 30
        }
        guard token == incoming, total == parts, next == part, now < expires else { self = Self(); return nil }
        ids.formUnion(values); next += 1
        if next == total { let result = ids; self = Self(); return result }
        return nil
    }
}

/// A separate menu-bar item per Android notification, with a shared native shade-style renderer.
final class AndroidActivityMenu: NSObject {
    private final class Entry {
        let item: NSStatusItem
        var event: [String: Any]
        var clockAnchor: TimeInterval
        var popover: NSPopover?
        var controller: NSHostingController<AndroidActivityHostedCard>?
        let model: AndroidActivityCardModel
        let status = AndroidActivityStatusModel()
        var statusView: AndroidActivityStatusHostingView?
        var expiresAt: TimeInterval?
        init(item: NSStatusItem, event: [String: Any], clockAnchor: TimeInterval) {
            self.item = item; self.event = event; self.clockAnchor = clockAnchor
            self.model = AndroidActivityCardModel(AndroidActivityPresentation(event: event, clockAnchor: clockAnchor))
        }
    }
    private var entries = [String: Entry]()
    var count: Int { entries.count }
    var onAction: (([String: Any], String) -> Void)?

    static func isActivity(_ event: [String: Any]) -> Bool {
        guard event["category"] as? String != "transport", event["layout"] as? String != "media" else { return false }
        return event["activity"] as? Bool == true || event["ongoing"] as? Bool == true || event["persistent"] as? Bool == true
    }

    func update(_ event: [String: Any]) {
        guard let id = event["id"] as? String, event["version"] as? String != nil else { return }
        let anchor = ActivityClock.anchor(event: event)
        let entry = entries[id] ?? Entry(item: NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength), event: event, clockAnchor: anchor)
        let previous = entry.event
        let isNew = entries[id] == nil
        entry.event = event; entry.clockAnchor = anchor
        entry.expiresAt = nil
        entry.model.enabled = true
        entry.status.enabled = true
        entry.model.presentation = AndroidActivityPresentation(event: event, clockAnchor: anchor)
        entries[id] = entry
        let item = entry.item
        if isNew || previous["activityIcon"] as? String != event["activityIcon"] as? String ||
            previous["appIcon"] as? String != event["appIcon"] as? String {
            var icon = AndroidActivityPresentation.image(event["activityIcon"] as? String)
            icon?.isTemplate = true
            icon = icon ?? AndroidActivityPresentation.image(event["appIcon"] as? String)
                ?? NSImage(systemSymbolName: "app.badge", accessibilityDescription: "Android activity")
            icon?.size = NSSize(width: 18, height: 18)
            entry.status.image = icon
        }
        item.button?.isEnabled = true
        let status = String((event["status"] as? String ?? "").prefix(16))
        entry.status.event = event
        entry.status.text = status
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let width = (status as NSString).size(withAttributes: [.font: font]).width
        item.length = status.isEmpty ? NSStatusItem.squareLength : ceil(18 + 4 + width + 8)
        if entry.statusView == nil, let button = item.button {
            let label = AndroidActivityStatusHostingView(rootView: AndroidActivityStatusLabel(model: entry.status))
            label.frame = button.bounds
            label.autoresizingMask = [.width, .height]
            button.addSubview(label)
            entry.statusView = label
            button.image = nil; button.title = ""
        }
        item.button?.toolTip = [event["app"], event["title"], event["body"]]
            .compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: "\n")
        item.button?.setAccessibilityLabel(item.button?.toolTip ?? "Android activity")
        item.button?.identifier = NSUserInterfaceItemIdentifier(id)
        item.button?.target = self
        item.button?.action = #selector(showActivity(_:))
        if entry.popover?.isShown == true { refresh(entry, id: id) }
    }

    func remove(_ id: String) {
        if let entry = entries.removeValue(forKey: id) {
            entry.popover?.close()
            NSStatusBar.system.removeStatusItem(entry.item)
        }
    }
    func removeDisallowed(_ allows: ([String: Any]) -> Bool) {
        for (id, entry) in entries where !allows(entry.event) { remove(id) }
    }
    func clear() { for id in Array(entries.keys) { remove(id) } }

    @objc private func showActivity(_ sender: NSStatusBarButton) {
        guard let id = sender.identifier?.rawValue, let entry = entries[id] else { return }
        if entry.popover?.isShown == true { entry.popover?.close(); return }
        for other in entries.values { other.popover?.close() }
        if entry.popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            entry.popover = popover
        }
        refresh(entry, id: id)
        entry.popover?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func refresh(_ entry: Entry, id: String) {
        guard let popover = entry.popover else { return }
        // One native surface clips the legibility tint, including the chevron and outer corners.
        popover.hasFullSizeContent = true
        popover.appearance = NSApp.effectiveAppearance
        if entry.controller == nil {
            let root = AndroidActivityHostedCard(model: entry.model) { [weak self] version, action in
                self?.perform(id: id, version: version, action: action)
            }
            let controller = NSHostingController(rootView: root)
            entry.controller = controller
            popover.contentViewController = controller
        }
        resize(entry)
        // Published state updates layout on the next run-loop pass.
        DispatchQueue.main.async { [weak self, weak entry] in
            guard let self, let entry, self.entries[id] === entry else { return }
            self.resize(entry)
        }
    }

    private func resize(_ entry: Entry) {
        guard let controller = entry.controller, let popover = entry.popover else { return }
        controller.view.layoutSubtreeIfNeeded()
        let size = controller.view.fittingSize
        let desired = NSSize(width: 380, height: min(760, max(80, size.height)))
        if popover.contentSize != desired { popover.contentSize = desired }
    }

    /// Authoritative membership prunes missing notifications without removing matching status items.
    func reconcile(_ ids: Set<String>) {
        for id in Array(entries.keys) where !ids.contains(id) { remove(id) }
    }

    /// A brief outage must not tear down the menu bar. Old controls remain unusable.
    func suspend(now: TimeInterval = ActivityClock.now) {
        for (id, entry) in entries {
            entry.model.enabled = false
            entry.status.enabled = false
            // The card remains readable; only its authenticated phone actions are suspended.
            entry.item.button?.isEnabled = true
            if entry.expiresAt == nil { entry.expiresAt = now + 30 }
            if entry.popover?.isShown == true { refresh(entry, id: id) }
        }
    }

    /// Both the visible card and tests use this path; an old card cannot execute a rotated token.
    func perform(id: String, version: String, action: String) {
        guard let entry = entries[id], entry.model.enabled, entry.event["version"] as? String == version else { return }
        if action == "open" {
            guard entry.event["canOpen"] as? Bool == true else { return }
        } else {
            guard (entry.event["actions"] as? [[String: Any]] ?? []).contains(where: {
                $0["id"] as? String == action && $0["reply"] as? Bool != true
            }) else { return }
        }
        onAction?(entry.event, action)
    }

    func tick(now: TimeInterval = ActivityClock.now) {
        for (id, entry) in entries where entry.expiresAt.map({ now >= $0 }) == true { remove(id) }
    }

    // Object identity checks ensure update/reconciliation regressions cannot reintroduce flicker.
    func itemIdentity(_ id: String) -> ObjectIdentifier? { entries[id].map { ObjectIdentifier($0.item) } }
    func statusIdentity(_ id: String) -> ObjectIdentifier? { entries[id]?.statusView.map { ObjectIdentifier($0) } }
    func controllerIdentity(_ id: String) -> ObjectIdentifier? { entries[id]?.controller.map { ObjectIdentifier($0) } }
    func prepareCard(_ id: String) {
        guard let entry = entries[id] else { return }
        if entry.popover == nil { entry.popover = NSPopover() }
        refresh(entry, id: id)
    }

    static func clock(_ duration: TimeInterval, countDown: Bool) -> String {
        // Match Android Chronometer.updateText: round((remainingMs - 499)/1000), round(elapsedMs/1000).
        let seconds = Int(min(315_360_000, max(0, floor(duration + (countDown ? 0.001 : 0.5)))))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
