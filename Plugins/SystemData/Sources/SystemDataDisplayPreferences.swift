import Combine
import Foundation
import MacToolsPluginKit

/// Persisted display preferences shared by the settings workspace and the
/// widget detail list. The host storage keeps values across launches; the
/// default stays off so the workspace opens on found entries only.
@MainActor
final class SystemDataDisplayPreferences: ObservableObject {
    static let showAllItemsKey = "showAllItems"

    @Published var showAllItems: Bool {
        didSet {
            guard isAttached, showAllItems != oldValue, let portableStore else { return }
            guard portableStore.commit([Self.showAllItemsKey: .boolean(showAllItems)]) else {
                isAttached = false
                showAllItems = oldValue
                isAttached = true
                return
            }
            onPersistentPreferencesChange?()
        }
    }

    private var storage: PluginStorage?
    private var isAttached = false
    var onPersistentPreferencesChange: (() -> Void)?
    private var portableStore: PortablePreferencesStore? {
        storage.map { PortablePreferencesStore(storage: $0, fields: [Self.showAllItemsKey: .boolean(false)]) }
    }
    func portableBackup() -> Data? { portableStore?.backup() }
    func restorePortableBackup(_ data: Data) -> Bool {
        guard let storage, let portableStore else { return false }
        let before = showAllItems
        guard portableStore.restore(data) else { return false }
        isAttached = false
        showAllItems = storage.object(forKey: Self.showAllItemsKey) as? Bool ?? false
        isAttached = true
        if before != showAllItems { onPersistentPreferencesChange?() }
        return true
    }

    init() {
        self.showAllItems = false
    }

    /// Binds host storage at activation and reads the persisted value once;
    /// a missing key keeps the default (off) and is not written back.
    func attach(storage: PluginStorage) {
        self.storage = storage
        _ = portableStore?.recover()
        isAttached = false
        showAllItems = storage.bool(forKey: Self.showAllItemsKey)
        isAttached = true
    }
}
