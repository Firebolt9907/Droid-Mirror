import SwiftUI

@MainActor
private final class ClipboardConnectionStatus: NSObject, ObservableObject {
    @Published var mediaText = "Waiting for the background receiver…"
    @Published var text = "Waiting for the background receiver…"
    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receive(_:)),
            name: Notification.Name("app.droidmirror.receiverStatus"), object: nil)
    }
    @objc private func receive(_ event: Notification) {
        if let status = event.userInfo?["media"] as? String { mediaText = status }
        if let status = event.userInfo?["clipboard"] as? String { text = status }
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self) }
}

struct SettingsView: View {
    @EnvironmentObject private var model: MirrorModel
    @AppStorage("DroidMirror.clipboard.enabled") private var clipboardMirroring = false
    @AppStorage("DroidMirror.hotspot.automatic") private var automaticHotspot = false
    @AppStorage("DroidMirror.media.enabled") private var mediaSync = false
    @StateObject private var clipboardStatus = ClipboardConnectionStatus()
    @StateObject private var backgroundLogin = BackgroundLoginService()

    var body: some View {
        Form {
            Section("Background service") {
                Toggle("Start background service at login", isOn: Binding(
                    get: { backgroundLogin.enabled }, set: { backgroundLogin.setEnabled($0) }))
                    .disabled(model.isMirroring || model.isStarting)
                Text("Keeps phone notifications, link sharing and enabled sync features available after you log in. Does not open the mirror or start a mirroring session.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.isMirroring || model.isStarting {
                    Text("Stop mirroring before changing background startup.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if backgroundLogin.needsApproval {
                    Text("Allow DroidMirror under Login Items & Extensions in System Settings to finish enabling background startup.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items Settings…") { backgroundLogin.openLoginSettings() }
                }
                if !backgroundLogin.message.isEmpty {
                    Text(backgroundLogin.message).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Connection") {
                Button("Set up a phone…") { OnboardingWindowController.shared.show(model: model) }
                Text("Follow the guided setup for Bluetooth, phone permissions and your first mirror.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Transport", selection: $model.preferences.transport) {
                    ForEach(MirrorTransport.allCases) { Text($0.label).tag($0) }
                }.disabled(model.isMirroring || model.isStarting || model.isPairingBluetooth)
                if model.preferences.transport == .bluetoothClassic {
                    Picker("Paired phone", selection: $model.selectedID) {
                        Text("Select a phone").tag(String?.none)
                        ForEach(model.devices) { Text($0.displayName).tag(Optional($0.id)) }
                    }.disabled(model.isMirroring || model.isStarting || model.isPairingBluetooth)
                    HStack {
                        SecureField("BLE pairing code from Android", text: $model.bluetoothPairingCode)
                        Button("Pair Mac") { model.pairBluetooth() }
                            .disabled(model.selectedDevice == nil || model.bluetoothPairingCode.isEmpty || model.isPairingBluetooth)
                    }.disabled(model.isMirroring || model.isStarting)
                    Text("Once per phone: open Pair Mac (mirroring and notifications) in DroidMirror on Android and paste its code here. This pairs mirroring, notification forwarding and ADB discovery together. Allow notification forwarding on Android once.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Refresh") { model.refreshDevices() }.disabled(model.isStarting || model.isMirroring)
                        Button(model.isMirroring || model.isStarting ? "Stop" : "Mirror") {
                            if model.isMirroring || model.isStarting { model.stop() } else { model.start() }
                        }.disabled(!model.isMirroring && !model.isStarting && model.selectedDevice == nil)
                    }
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
                if model.preferences.transport == .wifiAware {
                    Text(model.wifiAwareStatus).font(.caption).foregroundStyle(.secondary)
                    Button("Check Wi-Fi Aware support") { model.checkWiFiAware() }
                        .disabled(model.isRefreshing || model.isMirroring || model.isStarting)
                    Text("Experimental direct connection. Mirroring is unavailable in this build.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Bluetooth and direct LAN video connect in parallel. LAN can carry the first video packet; otherwise Bluetooth starts at 320p, up to 15 fps, and a 128 kbps HEVC ceiling, then upgrades to the picture settings below. Video tries direct LAN or Tailscale IPs first, then an already-paired wireless ADB connection, then stays on Bluetooth. Relays and public Iroh discovery are disabled. Wireless ADB fallback requires Wireless debugging and one-time ADB pairing. Mouse, keyboard and navigation stay on Bluetooth. Audio requires a direct ADB session. Authorize Shizuku and enable the background bridge once in the Android companion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Phone hotspot") {
                Toggle("Automatically turn on phone hotspot when Mac is offline", isOn: $automaticHotspot)
                    .onChange(of: automaticHotspot) { _, _ in
                        UserDefaults.standard.synchronize()
                        DistributedNotificationCenter.default().postNotificationName(
                            Notification.Name("app.droidmirror.hotspotConfiguration"), object: nil,
                            userInfo: nil, deliverImmediately: true)
                    }
                Text("Click the hotspot menu bar icon to toggle your phone’s hotspot over Bluetooth. Green means on. The icon appears only when there is no Wi-Fi connection or you are connected to the phone’s hotspot. After you join the hotspot, switching to another Wi-Fi network turns it off. Allow Location Services to detect Wi-Fi network changes. Automatic mode waits 15 seconds and tries once per outage. Uses mobile data. Join the hotspot in the Wi-Fi menu; save it once for macOS auto-join. Requires Android 11+, the background bridge and authorized Shizuku.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NotificationAppsView()
            Section("Clipboard") {
                Toggle("Mirror clipboard over Bluetooth", isOn: $clipboardMirroring)
                    .onChange(of: clipboardMirroring) { _, _ in
                        UserDefaults.standard.synchronize()
                        DistributedNotificationCenter.default().postNotificationName(
                            Notification.Name("app.droidmirror.clipboardConfiguration"), object: nil,
                            userInfo: nil, deliverImmediately: true)
                    }
                Text(clipboardMirroring ? clipboardStatus.text : "Clipboard mirroring off")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Sync newly copied text, images and individual files in both directions, including between mirror sessions. Requires Bluetooth pairing, the Android background bridge and Shizuku. Images and files must be less than 5 MB; text is limited to 4 KiB. Marked sensitive clips are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Media playback") {
                Toggle("Sync phone and Apple Music playback", isOn: $mediaSync)
                    .onChange(of: mediaSync) { _, _ in
                        UserDefaults.standard.synchronize()
                        DistributedNotificationCenter.default().postNotificationName(
                            Notification.Name("app.droidmirror.mediaConfiguration"), object: nil,
                            userInfo: nil, deliverImmediately: true)
                    }
                Text(mediaSync ? clipboardStatus.mediaText : "Media syncing off")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Show phone media in macOS Now Playing and Apple Music on your phone. Syncs track details and playback controls over paired Bluetooth; audio stays on its original device. Allow notification access on Android and Music Automation permission on Mac. Local playback takes priority on each device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("iPhone-like behavior") {
                Toggle("Turn the Android display off while mirroring", isOn: $model.preferences.turnDeviceScreenOff)
                Toggle("Keep the device awake while connected", isOn: $model.preferences.stayAwake)
                Toggle("Keep the mirror above other windows", isOn: $model.preferences.alwaysOnTop)
                Toggle("Forward audio when no media is already playing", isOn: $model.preferences.forwardAudio)
            }
            .disabled(model.preferences.transport != .adb)
            Section("Picture (Wi-Fi / ADB)") {
                if model.preferences.transport == .bluetoothClassic {
                    LabeledContent("Codec", value: "HEVC (H.265)")
                } else {
                    Picker("Codec", selection: $model.preferences.codec) {
                        ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                    }
                }
                Picker("Frame rate", selection: $model.preferences.maxFPS) {
                    Text("30 fps").tag(30); Text("60 fps").tag(60); Text("90 fps").tag(90)
                }
                Picker("Resolution limit", selection: $model.preferences.maxSize) {
                    Text("1280 px").tag(1280); Text("1920 px").tag(1920); Text("Native").tag(0)
                }
                Stepper("Bit rate: \(model.preferences.bitRateMbps) Mbps", value: $model.preferences.bitRateMbps, in: 4...32, step: 2)
                Stepper("Wireless video buffer: \(model.preferences.wirelessVideoBufferMs) ms",
                        value: $model.preferences.wirelessVideoBufferMs, in: 0...200, step: 25)
                Text("A small buffer smooths uneven Wi-Fi frame delivery by adding playback delay. Default: 50 ms; 0 ms prioritizes latency. Applies next session to wireless ADB and automatic Bluetooth / Wi-Fi sessions.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.preferences.transport == .bluetoothClassic {
                    Text("These targets apply after the Wi-Fi handoff on your next session. Hybrid sessions keep regular HEVC throughout; input stays on BLE. Direct ADB sessions use their own selected codec and ADB input.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(model.preferences.transport == .wifiAware)
            Section("Input") {
                Picker("Scrolling", selection: $model.preferences.scrollMode) {
                    ForEach(ScrollMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Keyboard", selection: $model.preferences.keyboard) {
                    ForEach(KeyboardMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show physical touches on Android", isOn: $model.preferences.showTouches)
                Text("Touch-style scrolling is handled inside the mirror and does not require Accessibility permission. Smart text input gives the best clipboard behavior; UHID behaves like a physical keyboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(model.preferences.transport != .adb)
        }.formStyle(.grouped).padding(.vertical, 12)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                backgroundLogin.refresh()
            }

    }
}

struct WirelessView: View {
    @EnvironmentObject private var model: MirrorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "wifi").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Wireless debugging").font(.title2.bold())
                    Text("Android 11 or newer").foregroundStyle(.secondary)
                }
            }
            Text("On Android, open Developer options → Wireless debugging. Choose “Pair device with pairing code,” then enter the address and code below.")
                .fixedSize(horizontal: false, vertical: true)
            GroupBox("Pair once") {
                Grid(alignment: .leading, verticalSpacing: 10) {
                    GridRow { Text("Pair address"); TextField("192.168.1.20:37123", text: $model.pairingAddress) }
                    GridRow { Text("Pairing code"); SecureField("123456", text: $model.pairingCode) }
                }.padding(8)
                Button("Pair") { model.pair() }.buttonStyle(.borderedProminent).disabled(model.pairingAddress.isEmpty || model.pairingCode.isEmpty)
            }
            GroupBox("Connect") {
                HStack {
                    TextField("IP address and port", text: $model.connectAddress)
                    Button("Connect") { model.connect() }.buttonStyle(.borderedProminent).disabled(model.connectAddress.isEmpty)
                }.padding(8)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 520)
    }
}
