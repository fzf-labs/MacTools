import Foundation
import MacToolsPluginKit

enum LaunchControlScope: String, CaseIterable, Identifiable, Sendable {
    case user
    case global
    case system

    var id: String { rawValue }

    var title: String {
        title()
    }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .user:
            return localization.string("scope.user.title", defaultValue: "当前用户")
        case .global:
            return localization.string("scope.global.title", defaultValue: "全局")
        case .system:
            return localization.string("scope.system.title", defaultValue: "系统")
        }
    }
}

enum LaunchControlState: String, CaseIterable, Identifiable, Sendable {
    case running
    case loaded
    case disabled
    case failed
    case unloaded
    case unknown

    var id: String { rawValue }

    var title: String {
        title()
    }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .running:
            return localization.string("state.running.title", defaultValue: "运行中")
        case .loaded:
            return localization.string("state.loaded.title", defaultValue: "已加载")
        case .disabled:
            return localization.string("state.disabled.title", defaultValue: "已禁用")
        case .failed:
            return localization.string("state.failed.title", defaultValue: "异常退出")
        case .unloaded:
            return localization.string("state.unloaded.title", defaultValue: "未加载")
        case .unknown:
            return localization.string("state.unknown.title", defaultValue: "未知")
        }
    }
}

enum LaunchControlOrigin: String, CaseIterable, Identifiable, Sendable {
    case userCreated
    case thirdParty
    case system

    var id: String { rawValue }

    var title: String {
        title()
    }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .userCreated:
            return localization.string("origin.userCreated.title", defaultValue: "用户创建")
        case .thirdParty:
            return localization.string("origin.thirdParty.title", defaultValue: "应用创建")
        case .system:
            return localization.string("origin.system.title", defaultValue: "系统内置")
        }
    }
}

enum LaunchControlOriginFilter: String, CaseIterable, Identifiable {
    case all
    case favorite
    case manageable
    case userCreated
    case appCreated
    case system
    case readOnly

    var id: String { rawValue }

    var title: String {
        title()
    }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .all:
            return localization.string("originFilter.all.title", defaultValue: "全部来源")
        case .favorite:
            return localization.string("originFilter.favorite.title", defaultValue: "已关注")
        case .manageable:
            return localization.string("originFilter.manageable.title", defaultValue: "可操作")
        case .userCreated:
            return LaunchControlOrigin.userCreated.title(localization: localization)
        case .appCreated:
            return LaunchControlOrigin.thirdParty.title(localization: localization)
        case .system:
            return LaunchControlOrigin.system.title(localization: localization)
        case .readOnly:
            return localization.string("originFilter.readOnly.title", defaultValue: "只读")
        }
    }

    func matches(_ item: LaunchControlItem) -> Bool {
        switch self {
        case .all:
            return true
        case .favorite:
            return item.isFavorite
        case .manageable:
            return item.canManage
        case .userCreated:
            return item.origin == .userCreated
        case .appCreated:
            return item.origin == .thirdParty
        case .system:
            return item.origin == .system
        case .readOnly:
            return !item.canManage
        }
    }
}

enum LaunchControlFilter: String, CaseIterable, Identifiable {
    case all
    case user
    case global
    case system

    var id: String { rawValue }

    var title: String {
        title()
    }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .all:
            return localization.string("scopeFilter.all.title", defaultValue: "全部范围")
        case .user:
            return LaunchControlScope.user.title(localization: localization)
        case .global:
            return LaunchControlScope.global.title(localization: localization)
        case .system:
            return LaunchControlScope.system.title(localization: localization)
        }
    }

    var scope: LaunchControlScope? {
        switch self {
        case .all:
            return nil
        case .user:
            return .user
        case .global:
            return .global
        case .system:
            return .system
        }
    }
}

enum LaunchControlStateFilter: String, CaseIterable, Identifiable {
    case all
    case running
    case loaded
    case disabled
    case failed

    var id: String { rawValue }

    var title: String {
        title()
    }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .all:
            return localization.string("stateFilter.all.title", defaultValue: "全部状态")
        case .running:
            return LaunchControlState.running.title(localization: localization)
        case .loaded:
            return LaunchControlState.loaded.title(localization: localization)
        case .disabled:
            return LaunchControlState.disabled.title(localization: localization)
        case .failed:
            return LaunchControlState.failed.title(localization: localization)
        }
    }

    func matches(_ state: LaunchControlState) -> Bool {
        switch self {
        case .all:
            return true
        case .running:
            return state == .running
        case .loaded:
            return state == .loaded || state == .running
        case .disabled:
            return state == .disabled
        case .failed:
            return state == .failed
        }
    }
}

struct LaunchControlItem: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let plistURL: URL
    let scope: LaunchControlScope
    let origin: LaunchControlOrigin
    let state: LaunchControlState
    let pid: Int?
    let lastExitStatus: Int?
    let programArguments: [String]
    let runAtLoad: Bool
    let keepAliveDescription: String?
    let startInterval: Int?
    let startCalendarDescription: String?
    let rawPlist: String
    let launchctlDomain: String
    let isDisabled: Bool
    let isLoaded: Bool
    var isFavorite: Bool
    /// User-authored local note (persisted separately; never written to the plist).
    var note: String = ""

    var commandText: String {
        commandText()
    }

    func commandText(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        if !programArguments.isEmpty {
            return programArguments.joined(separator: " ")
        }

        return localization.string("item.commandText.empty", defaultValue: "未声明 ProgramArguments")
    }

    var triggerSummary: String {
        triggerSummary()
    }

    func triggerSummary(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        var parts: [String] = []
        if runAtLoad {
            parts.append(localization.string("item.trigger.runAtLoad", defaultValue: "登录/加载时运行"))
        }
        if let keepAliveDescription {
            parts.append(localization.format(
                "item.trigger.keepAlive",
                defaultValue: "KeepAlive: %@",
                keepAliveDescription
            ))
        }
        if let startInterval {
            parts.append(localization.format("item.trigger.startInterval", defaultValue: "每 %d 秒", startInterval))
        }
        if let startCalendarDescription {
            parts.append(localization.format(
                "item.trigger.startCalendar",
                defaultValue: "定时: %@",
                startCalendarDescription
            ))
        }
        return parts.isEmpty
            ? localization.string("item.trigger.empty", defaultValue: "未声明自动触发条件")
            : parts.joined(separator: " · ")
    }

    var canManage: Bool {
        scope == .user && !label.isEmpty && plistURL.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents").path)
    }

    var statusText: String {
        statusText()
    }

    func statusText(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        if let pid {
            return localization.format(
                "item.status.pid",
                defaultValue: "%@ · PID %d",
                state.title(localization: localization),
                pid
            )
        }
        if let lastExitStatus {
            return localization.format(
                "item.status.exitCode",
                defaultValue: "%@ · 退出码 %d",
                state.title(localization: localization),
                lastExitStatus
            )
        }
        return state.title(localization: localization)
    }
}

struct LaunchControlSnapshot: Equatable {
    var items: [LaunchControlItem] = []
    var selectedItemID: String?
    var isRefreshing = false
    var lastRefreshDate: Date?
    var errorMessage: String?
    var operationMessage: String?
    var scanLogEntries: [String] = []
    var currentScanTarget: String?

    var selectedItem: LaunchControlItem? {
        guard let selectedItemID else {
            return items.first
        }

        return items.first(where: { $0.id == selectedItemID }) ?? items.first
    }
}

@MainActor
final class LaunchControlFavoritesStore {
    private enum StorageKey {
        static let storage = "launch-control.favorite-item-ids"
    }

    private let storage: PluginStorage
    var onMutation: (() -> Void)?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "launch-control"),
        userDefaults: UserDefaults? = nil
    ) {
        self.storage = userDefaults.map {
            UserDefaultsPluginStorage(pluginID: context.pluginID, userDefaults: $0)
        } ?? context.storage
        storage.migrateValueIfNeeded(fromLegacyKey: StorageKey.storage, to: StorageKey.storage)
        _ = LaunchControlPortablePreferences.store(storage).recover()
    }

    func favoriteItemIDs() -> Set<String> {
        Set(storage.stringArray(forKey: StorageKey.storage) ?? [])
    }

    func isFavorite(_ itemID: String) -> Bool {
        favoriteItemIDs().contains(itemID)
    }

    @discardableResult
    func setFavorite(_ isFavorite: Bool, for itemID: String) -> Bool {
        var favorites = favoriteItemIDs()
        if isFavorite {
            favorites.insert(itemID)
        } else {
            favorites.remove(itemID)
        }
        guard favorites != favoriteItemIDs() else { return true }
        guard LaunchControlPortablePreferences.store(storage).commit([StorageKey.storage: .strings(favorites.sorted())]) else { return false }
        onMutation?()
        return true
    }
}

/// Persists per-item user notes locally (keyed by item ID / plist path). Notes are
/// never written back to the launchd plist — they live only in plugin storage.
@MainActor
final class LaunchControlNotesStore {
    private enum StorageKey {
        static let storage = "launch-control.item-notes"
    }

    private let storage: PluginStorage
    var onMutation: (() -> Void)?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "launch-control"),
        userDefaults: UserDefaults? = nil
    ) {
        self.storage = userDefaults.map {
            UserDefaultsPluginStorage(pluginID: context.pluginID, userDefaults: $0)
        } ?? context.storage
    }

    func allNotes() -> [String: String] {
        guard
            let data = storage.data(forKey: StorageKey.storage),
            let notes = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return notes
    }

    func note(for itemID: String) -> String {
        allNotes()[itemID] ?? ""
    }

    @discardableResult
    func setNote(_ note: String, for itemID: String) -> Bool {
        var notes = allNotes()
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            notes.removeValue(forKey: itemID)
        } else {
            notes[itemID] = trimmed
        }
        guard notes != allNotes() else { return true }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(notes),
              LaunchControlPortablePreferences.store(storage).commit([StorageKey.storage: .data(data)]) else { return false }
        onMutation?()
        return true
    }
}

enum LaunchControlScanEvent: Sendable {
    case directory(String)
    case file(String)
    case found(LaunchControlItem)
    case message(String)
}

enum LaunchControlManagedAction: String, Sendable {
    case bootstrap
    case bootout
    case enable
    case disable
    case start
    case stop
    case restart

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .bootstrap:
            return localization.string("managedAction.bootstrap.title", defaultValue: "加载")
        case .bootout:
            return localization.string("managedAction.bootout.title", defaultValue: "卸载")
        case .enable:
            return localization.string("managedAction.enable.title", defaultValue: "启用")
        case .disable:
            return localization.string("managedAction.disable.title", defaultValue: "禁用")
        case .start:
            return localization.string("managedAction.start.title", defaultValue: "启动")
        case .stop:
            return localization.string("managedAction.stop.title", defaultValue: "停止")
        case .restart:
            return localization.string("managedAction.restart.title", defaultValue: "重启")
        }
    }
}

struct LaunchControlPlistSummary: Sendable {
    let label: String
    let programArguments: [String]
    let runAtLoad: Bool
    let keepAliveDescription: String?
    let startInterval: Int?
    let startCalendarDescription: String?
    let rawPlist: String
}
