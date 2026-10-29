import Foundation
import MacToolsPluginKit

/// Preserves portable archives without retaining or activating the plugin runtime.
/// Imported payloads remain pending and cannot authorize action execution.
@MainActor
final class DisabledPluginPreferencesStore {
    struct PortableAction: Codable {
        let reference: ActionReference
        let requiresPreferences: Bool
    }

    struct Snapshot: Codable {
        var preferences: Data?
        var preferenceReferences: [ActionReference]
        var shortcutIDs: [String]
        var portableActions: [PortableAction]
        var pendingRestore = false
    }

    private static let key = "plugins.disabled.portablePreferences.v1"
    private let defaults: UserDefaults
    private(set) var snapshots: [String: Snapshot]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        snapshots = (defaults.dictionary(forKey: Self.key) ?? [:]).reduce(into: [:]) { result, entry in
            guard let data = entry.value as? Data,
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
            result[entry.key] = snapshot
        }
    }

    func save(_ snapshot: Snapshot, pluginID: String) throws {
        let data = try JSONEncoder().encode(snapshot)
        var stored = defaults.dictionary(forKey: Self.key) ?? [:]
        stored[pluginID] = data
        defaults.set(stored, forKey: Self.key)
        guard (defaults.dictionary(forKey: Self.key)?[pluginID] as? Data) == data else {
            throw CocoaError(.fileWriteUnknown)
        }
        snapshots[pluginID] = snapshot
    }

    func remove(_ pluginID: String) throws {
        var stored = defaults.dictionary(forKey: Self.key) ?? [:]
        stored.removeValue(forKey: pluginID)
        defaults.set(stored, forKey: Self.key)
        guard defaults.dictionary(forKey: Self.key)?[pluginID] == nil else {
            throw CocoaError(.fileWriteUnknown)
        }
        snapshots.removeValue(forKey: pluginID)
    }
}
