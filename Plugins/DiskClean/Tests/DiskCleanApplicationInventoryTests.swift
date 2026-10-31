import Foundation
import XCTest
@testable import DiskCleanPlugin

final class DiskCleanApplicationInventoryTests: XCTestCase {
    func testInventoryPreservesCopiesAndDoesNotDiscoverNestedApps() async throws {
        let root = try DiskCleanTempDirectory(name: "ApplicationInventory")
        defer { root.remove() }
        try makeApp(root, "Apps/Vendor/One.app", id: "org.example.editor")
        try makeApp(root, "Apps/Two.app", id: "org.example.editor")
        try makeApp(root, "Apps/Two.app/Contents/Helpers/Inner.app", id: "org.example.editor.helper")
        let result = await DiskCleanApplicationInventory(roots: [root.resolve("Apps").path]).scan()
        XCTAssertTrue(result.isComplete, result.issues.joined(separator: ","))
        XCTAssertEqual(result.applications.count, 2)
        XCTAssertEqual(Set(result.applications.map(\.bundleID)), ["org.example.editor"])
        XCTAssertEqual(Set(result.applications.map(\.path)).count, 2)
    }

    func testInvalidApplicationMakesInventoryIncompleteAndLinksAreNotFollowed() async throws {
        let root = try DiskCleanTempDirectory(name: "ApplicationInventory")
        defer { root.remove() }
        try root.makeDirectory("Apps/Broken.app")
        try makeApp(root, "Outside/Good.app", id: "org.example.good")
        try FileManager.default.createSymbolicLink(atPath: root.resolve("Apps/Linked.app").path, withDestinationPath: root.resolve("Outside/Good.app").path)
        let result = await DiskCleanApplicationInventory(roots: [root.resolve("Apps").path]).scan()
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.applications.isEmpty)
    }

    func testOwnershipRequiresExactBundleIDAndKeepsPersonalDataSeparate() throws {
        let root = try DiskCleanTempDirectory(name: "ApplicationOwnership")
        defer { root.remove() }
        try root.makeDirectory("Library/Caches/org.example.editor")
        try root.makeDirectory("Library/Caches/org.example.editor.beta")
        try root.makeDirectory("Library/Application Support/Editor")
        try root.makeDirectory("Library/Group Containers/org.example.editor")
        try root.makeFile("Library/Preferences/org.example.editor.plist", bytes: 2)
        let ownership = DiskCleanApplicationOwnership(home: root.url.path)
        let rows = ownership.associations(bundleID: "org.example.editor")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter(\.isPersonal).map(\.path), [root.resolve("Library/Preferences/org.example.editor.plist").path])
        XCTAssertFalse(rows.contains { $0.path.contains("Group Containers") || $0.path.hasSuffix(".beta") })
        XCTAssertTrue(ownership.associations(bundleID: "../Editor").isEmpty)
    }

    func testSystemApplicationIsNeverUninstallable() {
        XCTAssertNotNil(DiskCleanApplicationInventory.bundleRejection(path: "/Applications/Safari.app", bundleID: "com.apple.Safari"))
    }

    func testHomebrewAndManagedInstallerMetadataDoNotBlockApplicationTrash() async throws {
        let root = try DiskCleanTempDirectory(name: "ManagedApplicationInventory")
        defer { root.remove() }
        let path = "Apps/Editor.app"
        try makeApp(root, path, id: "org.example.editor")
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.editor",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "2026.10", "SMPrivilegedExecutables": ["org.example.helper": "identifier helper"],
            "SUInstallerLauncherService": "org.example.updater"], format: .xml, options: 0)
        try info.write(to: root.resolve(path + "/Contents/Info.plist"))
        let cask = try root.makeDirectory("Caskroom/editor/1.0")
        try FileManager.default.createSymbolicLink(at: cask.appendingPathComponent("Editor.app"), withDestinationURL: root.resolve(path))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.resolve(path).path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.resolve(path).path) }
        let inventory = DiskCleanApplicationInventory(roots: [root.resolve("Apps").path], homebrewRoots: [root.resolve("Caskroom").path])
        let result = await inventory.scan()
        XCTAssertTrue(result.isComplete)
        let app = try XCTUnwrap(result.applications.first)
        XCTAssertTrue(app.isHomebrew)
        XCTAssertNil(app.rejection)
        XCTAssertEqual(app.version, "2026.10")
    }

    private func makeApp(_ root: DiskCleanTempDirectory, _ path: String, id: String) throws {
        try root.makeDirectory(path + "/Contents")
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id,
            "CFBundleName": "Fixture", "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture"], format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: root.resolve(path + "/Contents/Info.plist").path))
    }
}
