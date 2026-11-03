import AppKit
import Foundation
import MacToolsPluginKit

@MainActor
final class LaunchControlController: ObservableObject {
    @Published private(set) var snapshot = LaunchControlSnapshot()

    var onStateChange: (() -> Void)?
    var onPersistentPreferencesChange: (() -> Void)?
    @Published private(set) var noteRestorationRevisions: [String: UInt] = [:]
    private let portablePreferences: LaunchControlPortablePreferences

    private let scanner: LaunchControlScanner
    private let runner: any LaunchControlCommandRunning
    private let favoritesStore: LaunchControlFavoritesStore
    private let notesStore: LaunchControlNotesStore
    private let localization: PluginLocalization
    private var activeOperations = 0
    private var refreshTask: Task<Void, Never>?

    init(
        scanner: LaunchControlScanner? = nil,
        runner: any LaunchControlCommandRunning = ProcessLaunchControlCommandRunner(),
        favoritesStore: LaunchControlFavoritesStore? = nil,
        notesStore: LaunchControlNotesStore? = nil,
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "launch-control"),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        initialSnapshot: LaunchControlSnapshot = LaunchControlSnapshot()
    ) {
        self.portablePreferences = LaunchControlPortablePreferences(storage: context.storage)
        _ = LaunchControlPortablePreferences.store(context.storage).recover()
        self.snapshot = initialSnapshot
        self.runner = runner
        self.favoritesStore = favoritesStore ?? LaunchControlFavoritesStore(context: context)
        self.notesStore = notesStore ?? LaunchControlNotesStore(context: context)
        self.localization = localization
        self.scanner = scanner ?? LaunchControlScanner(runner: runner, localization: localization)
        self.favoritesStore.onMutation = { [weak self] in self?.onPersistentPreferencesChange?() }
        self.notesStore.onMutation = { [weak self] in
            guard let self, self.portablePreferences.includesNotes else { return }
            self.onPersistentPreferencesChange?()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil

        guard snapshot.isRefreshing else {
            return
        }

        snapshot.isRefreshing = false
        snapshot.currentScanTarget = nil
        appendScanLog(localization.string("controller.scanLog.stopped", defaultValue: "扫描已停止"))
        onStateChange?()
    }

    func refresh() {
        guard !snapshot.isRefreshing else { return }

        snapshot.isRefreshing = true
        snapshot.items = []
        snapshot.selectedItemID = nil
        snapshot.errorMessage = nil
        snapshot.operationMessage = nil
        snapshot.scanLogEntries = [
            localization.string("controller.scanLog.started", defaultValue: "开始扫描 LaunchAgent / LaunchDaemon")
        ]
        snapshot.currentScanTarget = nil
        onStateChange?()

        let progressStream = AsyncStream<LaunchControlScanEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(120)
        )
        let progressTask = Task { @MainActor [weak self] in
            for await event in progressStream.stream {
                self?.handleScanEvent(event)
            }
        }

        refreshTask = Task { [weak self, scanner, progressStream] in
            let result = await Task.detached(priority: .userInitiated) {
                scanner.scan { event in
                    progressStream.continuation.yield(event)
                }
            }.value
            progressStream.continuation.finish()
            await progressTask.value

            guard let self, !Task.isCancelled else { return }
            self.apply(result: result)
        }
    }

    func selectItem(id: String?) {
        snapshot.selectedItemID = id
        onStateChange?()
    }

    func openInFinder(_ item: LaunchControlItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.plistURL])
    }

    func setFavorite(_ isFavorite: Bool, for item: LaunchControlItem) {
        guard favoritesStore.setFavorite(isFavorite, for: item.id) else { return }
        refreshPersistedState(for: item)
        snapshot.operationMessage = isFavorite
            ? localization.format("controller.favorite.added", defaultValue: "已关注 %@", item.label)
            : localization.format("controller.favorite.removed", defaultValue: "已取消关注 %@", item.label)
        onStateChange?()
    }

    func setNote(_ note: String, for item: LaunchControlItem) {
        guard notesStore.setNote(note, for: item.id) else { return }
        refreshPersistedState(for: item)
        let isCleared = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        snapshot.operationMessage = isCleared
            ? localization.format("controller.note.cleared", defaultValue: "已清除备注：%@", item.label)
            : localization.format("controller.note.saved", defaultValue: "已保存备注：%@", item.label)
        onStateChange?()
    }

    var includesNotesInBackup: Bool { portablePreferences.includesNotes }

    func setIncludesNotesInBackup(_ value: Bool) {
        guard value != includesNotesInBackup, portablePreferences.setIncludesNotes(value) else { return }
        onPersistentPreferencesChange?()
        onStateChange?()
        objectWillChange.send()
    }

    var unmatchedBackupReferences: [LaunchControlPortablePreferences.Reference] {
        portablePreferences.unmatchedReferences(matching: Set(snapshot.items.map(\.id)))
    }

    func preferencesBackup() -> Data? { portablePreferences.backup() }

    func restorePreferencesBackup(_ data: Data) -> Bool {
        guard !snapshot.isRefreshing, activeOperations == 0 else { return false }
        let previous = portablePreferences.backup()
        guard portablePreferences.restore(data) else { return false }
        let previousNotes = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0.note) })
        snapshot.items = sortedItems(snapshot.items.map(applyingPersistedState))
        for item in snapshot.items where previousNotes[item.id] != item.note {
            noteRestorationRevisions[item.id, default: 0] &+= 1
        }
        onStateChange?()
        if previous != portablePreferences.backup() { onPersistentPreferencesChange?() }
        return true
    }

    func bootstrap(_ item: LaunchControlItem) {
        scheduleManagedAction(
            item: item,
            title: actionTitle(.bootstrap),
            arguments: ["bootstrap", item.launchctlDomain, item.plistURL.path]
        )
    }

    func bootout(_ item: LaunchControlItem) {
        scheduleManagedAction(
            item: item,
            title: actionTitle(.bootout),
            arguments: ["bootout", item.launchctlDomain, item.plistURL.path]
        )
    }

    func enable(_ item: LaunchControlItem) {
        scheduleManagedAction(
            item: item,
            title: actionTitle(.enable),
            arguments: ["enable", "\(item.launchctlDomain)/\(item.label)"]
        )
    }

    func disable(_ item: LaunchControlItem) {
        scheduleManagedAction(
            item: item,
            title: actionTitle(.disable),
            arguments: ["disable", "\(item.launchctlDomain)/\(item.label)"]
        )
    }

    func start(_ item: LaunchControlItem) {
        scheduleManagedAction(
            item: item,
            title: actionTitle(.start),
            arguments: ["kickstart", "\(item.launchctlDomain)/\(item.label)"]
        )
    }

    func stop(_ item: LaunchControlItem) {
        scheduleManagedAction(
            item: item,
            title: actionTitle(.stop),
            arguments: ["kill", "TERM", "\(item.launchctlDomain)/\(item.label)"]
        )
    }

    func restart(_ item: LaunchControlItem) {
        scheduleManagedAction(
            item: item,
            title: actionTitle(.restart),
            arguments: ["kickstart", "-k", "\(item.launchctlDomain)/\(item.label)"]
        )
    }

    private func apply(result: LaunchControlScanResult) {
        let selectedID = snapshot.selectedItemID
        snapshot.items = sortedItems(result.items.map(applyingPersistedState))
        snapshot.selectedItemID = result.items.contains(where: { $0.id == selectedID })
            ? selectedID
            : result.items.first?.id
        snapshot.isRefreshing = false
        snapshot.lastRefreshDate = Date()
        snapshot.errorMessage = result.warnings.first
        snapshot.currentScanTarget = nil
        appendScanLog(localization.format("controller.scanLog.completed", defaultValue: "扫描完成：%d 项", result.items.count))
        onStateChange?()
    }

    private func handleScanEvent(_ event: LaunchControlScanEvent) {
        switch event {
        case let .directory(path):
            snapshot.currentScanTarget = path
            appendScanLog(localization.format("controller.scanLog.directory", defaultValue: "目录：%@", path))
        case let .file(path):
            snapshot.currentScanTarget = path
            appendScanLog(localization.format(
                "controller.scanLog.file",
                defaultValue: "读取：%@",
                URL(fileURLWithPath: path).lastPathComponent
            ))
        case let .found(item):
            upsertScannedItem(item)
        case let .message(message):
            appendScanLog(message)
        }

        onStateChange?()
    }

    private func upsertScannedItem(_ item: LaunchControlItem) {
        let item = applyingPersistedState(item)

        if let index = snapshot.items.firstIndex(where: { $0.id == item.id }) {
            snapshot.items[index] = item
        } else {
            snapshot.items.append(item)
        }
        snapshot.items = sortedItems(snapshot.items)
        if snapshot.selectedItemID == nil {
            snapshot.selectedItemID = snapshot.items.first?.id
        }
    }

    private func refreshPersistedState(for item: LaunchControlItem) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        snapshot.items[index] = applyingPersistedState(snapshot.items[index])
        snapshot.items = sortedItems(snapshot.items)
    }

    private func applyingPersistedState(_ item: LaunchControlItem) -> LaunchControlItem {
        var updated = item
        updated.isFavorite = favoritesStore.isFavorite(item.id)
        updated.note = notesStore.note(for: item.id)
        return updated
    }

    private func sortedItems(_ items: [LaunchControlItem]) -> [LaunchControlItem] {
        items.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite
            }
            if lhs.origin != rhs.origin {
                return lhs.origin.rawValue < rhs.origin.rawValue
            }
            if lhs.scope != rhs.scope {
                return lhs.scope.rawValue < rhs.scope.rawValue
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private func appendScanLog(_ message: String) {
        snapshot.scanLogEntries.append(message)
        if snapshot.scanLogEntries.count > 80 {
            snapshot.scanLogEntries.removeFirst(snapshot.scanLogEntries.count - 80)
        }
    }

    func performManagedActionAndWait(
        _ action: LaunchControlManagedAction,
        item: LaunchControlItem
    ) async -> Bool {
        let arguments: [String]
        switch action {
        case .start:
            arguments = ["kickstart", "\(item.launchctlDomain)/\(item.label)"]
        case .stop:
            arguments = ["kill", "TERM", "\(item.launchctlDomain)/\(item.label)"]
        case .restart:
            arguments = ["kickstart", "-k", "\(item.launchctlDomain)/\(item.label)"]
        case .bootstrap:
            arguments = ["bootstrap", item.launchctlDomain, item.plistURL.path]
        case .bootout:
            arguments = ["bootout", item.launchctlDomain, item.plistURL.path]
        case .enable:
            arguments = ["enable", "\(item.launchctlDomain)/\(item.label)"]
        case .disable:
            arguments = ["disable", "\(item.launchctlDomain)/\(item.label)"]
        }
        return await performManagedAction(
            item: item,
            title: actionTitle(action),
            arguments: arguments
        )
    }

    private func scheduleManagedAction(
        item: LaunchControlItem,
        title: String,
        arguments: [String]
    ) {
        Task { [weak self] in
            _ = await self?.performManagedAction(item: item, title: title, arguments: arguments)
        }
    }

    private func performManagedAction(
        item: LaunchControlItem,
        title: String,
        arguments: [String]
    ) async -> Bool {
        guard item.canManage else {
            snapshot.operationMessage = localization.string(
                "controller.operation.readOnly",
                defaultValue: "系统或全局启动项默认只读，避免误操作。"
            )
            onStateChange?()
            return false
        }

        activeOperations += 1
        defer { activeOperations -= 1 }
        snapshot.operationMessage = localization.format(
            "controller.operation.running",
            defaultValue: "%@ %@...",
            title,
            item.label
        )
        snapshot.errorMessage = nil
        onStateChange?()

        let runner = runner
        let result: Result<LaunchControlCommandResult, Error> = await Task.detached(priority: .userInitiated) {
            do {
                return .success(try runner.runLaunchctl(arguments: arguments))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case let .success(commandResult) where commandResult.exitCode == 0:
            snapshot.operationMessage = localization.format(
                "controller.operation.completed",
                defaultValue: "%@完成",
                title
            )
            refresh()
            return true
        case let .success(commandResult):
            let message = commandResult.combinedOutput
            snapshot.operationMessage = localization.format(
                "controller.operation.failed",
                defaultValue: "%@失败",
                title
            )
            snapshot.errorMessage = message.isEmpty
                ? localization.format(
                    "controller.operation.exitCode",
                    defaultValue: "launchctl 返回退出码 %d",
                    commandResult.exitCode
                )
                : message
            onStateChange?()
            return false
        case let .failure(error):
            snapshot.operationMessage = localization.format(
                "controller.operation.failed",
                defaultValue: "%@失败",
                title
            )
            snapshot.errorMessage = error.localizedDescription
            onStateChange?()
            return false
        }
    }

    private func actionTitle(_ action: LaunchControlManagedAction) -> String {
        action.title(localization: localization)
    }
}
