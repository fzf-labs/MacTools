import AppKit
import Combine
import Foundation
import MacToolsPluginKit
import UniformTypeIdentifiers

@MainActor
final class WallpaperController: ObservableObject {
    @Published private(set) var state = WallpaperState()
    @Published private(set) var displays: [WallpaperDisplay] = []
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var scanning = false
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    @Published private(set) var folderIssues: [UUID: String] = [:]
    @Published private(set) var searchIDs: [String] = []
    @Published private(set) var lastPage = 1
    @Published private(set) var currentPage = 0
    @Published private(set) var usage: (managed: Int64, cached: Int64) = (0, 0)
    var onChange: (() -> Void)?

    let library: WallpaperLibrary
    let source: any WallpaperSource
    let system: any WallpaperSystemControlling
    let localization: PluginLocalization
    private let transfers = WallpaperTransferService()
    private var active = false
    private var epoch: UInt = 0
    private var revision: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var operation: Task<ActionExecutionResult, Never>?
    private var operationScope: String?
    private var timer: Timer?
    private var watcher: WallpaperFolderObserver?
    private var folderFallbackTimer: Timer?
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var suspendedReasons: Set<String> = []
    private var lastOwnershipCheck = Date.distantPast
    private var queryEpoch: UInt = 0
    private var folderEpoch: UInt = 0
    private var remoteRevision: String?
    private var prefetchTask: Task<Void, Never>?
    private var pendingImports = 0
    private var deadlines: [String: ContinuousClock.Instant] = [:]

    init(context: PluginRuntimeContext, system: (any WallpaperSystemControlling)? = nil,
         library: WallpaperLibrary? = nil, source: any WallpaperSource = WallhavenWallpaperSource()) {
        localization = PluginLocalization(bundle: context.resourceBundle)
        self.system = system ?? WallpaperSystemAdapter()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacTools/Wallpaper", isDirectory: true)
        self.library = library ?? WallpaperLibrary(root: context.supportDirectory ?? base,
                                                   cache: context.cacheDirectory ?? base.appendingPathComponent("Thumbnails"))
        self.source = source
    }

    func text(_ key: String) -> String { localization.string(key, defaultValue: key) }
    var profile: WallpaperProfile { state.profiles[state.selectedScope] ?? WallpaperProfile() }
    var isSuspended: Bool { !suspendedReasons.isEmpty }
    var canGoBack: Bool {
        let records = targets(state.selectedScope).compactMap { state.history[$0.id] }
        return !records.isEmpty && records.count == targets(state.selectedScope).count && records.allSatisfy {
            $0.entries.indices.contains($0.cursor) && $0.cursor > 0
                && state.assets[$0.entries[$0.cursor - 1]]?.managedName != nil
        }
    }
    var currentAsset: WallpaperAsset? {
        guard let display = targets(state.selectedScope).first,
              let history = state.history[display.id], history.entries.indices.contains(history.cursor) else { return nil }
        return state.assets[history.entries[history.cursor]]
    }

    @discardableResult
    func activate() -> Task<Void, Never>? {
        guard !active else { return loadTask }
        active = true
        ready = false
        displays = system.displays()
        installObservers()
        let token = epoch
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await library.load()
                guard active, epoch == token, !Task.isCancelled else { return }
                state = loaded
                ready = true
                reconcileOwnership()
                restartWatcher()
                scan()
                updateTimer()
                await refreshUsage()
                publish()
            } catch {
                guard active, epoch == token, !Task.isCancelled else { return }
                self.error = text("The library could not be read. Existing data was preserved.")
                publish()
            }
        }
        return loadTask
    }

    func deactivate() {
        active = false
        invalidate()
        loadTask?.cancel(); scanTask?.cancel(); searchTask?.cancel()
        prefetchTask?.cancel()
        Task { await transfers.cancelAll() }
        timer?.invalidate(); timer = nil; watcher = nil
        folderFallbackTimer?.invalidate(); folderFallbackTimer = nil
        deadlines.removeAll()
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
        // The debounced final save is allowed to finish; it never writes to the desktop.
    }

    func refreshDisplays() {
        guard active else { return }
        let updated = system.displays()
        if updated != displays { invalidate(); displays = updated }
        reconcileOwnership()
        updateTimer()
        publish()
    }

    func targets(_ scope: String) -> [WallpaperDisplay] {
        scope == "all" ? displays : displays.filter { $0.id == scope }
    }

    func scopeTitle(_ scope: String) -> String {
        scope == "all" ? text("All Displays") : displays.first { $0.id == scope }.map { "\($0.name) · \($0.id.prefix(4))" } ?? text("Disconnected Display")
    }

    func configure(_ change: (inout WallpaperProfile) -> Void) {
        guard ready else { return }
        invalidate()
        var updated = profile
        change(&updated)
        updated.bag = []
        updated.retryCount = 0
        if updated.enabled {
            updated.nextDate = Date().addingTimeInterval(updated.interval)
            deadlines[state.selectedScope] = .now.advanced(by: .seconds(updated.interval))
        }
        state.profiles[state.selectedScope] = updated
        persist(); updateTimer()
    }

    func selectScope(_ scope: String) {
        guard scope == "all" || displays.contains(where: { $0.id == scope }), ready else { return }
        invalidate()
        if !state.independentDisplays || scope == "all" {
            for key in state.profiles.keys where key != scope { state.profiles[key]?.enabled = false }
        }
        state.selectedScope = scope
        if state.profiles[scope] == nil { state.profiles[scope] = WallpaperProfile() }
        persist(); updateTimer()
    }

    func setIndependent(_ enabled: Bool) {
        guard ready else { return }
        invalidate()
        for key in state.profiles.keys { state.profiles[key]?.enabled = false }
        state.independentDisplays = enabled
        state.selectedScope = enabled ? displays.first?.id ?? "all" : "all"
        if state.profiles[state.selectedScope] == nil { state.profiles[state.selectedScope] = WallpaperProfile() }
        persist(); updateTimer()
    }

    func addFolder() {
        guard ready else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.begin { [weak self] result in
            guard result == .OK else { return }
            Task { @MainActor in
                guard let self, self.active else { return }
                for url in panel.urls where !self.state.folders.contains(where: { $0.url == url }) {
                    do {
                        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                        self.state.folders.append(WallpaperFolder(url: url, bookmark: bookmark))
                    } catch { self.error = self.text("The folder is unavailable. Select it again.") }
                }
                self.persist(); self.restartWatcher(); self.scan()
            }
        }
    }

    func updateFolder(_ id: UUID, recursive: Bool? = nil, included: Bool? = nil, remove: Bool = false) {
        guard ready else { return }
        invalidate()
        if remove { state.folders.removeAll { $0.id == id } }
        else if let index = state.folders.firstIndex(where: { $0.id == id }) {
            if let recursive { state.folders[index].recursive = recursive }
            if let included { state.folders[index].included = included }
        }
        persist(); restartWatcher(); scan()
    }

    func scan() {
        guard active, ready else { return }
        scanTask?.cancel()
        folderEpoch &+= 1
        let token = folderEpoch
        let folders = state.folders
        scanning = true
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                let result = try await library.scan(folders)
                guard active, token == folderEpoch, !Task.isCancelled else { return }
                let discovered = Set(result.assets.map(\.id))
                for (id, asset) in state.assets where asset.folderID.map(result.completeFolderIDs.contains) == true && !discovered.contains(id) {
                    state.assets[id]?.folderID = nil
                    state.assets[id]?.localURL = nil
                }
                for var asset in result.assets {
                    asset.managedName = state.assets[asset.id]?.managedName
                    state.assets[asset.id] = asset
                }
                for resolved in result.resolvedFolders {
                    if let index = state.folders.firstIndex(where: { $0.id == resolved.id }) { state.folders[index] = resolved }
                }
                folderIssues = result.issues
                scanning = false
                persist()
            } catch is CancellationError { }
            catch { if token == folderEpoch { scanning = false; self.error = message(error); publish() } }
        }
    }

    func search(_ query: WallpaperQuery, more: Bool = false) {
        guard ready, active, !isSuspended else { return }
        searchTask?.cancel()
        queryEpoch &+= 1
        let token = queryEpoch
        searching = true
        let page = more ? currentPage + 1 : 1
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
                let result = try await source.search(query, page: page)
                guard active, token == queryEpoch, !Task.isCancelled else { return }
                for var asset in result.assets {
                    asset.managedName = state.assets[asset.id]?.managedName
                    state.assets[asset.id] = asset
                }
                searchIDs = Array(Set((more ? searchIDs : []) + result.assets.map(\.id))).sorted()
                state.queryMembership[query.identity, default: []].formUnion(result.assets.map(\.id))
                currentPage = result.page; lastPage = result.lastPage
                searching = false; remoteRevision = query.identity; error = nil
                persist()
            } catch is CancellationError { }
            catch { if active, token == queryEpoch { searching = false; self.error = message(error); publish() } }
        }
    }

    func useQuery(_ query: WallpaperQuery) {
        configure { $0.collection = .wallhaven; $0.query = query }
    }

    func assets(in section: String, query: String) -> [WallpaperAsset] {
        let ids: [String]
        switch section {
        case "wallhaven": ids = searchIDs
        case "favorites": ids = Array(state.favorites)
        case "history": ids = targets(state.selectedScope).flatMap { state.history[$0.id]?.entries.reversed() ?? [] }
        default:
            ids = state.assets.values.filter { asset in
                guard let folderID = asset.folderID else { return false }
                return section == "local" ? state.folders.contains { $0.id == folderID } : folderID.uuidString == section
            }.map(\.id)
        }
        var seen = Set<String>()
        let assets = ids.compactMap { id -> WallpaperAsset? in
            guard seen.insert(id).inserted, let asset = state.assets[id],
                  section == "wallhaven" || query.isEmpty || asset.title.localizedStandardContains(query) else { return nil }
            return asset
        }
        return section == "history" ? assets : assets.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func thumbnail(_ asset: WallpaperAsset) async -> Data? {
        guard active, !Task.isCancelled else { return nil }
        if let cached = try? await library.thumbnail(asset) { return cached }
        guard let url = asset.thumbnailURL, !isSuspended else { return nil }
        do {
            let data = try await transfers.fetch(url, limit: 4 * 1_024 * 1_024)
            try Task.checkCancellation()
            guard active, !isSuspended else { return nil }
            return try await library.thumbnail(asset, remoteData: data)
        } catch { return nil }
    }

    func favorite(_ id: String) async {
        guard ready, active, let asset = state.assets[id] else { return }
        if state.favorites.contains(id), await library.readable(asset) { state.favorites.remove(id); persist(); return }
        state.favorites.insert(id); persist()
        let token = epoch
        do {
            let imported = try await prepare(asset)
            guard active, epoch == token, !Task.isCancelled else { return }
            state.assets[id] = imported; persist(); await refreshUsage()
        } catch { if active, epoch == token { self.error = message(error); publish() } }
    }

    private func prepare(_ asset: WallpaperAsset) async throws -> WallpaperAsset {
        pendingImports += 1
        defer { pendingImports -= 1 }
        if await library.readable(asset) { return asset }
        if let remote = asset.remoteURL {
            let data = try await transfers.fetch(remote, limit: 50 * 1_024 * 1_024)
            return try await library.prepare(asset, remoteData: data)
        }
        let folder = state.folders.first { $0.id == asset.folderID }
        let access = folder?.url.startAccessingSecurityScopedResource() ?? false
        defer { if access { folder?.url.stopAccessingSecurityScopedResource() } }
        return try await library.prepare(asset)
    }

    func execute(_ command: String, assetID: String? = nil, scope: String? = nil, automatic: Bool = false) async -> ActionExecutionResult {
        guard active, ready, !busy, !isSuspended else { return .failed(message: text("Wallpaper is busy or unavailable.")) }
        let scope = scope ?? state.selectedScope
        guard scope == "all" || displays.contains(where: { $0.id == scope }) else { return .failed(message: text("Disconnected Display")) }
        busy = true
        operationScope = scope
        let token = epoch
        let task = Task { [weak self] in
            guard let self else { return ActionExecutionResult.cancelled }
            return await self.perform(command, assetID: assetID, scope: scope, automatic: automatic, token: token)
        }
        operation = task
        publish()
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if epoch == token { operation = nil; operationScope = nil; busy = false; publish() }
        return result
    }

    func cancelOperation() {
        let scope = operationScope
        invalidate()
        if let scope { state.profiles[scope]?.enabled = false; state.profiles[scope]?.pauseReason = nil }
        persist(); updateTimer()
    }

    private func perform(_ command: String, assetID: String?, scope: String, automatic: Bool, token: UInt) async -> ActionExecutionResult {
        do {
            var profile = state.profiles[scope] ?? WallpaperProfile()
            let targets = targets(scope)
            guard !targets.isEmpty else { throw WallpaperFailure.disconnected }
            if automatic {
                guard profile.enabled, ownershipMatches(scope) else { throw CancellationError() }
            }
            let targetIDs = automatic && scope == "all" ? targets.filter { profile.admittedDisplays.contains($0.id) } : targets
            guard !targetIDs.isEmpty else { throw WallpaperFailure.disconnected }
            var requests: [(WallpaperDisplay, WallpaperAsset, Int?)] = []
            if command == "previous" || (command == "next" && hasForwardHistory(scope)) {
                for display in targetIDs {
                    let history = state.history[display.id] ?? WallpaperHistory()
                    guard history.entries.indices.contains(history.cursor) else { throw WallpaperFailure.missingFile }
                    let index = history.cursor + (command == "previous" ? -1 : 1)
                    guard history.entries.indices.contains(index), let asset = state.assets[history.entries[index]],
                          await library.readable(asset) else { throw WallpaperFailure.missingFile }
                    requests.append((display, asset, index))
                }
            } else {
                var chosen: WallpaperAsset?
                if command == "apply-asset", let assetID { chosen = state.assets[assetID] }
                else {
                    var candidates = collectionAssets(profile)
                    if profile.collection == .wallhaven, candidates.isEmpty || candidates.count < 3 {
                        do {
                            let page = try await source.search(profile.query, page: 1)
                            guard active, token == epoch, !Task.isCancelled else { throw CancellationError() }
                            for var asset in page.assets {
                                asset.managedName = state.assets[asset.id]?.managedName
                                state.assets[asset.id] = asset
                            }
                            state.queryMembership[profile.query.identity, default: []].formUnion(page.assets.map(\.id))
                            candidates = collectionAssets(profile)
                        } catch {
                            if candidates.isEmpty { throw error }
                        }
                    }
                    let current = state.history[targetIDs[0].id].flatMap { $0.entries.indices.contains($0.cursor) ? $0.entries[$0.cursor] : nil }
                    var lastError: Error = WallpaperFailure.noCandidates
                    for _ in 0..<min(10, candidates.count) {
                        guard let id = WallpaperSelection.next(candidates: candidates.map(\.id), current: current, profile: &profile),
                              let candidate = state.assets[id] else { break }
                        do { chosen = try await prepare(candidate); break }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            lastError = error
                            candidates.removeAll { $0.id == id }
                        }
                    }
                    if chosen == nil { throw lastError }
                }
                guard let chosen else { throw WallpaperFailure.noCandidates }
                let imported = try await prepare(chosen)
                requests = targetIDs.map { ($0, imported, nil) }
            }
            guard active, epoch == token, !Task.isCancelled, !isSuspended else { throw CancellationError() }
            // Pin the payload before the OS can reference it, including after a process crash.
            for (_, asset, _) in requests {
                state.assets[asset.id] = asset
                state.appliedIDs.insert(asset.id)
                if let name = asset.managedName { state.appliedNames.insert(name) }
            }
            try await saveNow()
            var failures = 0
            var successes = 0
            for (display, asset, historyIndex) in requests {
                guard active, epoch == token, !Task.isCancelled, !isSuspended else { break }
                if automatic, !ownershipMatches(scope) {
                    profile.enabled = false
                    profile.pauseReason = state.profiles[scope]?.pauseReason
                    failures += 1
                    break
                }
                guard let url = library.managedURL(asset) else { failures += 1; continue }
                do {
                    let expected = WallpaperDesktopState(url: url.standardizedFileURL, fill: profile.fill)
                    if system.read(displayID: display.id) != expected { try system.apply(url, displayID: display.id, fill: profile.fill) }
                    profile.expected[display.id] = expected
                    profile.admittedDisplays.insert(display.id)
                    var history = state.history[display.id] ?? WallpaperHistory()
                    if let historyIndex { history.cursor = historyIndex } else { history.record(asset.id) }
                    state.history[display.id] = history
                    successes += 1
                    profile.recent = Array((profile.recent + [asset.id]).suffix(100))
                    // Ownership checks for subsequent screens must see successful writes immediately.
                    state.profiles[scope] = profile
                } catch { failures += 1 }
            }
            guard active, epoch == token, !Task.isCancelled else { try await saveNow(); return .cancelled }
            guard successes > 0 else { throw WallpaperFailure.disconnected }
            profile.retryCount = 0
            profile.nextDate = Date().addingTimeInterval(profile.interval)
            deadlines[scope] = .now.advanced(by: .seconds(profile.interval))
            profile.started = true
            if failures > 0 { profile.enabled = false; profile.pauseReason = "Some displays could not be updated. Rotation is paused." }
            state.profiles[scope] = profile
            try await saveNow()
            await refreshUsage()
            error = failures > 0 ? text("Some displays could not be updated. Rotation is paused.") : nil
            updateTimer()
            if failures == 0 { prefetch(scope) }
            return failures > 0 ? .failed(message: error!) : .succeeded()
        } catch is CancellationError { return .cancelled }
        catch {
            guard token == epoch, active else { return .cancelled }
            self.error = message(error)
            if automatic { scheduleRetry(error, scope: scope) }
            publish()
            return .failed(message: self.error!)
        }
    }

    private func collectionAssets(_ profile: WallpaperProfile) -> [WallpaperAsset] {
        let eligible = state.assets.values.filter { asset in
            switch profile.collection {
            case .local: return state.folders.contains { $0.id == asset.folderID && $0.included }
            case .favorites: return state.favorites.contains(asset.id) && asset.managedName != nil
            case .wallhaven: return state.queryMembership[profile.query.identity]?.contains(asset.id) == true
            }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if profile.collection == .wallhaven {
            let unseen = eligible.filter { !profile.recent.contains($0.id) }
            return unseen.isEmpty ? eligible : unseen
        }
        return eligible
    }

    private func prefetch(_ scope: String) {
        guard state.profiles[scope]?.enabled == true,
              let profile = state.profiles[scope], profile.collection == .wallhaven, !isSuspended else { return }
        prefetchTask?.cancel()
        let token = epoch
        let candidates = Array(collectionAssets(profile).prefix(2))
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            for candidate in candidates {
                do {
                    try Task.checkCancellation()
                    let imported = try await prepare(candidate)
                    guard active, epoch == token, !Task.isCancelled, !isSuspended else { return }
                    state.assets[imported.id] = imported
                    persist()
                } catch { return }
            }
        }
    }

    private func hasForwardHistory(_ scope: String) -> Bool {
        let values = targets(scope).compactMap { state.history[$0.id] }
        return values.count == targets(scope).count && !values.isEmpty && values.allSatisfy {
            $0.entries.indices.contains($0.cursor) && $0.cursor < $0.entries.count - 1
        }
    }

    func setRotation(_ enabled: Bool) async -> ActionExecutionResult {
        guard active, ready else { return .failed(message: text("Wallpaper is busy or unavailable.")) }
        let scope = state.selectedScope
        let token = epoch
        if !enabled {
            invalidate()
            state.profiles[scope, default: WallpaperProfile()].enabled = false
            state.profiles[scope]?.pauseReason = nil
            persist(); updateTimer()
            return .succeeded()
        }
        if profile.enabled { return .succeeded() }
        guard !busy, !isSuspended else { return .failed(message: text("Wallpaper is busy or unavailable.")) }
        if !profile.started {
            let result = await execute("next")
            guard case .succeeded = result else { return result }
        }
        guard active, epoch == token, state.selectedScope == scope, !isSuspended else { return .cancelled }
        var updated = state.profiles[scope] ?? WallpaperProfile()
        let available = targets(scope)
        guard !available.isEmpty else { return .failed(message: text("Disconnected Display")) }
        for display in available {
            guard let desktop = system.read(displayID: display.id) else { return .failed(message: text("The desktop could not be verified. Resume manually.")) }
            updated.expected[display.id] = desktop
        }
        updated.admittedDisplays = Set(available.map(\.id))
        updated.enabled = true; updated.pauseReason = nil; updated.retryCount = 0
        updated.nextDate = Date().addingTimeInterval(updated.interval)
        deadlines[scope] = .now.advanced(by: .seconds(updated.interval))
        state.profiles[scope] = updated
        persist(); updateTimer(); prefetch(scope)
        return .succeeded()
    }

    private func ownershipMatches(_ scope: String) -> Bool {
        guard let profile = state.profiles[scope] else { return false }
        for display in targets(scope) where profile.admittedDisplays.contains(display.id) {
            guard let actual = system.read(displayID: display.id), actual == profile.expected[display.id] else {
                state.profiles[scope]?.enabled = false
                state.profiles[scope]?.pauseReason = "The wallpaper changed outside MacTools. Rotation is paused."
                persist(); updateTimer()
                return false
            }
        }
        return true
    }

    private func reconcileOwnership() {
        for (scope, profile) in state.profiles where profile.enabled { _ = ownershipMatches(scope) }
    }

    private func updateTimer() {
        timer?.invalidate(); timer = nil
        deadlines = deadlines.filter { state.profiles[$0.key]?.enabled == true }
        guard active, state.profiles.values.contains(where: \.enabled) else { return }
        for (scope, profile) in state.profiles where profile.enabled && deadlines[scope] == nil {
            deadlines[scope] = .now.advanced(by: .seconds(max(0, min(profile.interval, profile.nextDate?.timeIntervalSinceNow ?? profile.interval))))
        }
        let remaining = deadlines.filter { !targets($0.key).isEmpty }.values.map { ContinuousClock.now.duration(to: $0).components }
            .map { max(1, Double($0.seconds) + Double($0.attoseconds) / 1e18) }
        let timer = Timer(timeInterval: min(60, remaining.min() ?? 60), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer.tolerance = 5
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func tick() async {
        guard active, ready, !isSuspended, !busy else { return }
        let now = Date()
        if now.timeIntervalSince(lastOwnershipCheck) >= 60 { reconcileOwnership(); lastOwnershipCheck = now }
        for (scope, profile) in state.profiles where profile.enabled && !targets(scope).isEmpty {
            guard let due = deadlines[scope], due <= .now else { continue }
            _ = await execute("next", scope: scope, automatic: true)
        }
    }

    private func scheduleRetry(_ failure: Error, scope: String) {
        var profile = state.profiles[scope] ?? WallpaperProfile()
        let retryable: Bool
        var minimumDelay: TimeInterval = 0
        switch failure {
        case let WallpaperFailure.rateLimited(delay): retryable = true; minimumDelay = delay
        case let WallpaperFailure.http(code): retryable = code >= 500
        case is URLError: retryable = true
        default: retryable = false
        }
        let retryCount = max(0, profile.retryCount)
        if retryable, retryCount < 3 {
            profile.nextDate = Date().addingTimeInterval(max([60.0, 300, 900][retryCount], minimumDelay))
            deadlines[scope] = .now.advanced(by: .seconds(max([60.0, 300, 900][retryCount], minimumDelay)))
            profile.retryCount = retryCount + 1
        } else {
            profile.enabled = false
            profile.pauseReason = "Rotation stopped. Check the source and resume."
        }
        state.profiles[scope] = profile
        persist(); updateTimer()
    }

    func cleanCache(clear: Bool = true) async {
        guard !busy, pendingImports == 0, ready else { return }
        do { try await library.clean(state: state, clear: clear); await refreshUsage() }
        catch { self.error = message(error); publish() }
    }

    func setCacheBudget(_ value: Int64) {
        state.cacheBudget = value
        persist()
        Task { await cleanCache(clear: false) }
    }

    func saveImage(_ asset: WallpaperAsset) async {
        do {
            let imported = try await prepare(asset)
            guard active, let url = library.managedURL(imported) else { return }
            state.assets[asset.id] = imported; persist()
            let panel = NSSavePanel()
            panel.title = text("Save Image…")
            panel.isExtensionHidden = false
            if let type = UTType(filenameExtension: url.pathExtension) { panel.allowedContentTypes = [type] }
            panel.nameFieldStringValue = (asset.title as NSString).deletingPathExtension + "." + url.pathExtension
            guard await panel.begin() == .OK, let destination = panel.url else { return }
            try await Task.detached {
                let data = try Data(contentsOf: url)
                try data.write(to: destination, options: .atomic)
            }.value
        } catch { self.error = message(error); publish() }
    }

    func openSource(_ asset: WallpaperAsset) {
        if let url = asset.pageURL, WallpaperHTTP.allows(url) { NSWorkspace.shared.open(url) }
        else if let url = asset.localURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func restartWatcher() {
        folderFallbackTimer?.invalidate(); folderFallbackTimer = nil
        watcher = WallpaperFolderObserver(urls: state.folders.map(\.url)) { [weak self] in self?.scan() }
        if !state.folders.isEmpty, watcher?.isWatching != true {
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.scan() }
            }
            timer.tolerance = 10
            folderFallbackTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in action() }
            }
            observations.append((center, token))
        }
        observe(NSWorkspace.willSleepNotification) { [weak self] in self?.suspend("sleep") }
        observe(NSWorkspace.screensDidSleepNotification) { [weak self] in self?.suspend("display") }
        observe(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.suspend("session") }
        observe(NSWorkspace.didWakeNotification) { [weak self] in self?.resume("sleep") }
        observe(NSWorkspace.screensDidWakeNotification) { [weak self] in self?.resume("display") }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.resume("session") }
        observe(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in self?.refreshDisplays() }
        observe(NSWorkspace.didMountNotification) { [weak self] in self?.scan() }
        observe(NSWorkspace.didUnmountNotification) { [weak self] in self?.scan() }
        let distributed = DistributedNotificationCenter.default()
        for (name, suspended) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            let token = distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if suspended { self?.suspend("lock") } else { self?.resume("lock") } }
            }
            observations.append((distributed, token))
        }
    }

    private func suspend(_ reason: String) {
        suspendedReasons.insert(reason); invalidate(); prefetchTask?.cancel()
        searchTask?.cancel(); searching = false
        Task { await transfers.cancelAll() }
        publish()
    }
    private func resume(_ reason: String) {
        suspendedReasons.remove(reason)
        guard !isSuspended else { return }
        refreshDisplays(); scan()
        Task { await tick() }
    }

    private func invalidate() {
        epoch &+= 1; operation?.cancel(); operation = nil; operationScope = nil; busy = false
        prefetchTask?.cancel()
    }
    private func publish() { objectWillChange.send(); onChange?() }
    private func persist() {
        guard ready else { return }
        pruneDiscoveryMetadata()
        saveTask?.cancel()
        revision &+= 1
        let revision = revision
        let snapshot = state
        saveTask = Task { [weak self, library] in
            do {
                try await Task.sleep(for: .milliseconds(100))
                try await library.save(snapshot, revision: revision)
            } catch is CancellationError { }
            catch { self?.error = self?.text("Changes could not be saved. Check available disk space."); self?.publish() }
        }
        publish()
    }

    private func saveNow() async throws {
        pruneDiscoveryMetadata()
        saveTask?.cancel(); revision &+= 1
        try await library.save(state, revision: revision)
    }

    private func pruneDiscoveryMetadata() {
        var queries = Set(state.profiles.values.filter { $0.collection == .wallhaven }.map { $0.query.identity })
        if let remoteRevision { queries.insert(remoteRevision) }
        state.queryMembership = state.queryMembership.filter { queries.contains($0.key) }
        var retained = state.appliedIDs.union(state.favorites).union(searchIDs)
        for history in state.history.values { retained.formUnion(history.entries) }
        for ids in state.queryMembership.values { retained.formUnion(ids) }
        let folders = Set(state.folders.map(\.id))
        state.assets = state.assets.filter { id, asset in
            retained.contains(id) || asset.folderID.map(folders.contains) == true
        }
    }

    func refreshUsage() async { if let value = try? await library.usage() { usage = value } }

    func message(_ error: Error) -> String {
        switch error {
        case WallpaperFailure.invalidImage: text("The image is unsupported, damaged, or too large.")
        case WallpaperFailure.noCandidates: text("No usable images. Choose a folder, favorites, or an online search.")
        case WallpaperFailure.missingFile: text("The image is unavailable. Choose another image.")
        case WallpaperFailure.disconnected: text("Disconnected Display")
        case WallpaperFailure.rateLimited: text("Wallhaven is busy. Try again later.")
        case is URLError: text("The network is unavailable. Your wallpaper was kept.")
        default: text("The operation failed. Your current wallpaper was kept where possible.")
        }
    }
}
