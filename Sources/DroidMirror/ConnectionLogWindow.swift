import AppKit

/// Keep long diagnostics selectable and scrollable instead of clipping them on the phone surface.
@MainActor
final class ConnectionLogWindow: NSWindowController {
    static let shared = ConnectionLogWindow()
    private let textView = NSTextView()

    func present(_ log: String) {
        if window == nil {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            textView.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.containerSize = NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.autoresizingMask = [.width]
            textView.isVerticallyResizable = true
            textView.textContainerInset = NSSize(width: 16, height: 16)
            scroll.documentView = textView
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "DroidMirror — Error Log"
            window.contentView = scroll
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        textView.string = log
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
