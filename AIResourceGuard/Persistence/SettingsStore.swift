import Foundation
import Combine

/// UserDefaults-backed Codable settings. Single source of truth for the
/// Managed/Protected lists and thresholds; persisted on every change.
@MainActor
final class SettingsStore: ObservableObject {
    private static let storageKey = "local.dev.AIResourceGuard.settings.v1"

    @Published var settings: AppSettings {
        didSet {
            guard oldValue != settings else { return }
            save()
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Helpers

    func managedConfig(forGroupKey key: String) -> ManagedAppConfig? {
        settings.managedApps.first { $0.key == key }
    }

    func isProtectedGroup(_ key: String) -> Bool {
        settings.protectedApps.contains(key)
    }

    func addManaged(key: String, displayName: String) {
        guard !settings.managedApps.contains(where: { $0.key == key }) else { return }
        settings.managedApps.append(ManagedAppConfig(key: key, displayName: displayName))
    }

    func removeManaged(key: String) {
        settings.managedApps.removeAll { $0.key == key }
    }

    func addProtected(key: String) {
        guard !settings.protectedApps.contains(key) else { return }
        settings.protectedApps.append(key)
    }

    func removeProtected(key: String) {
        settings.protectedApps.removeAll { $0 == key }
    }
}
