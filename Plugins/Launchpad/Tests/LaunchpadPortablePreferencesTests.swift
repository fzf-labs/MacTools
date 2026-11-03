import XCTest
@testable import LaunchpadPlugin

@MainActor
final class LaunchpadPortablePreferencesTests: XCTestCase {
    func testUnresolvedFolderAndHiddenAppRetainIdentityAndAlphabeticalResetRemovesLayout() throws {
        let source = FakePluginStorage()
        let preferences = LaunchpadPreferences(storage: source)
        let layout = LaunchpadLayoutStore(storage: source)
        let folderID = UUID().uuidString
        let a = LaunchpadAppRef(id: "/unavailable/Alpha.app", name: "Alpha")
        let b = LaunchpadAppRef(id: "/unavailable/Beta.app", name: "Beta")
        source.set(try JSONEncoder().encode(LaunchpadLayout(nodes: [.folder(id: folderID, name: "Folder", children: [b, a])])), forKey: "customLayout")
        layout.reloadCommittedSnapshot()
        preferences.hide(a.id)
        preferences.hotCorner = .topLeft
        let exporter = LaunchpadPortablePreferences(storage: source, preferences: preferences, layoutStore: layout, beforePublishing: {})
        let data = try XCTUnwrap(exporter.backup())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("/unavailable/"))
        let destination = FakePluginStorage()
        let restoredPreferences = LaunchpadPreferences(storage: destination)
        let restoredLayout = LaunchpadLayoutStore(storage: destination)
        var dismissed = 0
        let importer = LaunchpadPortablePreferences(storage: destination, preferences: restoredPreferences, layoutStore: restoredLayout, beforePublishing: { dismissed += 1 })
        var signals = 0
        importer.onPersistentPreferencesChange = { signals += 1 }
        XCTAssertTrue(importer.restore(data))
        guard case let .folder(id, _, children)? = restoredLayout.layout?.nodes.first else { return XCTFail("Missing folder") }
        XCTAssertEqual(id, folderID)
        XCTAssertEqual(children.map(\.name), ["Beta", "Alpha"])
        XCTAssertTrue(restoredPreferences.hiddenAppIDs.contains(children[1].id))
        XCTAssertEqual(importer.applicationName(for: children[1].id), "Alpha")
        XCTAssertEqual(restoredPreferences.hotCorner, .topLeft)
        XCTAssertEqual(importer.backup(), data)
        XCTAssertEqual(signals, 1)
        XCTAssertEqual(dismissed, 1)
        let empty = FakePluginStorage()
        let alphabetical = LaunchpadPortablePreferences(storage: empty, preferences: .init(storage: empty), layoutStore: .init(storage: empty), beforePublishing: {})
        XCTAssertTrue(importer.restore(try XCTUnwrap(alphabetical.backup())))
        XCTAssertNil(destination.object(forKey: "customLayout"))
        XCTAssertNil(restoredLayout.layout)
    }

    func testApplicationAliasUsesCanonicalInstallationRootWithoutLosingBundleIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let applications = directory.appendingPathComponent("Applications")
        let systemApplications = directory.appendingPathComponent("CryptexApplications")
        let bundle = systemApplications.appendingPathComponent("Browser.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.browser", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let alias = applications.appendingPathComponent("Browser.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: bundle)
        let roots: [PortableApplicationReference.Location: URL] = [.applications: applications, .cryptexApplications: systemApplications]
        let reference = PortableApplicationReference(url: alias, roots: roots)
        XCTAssertEqual(reference.location, .cryptexApplications)
        XCTAssertEqual(reference.bundleIdentifier, "com.example.browser")
        XCTAssertEqual(reference.relativePath, "Browser.app")
        XCTAssertEqual(reference.resolvedURL(roots: roots)?.standardizedFileURL, bundle.standardizedFileURL)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(reference), as: UTF8.self).contains(directory.path))
    }

    func testRejectedWriteDoesNotPublishOrDismissOverlay() throws {
        let source = FakePluginStorage()
        let preferences = LaunchpadPreferences(storage: source)
        preferences.hotCorner = .topLeft
        let exporter = LaunchpadPortablePreferences(storage: source, preferences: preferences, layoutStore: .init(storage: source), beforePublishing: {})
        let destination = FakePluginStorage()
        let restoredPreferences = LaunchpadPreferences(storage: destination)
        var dismissed = 0
        let importer = LaunchpadPortablePreferences(storage: destination, preferences: restoredPreferences, layoutStore: .init(storage: destination), beforePublishing: { dismissed += 1 })
        let before = destination.values as NSDictionary
        destination.rejectedKeys.insert("portable-app-bindings.v1")
        XCTAssertFalse(importer.restore(try XCTUnwrap(exporter.backup())))
        XCTAssertEqual(destination.values as NSDictionary, before)
        XCTAssertEqual(restoredPreferences.hotCorner, .off)
        XCTAssertEqual(dismissed, 0)
    }
}
