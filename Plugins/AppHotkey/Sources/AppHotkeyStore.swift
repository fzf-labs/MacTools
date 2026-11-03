import Foundation
import MacToolsPluginKit

@MainActor
final class AppHotkeyStore: ObservableObject {
    private enum Keys {
        static let entries = "entries"
    }

    @Published private(set) var entries: [AppShortcutEntry]

    private let storage: PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: PluginStorage) {
        self.storage = storage
        encoder.outputFormatting = [.sortedKeys]
        _ = Self.portableStore(storage: storage).recover()
        if let data = storage.data(forKey: Keys.entries),
           let loaded = try? JSONDecoder().decode([AppShortcutEntry].self, from: data) {
            self.entries = loaded
        } else {
            self.entries = []
        }
    }

    func addEntry(_ entry: AppShortcutEntry) {
        _ = commitEntries(entries + [entry], portableChanged: true)
    }

    func updateShortcut(id: UUID, shortcut: ShortcutBinding?) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var candidate = entries
        candidate[idx].shortcut = shortcut
        _ = commitEntries(candidate, portableChanged: false)
    }

    func deleteEntry(id: UUID) {
        _ = commitEntries(entries.filter { $0.id != id }, portableChanged: true)
    }

    func clearAllShortcuts() {
        let candidate = entries.map { entry in
            var copy = entry
            copy.shortcut = nil
            return copy
        }
        _ = commitEntries(candidate, portableChanged: false)
    }

    /// Returns the existing entry that conflicts with the shortcut, excluding the current entry.
    func conflictEntry(for shortcut: ShortcutBinding, excludingID: UUID? = nil) -> AppShortcutEntry? {
        entries.first { $0.id != excludingID && $0.shortcut == shortcut }
    }

    private struct PortableEntry: Codable, Equatable {
        let id: UUID
        let displayName: String
        let application: PortableApplicationReference
    }
    private struct PortablePreferences: Codable {
        let formatVersion: Int
        let isEnabled: Bool
        let entries: [PortableEntry]
    }
    var onPersistentPreferencesChange: (() -> Void)?
    var isEnabled: Bool { storage.object(forKey: "isEnabled") as? Bool ?? true }
    private static func portableStore(storage: any PluginStorage) -> PortablePreferencesStore {
        PortablePreferencesStore(storage: storage, fields: [
            "isEnabled": .boolean(true),
            Keys.entries: .data(Data("[]".utf8), maximumBytes: 1_024 * 1_024) { data in
                guard let entries = try? JSONDecoder().decode([AppShortcutEntry].self, from: data) else { return false }
                return entries.count <= 512 && Set(entries.map(\.id)).count == entries.count
            }
        ])
    }
    private var portableStore: PortablePreferencesStore { Self.portableStore(storage: storage) }
    @discardableResult
    func setEnabled(_ value: Bool) -> Bool {
        guard value != isEnabled else { return true }
        guard portableStore.commit(["isEnabled": .boolean(value)]) else { return false }
        onPersistentPreferencesChange?()
        return true
    }
    private func decodedPortable(_ data: Data) -> PortablePreferences? {
        guard data.count <= 1_024 * 1_024, let payload = try? decoder.decode(PortablePreferences.self, from: data),
              payload.formatVersion == 1, payload.entries.count <= 512,
              Set(payload.entries.map(\.id)).count == payload.entries.count,
              payload.entries.allSatisfy({ $0.application.isValid && !$0.displayName.isEmpty && $0.displayName.utf8.count <= 256
                  && !$0.displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { return nil }
        return payload
    }
    func portableBackup() -> Data? {
        guard portableStore.backup() != nil else { return nil }
        let payload = PortablePreferences(formatVersion: 1, isEnabled: isEnabled, entries: entries.map {
            PortableEntry(id: $0.id, displayName: $0.displayName,
                application: $0.portableApplicationReference ?? PortableApplicationReference(url: $0.bundleURL))
        })
        guard let data = try? encoder.encode(payload), decodedPortable(data) != nil else { return nil }
        return data
    }
    func actionEntryIDs(inPortableBackup data: Data) -> [UUID]? { decodedPortable(data)?.entries.map(\.id) }
    func restorePortableBackup(_ data: Data) -> Bool {
        guard let payload = decodedPortable(data) else { return false }
        var resolved = Set<String>()
        let candidate = payload.entries.map { incoming in
            var url = incoming.application.resolvedURL()
            if let candidateURL = url, !resolved.insert(candidateURL.path).inserted { url = nil }
            var entry = AppShortcutEntry(id: incoming.id, bundleURL: url, displayName: incoming.displayName)
            entry.portableApplicationReference = incoming.application
            if let existing = entries.first(where: { $0.id == incoming.id }),
               (existing.portableApplicationReference ?? PortableApplicationReference(url: existing.bundleURL)) == incoming.application {
                entry.shortcut = existing.shortcut
            }
            return entry
        }
        guard let encoded = try? encoder.encode(candidate) else { return false }
        let changed = entries != candidate || isEnabled != payload.isEnabled
        guard portableStore.commit([Keys.entries: .data(encoded), "isEnabled": .boolean(payload.isEnabled)]) else { return false }
        entries = candidate
        if changed { onPersistentPreferencesChange?() }
        return true
    }
    @discardableResult
    private func commitEntries(_ candidate: [AppShortcutEntry], portableChanged: Bool) -> Bool {
        guard entries != candidate else { return true }
        guard let data = try? encoder.encode(candidate), portableStore.commit([Keys.entries: .data(data)]) else { return false }
        entries = candidate
        if portableChanged { onPersistentPreferencesChange?() }
        return true
    }
}
