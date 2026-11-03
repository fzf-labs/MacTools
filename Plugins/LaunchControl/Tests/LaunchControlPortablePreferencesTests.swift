import XCTest
import MacToolsPluginKit
@testable import LaunchControlPlugin

@MainActor
final class LaunchControlPortablePreferencesTests: XCTestCase {
    func testFavoritesRebaseWithoutScanAndOmittedNotesPreserveDestination() throws {
        let source = FakePluginStorage()
        let destination = FakePluginStorage()
        let sourceHome = URL(fileURLWithPath: "/Users/source")
        let destinationHome = URL(fileURLWithPath: "/Users/destination")
        let sourcePath = "/Users/source/Library/LaunchAgents/example.plist"
        let destinationPath = "/Users/destination/Library/LaunchAgents/example.plist"
        source.set([sourcePath, "/Library/LaunchDaemons/global.plist"], forKey: LaunchControlPortablePreferences.Key.favorites)
        source.set(try JSONEncoder().encode([sourcePath: "Private source note"]), forKey: LaunchControlPortablePreferences.Key.notes)
        destination.set(try JSONEncoder().encode([destinationPath: "Local note"]), forKey: LaunchControlPortablePreferences.Key.notes)
        destination.set(["unrecognized-legacy-id"], forKey: LaunchControlPortablePreferences.Key.favorites)
        let exporter = LaunchControlPortablePreferences(storage: source, homeURL: sourceHome)
        let importer = LaunchControlPortablePreferences(storage: destination, homeURL: destinationHome)
        let data = try XCTUnwrap(exporter.backup())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("/Users/source"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Private source note"))
        XCTAssertTrue(importer.restore(data))
        XCTAssertEqual(Set(destination.stringArray(forKey: LaunchControlPortablePreferences.Key.favorites) ?? []),
                       [destinationPath, "/Library/LaunchDaemons/global.plist", "unrecognized-legacy-id"])
        XCTAssertEqual(importer.unmatchedReferences(matching: []).count, 2)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: XCTUnwrap(destination.data(forKey: LaunchControlPortablePreferences.Key.notes))), [destinationPath: "Local note"])
        XCTAssertEqual(importer.backup(), data)
    }

    func testOptedInNotesCannotOverwriteExcludedDestinationNotes() throws {
        let source = FakePluginStorage()
        let destination = FakePluginStorage()
        let path = "/Library/LaunchAgents/example.plist"
        let key = LaunchControlPortablePreferences.Key.notes
        source.set(try JSONEncoder().encode([path: "Imported\nnote"]), forKey: key)
        destination.set(try JSONEncoder().encode([path: "Protected"]), forKey: key)
        let exporter = LaunchControlPortablePreferences(storage: source)
        let importer = LaunchControlPortablePreferences(storage: destination)
        XCTAssertTrue(exporter.setIncludesNotes(true))
        let data = try XCTUnwrap(exporter.backup())
        XCTAssertFalse(importer.restore(data))
        XCTAssertFalse(importer.includesNotes)
        XCTAssertTrue(importer.setIncludesNotes(true))
        XCTAssertTrue(importer.restore(data))
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: XCTUnwrap(destination.data(forKey: key))), [path: "Imported\nnote"])
    }

    func testExcludedLegacyNoteDoesNotBlockFavoritesAndRemainsByteIdentical() throws {
        let storage = FakePluginStorage()
        let path = "/Library/LaunchAgents/example.plist"
        let raw = try JSONSerialization.data(withJSONObject: [path: String(repeating: "x", count: 16_385)], options: [.prettyPrinted])
        storage.set(raw, forKey: LaunchControlPortablePreferences.Key.notes)
        let provider = LaunchControlPortablePreferences(storage: storage)
        let data = try XCTUnwrap(provider.backup())
        XCTAssertNil(try JSONDecoder().decode(LaunchControlPortablePreferences.Payload.self, from: data).notes)
        let incoming = LaunchControlPortablePreferences.Payload(formatVersion: 1,
            favorites: [.init(location: .globalAgents, plistFileName: "example.plist")], notes: nil)
        XCTAssertTrue(provider.restore(try JSONEncoder().encode(incoming)))
        XCTAssertEqual(storage.stringArray(forKey: LaunchControlPortablePreferences.Key.favorites), [path])
        XCTAssertEqual(storage.data(forKey: LaunchControlPortablePreferences.Key.notes), raw)
        XCTAssertTrue(provider.setIncludesNotes(true))
        XCTAssertNil(provider.backup())
        XCTAssertEqual(storage.data(forKey: LaunchControlPortablePreferences.Key.notes), raw)
    }

    func testTraversalAndFutureVersionRejectBeforeMutation() throws {
        let storage = FakePluginStorage()
        let provider = LaunchControlPortablePreferences(storage: storage)
        let before = storage.values
        let bad = LaunchControlPortablePreferences.Payload(formatVersion: 1,
            favorites: [.init(location: .userAgents, plistFileName: "../outside.plist")], notes: nil)
        XCTAssertFalse(provider.restore(try JSONEncoder().encode(bad)))
        let future = LaunchControlPortablePreferences.Payload(formatVersion: 2, favorites: [], notes: nil)
        XCTAssertFalse(provider.restore(try JSONEncoder().encode(future)))
        XCTAssertEqual(storage.values as NSDictionary, before as NSDictionary)
    }
}
