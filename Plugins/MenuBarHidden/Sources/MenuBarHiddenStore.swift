// SPDX-License-Identifier: GPL-3.0-only
// Restored and adapted for MacTools on 2026-09-07.

import Foundation
import MacToolsPluginKit

enum MenuBarHiddenPersistenceMutationResult: Equatable {
    case committed
    case rejected(rollbackSucceeded: Bool)
    case recoveryRequired
}

@MainActor
final class MenuBarHiddenStore {
    private enum Key {
        static let isEnabled = "is-enabled"
        static let isAlwaysHiddenEnabled = "is-always-hidden-enabled"
        static let showsHiddenIconsInPanel = "shows-hidden-icons-in-panel"
        static let visibleItemStableKeys = "visible-item-stable-keys"
        static let hiddenItemStableKeys = "hidden-item-stable-keys"
        static let alwaysHiddenItemStableKeys = "always-hidden-item-stable-keys"
    }

    private let storage: PluginStorage

    init(storage: PluginStorage) {
        self.storage = storage
        _ = Self.portableStore(storage: storage).recover()
    }

    var onPersistentPreferencesChange: (() -> Void)?
    private struct PortableLayout: Codable {
        let visible: [String]
        let hidden: [String]
    }
    private struct PortablePreferences: Codable {
        let formatVersion: Int
        let isEnabled: Bool
        let isAlwaysHiddenEnabled: Bool
        let showsHiddenIconsInPanel: Bool
        let layout: PortableLayout?
        let alwaysHidden: [String]
    }
    private static func portableStore(storage: any PluginStorage) -> PortablePreferencesStore {
        PortablePreferencesStore(storage: storage, fields: [
            Key.isEnabled: .boolean(false), Key.isAlwaysHiddenEnabled: .boolean(false), Key.showsHiddenIconsInPanel: .boolean(false),
            Key.visibleItemStableKeys: .strings(), Key.hiddenItemStableKeys: .strings(), Key.alwaysHiddenItemStableKeys: .strings()
        ])
    }
    private var portableStore: PortablePreferencesStore { Self.portableStore(storage: storage) }
    var isEnabled: Bool {
        get { storage.object(forKey: Key.isEnabled) as? Bool ?? false }
        set { _ = setEnabled(newValue) }
    }
    @discardableResult
    func setEnabled(_ enabled: Bool) -> MenuBarHiddenPersistenceMutationResult {
        let previous = storage.object(forKey: Key.isEnabled)
        guard previous == nil || previous is Bool else { return .recoveryRequired }
        guard isEnabled != enabled else { return .committed }
        return commit([Key.isEnabled: .boolean(enabled)]) ? .committed : .rejected(rollbackSucceeded: storage.object(forKey: Key.isEnabled) as? Bool == previous as? Bool)
    }
    var isAlwaysHiddenEnabled: Bool {
        get { storage.object(forKey: Key.isAlwaysHiddenEnabled) as? Bool ?? false }
        set { _ = commit([Key.isAlwaysHiddenEnabled: .boolean(newValue)]) }
    }
    var showsHiddenIconsInPanel: Bool {
        get { storage.object(forKey: Key.showsHiddenIconsInPanel) as? Bool ?? false }
        set { _ = commit([Key.showsHiddenIconsInPanel: .boolean(newValue)]) }
    }
    var hasVisibleHiddenLayout: Bool {
        storage.object(forKey: Key.visibleItemStableKeys) != nil || storage.object(forKey: Key.hiddenItemStableKeys) != nil
    }
    var visibleItemStableKeys: [String] {
        get { normalizedStableKeys(storage.stringArray(forKey: Key.visibleItemStableKeys) ?? []) }
        set { _ = commit([Key.visibleItemStableKeys: .strings(normalizedStableKeys(newValue))]) }
    }
    var hiddenItemStableKeys: [String] {
        get { normalizedStableKeys(storage.stringArray(forKey: Key.hiddenItemStableKeys) ?? []) }
        set { _ = commit([Key.hiddenItemStableKeys: .strings(normalizedStableKeys(newValue))]) }
    }
    var orderedAlwaysHiddenItemStableKeys: [String] {
        get { normalizedStableKeys(storage.stringArray(forKey: Key.alwaysHiddenItemStableKeys) ?? []) }
        set {
            let keys = normalizedStableKeys(newValue)
            if keys.isEmpty { _ = commit([:], removing: [Key.alwaysHiddenItemStableKeys]) }
            else { _ = commit([Key.alwaysHiddenItemStableKeys: .strings(keys)]) }
        }
    }
    var alwaysHiddenItemStableKeys: Set<String> {
        get { Set(orderedAlwaysHiddenItemStableKeys) }
        set {
            let retained = orderedAlwaysHiddenItemStableKeys.filter { newValue.contains($0) }
            orderedAlwaysHiddenItemStableKeys = retained + newValue.subtracting(retained).sorted()
        }
    }
    func recordVisibleHiddenLayout(visibleKeys: [String], hiddenKeys: [String]) {
        let visible = normalizedStableKeys(visibleKeys)
        let hidden = normalizedStableKeys(hiddenKeys.filter { !visible.contains($0) })
        _ = commit([Key.visibleItemStableKeys: .strings(visible), Key.hiddenItemStableKeys: .strings(hidden)])
    }
    func recordAlwaysHiddenItem(_ tag: MenuBarItemTag) {
        guard !alwaysHiddenItemStableKeys.contains(tag.stableKey) else { return }
        orderedAlwaysHiddenItemStableKeys += [tag.stableKey]
    }
    func removeAlwaysHiddenItem(_ tag: MenuBarItemTag) {
        orderedAlwaysHiddenItemStableKeys.removeAll { $0 == tag.stableKey }
    }
    private func normalizedStableKeys(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private func decodedPortable(_ data: Data) -> PortablePreferences? {
        guard data.count <= 2 * 1_024 * 1_024,
              let payload = try? JSONDecoder().decode(PortablePreferences.self, from: data), payload.formatVersion == 1,
              PortablePreferenceField.strings().accepts(.strings(payload.alwaysHidden)) else { return nil }
        if let layout = payload.layout {
            guard PortablePreferenceField.strings().accepts(.strings(layout.visible)), PortablePreferenceField.strings().accepts(.strings(layout.hidden)),
                  Set(layout.visible).isDisjoint(with: layout.hidden) else { return nil }
        }
        return payload
    }
    func portableBackup() -> Data? {
        guard portableStore.backup() != nil else { return nil }
        let payload = PortablePreferences(formatVersion: 1, isEnabled: isEnabled, isAlwaysHiddenEnabled: isAlwaysHiddenEnabled,
            showsHiddenIconsInPanel: showsHiddenIconsInPanel,
            layout: hasVisibleHiddenLayout ? PortableLayout(visible: visibleItemStableKeys, hidden: hiddenItemStableKeys) : nil,
            alwaysHidden: orderedAlwaysHiddenItemStableKeys)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload), decodedPortable(data) != nil else { return nil }
        return data
    }
    func restorePortableBackup(_ data: Data) -> Bool {
        guard let payload = decodedPortable(data) else { return false }
        var candidate: [String: PortablePreferenceValue] = [
            Key.isEnabled: .boolean(payload.isEnabled), Key.isAlwaysHiddenEnabled: .boolean(payload.isAlwaysHiddenEnabled),
            Key.showsHiddenIconsInPanel: .boolean(payload.showsHiddenIconsInPanel), Key.alwaysHiddenItemStableKeys: .strings(payload.alwaysHidden)
        ]
        var removing = Set<String>()
        if let layout = payload.layout {
            candidate[Key.visibleItemStableKeys] = .strings(layout.visible)
            candidate[Key.hiddenItemStableKeys] = .strings(layout.hidden)
        } else { removing = [Key.visibleItemStableKeys, Key.hiddenItemStableKeys] }
        return commit(candidate, removing: removing)
    }
    private func commit(_ candidate: [String: PortablePreferenceValue], removing: Set<String> = []) -> Bool {
        let previous = portableStore.currentValues()
        let hadLayout = hasVisibleHiddenLayout
        guard portableStore.commit(candidate, removing: removing) else { return false }
        if previous != portableStore.currentValues() || hadLayout != hasVisibleHiddenLayout { onPersistentPreferencesChange?() }
        return true
    }
}
