import XCTest
@testable import MacTools

final class RightClickResourceStoreTests: XCTestCase {
    func testResourcePackageRoundTripKeepsContentsAndUsesFreshIdentities() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("template.md")
        try Data("# Real template\n".utf8).write(to: source)
        let store = RightClickResourceStore(root: root.appendingPathComponent("Managed"))
        let resource = try store.importResource(from: source, kind: .template)
        let archive = root.appendingPathComponent("Resources.mactoolsresources")
        try store.exportArchive(resources: [resource], to: archive)
        let imported = try XCTUnwrap(store.importArchive(from: archive).first)
        XCTAssertNotEqual(imported.id, resource.id)
        XCTAssertEqual(try Data(contentsOf: store.url(for: imported)), try Data(contentsOf: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.url(for: resource).path))
    }

    func testResourceArchiveRejectsTraversalAndConflictingPayloadStructure() {
        let resource = RightClickResource(name: "Template", kind: .template, filename: "placeholder")
        var safe = resource
        safe.filename = safe.id.uuidString + ".pages"
        let root = RightClickResourceStore.Payload(resourceID: safe.id, path: "", data: nil)
        let traversal = RightClickResourceStore.Payload(resourceID: safe.id, path: "../escape", data: Data())
        XCTAssertThrowsError(try RightClickResourceStore.validate(.init(resources: [safe], files: [root, traversal])))
        let fileRoot = RightClickResourceStore.Payload(resourceID: safe.id, path: "", data: Data())
        let child = RightClickResourceStore.Payload(resourceID: safe.id, path: "nested", data: Data())
        XCTAssertThrowsError(try RightClickResourceStore.validate(.init(resources: [safe], files: [fileRoot, child])))
    }

    func testWarpDirectoryEncodingNeverTreatsFilenameAsAdditionalParameters() throws {
        let path = "/tmp/项目 a&new_window=false#fragment"
        let url = try XCTUnwrap(RightClickTerminalAdapter.warpURL(directory: URL(fileURLWithPath: path), newTab: true))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "path", value: path)])
        XCTAssertNil(parts.fragment)
        XCTAssertEqual(parts.path, "/new_tab")
    }
}

extension RightClickResourceStoreTests {
    func testImportedPackageReconnectsMissingRestoredMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Notes.md")
        try Data("template".utf8).write(to: source)
        let store = RightClickResourceStore(root: root.appendingPathComponent("Managed"))
        let original = try store.importResource(from: source, kind: .template)
        let archive = root.appendingPathComponent("Export.mactoolsresources")
        try store.exportArchive(resources: [original], to: archive)
        try store.remove(original)
        let imported = try XCTUnwrap(store.importArchive(from: archive, restoring: [original]).first)
        XCTAssertEqual(imported.id, original.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.url(for: original).path))
    }
}
