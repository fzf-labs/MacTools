import Foundation
import MacToolsPluginKit

/// Portable metadata only. Resolving a launch directory never scans or changes launchd jobs.
@MainActor
struct LaunchControlPortablePreferences {
    enum Key {
        static let favorites = "launch-control.favorite-item-ids"
        static let notes = "launch-control.item-notes"
        static let includesNotes = "preferences-backup.include-notes"
    }

    struct Reference: Codable, Hashable {
        enum Location: String, Codable, CaseIterable {
            case userAgents, globalAgents, globalDaemons, systemAgents, systemDaemons
        }
        let location: Location
        let plistFileName: String

        var isValid: Bool {
            plistFileName.utf8.count <= 255 && plistFileName.hasSuffix(".plist")
                && plistFileName != ".plist" && !plistFileName.contains("/")
                && !plistFileName.contains("\\")
                && !plistFileName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }

    struct Note: Codable {
        let reference: Reference
        let text: String
    }

    struct Payload: Codable {
        let formatVersion: Int
        let favorites: [Reference]
        let notes: [Note]?
    }

    let storage: any PluginStorage
    var homeURL = FileManager.default.homeDirectoryForCurrentUser

    static func store(_ storage: any PluginStorage) -> PortablePreferencesStore {
        PortablePreferencesStore(storage: storage, fields: [
            Key.favorites: .strings([], maximumCount: 1_024, maximumStringBytes: 4_096),
            Key.notes: .data(Data("{}".utf8), maximumBytes: 2_097_152) { data in
                guard let notes = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
                return notes.count <= 1_024 && notes.allSatisfy {
                    !$0.key.isEmpty && $0.key.utf8.count <= 4_096 && validNote($0.value)
                }
            },
            Key.includesNotes: .boolean(false),
        ])
    }

    static func validNote(_ text: String) -> Bool {
        text.utf8.count <= 16_384 && !text.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }
    }

    var includesNotes: Bool { storage.bool(forKey: Key.includesNotes) }

    func setIncludesNotes(_ value: Bool) -> Bool {
        Self.store(storage).commit([Key.includesNotes: .boolean(value)])
    }

    func backup() -> Data? {
        let store = Self.store(storage)
        let keys: Set<String> = includesNotes ? [Key.favorites, Key.notes] : [Key.favorites]
        guard store.backup(including: keys) != nil, let values = store.currentValues(including: keys),
              case let .strings(favorites)? = values[Key.favorites] else { return nil }
        var portableNotes: [Note]?
        if includesNotes {
            guard case let .data(notesData)? = values[Key.notes],
                  let notes = try? JSONDecoder().decode([String: String].self, from: notesData) else { return nil }
            portableNotes = notes.compactMap { key, text in
                reference(for: key).map { Note(reference: $0, text: text) }
            }.sorted { order($0.reference, $1.reference) }
        }
        let payload = Payload(
            formatVersion: 1,
            favorites: favorites.compactMap(reference).sorted(by: order),
            notes: portableNotes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload), data.count <= 2_097_152 else { return nil }
        return data
    }

    func restore(_ data: Data) -> Bool {
        guard data.count <= 2_097_152,
              let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.formatVersion == 1,
              payload.favorites.count <= 1_024,
              payload.favorites.allSatisfy(\.isValid), Set(payload.favorites).count == payload.favorites.count,
              (payload.notes?.count ?? 0) <= 1_024,
              payload.notes?.allSatisfy({ $0.reference.isValid && Self.validNote($0.text) }) != false,
              Set(payload.notes?.map(\.reference) ?? []).count == (payload.notes?.count ?? 0),
              Self.store(storage).recover(),
              let values = Self.store(storage).currentValues(including: [Key.favorites]),
              case let .strings(previousFavorites)? = values[Key.favorites]
        else { return false }
        let favorites = previousFavorites.filter { reference(for: $0) == nil } + payload.favorites.map(path)
        var candidate: [String: PortablePreferenceValue] = [Key.favorites: .strings(favorites.sorted())]
        if let incoming = payload.notes {
            guard let values = Self.store(storage).currentValues(including: [Key.notes]),
                  case let .data(previousNotes)? = values[Key.notes],
                  var notes = try? JSONDecoder().decode([String: String].self, from: previousNotes) else { return false }
            if includesNotes { notes = notes.filter { reference(for: $0.key) == nil } }
            for note in incoming {
                let itemID = path(for: note.reference)
                if !includesNotes, let protected = notes[itemID], protected != note.text { return false }
                notes[itemID] = note.text
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let notesData = try? encoder.encode(notes) else { return false }
            candidate[Key.notes] = .data(notesData)
        }
        return Self.store(storage).commit(candidate)
    }

    func unmatchedReferences(matching itemIDs: Set<String>) -> [Reference] {
        let favorites = storage.stringArray(forKey: Key.favorites) ?? []
        let notes = storage.data(forKey: Key.notes).flatMap {
            try? JSONDecoder().decode([String: String].self, from: $0)
        } ?? [:]
        return Set((favorites + notes.keys).filter { !itemIDs.contains($0) }.compactMap(reference)).sorted(by: order)
    }

    func reference(for path: String) -> Reference? {
        for location in Reference.Location.allCases {
            let prefix = directory(for: location).path + "/"
            guard path.hasPrefix(prefix) else { continue }
            let reference = Reference(location: location, plistFileName: String(path.dropFirst(prefix.count)))
            if reference.isValid { return reference }
        }
        return nil
    }

    private func path(for reference: Reference) -> String {
        directory(for: reference.location).appendingPathComponent(reference.plistFileName).path
    }

    private func directory(for location: Reference.Location) -> URL {
        switch location {
        case .userAgents: homeURL.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        case .globalAgents: URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true)
        case .globalDaemons: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
        case .systemAgents: URL(fileURLWithPath: "/System/Library/LaunchAgents", isDirectory: true)
        case .systemDaemons: URL(fileURLWithPath: "/System/Library/LaunchDaemons", isDirectory: true)
        }
    }

    private func order(_ lhs: Reference, _ rhs: Reference) -> Bool {
        (lhs.location.rawValue, lhs.plistFileName) < (rhs.location.rawValue, rhs.plistFileName)
    }
}
