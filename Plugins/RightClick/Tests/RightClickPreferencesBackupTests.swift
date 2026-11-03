import XCTest
import MacToolsPluginKit
@testable import RightClickPlugin

@MainActor
final class RightClickPreferencesBackupTests: XCTestCase {
    func testMenuAndMissingApplicationRoundTripPreservesDestinationLifecycleAndLanguage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.json")
        let destinationURL = directory.appendingPathComponent("destination.json")
        var source = RightClickConfiguration()
        source.copyFileURL = false
        let app = RightClickOpenWithApp(name: "Missing", appPath: "/missing/Example.app", fileExtensions: ["txt"])
        source.openWithApps = [app]
        XCTAssertTrue(RightClickConfigurationStore.save(source, to: sourceURL))
        var local = RightClickConfiguration()
        local.menuEnabled = false
        local.preferredLanguages = ["ja"]
        XCTAssertTrue(RightClickConfigurationStore.save(local, to: destinationURL))
        let exporter = RightClickPlugin(configurationFileURL: sourceURL)
        let importer = RightClickPlugin(configurationFileURL: destinationURL)
        let data = try XCTUnwrap(exporter.makePortablePreferencesBackup())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("/missing/"))
        var signals = 0
        importer.onPersistentPreferencesChange = { signals += 1 }
        XCTAssertTrue(importer.restorePortablePreferencesReportingResult(from: data))
        XCTAssertEqual(signals, 1)
        XCTAssertTrue(importer.restorePortablePreferencesReportingResult(from: data))
        XCTAssertEqual(signals, 1)
        let restored = RightClickConfigurationStore.load(from: destinationURL)
        XCTAssertFalse(restored.menuEnabled)
        XCTAssertEqual(restored.preferredLanguages, ["ja"])
        XCTAssertFalse(restored.copyFileURL)
        XCTAssertEqual(restored.openWithApps.first?.id, app.id)
        XCTAssertEqual(restored.openWithApps.first?.appPath, "")
        XCTAssertNotNil(restored.openWithApps.first?.portableApplicationReference)
        XCTAssertTrue(restored.openWithApplications(matching: [directory.appendingPathComponent("example.txt")]).isEmpty)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(importer.makePortablePreferencesBackup())) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testInvalidSourceCannotExportDefaultsOrBeOverwrittenByImport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("configuration.json")
        let plugin = RightClickPlugin(configurationFileURL: fileURL)
        XCTAssertNotNil(plugin.makePortablePreferencesBackup(), "A new installation has default portable preferences")
        try Data(#"{"copyFileURL":false}"#.utf8).write(to: fileURL)
        let backup = try XCTUnwrap(plugin.makePortablePreferencesBackup(), "Missing legacy fields retain their defaults")
        for text in ["{", #"{"copyFileURL":"invalid"}"#, #"{"openWithApps":[{"name":"incomplete"}]}"#] {
            let corrupt = Data(text.utf8)
            try corrupt.write(to: fileURL)
            XCTAssertNil(plugin.makePortablePreferencesBackup())
            XCTAssertFalse(plugin.restorePortablePreferencesReportingResult(from: backup))
            XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
        }
        var unresolved = RightClickOpenWithApp(name: "Missing", appPath: "")
        unresolved.portableApplicationReference = Data("invalid identity".utf8)
        XCTAssertTrue(RightClickConfigurationStore.save(.init(openWithApps: [unresolved]), to: fileURL))
        XCTAssertNil(plugin.makePortablePreferencesBackup(), "An unreadable retained identity must not become a new default identity")
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
        XCTAssertNil(plugin.makePortablePreferencesBackup(), "An existing unreadable source is not an absent configuration")
    }
    func testReleasedBackupRestoresIntoCurrentMenuAndRejectsMalformedFormat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("configuration.json")
        let plugin = RightClickPlugin(configurationFileURL: fileURL)
        let reference = PortableApplicationReference(url: directory.appendingPathComponent("Missing.app"))
        let identity = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference))
        var legacy: [String: Any] = [
            "formatVersion": 1, "newFolder": false, "newFile": true, "openInTerminal": true,
            "copyFileName": true, "copyAbsolutePath": true, "copyRelativePath": true,
            "copyShellEscapedPath": true, "copyFileURL": false,
            "applications": [["id": UUID().uuidString, "name": "Missing", "application": identity, "fileExtensions": ["txt"]]]
        ]
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: try JSONSerialization.data(withJSONObject: legacy)))
        let restored = RightClickConfigurationStore.load(from: fileURL)
        XCTAssertFalse(restored.isEnabled(.newFolder))
        XCTAssertFalse(restored.isEnabled(.copyURL))
        XCTAssertTrue(restored.isEnabled(.rename) == RightClickConfiguration.inactiveDefault.isEnabled(.rename))
        XCTAssertEqual(restored.openWithApps.first?.name, "Missing")
        XCTAssertTrue(restored.openWithApps.first?.isUnresolved == true)
        legacy["applications"] = [["id": "invalid"]]
        XCTAssertFalse(plugin.restorePortablePreferencesReportingResult(from: try JSONSerialization.data(withJSONObject: legacy)))
        XCTAssertEqual(RightClickConfigurationStore.load(from: fileURL), restored)
    }

}
