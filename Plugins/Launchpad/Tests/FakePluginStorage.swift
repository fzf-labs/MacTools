import Foundation
import MacToolsPluginKit

/// In-memory `PluginStorage` shared across Launchpad plugin tests so they touch no real
/// `UserDefaults`. Extracted from the former private `FakeStorage` nested in
/// `LaunchpadPreferencesTests` so `LaunchpadLayoutStoreTests` (and future tests) can reuse it.
///
/// `writeCount` is test-only instrumentation: it counts persistence writes so a test can
/// assert that a no-op mutation does not touch storage (design risk R8).
@MainActor
final class FakePluginStorage: PluginStorage {
    var rejectedKeys = Set<String>()
    var values: [String: Any] = [:]
    private(set) var writeCount = 0

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }

    func set(_ value: Any?, forKey key: String) {
        guard !rejectedKeys.contains(key) else { return }
        values[key] = value
        writeCount += 1
    }

    func removeObject(forKey key: String) {
        guard !rejectedKeys.contains(key) else { return }
        values[key] = nil
        writeCount += 1
    }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        if values[key] == nil, let legacy = values[legacyKey] {
            values[key] = legacy
            values[legacyKey] = nil
            writeCount += 1     // a migration mutates persisted state — no-write assertions must see it
        }
    }
}
