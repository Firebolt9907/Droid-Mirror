import AppKit
import ApplicationServices

/// The phone's reported output volume for one advertised media session.
struct PhoneVolumeState: Equatable {
    let id: String
    let level: Int
    let max: Int
    let muted: Bool
    let name: String

    init(id: String, level: Int, max: Int, muted: Bool, name: String) {
        self.id = id; self.level = level; self.max = max; self.muted = muted; self.name = name
    }
    init?(_ event: [String: Any], expectedID: String?) {
        guard event["type"] as? String == "mediaVolumeState",
              let id = event["id"] as? String, id == expectedID,
              let max = event["max"] as? Int, (1...1000).contains(max),
              let level = event["level"] as? Int, (0...max).contains(level),
              let muted = event["muted"] as? Bool else { return nil }
        let name = (event["name"] as? String).map { String($0.prefix(64)) } ?? ""
        self.init(id: id, level: level, max: max, muted: muted, name: name)
    }
    var fraction: Double { muted ? 0 : Double(level) / Double(max) }
    /// Mirrors Android's one-step response so the HUD reacts before the reply arrives.
    func predicting(_ action: String) -> PhoneVolumeState {
        switch action {
        case "up": return PhoneVolumeState(id: id, level: Swift.min(max, level + 1), max: max, muted: false, name: name)
        case "down": return PhoneVolumeState(id: id, level: Swift.max(0, level - 1), max: max, muted: muted, name: name)
        case "mute": return PhoneVolumeState(id: id, level: level, max: max, muted: !muted, name: name)
        default: return self
        }
    }
}

/// Decodes the system-defined media-key event used for the keyboard volume keys.
enum VolumeKeyEvent {
    case press(String)   // Includes auto-repeats.
    case release
    static func decode(subtype: Int16, data1: Int) -> VolumeKeyEvent? {
        guard subtype == 8 else { return nil }
        let data = UInt32(truncatingIfNeeded: data1)
        let key = data >> 16, state = (data >> 8) & 0xff
        let action: String
        switch key {
        case 0: action = "up"      // NX_KEYTYPE_SOUND_UP
        case 1: action = "down"    // NX_KEYTYPE_SOUND_DOWN
        case 7: action = "mute"    // NX_KEYTYPE_MUTE
        default: return nil
        }
        switch state {
        case 0x0a: return .press(action)
        case 0x0b: return .release
        default: return nil
        }
    }
}

/// A global session tap that exists only while phone media is in Now Playing.
/// Outside that window the volume keys are never observed.
final class PhoneVolumeKeyTap {
    var onPress: ((String) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var prompted = false
    private(set) var needsPermission = false

    var active: Bool { tap != nil }

    func setActive(_ wanted: Bool) {
        if wanted == active { return }
        wanted ? start() : stop()
    }
    private func start() {
        let options = ["AXTrustedCheckOptionPrompt": !prompted] as CFDictionary
        prompted = true
        guard AXIsProcessTrustedWithOptions(options) else { needsPermission = true; return }
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: phoneVolumeTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            needsPermission = true; return
        }
        needsPermission = false
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
    /// Retries after the user grants Accessibility, without prompting again.
    func retryIfPermitted(_ wanted: Bool) {
        guard wanted, !active, needsPermission, AXIsProcessTrusted() else { return }
        start()
    }
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event),
              let key = VolumeKeyEvent.decode(subtype: ns.subtype.rawValue, data1: ns.data1) else {
            return Unmanaged.passUnretained(event)
        }
        // Consume both edges so macOS does not also change the Mac's volume.
        if case .press(let action) = key { onPress?(action) }
        return nil
    }
    deinit { stop() }
}

private func phoneVolumeTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                    userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<PhoneVolumeKeyTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
}

/// Phone volume overlay modeled on the macOS volume HUD.
final class PhoneVolumeHUD {
    private var panel: NSPanel?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let bar = PhoneVolumeBar()
    private var hideWork: DispatchWorkItem?
    private static let size = NSSize(width: 300, height: 74)

    func show(_ state: PhoneVolumeState) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        title.stringValue = state.name.isEmpty ? "Phone" : state.name
        let symbol: String
        if state.muted || state.level == 0 { symbol = "speaker.slash.fill" }
        else if state.fraction < 0.34 { symbol = "speaker.wave.1.fill" }
        else if state.fraction < 0.67 { symbol = "speaker.wave.2.fill" }
        else { symbol = "speaker.wave.3.fill" }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Phone volume")
        bar.setFraction(state.fraction, animated: panel.isVisible && panel.alphaValue > 0.5)
        panel.setAccessibilityValue("\(Int((state.fraction * 100).rounded()))%")
        position(panel)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
    var visible: Bool { panel?.isVisible == true && hideWork != nil }
    func hide() {
        hideWork?.cancel(); hideWork = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) { [weak self] in
            if self?.hideWork == nil { panel.orderOut(nil) }
        }
    }
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }
        if #available(macOS 26, *) {
            // Tahoe and later present the volume HUD at the top-right, under the menu bar.
            panel.setFrameOrigin(NSPoint(x: area.maxX - Self.size.width - 12, y: area.maxY - Self.size.height - 10))
        } else {
            panel.setFrameOrigin(NSPoint(x: area.midX - Self.size.width / 2, y: area.minY + 120))
        }
    }
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = 0
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityRole(.popover)
        panel.setAccessibilityLabel("Phone volume")

        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.contentTintColor = .labelColor
        let subtitle = NSTextField(labelWithString: "Phone volume")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        for view in [title, subtitle, icon, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            subtitle.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            bar.heightAnchor.constraint(equalToConstant: 8),
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let radius: CGFloat = 20
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.cornerRadius = radius
            glass.contentView = content
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: content.frame)
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = radius
            effect.layer?.masksToBounds = true
            content.frame = effect.bounds
            content.autoresizingMask = [.width, .height]
            effect.addSubview(content)
            panel.contentView = effect
        }
        return panel
    }
}

/// A capsule track with a filled level, like the system volume slider.
private final class PhoneVolumeBar: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    private var fraction = 0.0
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track); layer?.addSublayer(fill)
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
            fill.backgroundColor = NSColor.labelColor.withAlphaComponent(0.9).cgColor
        }
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = bounds; track.cornerRadius = bounds.height / 2
        applyFill()
        CATransaction.commit()
    }
    func setFraction(_ value: Double, animated: Bool) {
        fraction = min(1, max(0, value))
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.12)
        applyFill()
        CATransaction.commit()
    }
    private func applyFill() {
        let width = bounds.width * fraction
        fill.frame = NSRect(x: 0, y: 0, width: width < 0.5 ? 0 : max(bounds.height, width), height: bounds.height)
        fill.cornerRadius = bounds.height / 2
    }
}
