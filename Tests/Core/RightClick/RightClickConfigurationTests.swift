import XCTest
@testable import MacTools

final class RightClickConfigurationStoreTests: XCTestCase {
    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("right-click-menu.json")
    }

    func testSaveThenLoadRoundTrips() throws {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        var config = RightClickConfiguration.activeDefault
        config.preferredLanguages = ["en"]
        config.setEnabled(.terminal, false)
        config.setEnabled(.copyURL, false)
        config.openWithApps = [
            RightClickOpenWithApp(name: "Code", appPath: "/Applications/Code.app", fileExtensions: ["txt", "md"])
        ]

        XCTAssertTrue(RightClickConfigurationStore.save(config, to: fileURL))
        let loaded = RightClickConfigurationStore.load(from: fileURL)

        XCTAssertEqual(loaded, config)
        XCTAssertEqual(loaded.preferredLanguages, ["en"])
        XCTAssertFalse(loaded.isEnabled(.terminal))
        XCTAssertEqual(loaded.openWithApps.first?.name, "Code")
        XCTAssertEqual(loaded.openWithApps.first?.fileExtensions, ["txt", "md"])
    }

    func testInvalidConfigurationKeepsMenusInactive() throws {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var incomplete = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(RightClickConfiguration.activeDefault)) as? [String: Any])
        incomplete.removeValue(forKey: "enabledActions")
        var unsupported = RightClickConfiguration.activeDefault
        unsupported.schemaVersion = 99
        for data in [Data("not json".utf8), try JSONSerialization.data(withJSONObject: incomplete), try JSONEncoder().encode(unsupported)] {
            try data.write(to: fileURL)
            XCTAssertEqual(RightClickConfigurationStore.load(from: fileURL), .inactiveDefault)
        }
    }

    func testSetMenuEnabledPreservesExistingSettings() throws {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        var config = RightClickConfiguration.activeDefault
        config.setEnabled(.copyName, false)
        config.openWithApps = [
            RightClickOpenWithApp(name: "Code", appPath: "/Applications/Code.app")
        ]
        XCTAssertTrue(RightClickConfigurationStore.save(config, to: fileURL))

        RightClickConfigurationStore.setMenuEnabled(false, fileURL: fileURL)
        var loaded = RightClickConfigurationStore.load(from: fileURL)
        XCTAssertFalse(loaded.menuEnabled)
        XCTAssertFalse(loaded.isEnabled(.copyName))
        XCTAssertEqual(loaded.openWithApps.first?.name, "Code")

        RightClickConfigurationStore.setMenuEnabled(true, fileURL: fileURL)
        loaded = RightClickConfigurationStore.load(from: fileURL)
        XCTAssertTrue(loaded.menuEnabled)
        XCTAssertFalse(loaded.isEnabled(.copyName))
        XCTAssertEqual(loaded.openWithApps.first?.name, "Code")
    }

}

final class RightClickOpenWithAppTests: XCTestCase {
    func testMatchesListedExtensionsCaseInsensitively() {
        let app = RightClickOpenWithApp(name: "Editor", appPath: "/E.app", fileExtensions: ["txt", "md"])
        XCTAssertTrue(app.matches(fileExtension: "txt"))
        XCTAssertTrue(app.matches(fileExtension: "TXT"))
        XCTAssertTrue(app.matches(fileExtension: "md"))
        XCTAssertFalse(app.matches(fileExtension: "png"))
    }

}
