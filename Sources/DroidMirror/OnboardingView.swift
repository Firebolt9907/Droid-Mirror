import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private weak var model: MirrorModel?

    static func needsFirstRun(model: MirrorModel) -> Bool {
        !UserDefaults.standard.bool(forKey: "DroidMirror.onboarding.completed") &&
        (UserDefaults.standard.bool(forKey: "DroidMirror.onboarding.started") ||
         (model.preferences.bluetoothDeviceID == nil &&
          !UserDefaults.standard.bool(forKey: "DroidMirror.BLE.enabled")))
    }

    func show(model: MirrorModel) {
        self.model = model
        model.isOnboarding = true
        UserDefaults.standard.set(true, forKey: "DroidMirror.onboarding.started")
        if window == nil {
            let content = OnboardingView().environmentObject(model)
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.title = "Set up DroidMirror"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.deferAutomaticStartAfterSetup()
        model?.isOnboarding = false
        model?.bluetoothPairingCode = ""
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var model: MirrorModel
    @State private var step = min(3, max(0, UserDefaults.standard.integer(forKey: "DroidMirror.onboarding.step")))
    @State private var existingPairingID: String?
    @State private var pairingCheckError: String?
    @State private var didVerifyMirror = false
    private let titles = ["Connect Bluetooth", "Prepare your phone", "Pair DroidMirror", "Try your first mirror"]

    private var busy: Bool { model.isStarting || model.isMirroring || model.isPairingBluetooth }
    private var codeSaved: Bool {
        guard let id = model.selectedID else { return false }
        return existingPairingID == id || model.savedPairingDeviceID == id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your phone, on your Mac").font(.title.bold())
                    Text("One setup. Start future sessions from your Mac.").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                ForEach(titles.indices, id: \.self) { index in
                    Capsule().fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.18)).frame(height: 4)
                }
            }.accessibilityLabel("Step \(step + 1) of 4")
            Text("STEP \(step + 1) OF 4").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(titles[step]).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case 0: bluetoothStep
                    case 1: phoneStep
                    case 2: pairingStep
                    default: mirrorStep
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Set up later") { OnboardingWindowController.shared.close() }
                    .disabled(model.isPairingBluetooth)
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }.disabled(busy)
                }
                if step < 3 {
                    Button(step == 1 ? "Phone is prepared" : "Continue") { step += 1 }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || (step == 0 && model.selectedDevice?.isBluetooth != true) || (step == 2 && !codeSaved))
                } else {
                    Button(didVerifyMirror ? "Finish setup" : "Mirror my phone") {
                        if didVerifyMirror { OnboardingWindowController.shared.close() }
                        else { model.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!didVerifyMirror && (busy || model.selectedDevice?.isBluetooth != true || !codeSaved))
                }
            }
        }
        .padding(28).frame(width: 600, height: 610)
        .task(id: model.selectedID) { await checkPairing() }
        .onChange(of: step) { _, value in
            UserDefaults.standard.set(value, forKey: "DroidMirror.onboarding.step")
        }
        .onChange(of: model.verifiedBluetoothDeviceID) { _, deviceID in
            if let deviceID, deviceID == model.selectedID && step == 3 {
                didVerifyMirror = true
                UserDefaults.standard.set(true, forKey: "DroidMirror.onboarding.completed")
            }
        }
    }

    private var bluetoothStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep both devices nearby. On your phone, open Settings → Bluetooth and pair this Mac. Accept the matching system code on both devices.")
            Button("Open Mac Bluetooth settings") { openSettings("com.apple.Bluetooth") }
            Text("Then select the same phone here. System Bluetooth pairing and DroidMirror’s private code are separate steps.")
                .foregroundStyle(.secondary)
            Picker("Your Android phone", selection: $model.selectedID) {
                Text("Select your phone").tag(String?.none)
                ForEach(model.devices.filter(\.isBluetooth)) { Text($0.displayName).tag(Optional($0.id)) }
            }.disabled(busy || model.preferences.transport != .bluetoothClassic)
            HStack {
                Button("Find paired phones") {
                    model.preferences.transport = .bluetoothClassic
                    model.refreshDevices()
                }.disabled(busy || model.isRefreshing)
                if model.isRefreshing { ProgressView().controlSize(.small) }
            }
            Text(model.devices.isEmpty ? "No phones found yet. Finish system Bluetooth pairing, then find paired phones again." : "Choose the same Mac in the phone app when asked.")
                .font(.callout).foregroundStyle(.secondary)
            if model.preferences.transport != .bluetoothClassic {
                Text("Choose Find paired phones to use Automatic (Bluetooth → Wi-Fi) for this setup.").font(.callout)
            }
            if busy { Text("Finish or stop the current connection before changing pairing.").foregroundStyle(.secondary) }
            if !model.isRefreshing { Text(model.status).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var phoneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            instruction("1", "Open DroidMirror on Android", "The phone app walks through the matching setup steps. Allow Nearby devices so it can connect over Bluetooth.")
            instruction("2", "Start and authorize Shizuku", "Shizuku lets DroidMirror control and mirror your phone. Follow Set up Shizuku on the phone, start it, then tap Authorize Shizuku and allow DroidMirror.")
            instruction("3", "Select this Mac", "Choose this Mac in the phone app’s paired device list. On the next screen you’ll save its private DroidMirror code here.")
            Text("After a phone restart, Shizuku may need to be started again. The phone checks its status when you return to setup.")
                .font(.callout).foregroundStyle(.secondary)
            Text("The Mac cannot check these phone settings until it connects. Continue when the phone shows Shizuku is authorized.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var pairingStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On your phone, tap Show pairing code, then enable the background bridge. Enter that code below for \(model.selectedDevice?.displayName ?? "your selected phone").")
            Text("This is the long private code from DroidMirror, separate from the short system Bluetooth code. Keep it private.")
                .font(.callout).foregroundStyle(.secondary)
            SecureField("Private DroidMirror pairing code", text: $model.bluetoothPairingCode)
                .textFieldStyle(.roundedBorder).disabled(busy)
            HStack {
                Button("Save pairing code") { model.pairBluetooth() }
                    .disabled(busy || model.bluetoothPairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.isPairingBluetooth { ProgressView().controlSize(.small) }
            }
            if let error = model.pairingError ?? pairingCheckError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if codeSaved {
                Label("Code saved securely on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Your first mirror attempt will verify that the phone has the same code.").foregroundStyle(.secondary)
            }
        }
    }

    private var mirrorStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if didVerifyMirror {
                Label("Your first mirror connected", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                Text("Next time, keep Bluetooth on, Shizuku running and the phone bridge enabled. Lock your phone, then press Mirror on your Mac.")
            } else {
                instruction("1", "Enable the background bridge", "On the phone’s Pair DroidMirror step, tap Enable background bridge. Leave it enabled for future sessions.")
                instruction("2", "Lock your phone", "Press the phone’s power button before starting. Mirroring waits while the phone is unlocked and in use.")
                instruction("3", "Press Mirror my phone", "Bluetooth starts the connection. On the same Wi-Fi, video can upgrade automatically. Wireless debugging is optional.")
            }
            if model.isStarting { ProgressView("Connecting to your phone…") }
            Text(model.status).font(.callout).foregroundStyle(.secondary)
            if let error = model.errorMessage {
                let failure = ConnectionFailure.recognize(error)
                GroupBox(failure.title) {
                    Text(failure.message).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            DisclosureGroup("Still having trouble?") {
                Text("Check that both apps are the matching version and that you chose the same phone and Mac. If the code was rejected, go Back and save the code again. After updating either app during a session, let the old session end, reopen the apps and reconnect. Notification forwarding and wireless ADB are optional; neither is required for your first Bluetooth mirror.")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }

    private func instruction(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.headline).foregroundStyle(.tint).frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func checkPairing() async {
        existingPairingID = nil
        pairingCheckError = nil
        didVerifyMirror = false
        model.bluetoothPairingCode = ""
        model.pairingError = nil
        guard let device = model.selectedDevice, device.isBluetooth else { step = 0; return }
        guard let helper = ClassicBluetoothTransport.helperPath else {
            pairingCheckError = "Bluetooth helper missing. Install a complete DroidMirror app build, then reopen setup."
            return
        }
        do {
            let result = try await ProcessRunner.output(helper, ["--has-pairing", device.id], timeout: 5)
            guard !Task.isCancelled, model.selectedID == device.id else { return }
            if result.trimmingCharacters(in: .whitespacesAndNewlines) == "paired" { existingPairingID = device.id }
        } catch {
            guard !Task.isCancelled else { return }
            pairingCheckError = "Could not check the saved code. You can save the phone’s code again."
        }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}
