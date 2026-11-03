import Combine
import Foundation
import MacToolsPluginKit

/// One model owns all five Settings pages. Navigation and text editing reuse source snapshots.
@MainActor
final class LauncherSettingsModel: ObservableObject {
    let host: PluginHost
    let preferences: LauncherPreferences
    let catalog: ApplicationCatalog
    @Published private(set) var revision: UInt = 0
    private var cached: [String: [LauncherResult]] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var pendingCategories: Set<LauncherCategory> = []
    private var refreshTask: Task<Void, Never>?
    private let snapshot: (LauncherCategory?) -> [LauncherResult]

    init(host: PluginHost, defaults: UserDefaults = .standard,
         snapshot: ((LauncherCategory?) -> [LauncherResult])? = nil) {
        self.host = host
        catalog = host.applicationCatalog
        preferences = LauncherPreferences(defaults: defaults, onPersistentChange: { [weak host] in
            host?.preferencesBackupChangeReporter.didPersist(.application)
        })
        self.snapshot = snapshot ?? { [weak host] category in
            guard let host else { return [] }
            return LauncherCatalogSnapshot.make(host: host, category: category)
        }
        host.objectWillChange.sink { [weak self] in self?.scheduleInvalidation([.pluginFeatures]) }.store(in: &subscriptions)
        catalog.objectWillChange.sink { [weak self] in self?.scheduleInvalidation([.applications]) }.store(in: &subscriptions)
        host.systemSettingsCatalog.objectWillChange.sink { [weak self] in self?.scheduleInvalidation([.systemSettings]) }.store(in: &subscriptions)
        PluginRuntimeLocalization.source.$revision.dropFirst().sink { [weak self] _ in
            self?.scheduleInvalidation(Set(LauncherCategory.allCases))
        }.store(in: &subscriptions)
    }
    isolated deinit { refreshTask?.cancel() }

    func results(for category: LauncherCategory?) -> [LauncherResult] {
        let key = category?.rawValue ?? "all"
        if let existing = cached[key] { return existing }
        let entries = snapshot(category)
        cached[key] = entries
        return entries
    }
    private func scheduleInvalidation(_ categories: Set<LauncherCategory>) {
        pendingCategories.formUnion(categories)
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            for category in pendingCategories { cached[category.rawValue] = nil }
            cached["all"] = nil
            pendingCategories.removeAll()
            refreshTask = nil
            revision &+= 1
        }
    }
    #if DEBUG
    func waitForScheduledRefreshForTests() async { await refreshTask?.value }
    #endif
}
