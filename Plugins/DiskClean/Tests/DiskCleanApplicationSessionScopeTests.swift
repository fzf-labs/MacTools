import Foundation
import XCTest
@testable import DiskCleanPlugin

final class DiskCleanApplicationSessionScopeTests: XCTestCase {
    func testSessionExceptionRequiresPersonalOwnedScopeAndPreservesOtherProtections() throws {
        let home = "/Users/tester"
        let id = "org.example.editor"
        let path = home + "/Library/Application Support/" + id
        let proof = DiskCleanApplicationProof(path: path, ownerID: id, mainBundleID: id, allowsPersonalSessionRemoval: true)
        let scope = try XCTUnwrap(DiskCleanApplicationSessionScope(path: path, home: home, proof: proof))
        let policy = DiskCleanSafetyPolicy(homeDirectory: home)
        for suffix in ["/session/Cookies", "/session/Cookies-journal", "/Session Storage", "/Local State"] {
            XCTAssertFalse(policy.safetyStatus(for: path + suffix).isCleanable)
            XCTAssertTrue(policy.safetyStatus(for: path + suffix, applicationSessionScope: scope).isCleanable)
        }
        for protected in [home + "/Library/Keychains/login.keychain-db", path + "/session/access_token",
                          path + "/session/Login Data", path + "/session/Web Data", path + "/credentials/Cookies",
                          home + "/Library/Application Support/other/session/Cookies"] {
            XCTAssertFalse(policy.safetyStatus(for: protected, applicationSessionScope: scope).isCleanable, protected)
        }
        let whitelist = DiskCleanWhitelistStore(homeDirectory: home, includeDefaults: false,
            customRules: [path + "/session/*"])
        let whitelisted = DiskCleanSafetyPolicy(homeDirectory: home, whitelistStore: whitelist)
        guard case .whitelisted = whitelisted.safetyStatus(for: path + "/session/Cookies", applicationSessionScope: scope) else {
            return XCTFail("Session selection must not bypass a whitelist")
        }
        var unreviewed = proof
        unreviewed.allowsPersonalSessionRemoval = false
        XCTAssertNil(DiskCleanApplicationSessionScope(path: path, home: home, proof: unreviewed))
        var ambiguous = proof
        ambiguous.mainBundleID = nil
        XCTAssertNil(DiskCleanApplicationSessionScope(path: path, home: home, proof: ambiguous))
        let shared = home + "/Library/Group Containers/group.shared"
        XCTAssertNil(DiskCleanApplicationSessionScope(path: shared, home: home,
            proof: .init(path: shared, ownerID: id, mainBundleID: id, allowsPersonalSessionRemoval: true)))
        let cache = home + "/Library/Caches/" + id
        XCTAssertNil(DiskCleanApplicationSessionScope(path: cache, home: home,
            proof: .init(path: cache, ownerID: id, mainBundleID: id, allowsPersonalSessionRemoval: true)))
    }

    func testContentReviewAllowsOnlyOwnedSessionStateAndRechecksSensitiveDescendants() throws {
        let root = try DiskCleanTempDirectory(name: "PersonalSessionReview")
        defer { root.remove() }
        let id = "org.example.editor"
        let path = try root.makeFile("Library/Application Support/" + id + "/session/Cookies", bytes: 4)
            .deletingLastPathComponent().deletingLastPathComponent().path
        let policy = DiskCleanSafetyPolicy(homeDirectory: root.path)
        let proof = DiskCleanApplicationProof(path: path, ownerID: id, mainBundleID: id, allowsPersonalSessionRemoval: true)
        let scope = try XCTUnwrap(DiskCleanApplicationSessionScope(path: path, home: root.path, proof: proof))
        XCTAssertNotNil(DiskCleanContentReview(policy: policy).inspect(path: path).rejection)
        let review = DiskCleanContentReview(policy: policy, applicationSessionScope: scope)
        XCTAssertNil(review.inspect(path: path).rejection)
        try root.makeFile("Library/Application Support/" + id + "/session/access_token", bytes: 4)
        XCTAssertNotNil(review.inspect(path: path).rejection)
    }
}
