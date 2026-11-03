import Combine
import Foundation
import MacToolsPluginKit

@MainActor
final class ActivityBarPresentationPreferences: ObservableObject {
    private let storage: any PluginStorage
    private var isRestoring = false
    var onPersistentPreferencesChange: (() -> Void)?
    @Published var statsExpanded: Bool {
        didSet {
            guard !isRestoring, statsExpanded != oldValue else { return }
            guard portableStore.commit(["stats-expanded": .boolean(statsExpanded)]) else { isRestoring = true; statsExpanded = oldValue; isRestoring = false; return }
            onPersistentPreferencesChange?()
        }
    }
    @Published var chartRange: ActivityBarChartRange {
        didSet {
            guard !isRestoring, chartRange != oldValue else { return }
            guard portableStore.commit(["chart-range": .string(chartRange.rawValue)]) else { isRestoring = true; chartRange = oldValue; isRestoring = false; return }
            onPersistentPreferencesChange?()
        }
    }
    init(storage: any PluginStorage) {
        self.storage = storage
        _ = Self.portableStore(storage: storage).recover()
        storage.migrateValueIfNeeded(fromLegacyKey: "activity-bar.stats-expanded", to: "stats-expanded")
        storage.migrateValueIfNeeded(fromLegacyKey: "activity-bar.chart-range", to: "chart-range")
        statsExpanded = storage.object(forKey: "stats-expanded") as? Bool ?? true
        chartRange = storage.string(forKey: "chart-range").flatMap(ActivityBarChartRange.init(rawValue:)) ?? .sevenDays
    }
    private static func portableStore(storage: any PluginStorage) -> PortablePreferencesStore {
        PortablePreferencesStore(storage: storage, fields: [
            "stats-expanded": .boolean(true), "chart-range": .choice("7d", allowed: ActivityBarChartRange.allCases.map(\.rawValue))
        ])
    }
    private var portableStore: PortablePreferencesStore { Self.portableStore(storage: storage) }
    func portableBackup() -> Data? { portableStore.backup() }
    func restorePortableBackup(_ data: Data) -> Bool {
        let previous = portableStore.currentValues()
        guard portableStore.restore(data) else { return false }
        isRestoring = true
        statsExpanded = storage.object(forKey: "stats-expanded") as? Bool ?? true
        chartRange = storage.string(forKey: "chart-range").flatMap(ActivityBarChartRange.init(rawValue:)) ?? .sevenDays
        isRestoring = false
        if previous != portableStore.currentValues() { onPersistentPreferencesChange?() }
        return true
    }
}
