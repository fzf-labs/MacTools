import AppKit
import Foundation
import MacToolsPluginKit

@MainActor
final class IPOverviewViewModel: ObservableObject {
    private enum RefreshMode {
        case full
        case addresses
    }

    private enum StorageKey {
        static let cachedState = "cachedState"
        static let hidesSensitiveInfo = "hidesSensitiveInfo"
    }

    private struct CachedState: Codable {
        let cachedAt: Date
        let fullSnapshotCachedAt: Date?
        let snapshot: IPOverviewSnapshot
        let connectivityResults: [IPOverviewConnectivityResult]
        let webRTCResults: [IPOverviewLeakTestResult]
        let dnsLeakResults: [IPOverviewLeakTestResult]
        let networkQualityState: IPOverviewNetworkQualityRunState
    }

    private static let cacheTimeToLive: TimeInterval = 24 * 60 * 60

    @Published private(set) var snapshot: IPOverviewSnapshot = .empty {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var connectivityResults: [IPOverviewConnectivityResult] = [] {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var isCheckingConnectivity = false {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var webRTCResults: [IPOverviewLeakTestResult] = [] {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var dnsLeakResults: [IPOverviewLeakTestResult] = [] {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var isCheckingWebRTC = false {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var isCheckingDNSLeak = false {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var networkQualityState: IPOverviewNetworkQualityRunState = .waiting {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var isShowingDetails = false {
        didSet {
            onSnapshotChange?()
        }
    }
    @Published private(set) var hidesSensitiveInfo = false {
        didSet {
            onSnapshotChange?()
        }
    }
    private let provider: any IPOverviewProviding
    private let connectivityChecker: any IPOverviewConnectivityChecking
    private let leakTester: any IPOverviewLeakTesting
    private let networkQualityMeasurer: any IPOverviewNetworkQualityMeasuring
    private let storage: PluginStorage
    private let localization: PluginLocalization
    private let pasteboard: NSPasteboard
    private let currentDate: @MainActor () -> Date
    private var refreshTask: Task<Void, Never>?
    private var refreshMode: RefreshMode?
    private var refreshGeneration = 0
    private var connectivityTask: Task<Void, Never>?
    private var webRTCTask: Task<Void, Never>?
    private var dnsLeakTask: Task<Void, Never>?
    private var networkQualityTask: Task<Void, Never>?
    private var stateCachedAt: Date?
    private var fullSnapshotCachedAt: Date?
    var onSnapshotChange: (() -> Void)?

    var isRefreshingAll: Bool {
        snapshot.isRefreshing
            || isCheckingConnectivity
            || isCheckingWebRTC
            || isCheckingDNSLeak
            || isMeasuringNetworkQuality
    }

    var isMeasuringNetworkQuality: Bool {
        if case .running = networkQualityState {
            return true
        }

        return false
    }

    init(
        provider: (any IPOverviewProviding)? = nil,
        connectivityChecker: (any IPOverviewConnectivityChecking)? = nil,
        leakTester: (any IPOverviewLeakTesting)? = nil,
        networkQualityMeasurer: (any IPOverviewNetworkQualityMeasuring)? = nil,
        storage: PluginStorage = UserDefaultsPluginStorage(pluginID: "ip-overview"),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        pasteboard: NSPasteboard = .general,
        currentDate: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.localization = localization
        self.provider = provider ?? IPOverviewService(localization: localization)
        self.connectivityChecker = connectivityChecker ?? IPOverviewConnectivityService(localization: localization)
        self.leakTester = leakTester ?? IPOverviewLeakTestService(localization: localization)
        self.networkQualityMeasurer = networkQualityMeasurer ?? IPOverviewNetworkQualityService(localization: localization)
        self.storage = storage
        _ = Self.portableStore(storage: storage).recover()
        self.currentDate = currentDate
        self.pasteboard = pasteboard
        self.hidesSensitiveInfo = storage.bool(forKey: StorageKey.hidesSensitiveInfo)
        self.connectivityResults = Self.loadConnectivityTargets(storage: storage).map {
            IPOverviewConnectivityResult(id: $0.id, target: $0, status: .waiting)
        }
        self.webRTCResults = IPOverviewWebRTCTarget.defaults.map {
            IPOverviewLeakTestResult(id: $0.id, name: $0.name, status: .waiting)
        }
        self.dnsLeakResults = Self.dnsLeakProbes(localization: localization).map {
            IPOverviewLeakTestResult(id: $0.id, name: $0.name, status: .waiting)
        }
        restoreCachedStateIfFresh()
    }

    deinit {
        refreshTask?.cancel()
        connectivityTask?.cancel()
        webRTCTask?.cancel()
        dnsLeakTask?.cancel()
        networkQualityTask?.cancel()
    }

    @discardableResult
    func refreshIfNeeded() -> Task<Void, Never>? {
        guard !hasFreshSnapshot else {
            return nil
        }

        return refreshAddresses()
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard refreshTask == nil else {
            return nil
        }

        snapshot.isRefreshing = true
        snapshot.errorMessage = nil
        refreshMode = .full
        refreshGeneration += 1
        let generation = refreshGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let nextSnapshot = await provider.collectSnapshot()
            defer {
                clearRefreshTask(generation: generation)
            }
            guard !Task.isCancelled, refreshGeneration == generation else { return }
            snapshot = nextSnapshot
            cacheCurrentState(includeFullSnapshot: true)
        }
        refreshTask = task
        return task
    }

    @discardableResult
    func refreshAddresses() -> Task<Void, Never>? {
        guard refreshTask == nil else {
            return nil
        }

        snapshot.isRefreshing = true
        snapshot.errorMessage = nil
        refreshMode = .addresses
        refreshGeneration += 1
        let generation = refreshGeneration
        let currentSnapshot = snapshot
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let nextSnapshot = await provider.collectAddressSnapshot(preserving: currentSnapshot)
            defer {
                clearRefreshTask(generation: generation)
            }
            guard !Task.isCancelled, refreshGeneration == generation else { return }
            snapshot = nextSnapshot
            cacheCurrentState()
        }
        refreshTask = task
        return task
    }

    func refreshAddressesAndWait() async {
        let task = refreshAddresses() ?? refreshTask
        await task?.value
    }

    func refreshAllIfNeeded() {
        guard !hasFreshDetailState else {
            checkDiagnosticsIfNeeded()
            measureNetworkQualityIfNeeded()
            return
        }

        refreshAll()
    }

    func refreshAll() {
        if refreshMode == .addresses {
            cancelRefresh()
        }

        refresh()
        checkConnectivity()
        checkWebRTCLeak()
        checkDNSLeak()
        measureNetworkQuality()
    }

    func showDetails() {
        isShowingDetails = true
    }

    func showSummary() {
        isShowingDetails = false
    }

    var onPersistentPreferencesChange: (() -> Void)?
    private static func portableStore(storage: any PluginStorage) -> PortablePreferencesStore {
        PortablePreferencesStore(storage: storage, fields: [StorageKey.hidesSensitiveInfo: .boolean(false)])
    }
    private var portableStore: PortablePreferencesStore { Self.portableStore(storage: storage) }
    func portableBackup() -> Data? { portableStore.backup() }
    func restorePortableBackup(_ data: Data) -> Bool {
        let before = hidesSensitiveInfo
        guard portableStore.restore(data) else { return false }
        hidesSensitiveInfo = storage.object(forKey: StorageKey.hidesSensitiveInfo) as? Bool ?? false
        if before != hidesSensitiveInfo { onPersistentPreferencesChange?() }
        return true
    }

    func toggleSensitiveInfoVisibility() {
        let candidate = !hidesSensitiveInfo
        guard portableStore.commit([StorageKey.hidesSensitiveInfo: .boolean(candidate)]) else { return }
        hidesSensitiveInfo = candidate
        onPersistentPreferencesChange?()
    }

    func cancel() {
        cancelRefresh()
        connectivityTask?.cancel()
        connectivityTask = nil
        isCheckingConnectivity = false
        webRTCTask?.cancel()
        webRTCTask = nil
        isCheckingWebRTC = false
        dnsLeakTask?.cancel()
        dnsLeakTask = nil
        isCheckingDNSLeak = false
        networkQualityTask?.cancel()
        networkQualityTask = nil
        if isMeasuringNetworkQuality {
            networkQualityState = .failed(localization.string("speed.error.cancelled", defaultValue: "测速已取消"))
        }
    }

    func copy(_ value: String?) {
        guard let value, !value.isEmpty else {
            return
        }

        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    func checkConnectivity() {
        guard connectivityTask == nil else {
            return
        }

        isCheckingConnectivity = true
        connectivityResults = connectivityResults.map {
            IPOverviewConnectivityResult(id: $0.id, target: $0.target, status: .checking)
        }

        let targets = connectivityResults.map(\.target)
        connectivityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                connectivityTask = nil
                isCheckingConnectivity = false
            }

            var nextResults: [IPOverviewConnectivityResult] = []
            for target in targets {
                guard !Task.isCancelled else { return }
                let result = await connectivityChecker.check(target: target)
                nextResults.append(result)
                connectivityResults = targets.map { candidate in
                    nextResults.first(where: { $0.id == candidate.id })
                        ?? IPOverviewConnectivityResult(
                            id: candidate.id,
                            target: candidate,
                            status: .checking
                        )
                }
            }
            cacheCurrentState()
        }
    }

    func addConnectivityTarget(name: String, urlString: String) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURLString = Self.normalizedURLString(urlString)
        guard !trimmedName.isEmpty else {
            return localization.string("customTarget.error.emptyName", defaultValue: "请输入名称")
        }
        guard let normalizedURLString, URL(string: normalizedURLString) != nil else {
            return localization.string("customTarget.error.invalidURL", defaultValue: "请输入有效 URL")
        }

        let target = IPOverviewConnectivityTarget(
            id: "custom-\(UUID().uuidString)",
            name: trimmedName,
            urlString: normalizedURLString,
            isCustom: true
        )
        let targets = connectivityResults.map(\.target) + [target]
        saveConnectivityTargets(targets)
        connectivityResults.append(IPOverviewConnectivityResult(
            id: target.id,
            target: target,
            status: .waiting
        ))
        cacheCurrentState()
        return nil
    }

    func removeConnectivityTarget(id: String) {
        guard connectivityResults.contains(where: { $0.id == id && $0.target.isCustom }) else {
            return
        }

        let targets = connectivityResults
            .map(\.target)
            .filter { $0.id != id }
        saveConnectivityTargets(targets)
        connectivityResults.removeAll { $0.id == id }
        cacheCurrentState()
    }

    func checkWebRTCLeak() {
        guard webRTCTask == nil else {
            return
        }

        isCheckingWebRTC = true
        let targets = IPOverviewWebRTCTarget.defaults
        webRTCResults = targets.map {
            IPOverviewLeakTestResult(id: $0.id, name: $0.name, status: .checking)
        }

        webRTCTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                webRTCTask = nil
                isCheckingWebRTC = false
            }

            var nextResults: [IPOverviewLeakTestResult] = []
            for target in targets {
                guard !Task.isCancelled else { return }
                let result = await leakTester.checkWebRTC(target: target)
                nextResults.append(result)
                webRTCResults = targets.map { candidate in
                    nextResults.first(where: { $0.id == candidate.id })
                        ?? IPOverviewLeakTestResult(id: candidate.id, name: candidate.name, status: .checking)
                }
            }
            cacheCurrentState()
        }
    }

    func checkDNSLeak() {
        guard dnsLeakTask == nil else {
            return
        }

        isCheckingDNSLeak = true
        let probes = Self.dnsLeakProbes(localization: localization)
        dnsLeakResults = probes.map {
            IPOverviewLeakTestResult(id: $0.id, name: $0.name, status: .checking)
        }

        dnsLeakTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                dnsLeakTask = nil
                isCheckingDNSLeak = false
            }

            var nextResults: [IPOverviewLeakTestResult] = []
            for probe in probes {
                guard !Task.isCancelled else { return }
                let result = await leakTester.checkDNS(id: probe.id, name: probe.name)
                nextResults.append(result)
                dnsLeakResults = probes.map { candidate in
                    nextResults.first(where: { $0.id == candidate.id })
                        ?? IPOverviewLeakTestResult(id: candidate.id, name: candidate.name, status: .checking)
                }
            }
            cacheCurrentState()
        }
    }

    func measureNetworkQuality() {
        guard networkQualityTask == nil else {
            return
        }

        networkQualityState = .running(.started())
        networkQualityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await networkQualityMeasurer.measure { [weak self] event in
                await MainActor.run {
                    self?.handleNetworkQualityProgress(event)
                }
            }
            defer {
                networkQualityTask = nil
            }
            guard !Task.isCancelled else { return }

            switch result {
            case .success(let measurement):
                networkQualityState = .completed(
                    measurement,
                    completedNetworkQualityProgress(for: measurement)
                )
            case .failure(let message):
                networkQualityState = .failed(message)
            }
            cacheCurrentState()
        }
    }

    private func completedNetworkQualityProgress(
        for measurement: IPOverviewNetworkQualityMeasurement
    ) -> IPOverviewNetworkQualityProgress {
        let existingProgress: IPOverviewNetworkQualityProgress
        if case .running(let progress) = networkQualityState {
            existingProgress = progress
        } else {
            existingProgress = .started()
        }

        return IPOverviewNetworkQualityProgress(
            startedAt: existingProgress.startedAt,
            phase: .measuringLatency,
            downloadSamples: Self.completedNetworkQualitySamples(
                existingProgress.downloadSamples,
                fallback: measurement.downloadMbps
            ),
            uploadSamples: Self.completedNetworkQualitySamples(
                existingProgress.uploadSamples,
                fallback: measurement.uploadMbps
            )
        )
    }

    private func handleNetworkQualityProgress(_ event: IPOverviewNetworkQualityProgressEvent) {
        guard case .running(var progress) = networkQualityState else {
            return
        }

        switch event {
        case .phase(let phase):
            progress.phase = phase
        case .download(let value):
            progress.phase = .measuringDownload
            progress.downloadSamples = Self.appendingNetworkQualitySample(
                value,
                to: progress.downloadSamples
            )
        case .upload(let value):
            progress.phase = .measuringUpload
            progress.uploadSamples = Self.appendingNetworkQualitySample(
                value,
                to: progress.uploadSamples
            )
        }

        networkQualityState = .running(progress)
    }

    func checkDiagnosticsIfNeeded() {
        if connectivityResults.contains(where: { $0.status == .waiting }) {
            checkConnectivity()
        }

        if webRTCResults.contains(where: { $0.status == .waiting }) {
            checkWebRTCLeak()
        }

        if dnsLeakResults.contains(where: { $0.status == .waiting }) {
            checkDNSLeak()
        }
    }

    private var hasFreshSnapshot: Bool {
        guard let freshnessDate = snapshot.lastUpdated else {
            return false
        }

        return Self.isFresh(freshnessDate, now: currentDate())
    }

    private var hasFreshDetailState: Bool {
        guard let fullSnapshotCachedAt else {
            return false
        }

        return Self.isFresh(fullSnapshotCachedAt, now: currentDate())
    }

    private func measureNetworkQualityIfNeeded() {
        switch networkQualityState {
        case .waiting, .failed:
            measureNetworkQuality()
        case .running, .completed:
            return
        }
    }

    @discardableResult
    private func restoreCachedStateIfFresh() -> Bool {
        guard
            let data = storage.data(forKey: StorageKey.cachedState),
            let cachedState = try? JSONDecoder().decode(CachedState.self, from: data),
            Self.isFresh(cachedState.cachedAt, now: currentDate())
        else {
            return false
        }

        var restoredSnapshot = cachedState.snapshot
        restoredSnapshot.isRefreshing = false
        snapshot = restoredSnapshot
        connectivityResults = Self.restoredConnectivityResults(cachedState.connectivityResults)
        webRTCResults = Self.restoredLeakResults(cachedState.webRTCResults)
        dnsLeakResults = Self.restoredLeakResults(cachedState.dnsLeakResults)
        networkQualityState = Self.restoredNetworkQualityState(cachedState.networkQualityState)
        stateCachedAt = cachedState.cachedAt
        fullSnapshotCachedAt = cachedState.fullSnapshotCachedAt
        return true
    }

    private func cacheCurrentState(includeFullSnapshot: Bool = false) {
        let cachedAt = currentDate()
        var cachedSnapshot = snapshot
        cachedSnapshot.isRefreshing = false
        let nextFullSnapshotCachedAt = includeFullSnapshot ? cachedAt : fullSnapshotCachedAt

        let cachedState = CachedState(
            cachedAt: cachedAt,
            fullSnapshotCachedAt: nextFullSnapshotCachedAt,
            snapshot: cachedSnapshot,
            connectivityResults: Self.restoredConnectivityResults(connectivityResults),
            webRTCResults: Self.restoredLeakResults(webRTCResults),
            dnsLeakResults: Self.restoredLeakResults(dnsLeakResults),
            networkQualityState: Self.restoredNetworkQualityState(networkQualityState)
        )

        guard let data = try? JSONEncoder().encode(cachedState) else {
            return
        }

        storage.set(data, forKey: StorageKey.cachedState)
        stateCachedAt = cachedAt
        fullSnapshotCachedAt = nextFullSnapshotCachedAt
    }

    private func saveConnectivityTargets(_ targets: [IPOverviewConnectivityTarget]) {
        guard let data = try? JSONEncoder().encode(targets.filter(\.isCustom)) else {
            return
        }

        storage.set(data, forKey: "customConnectivityTargets")
    }

    private static func loadConnectivityTargets(storage: PluginStorage) -> [IPOverviewConnectivityTarget] {
        guard
            let data = storage.data(forKey: "customConnectivityTargets"),
            let customTargets = try? JSONDecoder().decode([IPOverviewConnectivityTarget].self, from: data)
        else {
            return IPOverviewConnectivityTarget.defaults
        }

        return IPOverviewConnectivityTarget.defaults + customTargets
    }

    private static func normalizedURLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }

        return "https://\(trimmed)"
    }

    private static func appendingNetworkQualitySample(_ value: Double, to samples: [Double]) -> [Double] {
        let maximumSampleCount = 28
        let nextSamples = samples + [value]
        if nextSamples.count <= maximumSampleCount {
            return nextSamples
        }

        return Array(nextSamples.suffix(maximumSampleCount))
    }

    private static func completedNetworkQualitySamples(_ samples: [Double], fallback: Double?) -> [Double] {
        if !samples.isEmpty {
            return samples
        }

        return fallback.map { [$0] } ?? []
    }

    private static func isFresh(_ date: Date, now: Date) -> Bool {
        date >= now || now.timeIntervalSince(date) < cacheTimeToLive
    }

    private static func restoredConnectivityResults(
        _ results: [IPOverviewConnectivityResult]
    ) -> [IPOverviewConnectivityResult] {
        results.map { result in
            if case .checking = result.status {
                return IPOverviewConnectivityResult(id: result.id, target: result.target, status: .waiting)
            }

            return result
        }
    }

    private static func restoredLeakResults(_ results: [IPOverviewLeakTestResult]) -> [IPOverviewLeakTestResult] {
        results.map { result in
            if case .checking = result.status {
                return IPOverviewLeakTestResult(id: result.id, name: result.name, status: .waiting)
            }

            return result
        }
    }

    private static func restoredNetworkQualityState(
        _ state: IPOverviewNetworkQualityRunState
    ) -> IPOverviewNetworkQualityRunState {
        if case .running = state {
            return .waiting
        }

        return state
    }

    private func cancelRefresh() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshMode = nil
        snapshot.isRefreshing = false
    }

    private func clearRefreshTask(generation: Int) {
        guard refreshGeneration == generation else {
            return
        }

        refreshTask = nil
        refreshMode = nil
    }

    private static func dnsLeakProbes(localization: PluginLocalization) -> [(id: String, name: String)] {
        (1...4).map {
            (
                id: "dns-\($0)",
                name: localization.format("dns.probe.name", defaultValue: "DNS 出口检测 #%d", $0)
            )
        }
    }
}
