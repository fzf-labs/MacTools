import Foundation
import XCTest
@testable import DiskCleanPlugin

final class DiskCleanPurgeRootPolicyTests: XCTestCase {
    func testRejectsBroadRootsWhileAllowingProjectSubfolders() {
        for path in ["/", "/Applications", "/System", "/Users", "/Library", "/Volumes", NSHomeDirectory(),
                     NSHomeDirectory() + "/Documents", "/Users/Another", "/Users/Another/Desktop", "/home/Another/Downloads"] {
            XCTAssertTrue(DiskCleanPurgeRootPolicy.isTooBroad(path), path)
        }
        for path in [NSHomeDirectory() + "/Documents/MyApp", "/Users/Another/Desktop/MyApp", "/home/Another/Downloads/MyApp"] {
            XCTAssertFalse(DiskCleanPurgeRootPolicy.isTooBroad(path), path)
        }
    }
}
