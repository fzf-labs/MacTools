import XCTest
import SwiftUI
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class LauncherSystemActionTests: XCTestCase {
    private func makeHost(_ plugins: [any MacToolsPlugin] = []) throws -> (PluginHost, UserDefaults) {
        let suite = "LauncherSystemActionTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let host = PluginHost(plugins: plugins, shortcutStore: .init(userDefaults: defaults),
            pluginOrderingStore: .init(userDefaults: defaults), preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()))
        return (host, defaults)
    }
    func testBuiltInCommandsExistWithoutPluginsAndRespectSearchPreferences() throws {
        let (host, defaults) = try makeHost()
        let commands = LauncherCatalogSnapshot.make(host: host, category: .systemOperations)
        XCTAssertEqual(Set(commands.map(\.id)), Set(LauncherSystemAction.allCases.map(\.identity)))
        XCTAssertTrue(host.actionRegistry.issues.isEmpty)
        for command in LauncherSystemAction.allCases {
            let definition = try XCTUnwrap(host.actionRegistry.definition(for: command.reference.key))
            XCTAssertEqual(host.launcherRole(for: command.reference), .systemOperation)
            XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
            if [.restart, .shutDown, .logOut, .emptyTrash].contains(command) {
                XCTAssertEqual(definition.risk, .confirmationRequired)
                XCTAssertNotNil(definition.confirmation)
            }
        }
        let model = LauncherModel(host: host, defaults: defaults, systemSettings: { [] })
        model.preferences.update { $0.disabledSources = [LauncherCategory.applications.rawValue, LauncherCategory.systemSettings.rawValue] }
        model.present()
        XCTAssertTrue(model.results.isEmpty)
        model.query = "Sleep Displays"
        XCTAssertEqual(model.results.first?.id, LauncherSystemAction.sleepDisplays.identity)
        XCTAssertTrue(model.preferences.setAlias("screenoff", for: LauncherSystemAction.sleepDisplays.identity, title: "Sleep Displays"))
        model.query = "screenoff"
        XCTAssertEqual(model.results.first?.id, LauncherSystemAction.sleepDisplays.identity)
        model.hideSelected(); model.rebuild()
        XCTAssertTrue(model.results.isEmpty)
        model.preferences.update { $0.disabledSources.insert(LauncherCategory.systemOperations.rawValue) }
        model.query = "Sleep"
        XCTAssertTrue(model.results.isEmpty)
        model.reset()
    }
    func testPluginLifecycleCannotReplaceSystemCommandsAndPluginActionsStaySeparate() async throws {
        for plugin in [SystemActionTestPlugin(), DeclaredSystemActionTestPlugin()] {
            let (host, defaults) = try makeHost([plugin])
            func commands() -> [LauncherResult] { LauncherCatalogSnapshot.make(host: host, category: .systemOperations) }
            let first = commands()
            for item in first {
                XCTAssertNil(item.pluginID)
                guard case let .action(reference) = item.target else { return XCTFail("Expected host system action") }
                XCTAssertEqual(reference.key.providerID, LauncherSystemAction.providerID)
            }
            let pluginReference = ActionReference(key: .init(providerID: "system-power", actionID: "sleep"))
            let pluginID = LauncherIdentity.action(pluginReference)
            let features = LauncherCatalogSnapshot.make(host: host, category: .pluginFeatures)
            XCTAssertEqual(features.map(\.id), [pluginID])
            XCTAssertEqual(features.first?.pluginID, "system-power")
            XCTAssertEqual(host.launcherRole(for: pluginReference), .pluginFeature)
            XCTAssertFalse(first.contains { $0.id == pluginID })

            let model = LauncherModel(host: host, defaults: defaults, systemSettings: { [] })
            model.preferences.update { $0.disabledSources = ["applications", "system-settings", "plugin-features"] }
            model.present(); model.query = "Sleep"
            XCTAssertFalse(model.results.isEmpty)
            XCTAssertTrue(model.results.allSatisfy { $0.category == .systemOperations })
            model.preferences.update { $0.disabledSources = ["applications", "system-settings", "system-operations"] }
            model.rebuild()
            XCTAssertEqual(model.results.map(\.id), [pluginID])
            model.reset()

            plugin.exposesCommand = false
            plugin.onStateChange?()
            await host.waitForScheduledPluginStateRebuildForTests()
            XCTAssertEqual(commands().map(\.id), first.map(\.id))
            XCTAssertTrue(LauncherCatalogSnapshot.make(host: host, category: .pluginFeatures).isEmpty)
            XCTAssertNil(host.launcherRole(for: pluginReference))
        }
    }
    func testProviderRejectsForgedReferencesAndExecutionUsesInjectedEffects() async throws {
        var executed: [LauncherSystemAction] = []
        let provider = LauncherSystemActionProvider { command, _ in executed.append(command); return .succeeded() }
        let registration = provider.registration
        let forged = ActionReference(key: LauncherSystemAction.openTrash.reference.key,
                                     parameters: try .init(["script": .string("untrusted")]))
        XCTAssertFalse(registration.availability(forged).isAvailable)
        XCTAssertNil(provider.command(for: .init(key: .init(providerID: "other", actionID: "sleep"))))
        XCTAssertNil(provider.command(for: .init(key: LauncherSystemAction.sleep.reference.key, schemaVersion: 2)))
        let invocation = ActionInvocation(reference: LauncherSystemAction.openTrash.reference, source: .manual, mode: .foreground)
        let handle = try registration.begin(invocation).get()
        let outcome = await handle.result()
        XCTAssertEqual(outcome, .succeeded())
        XCTAssertEqual(executed, [.openTrash])
        XCTAssertThrowsError(try registration.begin(.init(reference: forged, source: .manual, mode: .foreground)).get())
        XCTAssertEqual(executed, [.openTrash])
    }
}

@MainActor
private class SystemActionTestPlugin: MacToolsPlugin, PluginActionProviding {
    var exposesCommand = true
    var metadata: PluginMetadata { .init(id: "system-power", title: "Power", iconName: "power", iconTint: .red, order: 1, defaultDescription: "Test") }
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var actionDefinitions: [ActionDefinition] {
        exposesCommand ? [.init(key: .init(providerID: "system-power", actionID: "sleep"), title: "Sleep", description: "Test", systemImage: "moon.zzz")] : []
    }
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle { .init { .succeeded() } }
}

@MainActor
private final class DeclaredSystemActionTestPlugin: SystemActionTestPlugin, PluginLauncherActionProviding {
    func launcherRole(for reference: ActionReference) -> LauncherActionRole? { .systemOperation }
}
