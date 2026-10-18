import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: MirrorModel
    @State private var showWireless = false
    @State private var showSettings = false
    @State private var showPinPad = false
    @State private var pinDigitCount = 0

    var body: some View {
        HStack(spacing: 8) {
            connectionIndicator
            devicePicker
            Divider().frame(height: 28).padding(.horizontal, 2)

            if model.isMirroring && model.selectedDevice?.isBluetooth != true {
                toolbarButton("chevron.backward", help: "Back", action: model.goBack)
                toolbarButton("circle", help: "Home", action: model.goHome)
                toolbarButton("square.on.square", help: "Recent apps", action: model.switchApps)
                toolbarButton("speaker.minus", help: "Volume down", action: model.volumeDown)
                toolbarButton("speaker.plus", help: "Volume up", action: model.volumeUp)
                toolbarButton("power", help: "Power", action: model.toggleScreenPower)
                Button { showPinPad.toggle() } label: {
                    Image(systemName: model.isDeviceLocked ? "lock.fill" : "lock")
                        .frame(width: 20, height: 22)
                        .foregroundStyle(model.isDeviceLocked ? Color.orange : Color.primary)
                }
                .buttonStyle(.borderless)
                .help("PIN keypad")
                .popover(isPresented: $showPinPad, arrowEdge: .bottom) {
                    PinPadView(digitCount: $pinDigitCount) { digit in
                        model.enterPinDigit(digit)
                    } onDelete: {
                        model.deletePinDigit()
                    } onSubmit: {
                        let sent = model.submitPin()
                        if sent {
                            pinDigitCount = 0
                            showPinPad = false
                        }
                        return sent
                    }
                }
            }

            Button { model.isMirroring ? model.stop() : model.start() } label: {
                Label(model.isMirroring ? "Stop" : "Mirror", systemImage: model.isMirroring ? "stop.fill" : "play.fill")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isMirroring ? .red : .accentColor)
            .disabled(model.isStarting || (!model.isMirroring && model.selectedDevice?.isOnline != true))

            Button { showSettings.toggle() } label: {
                Image(systemName: "ellipsis").frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showSettings, arrowEdge: .bottom) { compactSettings }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .padding(18)
        .background(WindowStyler())
        .fixedSize()

        .sheet(isPresented: $showWireless) { WirelessView().environmentObject(model) }
        .onChange(of: model.isDeviceLocked) { _, locked in
            if locked { pinDigitCount = 0; showPinPad = true }
        }
    }

    private var connectionIndicator: some View {
        ZStack {
            Circle().fill(.black.opacity(0.18)).frame(width: 34, height: 34)
            Image(systemName: model.selectedDevice?.isBluetooth == true ? "antenna.radiowaves.left.and.right" : (model.selectedDevice?.isWireless == true ? "wifi" : "smartphone"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.selectedDevice?.isOnline == true ? Color.accentColor : Color.secondary)
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(model.isMirroring ? Color.green : (model.selectedDevice?.isOnline == true ? Color.blue : Color.gray))
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1))
        }
    }

    private var devicePicker: some View {
        Menu {
            if model.devices.isEmpty {
                Text("No Android devices")
            } else {
                ForEach(model.devices) { device in
                    Button {
                        model.selectedID = device.id
                    } label: {
                        Label(device.displayName, systemImage: model.selectedID == device.id ? "checkmark" : (device.isWireless ? "wifi" : "cable.connector"))
                    }
                }
            }
            Divider()
            Button("Refresh", systemImage: "arrow.clockwise") { model.refreshDevices() }
            Button("Set up a phone…", systemImage: "iphone.gen3.radiowaves.left.and.right") {
                OnboardingWindowController.shared.show(model: model)
            }
            Button("Connect wirelessly…", systemImage: "wifi") { showWireless = true }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.selectedDevice?.displayName ?? "No device")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(model.isMirroring ? "Mirroring" : (model.selectedDevice?.isOnline == true ? (model.selectedDevice?.isBluetooth == true ? "Bluetooth paired" : "Ready") : "Not connected"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 118, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func toolbarButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 20, height: 22) }
            .buttonStyle(.borderless).help(help)
    }

    private var compactSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mirror options").font(.headline)
            Picker("Connection", selection: $model.preferences.transport) {
                ForEach(MirrorTransport.allCases) { Text($0.label).tag($0) }
            }.disabled(model.isMirroring || model.isStarting)
            if model.preferences.transport == .bluetoothClassic {
                Text("Starts over Bluetooth with HEVC at 480p, up to 16 fps and 256 kbps, then upgrades to your Wi-Fi picture settings when paired wireless ADB is available. Authorize Shizuku and enable Mac connections once on Android. Mouse, keyboard and navigation stay on BLE.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.preferences.transport == .wifiAware {
                Text(model.wifiAwareStatus).font(.caption).foregroundStyle(.secondary)
                Button("Check Wi-Fi Aware support") { model.checkWiFiAware() }
                    .disabled(model.isRefreshing)
            }
            Group {
            Toggle("Start mirroring automatically", isOn: $model.preferences.autoStart)
            Toggle("Keep phone screen off", isOn: $model.preferences.turnDeviceScreenOff)
            Toggle("Forward audio to Mac", isOn: $model.preferences.forwardAudio)
            Toggle("Always on top", isOn: $model.preferences.alwaysOnTop)
            Divider()
            Picker("Scrolling", selection: $model.preferences.scrollMode) {
                ForEach(ScrollMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            if model.preferences.scrollMode == .touchSwipe {
                Text("Converts two-finger and mouse-wheel movement into real Android touch gestures for overscroll, pull-to-refresh, and gesture-driven app features.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Quality", selection: $model.preferences.maxSize) {
                Text("Efficient").tag(1280); Text("High").tag(1920); Text("Native").tag(0)
            }
            Picker("Frame rate", selection: $model.preferences.maxFPS) {
                Text("30 fps").tag(30); Text("60 fps").tag(60); Text("90 fps").tag(90)
            }
            }.disabled(model.preferences.transport != .adb)
            Text("Changes apply the next time the mirror starts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(width: 280)
    }
}

private struct PinPadView: View {
    @Binding var digitCount: Int
    let onDigit: (Int) -> Bool
    let onDelete: () -> Bool
    let onSubmit: () -> Bool

    private let rows = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.title2)
                Text("Enter Android PIN").font(.headline)
                HStack(spacing: 9) {
                    ForEach(0..<max(4, min(8, digitCount)), id: \.self) { index in
                        Circle()
                            .fill(index < digitCount ? Color.primary : Color.secondary.opacity(0.22))
                            .frame(width: 10, height: 10)
                    }
                }
                .frame(height: 18).padding(.top, 5)
            }

            ForEach(rows, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(row, id: \.self) { digit in digitButton(digit) }
                }
            }
            HStack(spacing: 12) {
                Button {
                    if onDelete(), digitCount > 0 { digitCount -= 1 }
                } label: { Image(systemName: "delete.left").frame(width: 42, height: 34) }
                    .buttonStyle(.borderless).disabled(digitCount == 0)
                digitButton(0)
                Button { _ = onSubmit() } label: { Image(systemName: "arrow.right.circle.fill").frame(width: 42, height: 34) }
                    .buttonStyle(.borderless).foregroundStyle(.tint).disabled(digitCount == 0)
            }
            Text("Digits are sent immediately and are never stored.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18).frame(width: 220)
    }

    private func digitButton(_ digit: Int) -> some View {
        Button {
            if onDigit(digit) { digitCount = min(8, digitCount + 1) }
        } label: {
            Text("\(digit)").font(.title3).frame(width: 42, height: 34)
        }
        .buttonStyle(.bordered)
        .clipShape(Circle())
    }
}

private struct WindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { style(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { style(nsView.window) }
    }

    private func style(_ window: NSWindow?) {
        guard let window else { return }
        ToolbarWindowRegistry.shared.window = window
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.invalidateShadow()
    }
}
