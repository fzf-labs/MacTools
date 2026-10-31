import Foundation
import XCTest
@testable import DiskCleanPlugin

@MainActor
final class DiskCleanScanRootsTests: XCTestCase {
    func testRootsNormalizePersistedAndDefaultAliasesWithoutChangingOtherWorkflows() throws {
        let root = try DiskCleanTempDirectory(name: "ScanRoots")
        defer { root.remove() }
        let target = try root.makeDirectory("Applications").path
        let alias = root.resolve("Alias").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: target)
        let suiteName = "DiskCleanScanRootsTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["separate"], forKey: "projectRoots")
        let store = DiskCleanScanRootsStore(key: "applicationRoots", defaults: [target, alias], preferences: defaults)
        let model = DiskCleanScanRoots(store: store)
        XCTAssertEqual(model.paths, [target])
        XCTAssertNil(defaults.stringArray(forKey: "applicationRoots"))
        XCTAssertEqual(defaults.stringArray(forKey: "projectRoots"), ["separate"])
    }
}
