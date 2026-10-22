import Foundation

@main
struct ConnectionFailureTests {
    static func main() async throws {
        let cases: [(String, String)] = [
            ("Command timed out", "Timed out"),
            ("PAIRING_CODE_MISMATCH: Pairing code is wrong.", "Pairing code is wrong"),
            ("Bluetooth timed out\nPAIRING_CODE_MISMATCH\nERROR: Server connection failed", "Pairing code is wrong"),
            ("BLE operation stalled (write=1 read=0 queued=5).", "Timed out"),
            ("Shizuku unavailable", "Start Shizuku"),
            ("Shizuku is not authorized; phone display stays on.", "Authorize Shizuku"),
            ("Could not open Classic L2CAP. Enable the background bridge and authorize Shizuku on Android.", "Enable bridge on Android phone"),
            ("Classic L2CAP connection failed in the macOS Bluetooth framework (error=4)", "Enable bridge on Android phone"),
            ("error: device unauthorized.", "Allow USB debugging"),
            ("adb: device offline", "Phone disconnected"),
            ("BLE input unavailable. Enable Bluetooth and allow DroidMirror Bluetooth access.", "Enable Bluetooth"),
            ("Pair the phone in macOS Bluetooth settings first", "Pair your phone"),
            ("Pair BLE once in DroidMirror Settings using the code from the Android companion.", "Pair your phone"),
            ("EVENT PHONE_ON\nWARN: Device disconnected", "Phone in use"),
            ("EVENT PHONE_LOCAL_USE\nBluetooth stream closed", "Phone in use"),
            ("EVENT SESSION_ENDED\nWARN: Device disconnected", "Remote session ended"),
            ("EVENT PHONE_IN_USE", "Phone in use"),
            ("EVENT PIN_PAUSED\nEVENT CAPTURE_FAILED", "Could not start screen capture"),
            ("EVENT PIN_FAILED\nBluetooth connection timed out", "Automatic unlock failed"),
            ("Automatic unlock paused after an incomplete startup", "Automatic unlock paused"),
            ("EVENT CAPTURE_FAILED", "Could not start screen capture"),
            ("Bluetooth stream closed. Reconnect from your Mac.", "Bluetooth disconnected"),
            ("BLE clock synchronization failed. Update the Android companion.", "Update DroidMirror")
        ]
        for (diagnostic, title) in cases {
            let failure = ConnectionFailure.recognize(diagnostic)
            precondition(failure.title == title, "Unexpected classification: \(diagnostic): \(failure.title)")
            precondition(!failure.showsLog)
        }
        let screenshotLog = """
        Bluetooth video stopped (exit 1).

        LISTENING 55011 55012
        Opening Classic L2CAP PSM 0xd001
        Classic L2CAP connection failed in the macOS Bluetooth framework (error=0)
        WARN: Could not set app name
        WARN: Could not clear rendering: Parameter 'renderer' is invalid
        ERROR: Could not render: Parameter 'renderer' is invalid
        """
        let screenshotFailure = ConnectionFailure.recognize(screenshotLog)
        precondition(screenshotFailure.title == "Enable bridge on Android phone")
        precondition(!screenshotFailure.showsLog, "Secondary renderer errors must not hide the bridge failure")
        let invalidBLELog = """
        Bluetooth video stopped (exit 1).

        LISTENING 61806 61807
        Trying direct IP (LAN/VPN) video
        Iroh: LAN endpoint bound; relays and public discovery disabled
        Opening Classic L2CAP PSM 0xd001
        Android accepted mirror session; starting BLE discovery
        BLE setup: scanning for the phone's BLE service
        BLE setup: connecting to a BLE service candidate
        BLE candidate: 3D1B1E59-DC41-7410-3668-37BAD3AC3FAF
        BLE setup: discovering BLE services
        BLE setup: discovering BLE characteristics
        BLE setup: reading the BLE session nonce
        BLE setup: writing the BLE authentication challenge
        BLE setup: reading the BLE pairing proof
        BLE setup: reading the authenticated phone clock
        BLE setup: authenticated BLE ready
        READY 61806 61807
        BLE side channel authenticated; Classic L2CAP carries video only (phone to Mac)
        Invalid BLE control or event stream.

        WARN: Could not set app name
        WARN: Could not clear rendering: Parameter 'renderer' is invalid
        ERROR: Could not render: Parameter 'renderer' is invalid
        ERROR: Server connection failed
        """
        let invalidBLEFailure = ConnectionFailure.recognize(invalidBLELog)
        precondition(invalidBLEFailure.title == "Bluetooth session interrupted")
        precondition(!invalidBLEFailure.showsLog, "Secondary renderer errors must not hide the BLE stream failure")
        let lanUnavailableBLELog = """
        BLE setup: authenticated BLE ready
        READY 61924 61925
        BLE side channel authenticated; Classic L2CAP carries video only (phone to Mac)
        Received Tailscale direct IP candidate over authenticated BLE
        Iroh: Peer connection failed: Err(Elapsed(()))
        EVENT LAN_UNAVAILABLE
        Invalid BLE control or event stream.

        WARN: Could not set app name
        WARN: Device disconnected
        """
        let lanUnavailableBLEFailure = ConnectionFailure.recognize(lanUnavailableBLELog)
        precondition(lanUnavailableBLEFailure.title == "Bluetooth session interrupted")
        precondition(!lanUnavailableBLEFailure.showsLog, "A failed direct IP probe must not hide the BLE stream failure")
        // Setup advice mentioning Shizuku must not hide the actual failure.
        precondition(ConnectionFailure.recognize("Bluetooth connection timed out. Keep Shizuku running.").title == "Timed out")
        let unknown = "Stream began\n" + String(repeating: "verbose diagnostic\n", count: 2000) + "Unexpected packet 0xFE\n"
        precondition(ConnectionFailure.recognize(unknown).showsLog)
        precondition(ConnectionFailure.recognize("Shizuku version 13\nUnexpected packet 0xFE").showsLog)

        // Exercise real pipes, including a cause beyond the old 8 KB cap.
        precondition(ConnectionFailure.recognize("Configuration: timeout=5000\nUnknown packet").showsLog)
        do {
            _ = try await ProcessRunner.output("/bin/sh", ["-c", "printf 'startup diagnostic\n'; exec /bin/sleep 2"], timeout: 0.2)
            preconditionFailure("The command must time out")
        } catch {
            precondition(error.localizedDescription.contains("startup diagnostic"), "Timeouts must preserve earlier output")
            precondition(ConnectionFailure.recognize(error.localizedDescription).title == "Timed out")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
        process.arguments = ["%s", unknown]
        let diagnostics = ProcessDiagnostics()
        diagnostics.attach(to: process, captureOutput: true)
        try process.run()
        process.waitUntilExit()
        precondition(diagnostics.snapshot() == unknown, "Full output must survive the diagnostic drain")
        diagnostics.reset()
        precondition(diagnostics.finish().isEmpty, "A new attempt must not inherit the previous log")
        print("PASS: common failures classified; unknown failures use full logs; diagnostics survive beyond 8 KB and reset between attempts")
    }
}
