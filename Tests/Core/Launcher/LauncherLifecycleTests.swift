import AppKit
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class LauncherLifecycleTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "LauncherLifecycleTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        LauncherPreferences(defaults: defaults).update { $0.disabledSources = ["applications", "system-settings"] }
        return defaults
    }
    private func host(_ plugins: [any MacToolsPlugin], defaults: UserDefaults) -> PluginHost {
        PluginHost(plugins: plugins, shortcutStore: .init(userDefaults: defaults),
            pluginOrderingStore: .init(userDefaults: defaults), preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()))
    }
    func testSettingsReuseSourceSnapshotsAndInvalidateChangedProviders() async throws {
        let defaults = try defaults()
        let provider = DeclaredLauncherTestPlugin()
        let host = host([provider], defaults: defaults)
        var builds: [LauncherCategory?: Int] = [:]
        var systemLookups = 0
        let settings = LauncherSettingsModel(host: host, defaults: defaults, snapshot: { category in
            builds[category, default: 0] += 1
            return LauncherCatalogSnapshot.make(host: host, category: category, settings: { systemLookups += 1; return [] })
        })
        XCTAssertEqual(settings.results(for: .pluginFeatures).count, 1)
        XCTAssertEqual(systemLookups, 0)
        XCTAssertTrue(settings.results(for: .systemSettings).isEmpty)
        XCTAssertEqual(settings.results(for: .pluginFeatures).count, 1)
        XCTAssertEqual(builds[.pluginFeatures], 1)
        XCTAssertEqual(builds[.systemSettings], 1)
        provider.includesOther = true
        provider.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        await settings.waitForScheduledRefreshForTests()
        XCTAssertEqual(settings.results(for: .pluginFeatures).count, 2)
        XCTAssertTrue(settings.results(for: .systemSettings).isEmpty)
        XCTAssertEqual(systemLookups, 1)
        XCTAssertEqual(builds[.pluginFeatures], 2)
        provider.isExposed = false
        provider.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        await settings.waitForScheduledRefreshForTests()
        XCTAssertTrue(settings.results(for: .pluginFeatures).isEmpty)
    }

    func testOnlyDeclaredFunctionsAppearAndEmptyHomeHasNoPromotions() throws {
        let defaults = try defaults()
        let provider = DeclaredLauncherTestPlugin()
        let host = host([provider], defaults: defaults)
        let model = LauncherModel(host: host, defaults: defaults, systemSettings: { [] })
        model.preferences.toggleFavorite("tool.calculator.calculator")
        model.present()
        XCTAssertTrue(model.results.isEmpty)
        model.query = "Tool"
        XCTAssertEqual(model.results.map(\.title), ["Tool"])
        XCTAssertEqual(model.results.first?.category, .pluginFeatures)
        model.query = "Configure"
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.preferences.personalization.favorites.contains("tool.calculator.calculator"))
        model.reset()
    }
    func testCatalogRefreshKeepsSelectionAndWithdrawalPreservesPreferences() async throws {
        let defaults = try defaults()
        let provider = DeclaredLauncherTestPlugin()
        let host = host([provider], defaults: defaults)
        let model = LauncherModel(host: host, defaults: defaults, systemSettings: { [] })
        model.present(); model.query = "Tool"
        let id = try XCTUnwrap(model.selectedID)
        model.favorite()
        provider.includesOther = true
        provider.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        model.rebuild()
        XCTAssertEqual(model.selectedID, id)
        XCTAssertEqual(model.results.count, 2)
        provider.isExposed = false
        provider.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        model.rebuild()
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.preferences.personalization.favorites.contains(id))
        model.activate()
        XCTAssertEqual(provider.executions, 0)
        model.reset()
    }
    func testLegacyInventoryAllowsActualWorkspaceActionsAndExcludesUnknownProviders() throws {
        let defaults = try defaults()
        let legacy = LegacyLauncherTestPlugin(id: "disk-clean", actionID: "scan-and-review")
        let unknown = LegacyLauncherTestPlugin(id: "unknown", actionID: "open")
        let host = host([legacy, unknown], defaults: defaults)
        let model = LauncherModel(host: host, defaults: defaults, systemSettings: { [] })
        let results = model.catalogResults()
        XCTAssertEqual(results.map(\.pluginID), ["disk-clean"])
        XCTAssertNil(LauncherActionPolicy.legacyRole(for: .init(providerID: "disk-clean", actionID: "open-settings")))
        XCTAssertNil(LauncherActionPolicy.legacyRole(for: .init(providerID: "activity-bar", actionID: "reset-today")))
    }
    func testMatchQualityWinsOverUsageAndHiddenEntriesCannotExecute() throws {
        let defaults = try defaults()
        let provider = DeclaredLauncherTestPlugin()
        provider.includesOther = true
        let host = host([provider], defaults: defaults)
        let model = LauncherModel(host: host, defaults: defaults, systemSettings: { [] })
        let other = try XCTUnwrap(model.catalogResults().first { $0.title == "Other Tool" })
        for _ in 0..<3 { model.preferences.record(other.id) }
        model.present(); model.query = "Tool"
        XCTAssertEqual(model.results.first?.title, "Tool")
        model.hideSelected()
        model.rebuild()
        XCTAssertEqual(model.results.map(\.title), ["Other Tool"])
        model.reset()
    }
    func testPreparedOperationsAreOneUseAndReleaseOrInvalidateSafely() async throws {
        let operations = LauncherOperationRegistry(providerID: "test")
        var didRun = false
        let action = operations.prepare { didRun = true; return .succeeded() }
        XCTAssertTrue(operations.availability(action.reference).isAvailable)
        let invocation = ActionInvocation(reference: action.reference, source: .manual, mode: .foreground)
        let handle = try operations.begin(invocation)
        XCTAssertThrowsError(try operations.begin(invocation))
        operations.invalidate()
        let outcome = await handle.result()
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(didRun)
        action.release(); action.release()
        XCTAssertFalse(operations.availability(action.reference).isAvailable)
    }
    func testSystemSettingsAvailabilityAndFailedNavigation() {
        XCTAssertTrue(LauncherSystemSettings.availableEntries(majorVersion: 13, extensionExists: { _ in true }).isEmpty)
        let pages = LauncherSystemSettings.availableEntries(majorVersion: 14, extensionExists: { $0 == "Wi-Fi" })
        XCTAssertEqual(pages.map(\.id), ["wifi"])
        var opened: URL?
        XCTAssertFalse(LauncherSystemSettings.open(pages[0], using: { opened = $0; return false }))
        XCTAssertEqual(opened?.absoluteString, "x-apple.systempreferences:com.apple.wifi-settings-extension")
    }
}

@MainActor
private class LegacyLauncherTestPlugin: MacToolsPlugin, PluginActionProviding {
    let id: String
    let actionID: String
    var metadata: PluginMetadata { .init(id: id, title: "Test Plugin", iconName: "command", iconTint: .blue, order: 1, defaultDescription: "Test") }
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var executions = 0
    init(id: String, actionID: String) { self.id = id; self.actionID = actionID }
    var actionCatalogEntries: [ActionCatalogEntry] { actionDefinitions.map { .init(reference: .init(key: $0.key), title: $0.title) } }
    var actionDefinitions: [ActionDefinition] { [.init(key: .init(providerID: id, actionID: actionID), title: "Tool", description: "Test", systemImage: "command", capabilities: [.foregroundInteractive])] }
    func actionAvailability(for reference: ActionReference) -> ActionAvailability { .available }
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle { executions += 1; return .init { .succeeded() } }
}

@MainActor
private final class DeclaredLauncherTestPlugin: LegacyLauncherTestPlugin, PluginLauncherActionProviding {
    var includesOther = false
    var isExposed = true
    init() { super.init(id: "launcher-test", actionID: "perform") }
    override var actionDefinitions: [ActionDefinition] {
        [("perform", "Tool"), ("other", "Other Tool"), ("configure", "Configure Plugin")].map { id, title in
            .init(key: .init(providerID: metadata.id, actionID: id), title: title, description: "Test", systemImage: "command", capabilities: [.foregroundInteractive])
        }
    }
    override var actionCatalogEntries: [ActionCatalogEntry] {
        actionDefinitions.filter { includesOther || $0.key.actionID != "other" }.map { .init(reference: .init(key: $0.key), title: $0.title) }
    }
    func launcherRole(for reference: ActionReference) -> LauncherActionRole? {
        !isExposed || reference.key.actionID == "configure" ? nil : .pluginFeature
    }
}
