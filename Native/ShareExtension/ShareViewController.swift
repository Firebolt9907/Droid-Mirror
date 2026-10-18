import AppKit
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: NSViewController {
    private let label = NSTextField(wrappingLabelWithString: "Reading link…")
    private let send = NSButton(title: "Open on Phone", target: nil, action: nil)
    private var link: URL?
    private var loaded = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))
        send.target = self; send.action = #selector(share); send.isEnabled = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelShare))
        let buttons = NSStackView(views: [cancel, send])
        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !loaded else { return }; loaded = true
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        // Prefer URL attachments; Safari may also provide a text title.
        let urls = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }
        if urls.count == 1 { load(urls[0], type: UTType.url.identifier) }
        else if urls.isEmpty, let text = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            load(text, type: UTType.plainText.identifier)
        } else { label.stringValue = "Share one HTTP or HTTPS link." }
    }
    private func load(_ provider: NSItemProvider, type: String) {
        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, _ in
            let raw = (item as? URL)?.absoluteString ?? (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            let url = raw.flatMap { BrowserURL.browserURL($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            DispatchQueue.main.async {
                self?.link = url
                self?.send.isEnabled = url != nil
                self?.label.stringValue = url.map { "Open \($0.host ?? "link") in your phone’s default browser?" } ?? "Share one HTTP or HTTPS link."
            }
        }
    }
    @objc private func share() {
        guard let link else { return }
        var envelope = URLComponents()
        envelope.scheme = "droidmirror-share"; envelope.host = "open"
        envelope.queryItems = [URLQueryItem(name: "url", value: link.absoluteString)]
        guard let url = envelope.url else { return }
        // Address the helper inside this exact app, including when another build is installed.
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let receiver = app.appendingPathComponent("Contents/Helpers/DroidMirror Notifications.app")
        send.isEnabled = false
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([url], withApplicationAt: receiver, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.label.stringValue = error.localizedDescription; self?.send.isEnabled = true
                } else { self?.extensionContext?.completeRequest(returningItems: nil) }
            }
        }
    }
    @objc private func cancelShare() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
