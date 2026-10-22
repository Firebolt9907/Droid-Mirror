import SwiftUI

@MainActor
private final class NotificationAppsModel: NSObject, ObservableObject {
    @Published var connection = "Waiting for the background receiver…"
    @Published var apps = [String: String]()
    @Published var excluded = Set<String>()
    private let preferences = NotificationAppPreferences(defaults: .standard)

    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reload),
            name: NotificationAppPreferences.catalogChanged, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receive(_:)),
            name: Notification.Name("app.droidmirror.receiverStatus"), object: nil)
        reload()
    }
    @objc private func receive(_ event: Notification) {
        if let status = event.userInfo?["status"] as? String { connection = status }
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self) }
    @objc func reload() {
        UserDefaults.standard.synchronize()
        apps = preferences.apps
        excluded = preferences.excluded
    }
    func setAllowed(_ allowed: Bool, package: String) {
        preferences.setAllowed(allowed, package: package)
        reload()
        DistributedNotificationCenter.default().postNotificationName(NotificationAppPreferences.changed,
            object: nil, userInfo: nil, deliverImmediately: true)
    }
    var packages: [String] {
        apps.keys.sorted {
            let comparison = (apps[$0] ?? $0).localizedStandardCompare(apps[$1] ?? $1)
            return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
        }
    }
}

struct NotificationAppsView: View {
    @StateObject private var model = NotificationAppsModel()

    var body: some View {
        Section("Notifications") {
            LabeledContent("Phone connection", value: model.connection)
            DisclosureGroup("Set up notification forwarding / missing notifications") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. On Android, open DroidMirror → Optional features and recovery → Notification forwarding setup and background features. Enable the background bridge and pair this Mac once.")
                    Text("2. Open notification access, select DroidMirror and enable Allow notification access. Check that the setup screen says the listener is connected. Allowing DroidMirror’s own status notifications is a separate permission.")
                    Text("3. On this Mac, allow notifications for DroidMirror Notifications in System Settings → Notifications. Choose Banners or Alerts and check Focus if banners are missing. Keep DroidMirror’s background receiver running; enable startup at login above to receive after logging in.")
                    Text("4. Enable the source app below, then send a new message to the phone. Existing and silent notifications may appear only in Notification Center. Ongoing service, progress and secret notifications are filtered.")
                    Text("Mirroring can work before notification forwarding is ready. Shizuku and wireless debugging are not required for notification forwarding.")
                    Button("Open macOS Notification Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Text("Choose which phone apps can show notifications on this Mac. Apps appear after sending a notification. Turning an app off also clears its mirrored notifications from this Mac; notifications on your phone stay unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            if model.apps.isEmpty {
                Text("No phone notifications received yet. Open the setup checklist above, then send a new message to your phone.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.packages, id: \.self) { package in
                Toggle(isOn: Binding(get: { !model.excluded.contains(package) },
                    set: { model.setAllowed($0, package: package) })) {
                    VStack(alignment: .leading) {
                        Text(model.apps[package] ?? package)
                        Text(package).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.onAppear { model.reload() }
    }
}
