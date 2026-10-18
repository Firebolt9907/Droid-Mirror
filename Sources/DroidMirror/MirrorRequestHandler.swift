import Foundation

/// Receives requests from the renderer and the background notification helper.
@MainActor
final class MirrorRequestHandler: NSObject {
    private let connect: () -> Void

    init(connect: @escaping () -> Void) {
        self.connect = connect
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(requestMirror(_:)),
            name: Notification.Name("app.droidmirror.requestMirror"), object: nil)
    }

    @objc private func requestMirror(_ notification: Notification) {
        // Renderer buttons address their host; background notification requests
        // have no object and may be received by the active host.
        if let destination = notification.object as? String,
           destination != String(ProcessInfo.processInfo.processIdentifier) { return }
        connect()
    }
}
