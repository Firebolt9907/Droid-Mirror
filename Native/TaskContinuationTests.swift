import AppKit

final class BLEController {
    var authenticated = false
    var supportsTaskURLs = false
    @discardableResult func send(_ event: [String: Any]) -> Bool { authenticated }
}

@main struct TaskContinuationTests {
    static func main() {
        let now = Date()
        let event: [String: Any] = ["type": "taskContinuation", "url": "https://docs.google.com/document/d/example/edit", "package": "com.google.android.apps.docs.editors.docs"]
        var state = TaskContinuationState()
        state.receive(event, authenticated: false, now: now)
        precondition(state.currentURL(authenticated: true, now: now) == nil)
        state.receive(event, authenticated: true, now: now)
        precondition(state.currentURL(authenticated: true, now: now)?.host == "docs.google.com")
        precondition(state.currentURL(authenticated: false, now: now) == nil)
        precondition(state.currentURL(authenticated: true, now: now.addingTimeInterval(8)) == nil)
        state.receive(event, authenticated: true, now: now.addingTimeInterval(6))
        precondition(state.currentURL(authenticated: true, now: now.addingTimeInterval(9)) != nil)
        state.receive(["type": "taskContinuation"], authenticated: true, now: now)
        precondition(state.currentURL(authenticated: true, now: now) == nil)
        for value in ["javascript:alert(1)", "file:///tmp/document", "https://user:pass@example.com", "https:///", "https://example.com/\nsecret", "https://example.com/" + String(repeating: "x", count: 2048)] {
            precondition(TaskContinuationState.browserURL(value) == nil)
        }
        state.receive(event, authenticated: true, now: now)
        state.clear()
        precondition(state.currentURL(authenticated: true, now: now) == nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = BLEController()
        controller.authenticated = true
        var opened: URL?
        let continuation = TaskContinuation(openBrowser: { opened = $0 })
        continuation.controller = controller
        precondition(continuation.item == nil)
        continuation.receive(event)
        precondition(continuation.item?.button?.image != nil)
        precondition(continuation.item?.button?.image?.isTemplate == true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let icon = bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
        var iconEvent = event
        iconEvent["appIcon"] = icon
        continuation.receive(iconEvent)
        precondition(continuation.item?.button?.image?.isTemplate == false)
        precondition(continuation.item?.button?.image?.size == NSSize(width: 18, height: 18))
        iconEvent["appIcon"] = String(repeating: "x", count: 3000)
        continuation.receive(iconEvent)
        precondition(continuation.item?.button?.image?.isTemplate == true)
        continuation.receive(event)
        precondition(continuation.item?.button?.image?.isTemplate == true)
        continuation.item?.button?.performClick(nil)
        precondition(opened?.absoluteString == event["url"] as? String)
        continuation.receive(["type": "taskContinuation"])
        precondition(continuation.item == nil)
        continuation.receive(event)
        controller.authenticated = false
        opened = nil
        continuation.item?.button?.performClick(nil)
        precondition(opened == nil && continuation.item == nil)
        continuation.stop()
        print("PASS: authenticated suggestions, refresh, expiry, disconnect, clearing and browser URL validation")
        print("PASS: menu bar phone button appears only for a URL, dispatches browser action, disappears on clear/disconnect")
    }
}
