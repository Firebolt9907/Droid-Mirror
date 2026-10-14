import AppKit
import ApplicationServices
import Foundation

@MainActor
final class MirrorModel: ObservableObject {
    static let shared = MirrorModel()

    @Published var devices: [AndroidDevice] = []
    @Published var selectedID: String?
    @Published var isRefreshing = false
    @Published var isMirroring = false
    @Published var isDeviceLocked = false
    @Published var status = "Connect an Android device to begin"
    @Published var errorMessage: String?
    @Published var log = ""
    @Published var preferences: MirrorPreferences {
        didSet {
            savePreferences()
            if preferences.transport != oldValue.transport, !isMirroring, !isStarting {
                selectedID = nil
                devices = []
                autoStartAttemptedFor = nil
                refreshDevices()
            }
        }
    }
    @Published var pairingAddress = ""
    @Published var pairingCode = ""
    @Published var connectAddress = ""

    private var mirrorProcess: Process?
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
    private var originalAutoRotate: String?
    private var originalUserRotation: String?
    private var originalAODSettings: [String: String] = [:]
    private var originalLockAfterTimeout: String?
    private var rotationSerial: String?
    private var isTerminatingApplication = false
    private static let preferencesKey = "DroidMirror.preferences.v1"

    var selectedDevice: AndroidDevice? {
        devices.first { $0.id == selectedID }
    }

    var adbPath: String? { ToolLocator.find("adb") }
    var scrcpyPath: String? { ToolLocator.find("scrcpy") }

    init() {
        preferences = Self.loadPreferences()
        refreshTimer = .scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard self?.isMirroring == false else { return }
                self?.refreshDevices(silently: true)
            }
        }
    }

    private static func loadPreferences() -> MirrorPreferences {
        guard let data = UserDefaults.standard.data(forKey: preferencesKey),
              let preferences = try? JSONDecoder().decode(MirrorPreferences.self, from: data)
        else { return MirrorPreferences() }
        return preferences
    }

    private func savePreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: Self.preferencesKey)
    }

    func refreshDevices(silently: Bool = false) {
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
                if !silently { errorMessage = error.localizedDescription }
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
                if selectedID == nil || !paired.contains(where: { $0.id == selectedID }) {
                    selectedID = paired.first?.id
                }
                status = paired.isEmpty ? "Pair your phone in Bluetooth settings" : "Ready to mirror via Bluetooth"
            } catch {
                status = error.localizedDescription
                if !silently { errorMessage = error.localizedDescription }
            }
        }
    }

    func start() {
        guard mirrorProcess == nil, !isStarting else { return }
        if preferences.transport == .bluetoothClassic {
            isStarting = true
            Task {
                defer { isStarting = false }
                await startBluetooth()
            }
            return
        }
        isStarting = true
        status = "Starting adb…"
        Task {
            defer { isStarting = false }
            await startAfterADBCheck()
        }
    }

    private func startBluetooth() async {
        guard let device = selectedDevice, device.isBluetooth, let scrcpyPath else {
            errorMessage = "Select a paired Bluetooth phone and install the bundled scrcpy client."
            return
        }
        status = "Connecting over Bluetooth Classic…"
        phoneTakenOver = false
        sessionEndedOnPhone = false
        classicBluetooth.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .streamStarted: SessionNotifications.shared.began()
            case .phoneOn, .phoneLocalUse:
                if !self.phoneTakenOver {
                    self.phoneTakenOver = true
                    SessionNotifications.shared.localUse(restored: event == .phoneOn)
                }
            case .captureFailed:
                self.errorMessage = "Privileged capture unavailable. Authorize Shizuku and enable Mac connections once in the Android companion."
            case .sessionEnded:
                self.sessionEndedOnPhone = true
                self.status = "Remote session ended"
            }
        }
        do {
            let port = try await classicBluetooth.connect(address: device.id)
            guard preferences.transport == .bluetoothClassic, !isTerminatingApplication else {
                classicBluetooth.stop()
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: scrcpyPath)
            process.arguments = ["--external-video-port=\(port)", "--window-title=DroidMirror — \(device.displayName)",
                                 "--window-borderless", "--window-width=430", "--video-buffer=0",
                                 "--no-audio", "--no-control", "--pause-on-exit=false"]
            if preferences.alwaysOnTop { process.arguments?.append("--always-on-top") }
            // No serial, ADB environment, injected ADB toolbar, or shell cleanup.
            var environment = ProcessInfo.processInfo.environment
            for key in ["ADB", "ANDROID_SERIAL", "DROIDMIRROR_SERIAL", "DYLD_INSERT_LIBRARIES"] {
                environment.removeValue(forKey: key)
            }
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] child in
                Task { @MainActor in
                    guard let self else { return }
                    self.classicBluetooth.stop()
                    await SessionNotifications.shared.ended()
                    self.mirrorProcess = nil
                    self.isMirroring = false
                    self.sessionIsBluetooth = false
                    self.status = "Bluetooth mirror closed"
                    if child.terminationStatus != 0 && !self.phoneTakenOver && !self.sessionEndedOnPhone && self.errorMessage == nil {
                        self.errorMessage = "Bluetooth video stopped. Reconnect from your Mac. Keep Shizuku running and use the updated companion and bundled client."
                    }
                }
            }
            try process.run()
            mirrorProcess = process
            sessionIsBluetooth = true
            isMirroring = true
            status = "Bluetooth · 480p · up to 30 fps · 1 Mbps"
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

        do {
            _ = try await ProcessRunner.output(adbPath, ["start-server"])
        } catch {
            let detail = error.localizedDescription
            status = "adb could not start"
            if detail.localizedCaseInsensitiveContains("operation not permitted") {
                errorMessage = "macOS blocked adb from opening its local connection. Quit DroidMirror and launch it from Finder (not from the Codex preview link), then try again.\n\n\(detail)"
            } else {
                errorMessage = "Could not start adb:\n\(detail)"
            }
            return
        }

        await lockDeviceToPortrait(adbPath: adbPath, serial: device.id)
        let androidAudioWasAlreadyPlaying = preferences.forwardAudio
            ? await hasActiveAndroidAudio(adbPath: adbPath, serial: device.id)
            : false
        let macAudioWasAlreadyPlaying = preferences.forwardAudio
            ? await MacAudioActivity.hasSustainedPlayback()
            : false
        let shouldForwardAudio = preferences.forwardAudio &&
            !androidAudioWasAlreadyPlaying && !macAudioWasAlreadyPlaying

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: scrcpyPath)
        process.arguments = scrcpyArguments(for: device, forwardAudio: shouldForwardAudio)
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
        environment["DROIDMIRROR_HOST_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        environment["DROIDMIRROR_SWIPE_SCROLL"] = preferences.scrollMode == .touchSwipe ? "1" : "0"
        if let library = Bundle.main.privateFrameworksURL?.appendingPathComponent("libDroidMirrorStyle.dylib"),
           FileManager.default.fileExists(atPath: library.path) {
            environment["DYLD_INSERT_LIBRARIES"] = library.path
        }
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                self.log = output
                await SessionNotifications.shared.ended()
                await self.restoreDeviceStateAndLock()
                self.stopLockMonitoring()
                self.stopToolbarPositioning()
                self.mirrorProcess = nil
                self.isMirroring = false
                self.isDeviceLocked = false
                self.status = process.terminationStatus == 0 ? "Mirror closed" : "Mirror stopped unexpectedly"
                if process.terminationStatus != 0 {
                    self.errorMessage = output.split(separator: "\n").suffix(4).joined(separator: "\n").nilIfEmpty ?? "scrcpy exited with code \(process.terminationStatus)"
                }
                // The stream is the app now. Closing it (including Command-Q
                // while scrcpy is focused) closes the wrapper as well.
                if !self.isTerminatingApplication {
                    NSApp.terminate(nil)
                }
            }
        }
        do {
            try process.run()
            mirrorProcess = process
            isMirroring = true
            SessionNotifications.shared.began()
            status = "Mirroring \(device.displayName)"
        } catch {
            await restoreDeviceStateAndLock()
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
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
        classicBluetooth.stop()
        await SessionNotifications.shared.ended()
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopLockMonitoring()
        stopToolbarPositioning()
        mirrorProcess?.terminationHandler = nil
        if mirrorProcess?.isRunning == true {
            mirrorProcess?.interrupt()
            // Allow scrcpy's SDL quit path to send releases before fallback.
            for _ in 0..<10 {
                if mirrorProcess?.isRunning != true { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if mirrorProcess?.isRunning == true { mirrorProcess?.terminate() }
        }
        mirrorProcess = nil
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

    private func restoreDeviceStateAndLock() async {
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
            // Command is remapped to Android Control by the native window
            // integration. Keep scrcpy's own shortcut modifier out of its way.
            "--shortcut-mod=ralt",
            "--push-target=/sdcard/Download/",
            "--disable-screensaver",
            "--video-buffer=0",
            "--audio-buffer=30",
            "--pause-on-exit=false"
        ]
        if preferences.turnDeviceScreenOff { args.append("--turn-screen-off") }
        if preferences.powerOffOnClose { args.append("--power-off-on-close") }
        if preferences.stayAwake { args.append("--stay-awake") }
        if preferences.alwaysOnTop { args.append("--always-on-top") }
        if !forwardAudio { args.append("--no-audio") }
        if preferences.showTouches { args.append("--show-touches") }
        return args
    }
}
