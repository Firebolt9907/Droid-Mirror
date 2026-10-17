import Foundation

@main struct ToolEnvironmentTests {
    static func main() async throws {
        // Pass a realistic host environment into production helper-launch code.
        setenv("DYLD_INSERT_LIBRARIES", "/missing/libDroidMirrorHostShim.dylib", 1)
        setenv("DROIDMIRROR_HOST_PID", "123", 1)
        setenv("DROIDMIRROR_WIFI_FPS", "60", 1)
        let output = try await ProcessRunner.output("/usr/bin/env", [], timeout: 3)
        precondition(!output.contains("DYLD_INSERT_LIBRARIES="))
        precondition(!output.contains("DROIDMIRROR_HOST_PID="))
        precondition(output.contains("DROIDMIRROR_WIFI_FPS=60"))
        let clean = ToolProcessEnvironment.clean(["PATH": "/usr/bin", "DYLD_INSERT_LIBRARIES": "host-shim",
            "DROIDMIRROR_HOST_PID": "123", "DROIDMIRROR_WIFI_BIT_RATE": "12000000"])
        precondition(clean == ["PATH": "/usr/bin", "DROIDMIRROR_WIFI_BIT_RATE": "12000000"])
        print("PASS: real tool subprocess strips host injection and preserves video settings")
    }
}
