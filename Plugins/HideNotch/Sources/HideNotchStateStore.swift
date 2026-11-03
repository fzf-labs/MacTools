import Foundation
import MacToolsPluginKit

@MainActor
final class HideNotchStateStore: HideNotchStateStoring {
    private enum StorageKey {
        static let desiredEnabled = "hide-notch.enabled"
    }

    private let storage: PluginStorage
    private let legacyUserDefaults: UserDefaults
    private let obsoleteKeys = [
        "feature.hideNotchManagedWallpapers",
        "feature.hideNotchEnabled",
        "hide-notch.original-wallpaper-states",
        "hide-notch.managed-space-states"
    ]

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "hide-notch"),
        userDefaults: UserDefaults? = nil
    ) {
        self.legacyUserDefaults = userDefaults ?? .standard
        self.storage = userDefaults.map {
            UserDefaultsPluginStorage(pluginID: context.pluginID, userDefaults: $0)
        } ?? context.storage
        storage.migrateValueIfNeeded(
            fromLegacyKey: StorageKey.desiredEnabled,
            to: StorageKey.desiredEnabled
        )
        _ = portableStore.recover()
        removeObsoleteStateIfNeeded()
    }

    var desiredEnabled: Bool {
        get { storage.bool(forKey: StorageKey.desiredEnabled) }
        set {
            guard desiredEnabled != newValue,
                  portableStore.commit([StorageKey.desiredEnabled: .boolean(newValue)]) else { return }
            onPersistentPreferencesChange?()
        }
    }

    var onPersistentPreferencesChange: (() -> Void)?
    private var portableStore: PortablePreferencesStore {
        PortablePreferencesStore(storage: storage, fields: [StorageKey.desiredEnabled: .boolean(false)])
    }
    func portableBackup() -> Data? { portableStore.backup() }
    func restorePortableBackup(_ data: Data) -> Bool {
        let previous = desiredEnabled
        guard portableStore.restore(data) else { return false }
        if desiredEnabled != previous { onPersistentPreferencesChange?() }
        return true
    }

    private func removeObsoleteStateIfNeeded() {
        obsoleteKeys.forEach { legacyUserDefaults.removeObject(forKey: $0) }
    }
}
