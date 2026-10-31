import Foundation
import XCTest
@testable import DiskCleanPlugin

final class DiskCleanApplicationNameCandidateTests: XCTestCase {
    func testOrdinaryNameMatchesAreReviewablePersonalDataButKnownSharingIsProtected() throws {
        let root = try DiskCleanTempDirectory(name: "NameCandidateReview")
        defer { root.remove() }
        let app = try application(root: root, id: "org.example.editor", name: "Example Editor")
        let data = try root.makeFile("Library/Application Support/Example Editor/session/Cookies", bytes: 3)
            .deletingLastPathComponent().deletingLastPathComponent().path
        let hidden = try root.makeDirectory(".config/example_editor").path
        let identity = DiskCleanApplicationIdentity.read(bundleID: app.bundleID, copies: [app])
        let resolver = DiskCleanApplicationOwnership(home: root.path)
        let result = resolver.resolve(bundleID: app.bundleID, identity: identity, claimsComplete: false)
        for path in [data, hidden] {
            let row = try XCTUnwrap(result.associations.first { $0.path.caseInsensitiveCompare(path) == .orderedSame })
            XCTAssertNil(row.manualReason)
            XCTAssertTrue(row.isPersonal)
            let proof = try XCTUnwrap(row.proof)
            XCTAssertNotNil(proof.nameCandidate)
            XCTAssertNil(proof.rejection(at: row.path))
            let scope = try XCTUnwrap(DiskCleanApplicationSessionScope(path: row.path, home: root.path, proof: proof))
            XCTAssertNil(DiskCleanContentReview(policy: .init(homeDirectory: root.path), applicationSessionScope: scope)
                .inspect(path: row.path).rejection)
        }
        let collision = resolver.resolve(bundleID: app.bundleID, identity: identity, otherNames: ["example editor"])
        XCTAssertNotNil(collision.associations.first { $0.path == data }?.manualReason)
        XCTAssertNil(collision.associations.first { $0.path == data }?.proof?.nameCandidate)
        let zcode = try application(root: root, id: "dev.zcode.app", name: "ZCode")
        let known = try root.makeDirectory("Library/Application Support/ZCode").path
        let knownResult = resolver.resolve(bundleID: zcode.bundleID,
            identity: DiskCleanApplicationIdentity.read(bundleID: zcode.bundleID, copies: [zcode]))
        XCTAssertNotNil(knownResult.associations.first { $0.path == known }?.proof?.product)
        XCTAssertNil(knownResult.associations.first { $0.path == known }?.proof?.nameCandidate)
        let firefox = try application(root: root, id: "org.mozilla.firefox", name: "Firefox")
        let shared = try root.makeDirectory("Library/Application Support/Firefox").path
        let sharedResult = resolver.resolve(bundleID: firefox.bundleID,
            identity: DiskCleanApplicationIdentity.read(bundleID: firefox.bundleID, copies: [firefox]))
        XCTAssertNotNil(sharedResult.associations.first { $0.path == shared }?.manualReason)
        XCTAssertNil(sharedResult.associations.first { $0.path == shared }?.proof?.nameCandidate)
        XCTAssertFalse(DiskCleanApplicationNameCandidate(home: root.path, relativePath: "Library/Application Support/Google", matchedName: "Google").permits(root.resolve("Library/Application Support/Google").path))
    }

    func testFreshNameOwnerBlocksReviewedCandidateBeforeRemoval() async throws {
        let root = try DiskCleanTempDirectory(name: "NameCandidateRecheck")
        defer { root.remove() }
        let app = try application(root: root, id: "org.example.editor", name: "Example Editor")
        let path = try root.makeFile("Library/Application Support/Example Editor/session/Cookies", bytes: 3)
            .deletingLastPathComponent().deletingLastPathComponent().path
        let identity = DiskCleanApplicationIdentity.read(bundleID: app.bundleID, copies: [app])
        let result = DiskCleanApplicationOwnership(home: root.path).resolve(bundleID: app.bundleID, identity: identity)
        let proof = try XCTUnwrap(result.associations.first { $0.path == path }?.proof)
        try FileManager.default.removeItem(atPath: app.path)
        for hasOtherOwner in [false, true] {
            let presence = DiskCleanApplicationPresence(inventory: { _ in
                .init(applications: hasOtherOwner ? [.init(path: root.resolve("Other.app").path, bundleID: "org.example.beta",
                    name: "Example Editor Beta", executable: nil, rejection: nil)] : [], isComplete: true, issues: [])
            }, registered: { _ in false }, running: { _ in false })
            let validator = DiskCleanReviewValidator(policy: .init(homeDirectory: root.path),
                runner: FakeDiskCleanSubprocessRunner(), presence: presence)
            let reason = await validator.rejection(path: path, evidence: .application(bundleID: app.bundleID,
                roots: [], bundlePath: app.path, isBundle: false, proof: proof))
            XCTAssertEqual(reason != nil, hasOtherOwner)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
        XCTAssertNotNil(proof.rejection(at: root.resolve("Elsewhere").path))
    }

    private func application(root: DiskCleanTempDirectory, id: String, name: String) throws -> DiskCleanInstalledApplication {
        let contents = try root.makeDirectory("Apps/" + UUID().uuidString + ".app/Contents")
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id,
            "CFBundlePackageType": "APPL", "CFBundleName": name], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        return .init(path: contents.deletingLastPathComponent().path, bundleID: id, name: name, executable: nil, rejection: nil)
    }
}
