import Intents
import SwiftUI

@MainActor
private final class ClipboardConnectionStatus: NSObject, ObservableObject {
    @Published var focusText = "Waiting for the background receiver…"
    @Published var mediaText = "Waiting for the background receiver…"
    @Published var text = "Waiting for the background receiver…"
    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receive(_:)),
            name: Notification.Name("app.droidmirror.receiverStatus"), object: nil)
    }
    @objc private func receive(_ event: Notification) {
        if let status = event.userInfo?["focus"] as? String { focusText = status }
        if let status = event.userInfo?["media"] as? String { mediaText = status }
        if let status = event.userInfo?["clipboard"] as? String { text = status }
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self) }
}

struct SettingsView: View {
    @StateObject private var cameraExtension = CameraExtensionActivation()
    @AppStorage("DroidMirror.camera.facing") private var cameraFacing = "front"
    @EnvironmentObject private var model: MirrorModel
    @AppStorage("DroidMirror.clipboard.enabled") private var clipboardMirroring = false
    @AppStorage("DroidMirror.hotspot.automatic") private var automaticHotspot = false
    @AppStorage("DroidMirror.media.enabled") private var mediaSync = false
    @AppStorage("DroidMirror.media.volumeKeys") private var mediaVolumeKeys = false
    @AppStorage("DroidMirror.unlock.requireTouchID") private var requireTouchID = false
    @StateObject private var clipboardStatus = ClipboardConnectionStatus()
    @StateObject private var backgroundLogin = BackgroundLoginService()

    @AppStorage("DroidMirror.focus.macToPhone") private var focusToPhone = false
    @AppStorage("DroidMirror.focus.phoneToMac") private var focusFromPhone = false
    @AppStorage("DroidMirror.focus.onShortcut") private var focusOnShortcut = ""
    @AppStorage("DroidMirror.focus.offShortcut") private var focusOffShortcut = ""
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
            connectionSettings
            Section("Focus sync") {
                Toggle("Sync Mac Focus to phone Do Not Disturb", isOn: $focusToPhone)
                    .onChange(of: focusToPhone) { _, enabled in
                        if enabled { INFocusStatusCenter.default.requestAuthorization { _ in } }
                    }
                Toggle("Sync phone Do Not Disturb to Mac Shortcuts", isOn: $focusFromPhone)
                TextField("Focus on Shortcut name", text: $focusOnShortcut)
                TextField("Focus off Shortcut name", text: $focusOffShortcut)
                Text(clipboardStatus.focusText).font(.caption).foregroundStyle(.secondary)
                Text("Enable matching directions and notification policy access in Android Bridge Settings. Mac Focus requires Share Focus Status permission. Configure two Shortcuts with Set Focus actions; names are passed directly to shortcuts run. Unknown status leaves the phone unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Phone unlock") {
                Toggle("Require Touch ID to unlock phone", isOn: $requireTouchID)
                    .disabled(model.isMirroring || model.isStarting || (!requireTouchID && !PhoneUnlockAuthentication.available))
                Text("Uses Touch ID before entering the PIN saved on Android. Cancel to mirror the lock screen and unlock manually. No Mac password or Apple Watch fallback. Applies to new sessions.")
                    .font(.caption).foregroundStyle(.secondary)
                if !PhoneUnlockAuthentication.available {
                    Text("Touch ID is unavailable or locked out. Set up Touch ID in System Settings. In clamshell mode, use a supported external Touch ID keyboard or open the lid; otherwise unlock Android manually.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Phone Camera") {
                Button("Enable Mac Camera Extension…") { cameraExtension.activate() }
                    .disabled(model.isMirroring || model.isStarting || !CameraExtensionActivation.bundled)
                Picker("Camera", selection: $cameraFacing) {
                    Text("Front").tag("front")
                    Text("Back").tag("back")
                }
                Text("Wi-Fi: 1280 × 720 at 30 fps, 3 Mbps. Bluetooth: 320 × 240 at 15 fps, 128 kbps. Quality switches automatically during calls.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(cameraExtension.status).font(.caption).foregroundStyle(.secondary)
                Text("Appears while BLE is connected. The phone camera turns on only while a Mac app uses it. Arm Phone Camera in Android Bridge Settings first. Uses direct encrypted IP when available, otherwise Bluetooth.")
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
            ActivityAppsView()
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
                Toggle("Volume keys control phone media", isOn: $mediaVolumeKeys)
                    .disabled(!mediaSync)
                    .onChange(of: mediaVolumeKeys) { _, _ in
                        UserDefaults.standard.synchronize()
                        DistributedNotificationCenter.default().postNotificationName(
                            Notification.Name("app.droidmirror.mediaConfiguration"), object: nil,
                            userInfo: nil, deliverImmediately: true)
                    }
                Text("While phone media appears in macOS Now Playing, the keyboard volume and mute keys adjust the phone instead of the Mac, in any app, and show the phone's volume. Allow DroidMirror Notifications under Privacy & Security → Accessibility.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Show phone media in macOS Now Playing and Apple Music on your phone. Syncs track details and playback controls over paired Bluetooth; audio stays on its original device. Allow notification access on Android and Music Automation permission on Mac. Local playback takes priority on each device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            mirrorPreferences
        }.formStyle(.grouped).padding(.vertical, 12)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                backgroundLogin.refresh()
            }

    }

    private var connectionSettings: some View {
            Section("Connection") {
                Button("Set up a phone…") { OnboardingWindowController.shared.show(model: model) }
                Text("Follow the guided setup for Bluetooth, phone permissions and your first mirror.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Connection", selection: $model.preferences.transport) {
                    ForEach(MirrorTransport.allCases) { Text($0.label).tag($0) }
                }.disabled(model.isMirroring || model.isStarting || model.isPairingBluetooth)
                if model.preferences.transport == .bluetoothClassic {
                    Picker("Paired phone", selection: $model.selectedID) {
                        Text("Select a phone").tag(String?.none)
                        ForEach(model.devices) { Text($0.displayName).tag(Optional($0.id)) }
                    }.disabled(model.isMirroring || model.isStarting || model.isPairingBluetooth)
                    QRPairingButton()
                    HStack {
                        SecureField("BLE pairing code from Android", text: $model.bluetoothPairingCode)
                        Button(model.isPairingBluetooth ? "Pairing…" : "Pair Mac") {
                            model.bluetoothPairingCode = model.bluetoothPairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
                            model.pairBluetooth()
                        }
                            .disabled(model.selectedDevice?.isBluetooth != true || model.bluetoothPairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isPairingBluetooth)
                    }.disabled(model.isMirroring || model.isStarting)
                    Text("Scan this Mac’s QR code from DroidMirror on Android, or enter the phone’s pairing code here. Pairing also enables notification forwarding and ADB discovery.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Refresh") { model.refreshDevices() }.disabled(model.isRefreshing || model.isStarting || model.isMirroring || model.isPairingBluetooth)
                        Button(model.isStarting ? "Cancel" : (model.isMirroring ? "Stop" : "Mirror")) {
                            if model.isMirroring || model.isStarting { model.stop() } else { model.start() }
                        }
                        .disabled(!model.isMirroring && !model.isStarting && (model.isPairingBluetooth || model.selectedDevice?.isOnline != true))
                        .help(model.isStarting ? "Cancel the connection attempt" : mirrorActionHelp(model))
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
                if model.preferences.transport == .bluetoothClassic {
                    Text("Automatic chooses the best available video connection; mouse and keyboard use Bluetooth. Authorize Shizuku and enable the Android background bridge once.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("How Automatic works") {
                        Text("USB accessory video is preferred with no added buffer. Otherwise, direct LAN and Bluetooth connect in parallel; Bluetooth video upgrades when a faster path is ready.")
                        Text("Direct LAN or Tailscale is tried before paired wireless ADB. ADB fallback needs Wireless debugging and one-time pairing; relays and public discovery are disabled.")
                        Text("Bluetooth video starts at 320p, up to 15 fps and 128 kbps using HEVC. Audio forwarding requires an ADB session.")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if model.preferences.transport != .wifiAware {
                    Toggle("Start mirroring automatically", isOn: $model.preferences.autoStart)
                }
            }
    }

    @ViewBuilder
    private var mirrorPreferences: some View {
            if model.preferences.transport != .wifiAware {
                Section("iPhone-like behavior") {
                    if model.preferences.transport == .adb {
                        Toggle("Keep phone screen off", isOn: $model.preferences.turnDeviceScreenOff)
                        Toggle("Keep the device awake while connected", isOn: $model.preferences.stayAwake)
                        Toggle("Forward audio to Mac", isOn: $model.preferences.forwardAudio)
                    }
                    Toggle("Keep mirror above other windows", isOn: $model.preferences.alwaysOnTop)
                }
                Section("Video quality") {
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
                    Text("A buffer smooths wireless video at the cost of delay. Use 0 ms for lowest latency; the default is 50 ms.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.preferences.transport == .bluetoothClassic {
                        Text("These targets apply when Automatic uses a faster video path. Bluetooth fallback uses lower quality and HEVC.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Input") {
                    Picker("Scrolling", selection: $model.preferences.scrollMode) {
                        ForEach(ScrollMode.allCases) { Text($0.label).tag($0) }
                    }
                    if model.preferences.transport == .adb {
                        Picker("Keyboard", selection: $model.preferences.keyboard) {
                            ForEach(KeyboardMode.allCases) { Text($0.label).tag($0) }
                        }
                        Toggle("Show physical touches on Android", isOn: $model.preferences.showTouches)
                        Text("Smart text input supports clipboard integration; UHID acts like a physical keyboard.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Touch-style scrolling supports Android gestures without Accessibility permission.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Changes apply the next time the mirror starts.")
                .font(.caption).foregroundStyle(.secondary)
    }
}

struct WirelessView: View {
    @EnvironmentObject private var model: MirrorModel
    @Environment(\.dismiss) private var dismiss

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
                Button("Pair") {
                    model.pairingAddress = trimmed(model.pairingAddress)
                    model.pairingCode = trimmed(model.pairingCode)
                    model.pair()
                }.buttonStyle(.borderedProminent)
                    .disabled(trimmed(model.pairingAddress).isEmpty || trimmed(model.pairingCode).isEmpty || model.isRefreshing)
            }
            GroupBox("Connect") {
                HStack {
                    TextField("IP address and port", text: $model.connectAddress)
                    Button("Connect") {
                        model.connectAddress = trimmed(model.connectAddress)
                        model.connect()
                    }.buttonStyle(.borderedProminent)
                        .disabled(trimmed(model.connectAddress).isEmpty || model.isRefreshing)
                }.padding(8)
            }
            Text("Use IP address:port, for example 192.168.1.20:37123. Pairing and connection ports differ; use the connection address on the main Wireless debugging screen after pairing.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.isRefreshing {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing devices")
                }
                Text(model.status).font(.callout).textSelection(.enabled)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 520)
    }
}
