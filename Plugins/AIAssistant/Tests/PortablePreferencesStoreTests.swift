import Foundation
import XCTest
@testable import AIAssistantPlugin

@MainActor
final class PortablePreferencesStoreTests: XCTestCase {
    func testFailedCommitRestoresTouchedValuesAndAbsentKeysWithoutCopyingExcludedData() {
        let storage = AIAssistantInMemoryPluginStorage()
        let privateData = Data(repeating: 42, count: 2_097_153)
        storage.set(4, forKey: "changed")
        storage.set(true, forKey: "removed")
        storage.set(privateData, forKey: "private")
        let store = PortablePreferencesStore(storage: storage, fields: [
            "changed": .integer(0, range: 0...10), "created": .integer(0, range: 0...10),
            "removed": .boolean(false), "private": .data(Data(), maximumBytes: 1_024, validate: { _ in true })
        ])
        XCTAssertTrue(store.commit(["changed": .integer(6)]))
        storage.blockedSetKeys = ["created"]

        XCTAssertFalse(store.commit(["changed": .integer(8), "created": .integer(3)], removing: ["removed"]))

        XCTAssertEqual(storage.integer(forKey: "changed"), 6)
        XCTAssertNil(storage.object(forKey: "created"))
        XCTAssertTrue(storage.bool(forKey: "removed"))
        XCTAssertEqual(storage.data(forKey: "private"), privateData)
        XCTAssertNil(storage.object(forKey: "preferences-backup.restore.v2"))
    }

    func testScopedRecoveryRestoresOnlyJournaledKeys() throws {
        let storage = AIAssistantInMemoryPluginStorage()
        storage.set(8, forKey: "changed")
        storage.set(3, forKey: "created")
        storage.set(true, forKey: "untouched")
        let journal: [String: Any] = ["formatVersion": 2, "keys": ["changed", "created"], "previous": ["changed": 4]]
        storage.set(try PropertyListSerialization.data(fromPropertyList: journal, format: .binary, options: 0),
            forKey: "preferences-backup.restore.v2")
        let store = PortablePreferencesStore(storage: storage, fields: [
            "changed": .integer(0, range: 0...10), "created": .integer(0, range: 0...10), "untouched": .boolean(false)
        ])

        XCTAssertNil(store.backup())
        XCTAssertTrue(store.recover())
        XCTAssertEqual(storage.integer(forKey: "changed"), 4)
        XCTAssertNil(storage.object(forKey: "created"))
        XCTAssertTrue(storage.bool(forKey: "untouched"))
        XCTAssertNotNil(store.backup())
    }

    func testLegacyRecoveryPreservesItsFullFieldAndAbsentKeySemantics() throws {
        let storage = AIAssistantInMemoryPluginStorage()
        storage.set(8, forKey: "changed")
        storage.set(3, forKey: "created")
        storage.set(true, forKey: "outsideAllowlist")
        storage.set(try PropertyListSerialization.data(fromPropertyList: ["changed": 4], format: .binary, options: 0),
            forKey: "preferences-backup.restore.v1")
        let store = PortablePreferencesStore(storage: storage, fields: [
            "changed": .integer(0, range: 0...10), "created": .integer(0, range: 0...10)
        ])

        XCTAssertNil(store.backup())
        XCTAssertTrue(store.recover())
        XCTAssertEqual(storage.integer(forKey: "changed"), 4)
        XCTAssertNil(storage.object(forKey: "created"))
        XCTAssertTrue(storage.bool(forKey: "outsideAllowlist"))
        XCTAssertNotNil(store.backup())
    }
}
