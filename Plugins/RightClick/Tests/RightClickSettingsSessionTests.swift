import XCTest
@testable import RightClickPlugin

@MainActor
final class RightClickSettingsSessionTests: XCTestCase {
    func testFailedSaveRetainsDraftAndCanRetryWithoutChangingLifecycleFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("Parent")
        try Data().write(to: blocker)
        let file = blocker.appendingPathComponent("preferences.json")
        let session = RightClickSettingsSession(configuration: .activeDefault, fileURL: file)
        session.configuration.setEnabled(.newFile, false)
        XCTAssertNotNil(session.error)
        XCTAssertTrue(session.needsSaveRetry)
        XCTAssertFalse(session.configuration.isEnabled(.newFile))
        try FileManager.default.removeItem(at: blocker)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        session.saveDraft()
        XCTAssertNil(session.error)
        XCTAssertFalse(session.needsSaveRetry)
        let restored = RightClickConfigurationStore.load(from: file)
        XCTAssertFalse(restored.isEnabled(.newFile))
        XCTAssertFalse(restored.menuEnabled)
    }
}

@MainActor
final class RightClickPortablePreferencesTests: XCTestCase {
    func testBackupOmitsPayloadsAndRestorePreservesLifecycleAndLanguage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("configuration.json")
        var configuration = RightClickConfiguration.activeDefault
        configuration.preferredLanguages = ["en"]
        configuration.setEnabled(.rename, true)
        XCTAssertTrue(RightClickConfigurationStore.save(configuration, to: file))
        let plugin = RightClickPlugin(configurationURL: file)
        let data = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        let portable = try JSONDecoder().decode(RightClickConfiguration.self, from: data)
        XCTAssertFalse(portable.menuEnabled)
        XCTAssertNil(portable.preferredLanguages)
        configuration.setEnabled(.rename, false)
        XCTAssertTrue(RightClickConfigurationStore.save(configuration, to: file))
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: data))
        let restored = RightClickConfigurationStore.load(from: file)
        XCTAssertTrue(restored.menuEnabled)
        XCTAssertEqual(restored.preferredLanguages, ["en"])
        XCTAssertTrue(restored.isEnabled(.rename))
        var invalid = portable
        invalid.resources = [RightClickResource(name: "Invalid", kind: .template, filename: "../escape")]
        XCTAssertFalse(plugin.restorePortablePreferencesReportingResult(from: try JSONEncoder().encode(invalid)))
        XCTAssertEqual(RightClickConfigurationStore.load(from: file), restored)
    }
}
