import XCTest
@testable import MacTools

@MainActor
final class LauncherPreferencesTests: XCTestCase {
    func testAliasesFavoritesAndUsagePersistIndependently() throws {
        let suite = "LauncherPreferencesTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = LauncherPreferences(defaults: defaults)
        XCTAssertTrue(store.setAlias("wx", for: "one"))
        XCTAssertFalse(store.setAlias("ＷＸ", for: "two"))
        store.toggleFavorite("one"); store.record("one"); store.record("one")
        let restored = LauncherPreferences(defaults: defaults)
        XCTAssertEqual(restored.personalization.favorites, ["one"])
        XCTAssertEqual(restored.usage["one"]?.count, 2)
        restored.clearUsage()
        XCTAssertEqual(restored.personalization.aliases["one"], "wx")
        XCTAssertTrue(LauncherPreferences(defaults: defaults).usage.isEmpty)
        XCTAssertTrue(store.usage.isEmpty)
    }
    func testLegacySourceMigrationDoesNotOverrideLaterChoices() throws {
        let suite = "LauncherMigrationTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var old = LauncherPersonalization()
        old.disabledSources = ["commands"]
        defaults.set(try JSONEncoder().encode(old), forKey: LauncherPreferences.personalizationKey)
        let store = LauncherPreferences(defaults: defaults)
        XCTAssertTrue(store.personalization.disabledSources.contains("system-operations"))
        store.update { $0.disabledSources.remove("system-operations") }
        XCTAssertFalse(LauncherPreferences(defaults: defaults).personalization.disabledSources.contains("system-operations"))
        XCTAssertTrue(store.personalization.disabledSources.contains("plugin-features"))
    }
    func testPortablePreferencesExcludeLocalApplicationPaths() {
        var value = LauncherPersonalization()
        value.favorites = ["application./Applications/Foo.app", "tool.calculator.calculator"]
        value.aliases = ["application./Applications/Foo.app": "foo", "tool.calculator.calculator": "calc"]
        XCTAssertEqual(value.portable.favorites, ["tool.calculator.calculator"])
        XCTAssertEqual(value.portable.aliases, ["tool.calculator.calculator": "calc"])
    }
}
