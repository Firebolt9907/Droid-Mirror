import SwiftUI

@MainActor
private final class NotificationAppsModel: NSObject, ObservableObject {
    @Published var apps = [String: String]()
    @Published var excluded = Set<String>()
    private let preferences = NotificationAppPreferences(defaults: .standard)

    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reload),
            name: NotificationAppPreferences.catalogChanged, object: nil)
        reload()
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
            Text("Choose which phone apps can show notifications on this Mac. Apps appear after sending a notification. Turning an app off also clears its mirrored notifications from this Mac; notifications on your phone stay unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            if model.apps.isEmpty {
                Text("No apps yet. Pair your phone and allow notification forwarding on Android.")
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
