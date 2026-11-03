import Combine
import Foundation
import MacToolsPluginKit

enum LauncherCategory: String, CaseIterable, Identifiable {
    case applications
    case systemSettings = "system-settings"
    case systemOperations = "system-operations"
    case pluginFeatures = "plugin-features"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .applications: LauncherText.applications
        case .systemSettings: LauncherText.systemSettings
        case .systemOperations: LauncherText.systemOperations
        case .pluginFeatures: LauncherText.pluginFeatures
        }
    }
}


extension LauncherCategory {
    var sidebarImage: String {
        switch self {
        case .applications: "app"
        case .systemSettings: "gearshape.2"
        case .systemOperations: "bolt"
        case .pluginFeatures: "puzzlepiece.extension"
        }
    }
}

struct LauncherPersonalization: Codable, Equatable, Sendable {
    var favorites: [String] = []
    var aliases: [String: String] = [:]
    var hidden: Set<String> = []
    var labels: [String: String] = [:]
    var disabledSources: Set<String> = []
    var isValid: Bool {
        favorites.count <= 1000 && Set(favorites).count == favorites.count && aliases.count <= 1000
            && hidden.count <= 1000 && disabledSources.count <= 100
            && (favorites + Array(hidden) + Array(aliases.keys)).allSatisfy { !$0.isEmpty && $0.count <= 4096 }
            && aliases.values.allSatisfy { $0.count <= 80 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
            && Set(aliases.values.map(LauncherSearch.normalize)).count == aliases.count
    }
    mutating func migrateLegacySources() {
        if disabledSources.remove("commands") != nil { disabledSources.formUnion(["system-operations", "plugin-features"]) }
    }
    static func isLocalReference(_ id: String) -> Bool { id.hasPrefix("application.") || id.hasPrefix("quicklink-local.") }
    var portable: Self {
        var result = self
        result.labels = result.labels.filter { !Self.isLocalReference($0.key) }
        result.favorites.removeAll(where: Self.isLocalReference)
        result.aliases = result.aliases.filter { !Self.isLocalReference($0.key) }
        result.hidden = result.hidden.filter { !Self.isLocalReference($0) }
        return result
    }
}

@MainActor
final class LauncherPreferences: ObservableObject {
    struct Usage: Codable, Equatable { var count: Int; var lastUsed: Date }
    @Published private(set) var personalization: LauncherPersonalization
    @Published private(set) var usage: [String: Usage]
    private var observer: AnyCancellable?
    var onPersistentChange: (() -> Void)?
    private let defaults: UserDefaults
    static let personalizationKey = "launcher.personalization.v1"
    init(defaults: UserDefaults = .standard, onPersistentChange: (() -> Void)? = nil) {
        self.defaults = defaults; self.onPersistentChange = onPersistentChange
        personalization = defaults.data(forKey: Self.personalizationKey)
            .flatMap { try? JSONDecoder().decode(LauncherPersonalization.self, from: $0) } ?? .init()
        usage = defaults.data(forKey: "launcher.usage.v1")
            .flatMap { try? JSONDecoder().decode([String: Usage].self, from: $0) } ?? [:]
        personalization.migrateLegacySources()
        observer = NotificationCenter.default.publisher(for: .launcherPreferencesChanged).sink { [weak self] _ in
            guard let self else { return }
            if let data = defaults.data(forKey: Self.personalizationKey), var updated = try? JSONDecoder().decode(LauncherPersonalization.self, from: data) {
                updated.migrateLegacySources()
                if updated != personalization { personalization = updated }
            }
            let updatedUsage = defaults.data(forKey: "launcher.usage.v1").flatMap { try? JSONDecoder().decode([String: Usage].self, from: $0) } ?? [:]
            if usage != updatedUsage { usage = updatedUsage }
        }
    }
    func update(_ body: (inout LauncherPersonalization) -> Void) {
        var value = personalization; body(&value); value.migrateLegacySources()
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.personalizationKey)
        personalization = value
        onPersistentChange?()
        NotificationCenter.default.post(name: .launcherPreferencesChanged, object: nil)
    }
    func setAlias(_ alias: String, for id: String, title: String? = nil) -> Bool {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = LauncherSearch.normalize(alias)
        guard alias.count <= 80, !alias.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !personalization.aliases.contains(where: { $0.key != id && LauncherSearch.normalize($0.value) == normalized && !normalized.isEmpty }) else { return false }
        update { if alias.isEmpty { $0.aliases[id] = nil } else { $0.aliases[id] = alias }; if let title { $0.labels[id] = title } }
        return true
    }
    func toggleFavorite(_ id: String) {
        update { if $0.favorites.contains(id) { $0.favorites.removeAll { $0 == id } } else { $0.favorites.append(id) } }
    }
    func record(_ id: String, now: Date = .now) {
        usage[id] = Usage(count: min((usage[id]?.count ?? 0) + 1, 1_000_000), lastUsed: now)
        if usage.count > 500, let oldest = usage.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key { usage[oldest] = nil }
        if let data = try? JSONEncoder().encode(usage) { defaults.set(data, forKey: "launcher.usage.v1") }
        NotificationCenter.default.post(name: .launcherPreferencesChanged, object: nil)
    }
    func clearUsage() {
        usage = [:]; defaults.removeObject(forKey: "launcher.usage.v1")
        NotificationCenter.default.post(name: .launcherPreferencesChanged, object: nil)
    }
}

extension Notification.Name {
    static let launcherPreferencesChanged = Notification.Name("MacTools.launcherPreferencesChanged")
}

struct LauncherSearchProfile: Sendable {
    let title: String
    let keywords: String
    let latin: String
    let initials: String
    let alternateTitles: [String]
    init(title: String, keywords: [String], alternateTitles: [String] = []) {
        self.alternateTitles = alternateTitles.map(LauncherSearch.normalize)
        self.title = LauncherSearch.normalize(title)
        self.keywords = LauncherSearch.normalize(keywords.joined(separator: " "))
        let romanized = title.applyingTransform(.toLatin, reverse: false) ?? title
        let words = LauncherSearch.normalize(romanized).split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        latin = words.joined()
        initials = words.compactMap(\.first).map(String.init).joined()
    }
}

enum LauncherSearch {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func tier(query: String, profile: LauncherSearchProfile, alias: String?) -> Int? {
        let query = normalize(query)
        if query.isEmpty { return 0 }
        if let alias, normalize(alias) == query { return 6 }
        if profile.title == query || profile.alternateTitles.contains(query) { return 5 }
        if profile.title.hasPrefix(query) || profile.latin.hasPrefix(query) || profile.initials.hasPrefix(query) || profile.alternateTitles.contains(where: { $0.hasPrefix(query) }) { return 4 }
        if profile.title.contains(query) || profile.latin.contains(query) || profile.alternateTitles.contains(where: { $0.contains(query) }) { return 3 }
        if isSubsequence(query, of: profile.title) || isSubsequence(query, of: profile.latin) { return 2 }
        if query.split(whereSeparator: \.isWhitespace).allSatisfy({ profile.keywords.contains($0) }) { return 1 }
        return nil
    }
    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard needle.count >= 2 else { return false }
        var remaining = needle[...]
        for character in haystack where remaining.first == character { remaining = remaining.dropFirst() }
        return remaining.isEmpty
    }
}
