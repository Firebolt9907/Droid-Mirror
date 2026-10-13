import AppKit
import ApplicationServices
import Foundation

/// Turns scroll events over the scrcpy process into Android touch gestures.
/// Clicks and pointer motion continue to be handled directly by scrcpy.
final class SwipeScrollMonitor: @unchecked Sendable {
    private let adbPath: String
    private let serial: String
    private let mirrorPID: pid_t
    private let queue = DispatchQueue(label: "app.droidmirror.swipe-scroll")
    private let lock = NSLock()
    private var pendingDelta = 0.0
    private var flushScheduled = false
    private var displaySize = (width: 1080, height: 2400)
    private var eventTap: CFMachPort?
    private var source: CFRunLoopSource?

    init(adbPath: String, serial: String, mirrorPID: pid_t) {
        self.adbPath = adbPath
        self.serial = serial
        self.mirrorPID = mirrorPID
        queue.async { [weak self] in self?.loadDisplaySize() }
    }

    func start() -> Bool {
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else { return false }
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: swipeEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        source = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == mirrorPID else {
            return Unmanaged.passUnretained(event)
        }
        var delta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        if abs(delta) < 0.01 { delta = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) }
        guard abs(delta) >= 0.01 else { return nil }
        enqueue(delta)
        return nil
    }

    private func enqueue(_ delta: Double) {
        lock.lock()
        pendingDelta += delta
        let needsSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if needsSchedule {
            queue.asyncAfter(deadline: .now() + .milliseconds(18)) { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        lock.lock()
        let delta = pendingDelta
        pendingDelta = 0
        flushScheduled = false
        lock.unlock()
        guard abs(delta) >= 0.01 else { return }

        let width = displaySize.width
        let height = displaySize.height
        let startY = height / 2
        let distance = min(Int(Double(height) * 0.32), max(Int(Double(height) * 0.055), Int(abs(delta) * Double(height) * 0.012)))
        let endY = max(Int(Double(height) * 0.12), min(Int(Double(height) * 0.88), startY + (delta > 0 ? distance : -distance)))
        let duration = min(180, max(70, 70 + distance * 80 / max(height, 1)))
        _ = runADB(["shell", "input", "swipe", "\(width / 2)", "\(startY)", "\(width / 2)", "\(endY)", "\(duration)"])
    }

    private func loadDisplaySize() {
        let output = runADB(["shell", "wm", "size"])
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)x(\d+)"#),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let w = Range(match.range(at: 1), in: output), let h = Range(match.range(at: 2), in: output),
              let width = Int(output[w]), let height = Int(output[h]) else { return }
        displaySize = (width, height)
    }

    private func runADB(_ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        } catch { return "" }
    }
}

private let swipeEventCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<SwipeScrollMonitor>.fromOpaque(info).takeUnretainedValue().handle(type: type, event: event)
}
