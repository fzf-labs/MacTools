import Foundation
import MacToolsPluginKit

/// Compiled privately into participating plugin targets; this is not a PluginKit runtime API.
enum PortablePreferenceValue: Codable, Equatable {
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case data(Data)
    case strings([String])

    var object: Any {
        switch self {
        case let .boolean(value): value
        case let .integer(value): value
        case let .number(value): value
        case let .string(value): value
        case let .data(value): value
        case let .strings(value): value
        }
    }
}

struct PortablePreferenceField {
    let fallback: PortablePreferenceValue
    let accepts: (PortablePreferenceValue) -> Bool

    static func boolean(_ fallback: Bool) -> Self {
        Self(fallback: .boolean(fallback)) { if case .boolean = $0 { true } else { false } }
    }

    static func integer(_ fallback: Int, range: ClosedRange<Int>) -> Self {
        Self(fallback: .integer(fallback)) {
            if case let .integer(value) = $0 { range.contains(value) } else { false }
        }
    }

    static func number(_ fallback: Double, range: ClosedRange<Double>) -> Self {
        Self(fallback: .number(fallback)) {
            if case let .number(value) = $0 { value.isFinite && range.contains(value) } else { false }
        }
    }

    static func choice(_ fallback: String, allowed: [String]) -> Self {
        Self(fallback: .string(fallback)) {
            if case let .string(value) = $0 { allowed.contains(value) } else { false }
        }
    }

    static func strings(_ fallback: [String] = [], maximumCount: Int = 512, maximumStringBytes: Int = 1_024) -> Self {
        Self(fallback: .strings(fallback)) {
            guard case let .strings(values) = $0 else { return false }
            return values.count <= maximumCount && Set(values).count == values.count && values.allSatisfy {
                !$0.isEmpty && $0.utf8.count <= maximumStringBytes && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }
        }
    }

    static func data(_ fallback: Data, maximumBytes: Int, validate: @escaping (Data) -> Bool) -> Self {
        Self(fallback: .data(fallback)) {
            if case let .data(value) = $0 { value.count <= maximumBytes && validate(value) } else { false }
        }
    }

    func read(_ object: Any?) -> PortablePreferenceValue? {
        guard let object else { return fallback }
        let value: PortablePreferenceValue?
        switch fallback {
        case .boolean: value = (object as? Bool).map(PortablePreferenceValue.boolean)
        case .integer: value = (object as? Int).map(PortablePreferenceValue.integer)
        case .number: value = (object as? Double).map(PortablePreferenceValue.number)
        case .string: value = (object as? String).map(PortablePreferenceValue.string)
        case .data: value = (object as? Data).map(PortablePreferenceValue.data)
        case .strings: value = (object as? [String]).map(PortablePreferenceValue.strings)
        }
        return value.flatMap { accepts($0) ? $0 : nil }
    }
}

/// A bounded field allowlist and read-back-verified transaction over one plugin's storage.
/// It never discovers keys or reads credentials, files, or another plugin's state.
@MainActor
struct PortablePreferencesStore {
    private struct Envelope: Codable {
        let formatVersion: Int
        let values: [String: PortablePreferenceValue]
    }

    let storage: any PluginStorage
    let fields: [String: PortablePreferenceField]
    private let journalKey = "preferences-backup.restore.v2"
    private let legacyJournalKey = "preferences-backup.restore.v1"
    private let maximumBytes = 2 * 1_024 * 1_024

    func backup(including keys: Set<String>? = nil, overriding overrides: [String: PortablePreferenceValue] = [:]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard storage.object(forKey: journalKey) == nil, storage.object(forKey: legacyJournalKey) == nil,
              var values = currentValues(including: keys),
              Set(overrides.keys).isSubset(of: keys ?? Set(fields.keys)),
              overrides.allSatisfy({ fields[$0.key]?.accepts($0.value) == true }) else { return nil }
        values.merge(overrides, uniquingKeysWith: { _, incoming in incoming })
        guard
              let data = try? encoder.encode(Envelope(formatVersion: 1, values: values)),
              data.count <= maximumBytes else { return nil }
        return data
    }

    func currentValues(including keys: Set<String>? = nil) -> [String: PortablePreferenceValue]? {
        let selected = keys ?? Set(fields.keys)
        guard selected.isSubset(of: Set(fields.keys)) else { return nil }
        var values: [String: PortablePreferenceValue] = [:]
        for (key, field) in fields where selected.contains(key) {
            guard let value = field.read(storage.object(forKey: key)) else { return nil }
            values[key] = value
        }
        return values
    }

    func validatedValues(from data: Data) -> [String: PortablePreferenceValue]? {
        guard data.count <= maximumBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.formatVersion == 1,
              Set(envelope.values.keys).isSubset(of: Set(fields.keys)),
              envelope.values.allSatisfy({ fields[$0.key]?.accepts($0.value) == true }) else { return nil }
        return envelope.values
    }

    func restore(_ data: Data) -> Bool {
        guard let incoming = validatedValues(from: data), recover() else { return false }
        var candidate = incoming
        for (key, field) in fields where candidate[key] == nil {
            guard let value = field.read(storage.object(forKey: key)) else { return false }
            candidate[key] = value
        }
        return commit(candidate)
    }

    func commit(_ candidate: [String: PortablePreferenceValue], removing: Set<String> = []) -> Bool {
        guard Set(candidate.keys).isSubset(of: Set(fields.keys)),
              removing.isSubset(of: Set(fields.keys)), Set(candidate.keys).isDisjoint(with: removing),
              candidate.allSatisfy({ fields[$0.key]?.accepts($0.value) == true }), recover() else { return false }
        let keys = Set(candidate.keys).union(removing)
        guard !keys.isEmpty else { return true }
        var previous: [String: Any] = [:]
        for key in keys { previous[key] = storage.object(forKey: key) }
        // Explicit keys distinguish an absent old value from an untouched field during recovery.
        let envelope: [String: Any] = ["formatVersion": 2, "keys": keys.sorted(), "previous": previous]
        guard let journal = try? PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0),
              journal.count <= maximumBytes else { return false }
        storage.set(journal, forKey: journalKey)
        guard storage.data(forKey: journalKey) == journal else { return false }
        for (key, value) in candidate { storage.set(value.object, forKey: key) }
        for key in removing { storage.removeObject(forKey: key) }
        guard candidate.allSatisfy({ storage.object(forKey: $0.key) != nil && fields[$0.key]?.read(storage.object(forKey: $0.key)) == $0.value }),
              removing.allSatisfy({ storage.object(forKey: $0) == nil }) else {
            _ = recover()
            return false
        }
        storage.removeObject(forKey: journalKey)
        guard storage.object(forKey: journalKey) == nil else { _ = recover(); return false }
        return true
    }

    @discardableResult
    func recover() -> Bool {
        if let legacy = storage.object(forKey: legacyJournalKey) {
            guard storage.object(forKey: journalKey) == nil,
                  let previous = journalValues(legacy), Set(previous.keys).isSubset(of: Set(fields.keys)) else { return false }
            return recover(previous: previous, keys: Set(fields.keys), journalKey: legacyJournalKey)
        }
        guard let raw = storage.object(forKey: journalKey) else { return true }
        guard let envelope = journalValues(raw), Set(envelope.keys) == ["formatVersion", "keys", "previous"],
              envelope["formatVersion"] as? Int == 2, let keys = envelope["keys"] as? [String],
              Set(keys).count == keys.count, Set(keys).isSubset(of: Set(fields.keys)),
              let previous = envelope["previous"] as? [String: Any],
              Set(previous.keys).isSubset(of: Set(keys)) else { return false }
        return recover(previous: previous, keys: Set(keys), journalKey: journalKey)
    }

    private func journalValues(_ raw: Any) -> [String: Any]? {
        guard let data = raw as? Data, data.count <= maximumBytes,
              let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return values
    }

    private func recover(previous: [String: Any], keys: Set<String>, journalKey: String) -> Bool {
        for key in keys {
            if let value = previous[key] { storage.set(value, forKey: key) }
            else { storage.removeObject(forKey: key) }
        }
        guard keys.allSatisfy({ key in
            switch (previous[key] as? NSObject, storage.object(forKey: key) as? NSObject) {
            case (nil, nil): true
            case let (before?, after?): before.isEqual(after)
            default: false
            }
        }) else { return false }
        storage.removeObject(forKey: journalKey)
        return storage.object(forKey: journalKey) == nil
    }
}
