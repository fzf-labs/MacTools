import AppKit
import Combine
import Foundation
import OSLog
import MacToolsPluginKit

/// Owns discovery outside rendering and shares one snapshot between launcher search and Settings.
@MainActor
final class LauncherSystemSettingsCatalog: ObservableObject {
    struct Request: Sendable {
        let directory: URL
        let languages: [String]
        let fallback: [LauncherSystemSetting]
        let permissionLinks: [LauncherSystemSetting]
        let nameOverrides: [String: String]
        let cache: LauncherSystemSettingsScanner.Cache?
    }

    @Published private(set) var items: [LauncherSystemSetting] = []
    @Published private(set) var isRefreshing = false
    private var cache: LauncherSystemSettingsScanner.Cache?
    private var task: Task<Void, Never>?
    private var hasLoaded = false
    private var pendingRefresh = false
    private let directory: URL
    private let observesChanges: Bool
    private let scan: @Sendable (Request) -> LauncherSystemSettingsScanner.Snapshot
    private let validate: @Sendable (LauncherSystemSetting) -> Bool
    private var directoryObserver: DispatchSourceFileSystemObject?
    private var subscriptions: Set<AnyCancellable> = []
    private var wasFallback: Bool?

    init(directory: URL = LauncherSystemSettingsScanner.directory, observesChanges: Bool = true,
         scan: @escaping @Sendable (Request) -> LauncherSystemSettingsScanner.Snapshot = { request in
             LauncherSystemSettingsScanner.scan(directory: request.directory, languages: request.languages,
                 hardware: .read(), fallback: request.fallback, permissionLinks: request.permissionLinks,
                 nameOverrides: request.nameOverrides, cache: request.cache)
         }, validate: @escaping @Sendable (LauncherSystemSetting) -> Bool = { page in
             let hardware: LauncherSettingsHardware = ["com.apple.Mouse-Settings.extension", "com.apple.Trackpad-Settings.extension"].contains(page.bundleID)
                 ? .read(includingBiometry: false) : .init()
             return LauncherSystemSettingsScanner.isAvailable(page, hardware: hardware)
         }) {
        self.directory = directory
        self.observesChanges = observesChanges
        self.scan = scan
        self.validate = validate
    }

    isolated deinit { task?.cancel(); directoryObserver?.cancel() }

    @discardableResult
    func loadIfNeeded() -> Bool {
        guard !hasLoaded, task == nil else { return false }
        refresh()
        return true
    }

    func refresh(force: Bool = false) {
        if task != nil {
            pendingRefresh = pendingRefresh || force
            return
        }
        startObserving()
        isRefreshing = true
        let request = Request(directory: directory, languages: LauncherBundleNames.systemLanguages,
            fallback: LauncherSystemSettings.entries, permissionLinks: LauncherSystemSettings.permissionLinks,
            nameOverrides: ["energy": LauncherText.energy, "login-password": LauncherText.loginPassword], cache: force ? nil : cache)
        let scan = scan
        task = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) { scan(request) }.value
            guard let self, !Task.isCancelled else { return }
            cache = snapshot.cache
            items = snapshot.items
            hasLoaded = true
            isRefreshing = false
            task = nil
            if snapshot.usedFallback, wasFallback != true {
                AppLog.launcher.warning("System Settings discovery unavailable; using installed compatibility entries")
            }
            wasFallback = snapshot.usedFallback
            if pendingRefresh { pendingRefresh = false; refresh(force: true) }
        }
    }

    func canOpen(_ page: LauncherSystemSetting) async -> Bool {
        guard !Task.isCancelled,
              items.contains(where: { $0.id == page.id && $0.bundleID == page.bundleID }) else { return false }
        let validate = validate
        let available = await Task.detached(priority: .userInitiated) { validate(page) }.value
        return available && !Task.isCancelled
    }

    private func startObserving() {
        guard observesChanges, subscriptions.isEmpty else { return }
        PluginRuntimeLocalization.source.$revision.dropFirst().sink { [weak self] _ in
            self?.refresh(force: true)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh(force: true) }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let observer = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        observer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.refresh(force: true) }
        }
        observer.setCancelHandler { close(descriptor) }
        directoryObserver = observer
        observer.resume()
    }

    #if DEBUG
    func waitForRefreshForTests() async {
        while let task { await task.value }
    }
    #endif
}
