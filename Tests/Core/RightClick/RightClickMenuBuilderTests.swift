import XCTest
@testable import MacTools

final class RightClickMenuBuilderTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/Example")

    func testMenuOrderAndBackgroundSelectionConditions() throws {
        var configuration = RightClickConfiguration.activeDefault
        configuration.enabledActions = [.newFile, .newFolder, .terminal, .copyPath]
        configuration.categoryOrder = [.copy, .create, .open, .organize, .tools]
        configuration.actionOrder = [.newFile, .newFolder]
        let entries = RightClickMenuBuilder.entries(configuration: configuration, selection: .init(directory: directory))
        XCTAssertEqual(entries.compactMap(\.category), [.copy, .create, .open])
        let creation = try XCTUnwrap(entries.first { $0.category == .create })
        XCTAssertEqual(creation.children.map { $0.request?.action ?? $0.children.first?.request?.action }, [.newFile, .newFolder])
        let actions = leafActions(entries)
        XCTAssertEqual(actions.filter { $0 == .terminal }.count, 1)
        XCTAssertEqual(actions.filter { $0 == .copyPath }.count, 1)
        XCTAssertFalse(actions.contains(.copyName))
        XCTAssertFalse(actions.contains(.moveTo))
        XCTAssertTrue(actions.contains(.newFile))
    }

    func testSelectionConditionsAndFixedContextAreSharedByMenuRequests() {
        var configuration = RightClickConfiguration.activeDefault
        for action in RightClickAction.allCases { configuration.setEnabled(action, true) }
        let file = RightClickSelectionItem(url: directory.appendingPathComponent("a.txt"), isDirectory: false)
        let image = RightClickSelectionItem(url: directory.appendingPathComponent("a.png"), isDirectory: false, isImage: true)
        let mixed = RightClickSelection(items: [file, image], directory: directory)
        XCTAssertFalse(leafActions(RightClickMenuBuilder.entries(configuration: configuration, selection: mixed)).contains(.convertImage))
        let images = RightClickSelection(items: [image], directory: directory)
        let entries = RightClickMenuBuilder.entries(configuration: configuration, selection: images)
        XCTAssertTrue(leafActions(entries).contains(.convertImage))
        let requests = leafRequests(entries)
        XCTAssertTrue(requests.allSatisfy { $0.selection == images })
        XCTAssertFalse(leafActions(entries).contains(.dissolve))
    }

    func testRenamingSharedLocationUpdatesCopyMoveAndGoToWithoutChangingItsIdentity() {
        var configuration = RightClickConfiguration.activeDefault
        let location = RightClickLocation(name: "Original", path: "/Example/Shared")
        configuration.locations = [location]
        let actions: Set<RightClickAction> = [.copyTo, .moveTo, .goTo]
        for action in actions { configuration.setEnabled(action, true) }
        let selection = RightClickSelection(items: [.init(url: directory.appendingPathComponent("a.txt"), isDirectory: false)], directory: directory)
        configuration.locations[0].name = "Renamed"
        let entries = leafEntries(RightClickMenuBuilder.entries(configuration: configuration, selection: selection))
            .filter { $0.request.map { actions.contains($0.action) } ?? false }
        XCTAssertEqual(Set(entries.compactMap { $0.request?.action }), actions)
        XCTAssertEqual(entries.count, actions.count)
        XCTAssertTrue(entries.allSatisfy { $0.title == configuration.locations[0].name })
        XCTAssertTrue(entries.allSatisfy { $0.request?.resourceID == location.id && $0.request?.selection == selection })
        XCTAssertEqual(configuration.locations[0].path, location.path)
    }

    func testDisabledPluginHasNoMenu() {
        var configuration = RightClickConfiguration.activeDefault
        let selection = RightClickSelection(items: [.init(url: directory.appendingPathComponent("a.txt"), isDirectory: false)], directory: directory)
        configuration.menuEnabled = false
        XCTAssertTrue(RightClickMenuBuilder.entries(configuration: configuration, selection: selection).isEmpty)
    }

    func testRequestRoundTripRejectsNonFileTargetsAndUnsupportedVersions() throws {
        let request = RightClickRequest(action: .copyPath, selection: .init(directory: directory))
        XCTAssertEqual(RightClickRequest.decode(try XCTUnwrap(request.url(scheme: "mactools"))), request)
        var invalid = request
        invalid.selection.directory = URL(string: "https://example.com")
        XCTAssertNil(RightClickRequest.decode(try XCTUnwrap(invalid.url(scheme: "mactools"))))
        invalid = request
        invalid.version = 99
        XCTAssertNil(RightClickRequest.decode(try XCTUnwrap(invalid.url(scheme: "mactools"))))
        var unsupported = URLComponents(url: try XCTUnwrap(request.url(scheme: "mactools")), resolvingAgainstBaseURL: false)!
        unsupported.path = "/open-with"
        XCTAssertNil(RightClickRequest.decode(try XCTUnwrap(unsupported.url)))
    }

    private func leafEntries(_ entries: [RightClickMenuEntry]) -> [RightClickMenuEntry] {
        entries.flatMap { $0.request == nil ? leafEntries($0.children) : [$0] }
    }
    private func leafRequests(_ entries: [RightClickMenuEntry]) -> [RightClickRequest] { leafEntries(entries).compactMap(\.request) }
    private func leafActions(_ entries: [RightClickMenuEntry]) -> [RightClickAction] { leafRequests(entries).map(\.action) }
}
