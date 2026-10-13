import Foundation

@main
struct BLEProcessTests {
    static func main() throws {
        let echo = Process()
        echo.executableURL = URL(fileURLWithPath: "/bin/echo")
        echo.arguments = ["connected to 100.64.0.1:37183"]
        let output = try BLEController.runBounded(echo, timeout: 2)
        precondition(output == "connected to 100.64.0.1:37183")

        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleep.arguments = ["30"]
        let start = Date()
        let timedOut = try BLEController.runBounded(sleep, timeout: 0.1)
        precondition(timedOut == "ADB connection timed out")
        precondition(Date().timeIntervalSince(start) < 3)
        precondition(!sleep.isRunning)

        let missing = Process()
        missing.executableURL = URL(fileURLWithPath: "/nonexistent/droidmirror-adb")
        do {
            _ = try BLEController.runBounded(missing, timeout: 1)
            preconditionFailure("Expected a launch error")
        } catch { }
        print("BLE ADB subprocess tests passed (output, timeout, launch failure)")
    }
}
