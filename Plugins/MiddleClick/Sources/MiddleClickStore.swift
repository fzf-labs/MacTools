import Foundation
import MacToolsPluginKit

@MainActor
final class MiddleClickStore {
    private enum StorageKey {
        static let isEnabled = "middle-click.enabled"
        static let requiredFingerCount = "middle-click.required-finger-count"
    }

    private(set) var isEnabled: Bool
    private(set) var requiredFingerCount: Int

    private let storage: any PluginStorage

    init(storage: any PluginStorage) {
        self.storage = storage
        _ = Self.portableStore(storage: storage).recover()

        storage.migrateValueIfNeeded(
            fromLegacyKey: StorageKey.isEnabled,
            to: StorageKey.isEnabled
        )
        storage.migrateValueIfNeeded(
            fromLegacyKey: StorageKey.requiredFingerCount,
            to: StorageKey.requiredFingerCount
        )

        isEnabled = storage.bool(forKey: StorageKey.isEnabled)
        if storage.object(forKey: StorageKey.requiredFingerCount) == nil {
            requiredFingerCount = 3
        } else {
            requiredFingerCount = Self.normalizedFingerCount(
                storage.integer(forKey: StorageKey.requiredFingerCount)
            )
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        guard self.isEnabled != isEnabled else { return }
        guard portableStore.commit([StorageKey.isEnabled: .boolean(isEnabled)]) else { return }
        self.isEnabled = isEnabled
        onPersistentPreferencesChange?()
    }

    func setRequiredFingerCount(_ count: Int) {
        let normalizedCount = Self.normalizedFingerCount(count)
        guard requiredFingerCount != normalizedCount else { return }
        guard portableStore.commit([StorageKey.requiredFingerCount: .integer(normalizedCount)]) else { return }
        requiredFingerCount = normalizedCount
        onPersistentPreferencesChange?()
    }

    var onPersistentPreferencesChange: (() -> Void)?
    private static func portableStore(storage: any PluginStorage) -> PortablePreferencesStore {
        PortablePreferencesStore(storage: storage, fields: [
            StorageKey.isEnabled: .boolean(false), StorageKey.requiredFingerCount: .integer(3, range: 3...5)
        ])
    }
    private var portableStore: PortablePreferencesStore { Self.portableStore(storage: storage) }
    func portableBackup() -> Data? { portableStore.backup() }
    func restorePortableBackup(_ data: Data) -> Bool {
        let previous = portableStore.currentValues()
        guard portableStore.restore(data) else { return false }
        isEnabled = storage.object(forKey: StorageKey.isEnabled) as? Bool ?? false
        requiredFingerCount = storage.object(forKey: StorageKey.requiredFingerCount) as? Int ?? 3
        if previous != portableStore.currentValues() { onPersistentPreferencesChange?() }
        return true
    }

    private static func normalizedFingerCount(_ count: Int) -> Int {
        [3, 4, 5].contains(count) ? count : 3
    }
}
