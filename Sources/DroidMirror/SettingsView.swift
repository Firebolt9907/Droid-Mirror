import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: MirrorModel

    var body: some View {
        Form {
            Section("Connection") {
                Picker("Transport", selection: $model.preferences.transport) {
                    ForEach(MirrorTransport.allCases) { Text($0.label).tag($0) }
                }.disabled(model.isMirroring || model.isStarting)
                if model.preferences.transport == .bluetoothClassic {
                    Picker("Paired phone", selection: $model.selectedID) {
                        Text("Select a phone").tag(String?.none)
                        ForEach(model.devices) { Text($0.displayName).tag(Optional($0.id)) }
                    }.disabled(model.isMirroring || model.isStarting)
                    HStack {
                        SecureField("BLE pairing code from Android", text: $model.bluetoothPairingCode)
                        Button("Pair Mac") { model.pairBluetooth() }
                            .disabled(model.selectedDevice == nil || model.bluetoothPairingCode.isEmpty)
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
                Text("Bluetooth starts at 320p, up to 15 fps, and a 128 kbps HEVC ceiling, then upgrades video over Iroh to the picture settings below. Video tries direct LAN first, then an already-paired wireless ADB connection, then stays on Bluetooth. Relays and public Iroh discovery are disabled. Wireless ADB fallback requires Wireless debugging and one-time ADB pairing. Mouse, keyboard and navigation stay on Bluetooth. Audio requires a direct ADB session. Authorize Shizuku and enable the background bridge once in the Android companion.")
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
        .alert("DroidMirror", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
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
