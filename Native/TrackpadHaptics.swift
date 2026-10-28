import AppKit
import Darwin
import IOKit

/// A failed private attempt always retains the supported AppKit feedback path.
final class TrackpadHaptics {
    static let shared: TrackpadHaptics = {
        let actuator = PrivateTrackpadActuator()
        return TrackpadHaptics(performPrivate: { actuator.tick() }, performPublic: {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        })
    }()
    private let performPrivate: () -> Bool
    private let performPublic: () -> Void

    init(performPrivate: @escaping () -> Bool, performPublic: @escaping () -> Void) {
        self.performPrivate = performPrivate
        self.performPublic = performPublic
    }

    func tick() {
        if !performPrivate() { performPublic() }
    }
}

/// MultitouchSupport's existing strong actuation preset (6), with unknown
/// waveform parameters left at zero. No click-control or global settings changes.
/// Signatures: niw/MTActuatorTest.m; preset identifiers: Toxblh/MTMR HapticFeedback.swift.
final class PrivateTrackpadActuator {
    private typealias Create = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias OpenClose = @convention(c) (CFTypeRef) -> Int32
    private typealias Actuate = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32
    private let library: UnsafeMutableRawPointer?
    private let create: Create?
    private let open: OpenClose?
    private let close: OpenClose?
    private let actuate: Actuate?
    private var actuator: CFTypeRef?
    private var retryAt: TimeInterval = 0
    private var reportedPrivate = false
    private let lock = NSLock()

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY | RTLD_LOCAL)
        library = handle
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let address = dlsym(handle, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        create = symbol("MTActuatorCreateFromDeviceID", Create.self)
        open = symbol("MTActuatorOpen", OpenClose.self)
        close = symbol("MTActuatorClose", OpenClose.self)
        actuate = symbol("MTActuatorActuate", Actuate.self)
    }

    deinit {
        actuator = nil // Release the framework-owned object before unloading its code.
        if let library { dlclose(library) }
    }

    func tick() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let create, let open, let close, let actuate else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if actuator == nil {
            guard now >= retryAt else { return false }
            retryAt = now + 5
            for id in Self.deviceIDs() {
                guard let candidate = create(id)?.takeRetainedValue() else { continue }
                // Cache only a device we can actually open. Try other trackpads on failure.
                guard open(candidate) == kIOReturnSuccess else { continue }
                let status = actuate(candidate, 6, 0, 0, 0)
                let closed = close(candidate)
                if status == kIOReturnSuccess {
                    if closed == kIOReturnSuccess { actuator = candidate }
                    reportSuccess()
                    return true
                }
            }
            return false
        }
        guard let current = actuator else { return false }
        guard open(current) == kIOReturnSuccess else {
            actuator = nil; retryAt = now + 5
            return false
        }
        let status = actuate(current, 6, 0, 0, 0)
        let closed = close(current)
        if status != kIOReturnSuccess || closed != kIOReturnSuccess {
            actuator = nil; retryAt = now + 5
        }
        // A successful pulse must not also play the fallback if closing fails.
        if status == kIOReturnSuccess { reportSuccess(); return true }
        return false
    }

    private func reportSuccess() {
        if !reportedPrivate {
            reportedPrivate = true
            NSLog("DroidMirror haptics: private strong trackpad preset active")
        }
    }

    private static func deviceIDs() -> [UInt64] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == kIOReturnSuccess else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [(id: UInt64, builtIn: Bool)] = []
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            func property(_ key: String) -> AnyObject? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard (property("ActuationSupported") as? NSNumber)?.boolValue == true,
                  let id = property("Multitouch ID") as? NSNumber else { continue }
            devices.append((id.uint64Value, (property("MT Built-In") as? NSNumber)?.boolValue == true))
        }
        return devices.sorted { $0.builtIn && !$1.builtIn }.map(\.id)
    }
}
