import XCTest
import MacToolsPluginKit
@testable import LaunchControlPlugin

@MainActor
final class LaunchControlCanonicalActionTests: XCTestCase {
    func testRestorationInvalidatesOnlyEditorsWhoseSavedNotesChanged() throws {
        let path = "/Library/LaunchAgents/com.example.synthetic.plist"
        let item = makeItem(id: path, label: "com.example.synthetic", isFavorite: false)
        let other = makeItem(id: "/Library/LaunchAgents/com.example.other.plist", label: "com.example.other", isFavorite: false)
        let storage = FakePluginStorage()
        let runner = FakeLaunchControlCommandRunner()
        let controller = LaunchControlController(runner: runner,
            context: .init(pluginID: "launch-control", storage: storage), initialSnapshot: .init(items: [item, other]))
        controller.setNote("Saved note", for: item)
        let reference = LaunchControlPortablePreferences.Reference(location: .globalAgents, plistFileName: "com.example.synthetic.plist")
        func restore(notes: [LaunchControlPortablePreferences.Note]?) throws {
            let payload = LaunchControlPortablePreferences.Payload(formatVersion: 1, favorites: [reference], notes: notes)
            XCTAssertTrue(controller.restorePreferencesBackup(try JSONEncoder().encode(payload)))
        }

        try restore(notes: nil)
        XCTAssertTrue(controller.noteRestorationRevisions.isEmpty)
        XCTAssertEqual(controller.snapshot.items.first { $0.id == path }?.note, "Saved note")
        controller.setIncludesNotesInBackup(true)
        try restore(notes: [.init(reference: reference, text: "Saved note")])
        XCTAssertTrue(controller.noteRestorationRevisions.isEmpty)
        try restore(notes: [.init(reference: reference, text: "Imported note")])
        XCTAssertEqual(controller.noteRestorationRevisions, [path: 1])
        try restore(notes: nil)
        XCTAssertEqual(controller.noteRestorationRevisions, [path: 1])
        try restore(notes: [])
        XCTAssertEqual(controller.noteRestorationRevisions, [path: 2])
        XCTAssertEqual(controller.snapshot.items.first { $0.id == path }?.note, "")
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testOnlyFavoriteManageableItemsPublishCanonicalActions() throws {
        let favorite = makeItem(id: "favorite", label: "com.example.favorite", isFavorite: true)
        let ordinary = makeItem(id: "ordinary", label: "com.example.ordinary", isFavorite: false)
        let runner = FakeLaunchControlCommandRunner()
        let controller = LaunchControlController(
            runner: runner,
            initialSnapshot: LaunchControlSnapshot(items: [favorite, ordinary])
        )
        let plugin = LaunchControlPlugin(controller: controller)

        XCTAssertEqual(plugin.actionCatalogEntries.count, 3)
        XCTAssertTrue(plugin.actionCatalogEntries.allSatisfy { $0.title.contains(favorite.label) })
        XCTAssertFalse(plugin.actionCatalogEntries.contains { $0.title.contains(ordinary.label) })
        XCTAssertTrue(plugin.actionDefinitions.allSatisfy { definition in
            definition.parameters.first?.portability == .localOnly
                && definition.externalInvocationPolicy == .unavailable
        })
    }

    func testFavoriteStartActionWaitsForLaunchctlResult() async throws {
        let item = makeItem(id: "favorite", label: "com.example.favorite", isFavorite: true)
        let runner = FakeLaunchControlCommandRunner()
        let controller = LaunchControlController(
            runner: runner,
            initialSnapshot: LaunchControlSnapshot(items: [item])
        )
        let plugin = LaunchControlPlugin(controller: controller)
        let entry = try XCTUnwrap(plugin.actionCatalogEntries.first { $0.reference.key.actionID == "start-favorite" })

        let handle = try plugin.beginAction(
            ActionInvocation(reference: entry.reference, source: .actionGrid, mode: .background)
        )

        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(
            try XCTUnwrap(runner.calls.first),
            ["kickstart", "gui/501/\(item.label)"]
        )
    }

    func testOpenManagerRequestsConfigurationPresentation() {
        let plugin = LaunchControlPlugin()
        var requests = 0
        plugin.requestSettingsPresentation = { requests += 1 }

        plugin.handleAction(.invokeAction(controlID: LaunchControlPlugin.ControlID.openManager))

        XCTAssertEqual(requests, 1)
    }

    private func makeItem(id: String, label: String, isFavorite: Bool) -> LaunchControlItem {
        LaunchControlItem(
            id: id,
            label: label,
            plistURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/\(label).plist"),
            scope: .user,
            origin: .userCreated,
            state: .loaded,
            pid: nil,
            lastExitStatus: 0,
            programArguments: ["/usr/bin/true"],
            runAtLoad: false,
            keepAliveDescription: nil,
            startInterval: nil,
            startCalendarDescription: nil,
            rawPlist: "",
            launchctlDomain: "gui/501",
            isDisabled: false,
            isLoaded: true,
            isFavorite: isFavorite
        )
    }
}

private final class FakeLaunchControlCommandRunner: LaunchControlCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [[String]] = []

    var calls: [[String]] {
        lock.withLock { storedCalls }
    }

    func runLaunchctl(arguments: [String]) throws -> LaunchControlCommandResult {
        lock.withLock { storedCalls.append(arguments) }
        return LaunchControlCommandResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}
