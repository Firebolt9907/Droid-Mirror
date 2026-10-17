import AppKit
import ApplicationServices
import Foundation

@MainActor
final class MirrorModel: ObservableObject {
    static let shared = MirrorModel()

    @Published var devices: [AndroidDevice] = []
    @Published var selectedID: String? {
        didSet {
            MirrorRenderer.shared.configure(device: selectedDevice)
            if !restoringBluetoothSelection, preferences.transport == .bluetoothClassic,
               let device = selectedDevice, device.isBluetooth,
               preferences.bluetoothDeviceID != device.id {
                preferences.bluetoothDeviceID = device.id
            }
        }
    }
    @Published var isRefreshing = false
    @Published var isMirroring = false
    @Published var isDeviceLocked = false
    @Published var status = "Connect an Android device to begin"
    @Published var errorMessage: String? {
        didSet {
            guard let errorMessage else { return }
            PhoneWindowController.shared.present(title: "Connection failed", message: errorMessage, model: self)
        }
    }
    @Published var sessionNoticeTitle = "Ready to connect"
    @Published var sessionNoticeMessage = "Keep your phone locked and nearby."
    @Published var log = ""
    @Published var preferences: MirrorPreferences {
        didSet {
            savePreferences()
            if preferences.transport != oldValue.transport, !isMirroring, !isStarting {
                devices = []
                selectedID = preferences.transport == .bluetoothClassic ? preferences.bluetoothDeviceID : nil
                autoStartAttemptedFor = nil
                refreshDevices()
            }
        }
    }
    @Published var pairingAddress = ""
    @Published var pairingCode = ""
    @Published var connectAddress = ""
    @Published var bluetoothPairingCode = ""

    func pairBluetooth() {
        guard let device = selectedDevice, device.isBluetooth, !isStarting, !isMirroring else { return }
        let code = bluetoothPairingCode
        Task {
            do {
                try await ClassicBluetoothTransport.pair(address: device.id, code: code)
                bluetoothPairingCode = ""
                status = "Mirroring and notifications paired. Allow notification forwarding in Android’s DroidMirror app."
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private var connectionCancelled = false
    private var stoppedForInactivity = false
    private var startTask: Task<Void, Never>?
    private var mirrorProcess: MirrorSession?
    private let classicBluetooth = ClassicBluetoothTransport()
    @Published private(set) var isStarting = false
    private var sessionIsBluetooth = false
    private var phoneTakenOver = false
    private var sessionEndedOnPhone = false
    private var refreshTimer: Timer?
    private var lockPollTimer: Timer?
    private var toolbarPositionTimer: Timer?
    private var isCheckingLock = false
    private var autoStartAttemptedFor: String?
    private var restoringBluetoothSelection = false
    private var originalAutoRotate: String?
    private var originalUserRotation: String?
    private var originalAODSettings: [String: String] = [:]
    private var originalLockAfterTimeout: String?
    private var rotationSerial: String?
    private var isTerminatingApplication = false

    var selectedDevice: AndroidDevice? {
        devices.first { $0.id == selectedID }
    }

    var adbPath: String? { ToolLocator.find("adb") }
    var scrcpyPath: String? { MirrorRenderer.executablePath }

    init() {
        preferences = MirrorPreferencesStore.load()
        selectedID = preferences.transport == .bluetoothClassic ? preferences.bluetoothDeviceID : nil
        refreshTimer = .scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard self?.isMirroring == false else { return }
                self?.refreshDevices(silently: true)
            }
        }
    }

    private func savePreferences() {
        MirrorPreferencesStore.save(preferences)
    }

    @Published private(set) var wifiAwareStatus = "Check this Mac for Wi-Fi Aware support."
    private var wifiAwareChecked = false

    func checkWiFiAware() {
        guard !isRefreshing, !isMirroring, !isStarting else { return }
        isRefreshing = true
        wifiAwareChecked = true
        wifiAwareStatus = "Checking Wi-Fi Aware…"
        Task {
            defer { isRefreshing = false }
            do {
                let readiness = try await WiFiAwareTransport.probe()
                wifiAwareStatus = readiness.message
            } catch {
                wifiAwareStatus = error.localizedDescription
            }
            if preferences.transport == .wifiAware { status = wifiAwareStatus }
        }
    }

    func refreshDevices(silently: Bool = false) {
        guard !isStarting else { return }
        if preferences.transport == .wifiAware {
            devices = []
            selectedID = nil
            status = wifiAwareStatus
            if !silently || !wifiAwareChecked { checkWiFiAware() }
            return
        }
        if preferences.transport == .bluetoothClassic {
            refreshBluetoothDevices(silently: silently)
            return
        }
        guard !isRefreshing, let adbPath else {
            if self.adbPath == nil { status = "adb not found — install scrcpy with Homebrew" }
            return
        }
        isRefreshing = true
        Task {
            do {
                let text = try await ProcessRunner.output(adbPath, ["devices", "-l"])
                guard preferences.transport == .adb else { isRefreshing = false; return }
                let parsed = parseDevices(text)
                devices = parsed
                if selectedID == nil || !parsed.contains(where: { $0.id == selectedID }) {
                    selectedID = parsed.first(where: \ .isOnline)?.id ?? parsed.first?.id
                }
                if !isMirroring {
                    status = parsed.isEmpty ? "Connect an Android device to begin" : "Ready to mirror"
                }
                if parsed.first(where: \ .isOnline) == nil {
                    autoStartAttemptedFor = nil
                } else if preferences.autoStart, mirrorProcess == nil,
                          let online = parsed.first(where: \ .isOnline),
                          autoStartAttemptedFor != online.id {
                    selectedID = online.id
                    autoStartAttemptedFor = online.id
                    start()
                }
            } catch {
                if !silently && !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            isRefreshing = false
        }
    }

    private func parseDevices(_ text: String) -> [AndroidDevice] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(whereSeparator: \ .isWhitespace).map(String.init)
            guard parts.count >= 2 else { return nil }
            let fields = Dictionary(uniqueKeysWithValues: parts.dropFirst(2).compactMap { token -> (String, String)? in
                guard let colon = token.firstIndex(of: ":") else { return nil }
                return (String(token[..<colon]), String(token[token.index(after: colon)...]))
            })
            return AndroidDevice(
                id: parts[0], state: parts[1], model: fields["model"] ?? "",
                product: fields["product"] ?? "", transport: fields["transport_id"] ?? ""
            )
        }
    }

    private func refreshBluetoothDevices(silently: Bool) {
        guard !isRefreshing, !isMirroring, !isStarting else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            do {
                let paired = try await ClassicBluetoothTransport.pairedDevices()
                guard preferences.transport == .bluetoothClassic else { return }
                devices = paired
                restoringBluetoothSelection = true
                if selectedID == nil || !paired.contains(where: { $0.id == selectedID }) {
                    if let remembered = preferences.bluetoothDeviceID {
                        selectedID = paired.first(where: { $0.id == remembered })?.id
                    } else {
                        selectedID = paired.first?.id
                    }
                }
                restoringBluetoothSelection = false
                status = paired.isEmpty ? "Pair your phone in Bluetooth settings" : "Ready to mirror via Bluetooth"
                if preferences.autoStart, let device = selectedDevice,
                   device.id == preferences.bluetoothDeviceID,
                   autoStartAttemptedFor != device.id {
                    autoStartAttemptedFor = device.id
                    start()
                }
            } catch {
                status = error.localizedDescription
                if !silently && !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    func start() {
        guard mirrorProcess == nil, !isStarting else { return }
        if preferences.transport == .wifiAware {
            errorMessage = "Wi-Fi Aware direct mirroring is not available yet. Check support in connection settings."
            return
        }
        errorMessage = nil
        connectionCancelled = false
        stoppedForInactivity = false
        isStarting = true
        status = "Connecting to \(selectedDevice?.displayName ?? "your phone")…"
        PhoneWindowController.shared.present(title: "Connecting…", message: "Keep your phone locked and nearby.", model: self, connecting: true)
        startTask = Task {
            defer {
                isStarting = false
                startTask = nil
                if Task.isCancelled {
                    status = "Connection cancelled"
                    if errorMessage == nil && !isTerminatingApplication {
                        self.presentStoppedMirror()
                    }
                }
            }
            guard !Task.isCancelled else { return }
            if preferences.transport == .bluetoothClassic {
                await startBluetooth()
            } else {
                await startAfterADBCheck()
            }
        }
    }

    private func startBluetooth() async {
        guard let device = selectedDevice, device.isBluetooth, scrcpyPath != nil else {
            errorMessage = "Select a paired Bluetooth phone and install the bundled scrcpy client."
            return
        }
        preferences.bluetoothDeviceID = device.id
        autoStartAttemptedFor = device.id
        status = "Connecting over Bluetooth Classic…"
        phoneTakenOver = false
        sessionEndedOnPhone = false
        let wifiMaxSize = preferences.maxSize
        let wifiFPS = preferences.maxFPS
        let wifiBitRate = preferences.bitRateMbps
        classicBluetooth.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .wirelessActive:
                let resolution = wifiMaxSize == 0 ? "native resolution" : "\(wifiMaxSize) px"
                self.status = "Peer video · \(resolution) · up to \(wifiFPS) fps · \(wifiBitRate) Mbps target"
            case .wirelessRecovering:
                self.status = "Peer video disconnected · resuming Bluetooth…"
            case .bluetoothActive:
                self.status = "Bluetooth · up to 15 fps · 128 kbps maximum"
            case .streamStarted: break
            case .phoneOn, .phoneLocalUse:
                if !self.phoneTakenOver {
                    self.phoneTakenOver = true
                    SessionNotifications.shared.localUse(restored: event == .phoneOn)
                }
            case .phoneInUse:
                self.errorMessage = PhoneUsePolicy.errorMessage
                self.status = "Phone in use"
            case .captureFailed:
                self.errorMessage = "HEVC capture unavailable. Authorize Shizuku, enable Mac connections, and check that this phone supports HEVC encoding."
            case .sessionEnded:
                self.sessionEndedOnPhone = true
                self.status = "Remote session ended"
            }
        }
        do {
            let ports = try await classicBluetooth.connect(address: device.id, wirelessMaxSize: wifiMaxSize,
                                                           wirelessFPS: wifiFPS, wirelessBitRate: wifiBitRate * 1_000_000)
            guard !Task.isCancelled, preferences.transport == .bluetoothClassic, !isTerminatingApplication else {
                classicBluetooth.stop()
                return
            }
            let process = MirrorSession()
            process.arguments = ["--external-video-port=\(ports.video)", "--external-control-port=\(ports.control)", "--window-title=DroidMirror — \(device.displayName)",
                                 "--window-borderless", "--window-width=430", "--video-buffer=\(preferences.wirelessVideoBufferMs)",
                                 "--no-mouse-hover",
                                 "--mouse-bind=-hsn:-+++",
                                 "--no-audio", "--pause-on-exit=false"]
            process.arguments.append(contentsOf: PhoneWindowController.shared.videoPositionArguments)
            if preferences.alwaysOnTop { process.arguments.append("--always-on-top") }
            // Share the native chrome, with controls sent through scrcpy/BLE.
            var environment = ProcessInfo.processInfo.environment
            for key in ["ADB", "ANDROID_SERIAL", "DROIDMIRROR_SERIAL", "DYLD_INSERT_LIBRARIES"] {
                environment.removeValue(forKey: key)
            }
            environment["DROIDMIRROR_TRANSPORT"] = "bluetooth-classic"
            environment["DROIDMIRROR_CONNECTION_LABEL"] = "Bluetooth controls"
            configureMirrorUI(environment: &environment)
            process.environment = environment
            process.terminationHandler = { [weak self] child in
                let clientOutput = child.diagnostic
                Task { @MainActor in
                    guard let self else { return }
                    let bridgeOutput = self.classicBluetooth.diagnostic
                    self.classicBluetooth.stop()
                    self.mirrorProcess = nil
                    self.isMirroring = false
                    self.sessionIsBluetooth = false
                    self.status = "Mirror disconnected"
                    if !self.phoneTakenOver && self.errorMessage == nil {
                        self.presentStoppedMirror()
                    }
                    if child.terminationStatus != 0 && !self.phoneTakenOver && !self.sessionEndedOnPhone && self.errorMessage == nil && !self.connectionCancelled {
                        let details = (bridgeOutput + "\n" + clientOutput).trimmingCharacters(in: .whitespacesAndNewlines)
                        self.log = details
                        self.errorMessage = "Bluetooth video stopped (exit \(child.terminationStatus)).\n\n\(details)"
                    }
                }
            }
            try process.run()
            mirrorProcess = process
            sessionIsBluetooth = true
            isMirroring = true
            status = "Bluetooth · 320p · up to 15 fps · 128 kbps maximum"
        } catch is CancellationError {
            status = "Bluetooth connection cancelled"
        } catch {
            classicBluetooth.stop()
            errorMessage = error.localizedDescription
            status = "Bluetooth connection failed"
        }
    }

    private func startAfterADBCheck() async {
        guard mirrorProcess == nil, let device = selectedDevice, device.isOnline else {
            if selectedDevice?.isOnline == false { errorMessage = "Authorize USB debugging on the Android device, then refresh." }
            return
        }
        guard let scrcpyPath, let adbPath else {
            errorMessage = "scrcpy was not found. Install it with: brew install scrcpy"
            return
        }

        let process = MirrorSession()
        process.arguments = scrcpyArguments(for: device, forwardAudio: preferences.forwardAudio)
        var environment = ProcessInfo.processInfo.environment
        let toolDirectories = [
            URL(fileURLWithPath: adbPath).deletingLastPathComponent().path,
            URL(fileURLWithPath: scrcpyPath).deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let inheritedPath = environment["PATH"].map { [$0] } ?? []
        environment["PATH"] = (toolDirectories + inheritedPath).joined(separator: ":")
        environment["ADB"] = adbPath
        environment["DROIDMIRROR_SERIAL"] = device.id
        environment["DROIDMIRROR_TRANSPORT"] = "adb"
        environment["DROIDMIRROR_CONNECTION_LABEL"] = device.isWireless ? "Wi-Fi" : "USB"
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("DroidMirror-start-\(UUID().uuidString)")
        environment["DROIDMIRROR_START_GATE"] = gate.path
        configureMirrorUI(environment: &environment)
        process.environment = environment
        process.terminationHandler = { [weak self] process in
            let output = process.diagnostic
            Task { @MainActor in
                guard let self else { return }
                if self.isStarting { self.startTask?.cancel() }
                try? FileManager.default.removeItem(at: gate)
                self.log = output
                let localUse = output.contains("DROIDMIRROR_LOCAL_USE")
                if localUse { SessionNotifications.shared.localUse(restored: true) }
                await self.restoreDeviceStateAndLock(preserveLockScreen: localUse)
                self.stopLockMonitoring()
                self.stopToolbarPositioning()
                self.mirrorProcess = nil
                self.isMirroring = false
                self.isDeviceLocked = false
                self.status = localUse ? "Phone in use" : "Mirror disconnected"
                if !localUse && self.errorMessage == nil {
                    self.presentStoppedMirror()
                }
                if process.terminationStatus != 0 && !localUse && self.errorMessage == nil && !self.connectionCancelled {
                    self.errorMessage = output.split(separator: "\n").suffix(4).joined(separator: "\n").nilIfEmpty ?? "scrcpy exited with code \(process.terminationStatus)"
                }

            }
        }
        var approved = false
        defer {
            if !approved {
                try? FileManager.default.removeItem(at: gate)
                if process.isRunning { process.terminate() }
            }
        }
        do {
            try process.run()
            mirrorProcess = process
            do {
                _ = try await ProcessRunner.output(adbPath, ["start-server"])
            } catch {
                guard !Task.isCancelled else { return }
                let detail = error.localizedDescription
                status = "adb could not start"
                if detail.localizedCaseInsensitiveContains("operation not permitted") {
                    errorMessage = "macOS blocked adb from opening its local connection. Quit DroidMirror and launch it from Finder (not from the Codex preview link), then try again.\n\n\(detail)"
                } else {
                    errorMessage = "Could not start adb:\n\(detail)"
                }
                return
            }

            guard !Task.isCancelled, process.isRunning else { return }
            do {
                let power = try await ProcessRunner.output(adbPath, ["-s", device.id, "shell", "dumpsys", "power"], timeout: 5)
                let window = try await ProcessRunner.output(adbPath, ["-s", device.id, "shell", "dumpsys", "window", "policy"], timeout: 5)
                guard !Task.isCancelled, process.isRunning else { return }
                guard let inUse = PhoneUsePolicy.isInUse(power: power, windowPolicy: window) else {
                    throw RunnerError.failed("Could not check whether the phone is in use. Try again.")
                }
                if inUse {
                    status = "Phone in use"
                    errorMessage = PhoneUsePolicy.errorMessage
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                status = "Could not check phone availability"
                errorMessage = error.localizedDescription
                return
            }

            guard !Task.isCancelled, !isTerminatingApplication else { return }
            await lockDeviceToPortrait(adbPath: adbPath, serial: device.id)
            let androidAudioWasAlreadyPlaying = preferences.forwardAudio
                ? await hasActiveAndroidAudio(adbPath: adbPath, serial: device.id)
                : false
            let macAudioWasAlreadyPlaying = preferences.forwardAudio
                ? await MacAudioActivity.hasSustainedPlayback()
                : false
            guard !Task.isCancelled, !isTerminatingApplication else {
                await restoreDeviceStateAndLock()
                return
            }
            let shouldForwardAudio = preferences.forwardAudio &&
                !androidAudioWasAlreadyPlaying && !macAudioWasAlreadyPlaying
            guard process.isRunning, !Task.isCancelled else { return }
            try Data((shouldForwardAudio ? "1" : "0").utf8).write(to: gate, options: .atomic)
            approved = true
            isMirroring = true
            status = "Mirroring \(device.displayName)"
        } catch {
            await restoreDeviceStateAndLock()
            errorMessage = error.localizedDescription
        }
    }

    func stopForInactivity() {
        guard isMirroring || isStarting else { return }
        stoppedForInactivity = true
        stop()
        presentStoppedMirror()
    }

    // Completion and cancellation can arrive after the stop request. Keep its
    // reason visible throughout transport cleanup instead of showing Disconnected.
    func presentStoppedMirror() {
        if stoppedForInactivity {
            status = "Stopped due to inactivity"
            PhoneWindowController.shared.present(title: status,
                message: "Reconnect when you’re ready to use your phone again.", model: self)
        } else {
            PhoneWindowController.shared.present(title: "Disconnected", message: "Connect again when you’re ready.", model: self)
        }
    }

    func stop() {
        connectionCancelled = true
        startTask?.cancel()
        classicBluetooth.stop()
        stopLockMonitoring()
        stopToolbarPositioning()
        isDeviceLocked = false
        mirrorProcess?.interrupt()
        status = "Closing mirror…"
    }

    func shutdownForApplicationTermination() async {
        guard !isTerminatingApplication else { return }
        isTerminatingApplication = true
        startTask?.cancel()
        classicBluetooth.stop()
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopLockMonitoring()
        stopToolbarPositioning()
        mirrorProcess?.terminationHandler = nil
        if mirrorProcess?.isRunning == true {
            mirrorProcess?.terminate()
        }
        mirrorProcess = nil
        MirrorRenderer.shared.shutdown()
        await restoreDeviceStateAndLock()
    }

    private func lockDeviceToPortrait(adbPath: String, serial: String) async {
        let base = ["-s", serial, "shell", "settings"]
        let auto = try? await ProcessRunner.output(adbPath, base + ["get", "system", "accelerometer_rotation"])
        let rotation = try? await ProcessRunner.output(adbPath, base + ["get", "system", "user_rotation"])
        originalAutoRotate = auto?.trimmingCharacters(in: .whitespacesAndNewlines)
        originalUserRotation = rotation?.trimmingCharacters(in: .whitespacesAndNewlines)
        originalAODSettings.removeAll()
        for (namespace, key) in [
            ("secure", "doze_always_on"),
            ("system", "aod_mode"),
            ("secure", "aod_mode"),
            ("secure", "ambient_display_enabled")
        ] {
            let value = try? await ProcessRunner.output(
                adbPath, base + ["get", namespace, key]
            )
            let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleaned, !cleaned.isEmpty, cleaned != "null" {
                originalAODSettings["\(namespace)|\(key)"] = cleaned
            }
        }
        originalLockAfterTimeout = (try? await ProcessRunner.output(
            adbPath,
            base + ["get", "secure", "lock_screen_lock_after_timeout"]
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        rotationSerial = serial
        _ = try? await ProcessRunner.output(adbPath, base + ["put", "system", "accelerometer_rotation", "0"])
        _ = try? await ProcessRunner.output(adbPath, base + ["put", "system", "user_rotation", "0"])
    }

    private func restoreDeviceStateAndLock(preserveLockScreen: Bool = false) async {
        guard let adbPath, let serial = rotationSerial else { return }
        let auto = originalAutoRotate
        let rotation = originalUserRotation
        let aodSettings = originalAODSettings
        let lockAfterTimeout = originalLockAfterTimeout
        originalAutoRotate = nil
        originalUserRotation = nil
        originalAODSettings.removeAll()
        originalLockAfterTimeout = nil
        rotationSerial = nil

        let base = ["-s", serial, "shell", "settings"]
        if let auto, auto != "null", !auto.isEmpty {
            _ = try? await ProcessRunner.output(adbPath, base + ["put", "system", "accelerometer_rotation", auto])
        }
        if let rotation, rotation != "null", !rotation.isEmpty {
            _ = try? await ProcessRunner.output(adbPath, base + ["put", "system", "user_rotation", rotation])
        }
        for (encodedKey, value) in aodSettings {
            let parts = encodedKey.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            _ = try? await ProcessRunner.output(adbPath, base + ["put", parts[0], parts[1], value])
        }

        if preserveLockScreen { return }

        // Temporarily remove Android's post-sleep grace period so closing the
        // mirror always locks immediately, then restore the user's preference.
        let savedTimeout = lockAfterTimeout.flatMap { value in
            value != "null" && !value.isEmpty ? value : nil
        }
        if savedTimeout != nil {
            _ = try? await ProcessRunner.output(
                adbPath, base + ["put", "secure", "lock_screen_lock_after_timeout", "0"]
            )
        }
        _ = try? await ProcessRunner.output(
            adbPath, ["-s", serial, "shell", "input", "keyevent", "KEYCODE_SLEEP"]
        )
        try? await Task.sleep(for: .milliseconds(300))
        if let savedTimeout {
            _ = try? await ProcessRunner.output(
                adbPath, base + ["put", "secure", "lock_screen_lock_after_timeout", savedTimeout]
            )
        }
    }

    func toggleScreenPower() { sendShortcut(["KEYCODE_POWER"]) }
    func goHome() { sendShortcut(["KEYCODE_HOME"]) }
    func goBack() { sendShortcut(["KEYCODE_BACK"]) }
    func switchApps() { sendShortcut(["KEYCODE_APP_SWITCH"]) }
    func volumeUp() { sendShortcut(["KEYCODE_VOLUME_UP"]) }
    func volumeDown() { sendShortcut(["KEYCODE_VOLUME_DOWN"]) }
    @discardableResult
    func enterPinDigit(_ digit: Int) -> Bool {
        guard (0...9).contains(digit) else { return false }
        let keyCodes: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        return postKeyToMirror(keyCodes[digit])
    }
    @discardableResult func deletePinDigit() -> Bool { postKeyToMirror(51) }
    @discardableResult func submitPin() -> Bool { postKeyToMirror(36) }

    private func sendShortcut(_ keys: [String]) {
        guard !sessionIsBluetooth, preferences.transport == .adb, let adbPath, let serial = selectedID else { return }
        Task { _ = try? await ProcessRunner.output(adbPath, ["-s", serial, "shell", "input", "keyevent"] + keys) }
    }

    private func postKeyToMirror(_ keyCode: CGKeyCode) -> Bool {
        guard !sessionIsBluetooth, let process = mirrorProcess else { return false }
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        guard trusted else {
            errorMessage = "PIN entry needs Accessibility permission so DroidMirror can send keys directly to the mirror. Enable DroidMirror in System Settings → Privacy & Security → Accessibility, then try again."
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?.postToPid(process.processIdentifier)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?.postToPid(process.processIdentifier)
        return true
    }

    private func startLockMonitoring() {
        stopLockMonitoring()
        checkLockState()
        lockPollTimer = .scheduledTimer(withTimeInterval: 1.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkLockState() }
        }
    }

    private func stopLockMonitoring() {
        lockPollTimer?.invalidate()
        lockPollTimer = nil
        isCheckingLock = false
    }

    private func startToolbarPositioning(for processID: pid_t) {
        stopToolbarPositioning()
        positionToolbar(near: processID)
        toolbarPositionTimer = .scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.positionToolbar(near: processID) }
        }
    }

    private func stopToolbarPositioning() {
        toolbarPositionTimer?.invalidate()
        toolbarPositionTimer = nil
    }

    private func positionToolbar(near processID: pid_t) {
        guard let toolbar = ToolbarWindowRegistry.shared.window,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let mirror = windows.first(where: { info in
                  (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID &&
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 &&
                  ((info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.height ?? 0) > 300
              }),
              let dictionary = mirror[kCGWindowBounds as String] as? NSDictionary,
              let quartzFrame = CGRect(dictionaryRepresentation: dictionary),
              let mainScreen = NSScreen.main else { return }

        let streamTop = mainScreen.frame.maxY - quartzFrame.minY
        var x = quartzFrame.midX - toolbar.frame.width / 2
        var y = streamTop + 8
        let visible = mainScreen.visibleFrame
        x = min(max(x, visible.minX + 8), visible.maxX - toolbar.frame.width - 8)
        if y + toolbar.frame.height > visible.maxY {
            y = streamTop - toolbar.frame.height - 12
        }
        toolbar.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func checkLockState() {
        guard !isCheckingLock, isMirroring, let adbPath, let serial = selectedID else { return }
        isCheckingLock = true
        Task {
            defer { isCheckingLock = false }
            guard let output = try? await ProcessRunner.output(adbPath, ["-s", serial, "shell", "dumpsys", "window", "policy"]) else { return }
            let text = output.lowercased()
            let directIndicators = ["mshowinglockscreen=true", "iskeyguardshowing=true", "isstatusbarkeyguard=true"]
            var locked = directIndicators.contains { text.contains($0) }
            if !locked, let marker = text.range(of: "keyguardservicedelegate") {
                let block = text[marker.lowerBound...].prefix(1200)
                locked = block.contains("showing=true") || block.contains("secure=true") && block.contains("enabled=true")
            }
            guard locked else {
                isDeviceLocked = false
                return
            }

            // The keyguard also covers the ordinary swipe/notification lock
            // screen. Only display our keypad when the credential "bouncer"
            // actually exposes a PIN entry control.
            let hierarchy = (try? await ProcessRunner.output(
                adbPath,
                ["-s", serial, "exec-out", "uiautomator", "dump", "/dev/tty"]
            ))?.lowercased() ?? ""
            let pinMarkers = [
                "keyguard_pin_view", "pinentry", "pin_entry", "pin_pad",
                "key_enter", "enter pin", "enter your pin", "credential_pin"
            ]
            isDeviceLocked = pinMarkers.contains { hierarchy.contains($0) }
        }
    }

    func pair() {
        guard let adbPath, !pairingAddress.isEmpty, !pairingCode.isEmpty else { return }
        Task {
            do {
                let result = try await ProcessRunner.output(adbPath, ["pair", pairingAddress, pairingCode])
                status = result.trimmingCharacters(in: .whitespacesAndNewlines)
                refreshDevices()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func connect() {
        guard let adbPath, !connectAddress.isEmpty else { return }
        Task {
            do {
                let result = try await ProcessRunner.output(adbPath, ["connect", connectAddress])
                status = result.trimmingCharacters(in: .whitespacesAndNewlines)
                refreshDevices()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func hasActiveAndroidAudio(adbPath: String, serial: String) async -> Bool {
        let audioDump = (try? await ProcessRunner.output(
            adbPath, ["-s", serial, "shell", "dumpsys", "audio"], timeout: 1.5
        ))?.lowercased() ?? ""

        // PlaybackActivityMonitor records active AudioTrack players even when
        // an app does not publish a MediaSession (games and browsers often do
        // not). Match only explicit started-player states to avoid historical
        // stopped/paused entries in the same dump.
        let playerIsActive = audioDump.split(separator: "\n").contains { line in
            line.contains("state:started") ||
            line.contains("state=started") ||
            line.contains("state: started") ||
            line.contains("mstate=started")
        }
        let callIsActive = audioDump.contains("mode: mode_in_call") ||
            audioDump.contains("mode: mode_in_communication") ||
            audioDump.contains("mode=mode_in_call") ||
            audioDump.contains("mode=mode_in_communication")
        if playerIsActive || callIsActive { return true }

        // MediaSession is a second signal for OEMs whose audio dump omits the
        // player state. PlaybackState 3 is Android's PLAYING state.
        let sessions = (try? await ProcessRunner.output(
            adbPath, ["-s", serial, "shell", "dumpsys", "media_session"], timeout: 1.5
        ))?.lowercased() ?? ""
        return sessions.split(separator: "\n").contains { line in
            line.contains("playbackstate") &&
            (line.contains("state=3,") || line.contains("state=3 ") || line.hasSuffix("state=3"))
        }
    }

    private func configureMirrorUI(environment: inout [String: String]) {
        if let device = selectedDevice {
            environment["DROIDMIRROR_DEVICE_NAME"] = device.displayName
            environment["DROIDMIRROR_APPEARANCE_CACHE"] = PhoneAppearanceCache.path(for: device)
        }
        environment["SCRCPY_SERVER_PATH"] = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/scrcpy-server").path
        environment["DROIDMIRROR_ALWAYS_ON_TOP"] = preferences.alwaysOnTop ? "1" : "0"
        environment["DROIDMIRROR_HOST_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        environment["DROIDMIRROR_SWIPE_SCROLL"] = preferences.scrollMode == .touchSwipe ? "1" : "0"
        if let library = Bundle.main.privateFrameworksURL?.appendingPathComponent("libDroidMirrorStyle.dylib"),
           FileManager.default.fileExists(atPath: library.path) {
            environment["DYLD_INSERT_LIBRARIES"] = library.path
        }
    }

    private func scrcpyArguments(for device: AndroidDevice, forwardAudio: Bool) -> [String] {
        var args = [
            "--serial=\(device.id)",
            "--window-title=DroidMirror — \(device.displayName)",
            "--window-borderless",
            "--window-width=430",
            "--background-color=000000",
            "--capture-orientation=@0",
            "--max-fps=\(preferences.maxFPS)",
            "--video-bit-rate=\(preferences.bitRateMbps)M",
            "--max-size=\(preferences.maxSize)",
            "--video-codec=\(preferences.codec.rawValue)",
            "--keyboard=\(preferences.keyboard.rawValue)",
            "--mouse=sdk",
            "--no-mouse-hover",
            // Ignore right-clicks, including Shift+right-click: Android can
            // interpret a forwarded secondary click as Back too.
            "--mouse-bind=-hsn:-+++",
            // Command is remapped to Android Control by the native window
            // integration. Keep scrcpy's own shortcut modifier out of its way.
            "--shortcut-mod=ralt",
            "--push-target=/sdcard/Download/",
            "--disable-screensaver",
            // Pace wireless frames by capture timestamps instead of displaying
            // network bursts immediately. USB retains the zero-buffer path.
            "--video-buffer=\(device.isWireless ? preferences.wirelessVideoBufferMs : 0)",
            "--audio-buffer=30",
            "--pause-on-exit=false"
        ]
        args.append(contentsOf: PhoneWindowController.shared.videoPositionArguments)
        if preferences.turnDeviceScreenOff { args.append("--turn-screen-off") }
        if preferences.powerOffOnClose { args.append("--power-off-on-close") }
        if preferences.stayAwake { args.append("--stay-awake") }
        if preferences.alwaysOnTop { args.append("--always-on-top") }
        if !forwardAudio { args.append("--no-audio") }
        if preferences.showTouches { args.append("--show-touches") }
        return args
    }
}
