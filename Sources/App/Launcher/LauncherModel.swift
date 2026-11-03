import AppKit
import Combine
import Foundation
import OSLog
import MacToolsPluginKit

struct LauncherItemAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    init(id: String, title: String, systemImage: String = "return") {
        self.id = id; self.title = title; self.systemImage = systemImage
    }
}

struct LauncherResult: Identifiable {
    enum Target {
        case action(ActionReference)
        case input(ActionInputItem)
        case application(ApplicationCatalogItem)
        case systemSetting(LauncherSystemSetting)
        case workspace(String)
    }
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let keywords: [String]
    let category: LauncherCategory
    let pluginID: String?
    let target: Target
    var actions: [LauncherItemAction] {
        if case .application = target {
            return [.init(id: "open", title: LauncherText.open), .init(id: "reveal", title: LauncherText.reveal), .init(id: "copyPath", title: LauncherText.copyPath)]
        }
        if case .action = target { return [.init(id: "run", title: LauncherText.run)] }
        return [.init(id: "run", title: LauncherText.open)]
    }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published private(set) var focusRequestID: UInt = 0
    @Published var query = "" { didSet { if query != oldValue { rebuild(resetSelection: true) } } }
    @Published private(set) var results: [LauncherResult] = []
    @Published var selectedID: String?
    @Published var feedback: String?
    @Published var canRecoverSettings = false
    @Published var isBusy = false
    @Published var actionsVisible = false
    @Published var isSuspended = false
    let preferences: LauncherPreferences
    let host: PluginHost
    private var openingTask: Task<Void, Never>?
    private var lifetime = UUID()
    private var isPresented = false
    private var profiles: [String: (String, LauncherSearchProfile)] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private let settings: () -> [LauncherSystemSetting]
    var dismiss: () -> Void = {}
    var hideForHandoff: () -> Void = {}
    var showSettings: () -> Void = {}
    var onCompletion: (() -> Void)?

    init(host: PluginHost, defaults: UserDefaults = .standard,
         systemSettings: (() -> [LauncherSystemSetting])? = nil) {
        self.host = host
        self.settings = systemSettings ?? { [weak host] in host?.systemSettingsCatalog.items ?? [] }
        preferences = LauncherPreferences(defaults: defaults)
        preferences.onPersistentChange = { [weak host] in host?.preferencesBackupChangeReporter.didPersist(.application) }
        host.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.rebuild(resetSelection: false) }
        }.store(in: &subscriptions)
        host.applicationCatalog.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuild(resetSelection: false) }
        }.store(in: &subscriptions)
        host.systemSettingsCatalog.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuild(resetSelection: false) }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .launcherPreferencesChanged).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuild(resetSelection: false) }
        }.store(in: &subscriptions)
        PluginRuntimeLocalization.source.$revision.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuild(resetSelection: false) }
        }.store(in: &subscriptions)
    }
    var selected: LauncherResult? { results.first { $0.id == selectedID } }
    var sections: [LauncherResultsSection] {
        guard query.isEmpty else { return [.init(id: 0, title: "", results: results)] }
        let favoriteIDs = Set(preferences.personalization.favorites)
        return [.init(id: 0, title: LauncherText.favorite, results: results.filter { favoriteIDs.contains($0.id) }),
                .init(id: 1, title: LauncherText.recent, results: results.filter { !favoriteIDs.contains($0.id) })].filter { !$0.results.isEmpty }
    }
    func present() {
        AppLog.launcher.debug("Presenting launcher")
        reset()
        isPresented = true
        focusRequestID &+= 1
        host.captureCurrentFocusedWindowTarget()
        host.launcherSystemActions.captureTarget()
        if !preferences.personalization.disabledSources.contains(LauncherCategory.applications.rawValue) { host.applicationCatalog.refresh() }
        if !preferences.personalization.disabledSources.contains(LauncherCategory.systemSettings.rawValue) { host.systemSettingsCatalog.refresh() }
        host.refreshActionPresentations(providerIDs: ["apple-shortcuts"])
        rebuild(resetSelection: true)
    }
    func reset() {
        isPresented = false
        lifetime = UUID()
        openingTask?.cancel(); openingTask = nil
        query = ""; results = []; selectedID = nil; feedback = nil
        isBusy = false; actionsVisible = false; isSuspended = false; canRecoverSettings = false
    }
    func back() {
        if actionsVisible { actionsVisible = false } else { dismiss() }
    }
    func moveSelection(_ offset: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selectedID } ?? 0
        selectedID = results[min(max(index + offset, 0), results.count - 1)].id
    }
    func quickSelect(_ number: Int) {
        guard results.indices.contains(number - 1) else { return }
        selectedID = results[number - 1].id
        activate()
    }
    /// Includes hidden categories/items so Settings can restore them. Business configuration never enters this inventory.
    func catalogResults() -> [LauncherResult] {
        LauncherCatalogSnapshot.make(host: host, settings: settings)
    }

    func rebuild(resetSelection: Bool = false) {
        guard isPresented else { return }
        let personalization = preferences.personalization
        let candidates = catalogResults().filter {
            !personalization.disabledSources.contains($0.category.rawValue)
                && !personalization.hidden.contains($0.id)
                && ($0.pluginID.map { !personalization.disabledSources.contains($0) } ?? true)
        }
        let activeIDs = Set(candidates.map(\.id))
        profiles = profiles.filter { activeIDs.contains($0.key) }
        let ranked = candidates.compactMap { result -> (LauncherResult, Int)? in
            let signature = result.title + result.keywords.joined(separator: "|")
            if profiles[result.id]?.0 != signature {
                let alternates: [String]
                if case let .application(app) = result.target { alternates = app.alternateNames } else { alternates = [] }
                profiles[result.id] = (signature, .init(title: result.title, keywords: result.keywords, alternateTitles: alternates))
            }
            guard let profile = profiles[result.id]?.1,
                  let tier = LauncherSearch.tier(query: query, profile: profile, alias: personalization.aliases[result.id]) else { return nil }
            return (result, tier)
        }.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            let af = personalization.favorites.firstIndex(of: a.0.id), bf = personalization.favorites.firstIndex(of: b.0.id)
            if af != bf { return (af ?? Int.max) < (bf ?? Int.max) }
            let au = preferences.usage[a.0.id], bu = preferences.usage[b.0.id]
            if au?.count != bu?.count { return (au?.count ?? 0) > (bu?.count ?? 0) }
            if au?.lastUsed != bu?.lastUsed { return (au?.lastUsed ?? .distantPast) > (bu?.lastUsed ?? .distantPast) }
            return a.0.title.localizedStandardCompare(b.0.title) == .orderedAscending
        }.map(\.0)
        if query.isEmpty {
            let favorites = ranked.filter { personalization.favorites.contains($0.id) }
            let recent = ranked.filter { !personalization.favorites.contains($0.id) && preferences.usage[$0.id] != nil }
                .sorted { (preferences.usage[$0.id]?.lastUsed ?? .distantPast) > (preferences.usage[$1.id]?.lastUsed ?? .distantPast) }
            results = favorites + recent.prefix(8)
        } else { results = Array(ranked.prefix(100)) }
        if resetSelection || !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
    }
    func activate(actionID: String? = nil) {
        guard !isBusy, let selected,
              catalogResults().contains(where: { $0.id == selected.id }),
              !preferences.personalization.hidden.contains(selected.id),
              !preferences.personalization.disabledSources.contains(selected.category.rawValue) else { rebuild(); return }
        actionsVisible = false; feedback = nil; canRecoverSettings = false
        if case let .input(item) = selected.target {
            guard host.actionInputRegistry.contains(item), host.launcherRole(for: .init(key: item.id)) != nil else { rebuild(); return }
            dismiss()
            host.appPresentationHandler?(.composeActionInput(item))
            return
        }
        let revision = lifetime
        isBusy = true
        openingTask = Task { [weak self] in
            guard let self else { return }
            defer { if lifetime == revision { isBusy = false; openingTask = nil } }
            let prepared: LauncherPreparedAction
            switch selected.target {
            case let .action(reference):
                guard host.launcherRole(for: reference) != nil else { rebuild(); return }
                prepared = .init(reference: reference)
            case let .application(app):
                prepared = host.launcherOperations.prepare {
                    guard ApplicationScanner.isValidAppBundle(at: app.url.path) else { return .failed(message: LauncherText.unavailable) }
                    if actionID == "reveal" { NSWorkspace.shared.activateFileViewerSelecting([app.url]); return .succeeded() }
                    if actionID == "copyPath" {
                        NSPasteboard.general.clearContents()
                        return NSPasteboard.general.setString(app.url.path, forType: .string) ? .succeeded() : .failed(message: LauncherText.unavailable)
                    }
                    do {
                        let running = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.resolvingSymlinksInPath() == app.url.resolvingSymlinksInPath() }
                        if let running, running.activate(options: [.activateAllWindows]) { return .succeeded() }
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.allowsRunningApplicationSubstitution = false
                        _ = try await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
                        return .succeeded()
                    } catch { return .failed(message: LauncherText.unavailable) }
                }
            case let .systemSetting(page):
                prepared = host.launcherOperations.prepare { [weak self] in
                    if let self, await self.host.systemSettingsCatalog.canOpen(page), LauncherSystemSettings.open(page) { return .succeeded() }
                    self?.canRecoverSettings = true
                    return .failed(message: LauncherText.settingsFailed)
                }
            case let .workspace(pluginID):
                prepared = host.launcherOperations.prepare { [weak host = self.host] in
                    guard let host, host.canOpenLauncherWorkspace(pluginID) else { return .failed(message: LauncherText.unavailable) }
                    host.presentPluginSettings(pluginID: pluginID)
                    return .succeeded()
                }
            case .input: return
            }
            await execute(prepared, identity: actionID == nil || actionID == "open" || actionID == "run" ? selected.id : nil, revision: revision)
        }
    }
    private func execute(_ prepared: LauncherPreparedAction, identity: String?, revision: UUID) async {
        guard case let .success(action) = host.actionRegistry.registeredAction(for: prepared.reference),
              let mode = ActionSurfaceExecutionSupport.preferredMode(for: action.definition) else {
            prepared.release(); feedback = LauncherText.unavailable; return
        }
        hideForHandoff()
        let start = await host.actionExecutor.startSurfaceIndependentTrackingCompletion(
            .init(reference: prepared.reference, source: .manual, mode: mode), expectedDefinition: action.definition,
            completionObserver: { [weak self] outcome in
                prepared.release()
                if case .completed(.succeeded) = outcome, let identity { self?.preferences.record(identity) }
            })
        guard revision == lifetime else {
            if case .started = start.outcome {} else { prepared.release() }
            return
        }
        switch start.outcome {
        case .started:
            if let completion = start.completion {
                for await outcome in completion {
                    guard lifetime == revision else { return }
                    if case .completed(.succeeded) = outcome { dismiss() }
                    else { feedback = ActionSurfaceExecutionSupport.feedback(for: outcome); onCompletion?() }
                }
            } else { dismiss() }
        case .cancelled: prepared.release(); onCompletion?()
        case let .rejected(reason):
            prepared.release(); feedback = ActionSurfaceExecutionSupport.message(for: reason); onCompletion?()
        }
    }
    func favorite() {
        guard let selected else { return }
        preferences.update { $0.labels[selected.id] = selected.title }
        preferences.toggleFavorite(selected.id)
    }
    func hideSelected() { guard let selected else { return }; preferences.update { $0.hidden.insert(selected.id) } }
    func recoverSystemSettings() { _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
}

struct LauncherResultsSection: Identifiable {
    let id: Int
    let title: String
    let results: [LauncherResult]
}
