import AppKit
import SwiftUI

/// Routes launch, reconnects and status messages to the app's persistent phone surface.
@MainActor
final class PhoneWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PhoneWindowController()
    private weak var model: MirrorModel?
    private var observing = false

    func show(model: MirrorModel) {
        self.model = model
        MirrorRenderer.shared.configure(device: model.selectedDevice)
        if !observing {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(connectingVisible(_:)),
                name: Notification.Name("app.droidmirror.connectingVisible"),
                object: String(ProcessInfo.processInfo.processIdentifier))
            observing = true
        }
        do {
            try MirrorRenderer.shared.prepare()
            window?.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)
            MirrorRenderer.shared.focus()
        } catch {
            showFallback(model: model)
        }
    }

    func present(title: String, message: String, model: MirrorModel, connecting: Bool = false) {
        model.sessionNoticeTitle = title
        model.sessionNoticeMessage = message
        // Status changes update the existing stage without stealing focus from
        // another app. Starting a connection remains an explicit focus action.
        if connecting || !MirrorRenderer.shared.isRunning { show(model: model) }
        MirrorRenderer.shared.configure(device: model.selectedDevice)
        MirrorRenderer.shared.present(title: title, message: message, connecting: connecting)
    }

    func reopen(model: MirrorModel) { show(model: model) }

    @objc private func connectingVisible(_ notification: Notification) { window?.orderOut(nil) }

    func rendererClosed() {
        guard let model else { return }
        model.sessionNoticeTitle = "Connection ended"
        model.sessionNoticeMessage = "Connect again when you’re ready."
        showFallback(model: model)
    }

    var videoPositionArguments: [String] { [] } // The native surface retains its own frame across attempts.

    private func showFallback(model: MirrorModel) {
        if window == nil {
            let controller = NSHostingController(rootView: PhoneConnectionView().environmentObject(model))
            let window = PhoneFallbackWindow(contentViewController: controller)
            window.title = "DroidMirror"
            window.styleMask = [.borderless, .miniaturizable]
            window.collectionBehavior = [.primary, .managed, .participatesInCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 360, height: min(800, (NSScreen.main?.visibleFrame.height ?? 900) - 96)))
            window.delegate = self
            window.center()
            self.window = window
        }
        // If the renderer is unavailable, the fallback becomes the public app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model?.isStarting == true || model?.isMirroring == true { model?.stop() }
        return true
    }
}

private final class PhoneFallbackWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct PhoneConnectionView: View {
    @EnvironmentObject private var model: MirrorModel
    var body: some View {
        let appearance = PhoneAppearanceSnapshot(device: model.selectedDevice)
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
            Text(model.isStarting ? "Connecting to \(appearance.name ?? model.selectedDevice?.displayName ?? "your phone")…" : model.sessionNoticeTitle).font(.title2.weight(.semibold))
            Text(model.sessionNoticeMessage).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(10)
            if model.isStarting {
                ProgressView()
                Button("Cancel") { model.stop() }
            } else {
                Button(model.sessionNoticeTitle == "Stopped due to inactivity" ? "Reconnect" : "Connect Again") { model.start() }.buttonStyle(.borderedProminent)
                    .disabled(model.isMirroring || model.selectedDevice?.isOnline != true)
                Button("Settings…") { SettingsWindowController.shared.show(model: model) }.buttonStyle(.link)
            }
            Spacer()
        }
        .padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GeometryReader { geometry in
                if let wallpaper = appearance.wallpaper {
                    Image(nsImage: wallpaper).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: 24).overlay(Color.black.opacity(0.58))
                } else { Color(white: 0.06) }
            }
        }
        .clipShape(PhoneScreenShape(topRatio: appearance.topRatio, bottomRatio: appearance.bottomRatio))
        .preferredColorScheme(.dark)
    }
}
