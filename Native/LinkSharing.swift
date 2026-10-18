import AppKit

/// Explicit shares use the existing authenticated, sequenced BLE channel.
final class LinkSharing {
    weak var controller: BLEController?
    private var pending: (id: String, url: URL, deadline: Date, sent: Bool)?
    private var received = [String]()
    var now: () -> Date = { Date() }
    var openBrowser: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var report: (String) -> Void = { message in
        // Do not run a nested AppKit loop inside a BLE reset/completion callback.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "DroidMirror link sharing"
            alert.informativeText = message
            alert.runModal()
        }
    }

    func share(_ envelope: URL) {
        guard let parts = URLComponents(url: envelope, resolvingAgainstBaseURL: false),
              parts.scheme == "droidmirror-share", parts.host == "open",
              let raw = parts.queryItems?.first(where: { $0.name == "url" })?.value,
              let url = TaskContinuationState.browserURL(raw) else { report("Share an HTTP or HTTPS link."); return }
        guard pending == nil else { report("Another link is still being sent. Try again shortly."); return }
        pending = (UUID().uuidString, url, now().addingTimeInterval(15), false)
        tick()
    }
    func cancel() { pending = nil; controller = nil }
    func disconnected() {
        // A sent browser action may already have executed. Never replay it.
        guard pending?.sent == true else { return }
        pending = nil
        report("Bluetooth disconnected before the phone confirmed opening the link. Check the phone before sharing again.")
    }
    func connected() {
        if controller?.supportsLinkSharing == true { controller?.send(["type": "linkSubscribe"]) }
        tick()
    }
    func tick() {
        guard var request = pending else { return }
        if now() >= request.deadline {
            pending = nil
            report("The phone did not confirm opening the link. Check that DroidMirror is ready, Bluetooth is connected, and Shizuku is authorized on the phone.")
        } else if !request.sent, let controller, controller.authenticated {
            guard controller.supportsLinkSharing else {
                pending = nil; report("Update DroidMirror on the phone to use link sharing."); return
            }
            request.sent = true
            pending = request
            controller.request(["type": "openLink", "url": request.url.absoluteString],
                               expecting: "openLinkResult", timeout: request.deadline.timeIntervalSince(now()),
                               id: request.id) { [weak self] outcome in
                guard let self, self.pending?.id == request.id else { return }
                self.pending = nil
                switch outcome {
                case .response(let event):
                    if event["success"] as? Bool != true {
                        self.report("The phone could not open its default browser. Check the default browser setting and authorize Shizuku in DroidMirror.")
                    }
                case .notQueued:
                    self.report("The Bluetooth command queue is busy. Try sharing the link again shortly.")
                case .timedOut, .disconnected:
                    self.report("The phone did not confirm opening the link. Check the phone before sharing again.")
                }
            }
        }
    }
    func receive(_ event: [String: Any]) {
        guard controller?.authenticated == true, let id = event["request"] as? String,
              UUID(uuidString: id) != nil else { return }
        if event["type"] as? String == "shareLink", let raw = event["url"] as? String,
           let url = TaskContinuationState.browserURL(raw) {
            // Never open the same explicit share twice, even across reconnects.
            let success: Bool
            if received.contains(id) { success = true }
            else {
                success = openBrowser(url)
                if success { received.append(id); if received.count > 64 { received.removeFirst() } }
            }
            controller?.send(["type": "shareLinkResult", "request": id, "success": success])
        }
    }
}
