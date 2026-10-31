import Foundation
import XCTest
@testable import DiskCleanPlugin

final class DiskCleanApplicationCrashRecordTests: XCTestCase {
    func testOnlyExactExecutableTimestampRecordsReceiveOwnershipEvidence() throws {
        let root = try DiskCleanTempDirectory(name: "CrashRecordOwnership")
        defer { root.remove() }
        let id = "org.example.editor"
        let path = root.resolve("Library/Application Support/CrashReporter/Editor_" + UUID().uuidString + ".plist")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(["ForceQuitDate": Date()], to: path)
        let record = DiskCleanApplicationCrashRecord(home: root.path, executable: "Editor")
        XCTAssertTrue(record.permits(path.path))
        let identity = DiskCleanApplicationIdentity(ids: [id], names: ["Editor"], mainBundleID: id, executables: ["Editor"])
        let resolver = DiskCleanApplicationOwnership(home: root.path)
        let result = resolver.resolve(bundleID: id, identity: identity, claimsComplete: false)
        let candidate = try XCTUnwrap(result.associations.first { $0.path == path.path })
        XCTAssertNil(candidate.manualReason)
        XCTAssertFalse(candidate.isPersonal)
        XCTAssertNotNil(candidate.proof?.crashRecord)
        let conflict = resolver.resolve(bundleID: id, identity: identity, otherExecutables: ["editor"])
        XCTAssertNotNil(conflict.associations.first { $0.path == path.path }?.manualReason)
        let nameOnly = resolver.resolve(bundleID: id, identity: .init(ids: [id], names: ["Editor"]))
        XCTAssertNotNil(nameOnly.associations.first { $0.path == path.path }?.manualReason)
        try write(["ForceQuitDate": Date(), "UserDocument": "Keep"], to: path)
        XCTAssertFalse(record.permits(path.path))
        XCTAssertNotNil(candidate.proof?.rejection(at: path.path))
        let arbitrary = resolver.resolve(bundleID: id, identity: identity)
        let reviewed = try XCTUnwrap(arbitrary.associations.first { $0.path == path.path })
        XCTAssertNil(reviewed.manualReason)
        XCTAssertTrue(reviewed.isPersonal)
        XCTAssertNil(reviewed.proof?.crashRecord)
        XCTAssertNotNil(reviewed.proof?.nameCandidate)
        let alias = root.resolve("Library/Application Support/CrashReporter/Editor_" + UUID().uuidString + ".plist")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: path)
        XCTAssertFalse(record.permits(alias.path))
    }

    func testFreshExecutableClaimBlocksPreviouslyAttributedRecord() async throws {
        let root = try DiskCleanTempDirectory(name: "FreshCrashRecordOwner")
        defer { root.remove() }
        let path = root.resolve("Library/Application Support/CrashReporter/Editor_" + UUID().uuidString + ".plist")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(["ForceQuitDate": Date()], to: path)
        let id = "org.example.original"
        let proof = DiskCleanApplicationProof(path: path.path, ownerID: id, mainBundleID: id,
            crashRecord: .init(home: root.path, executable: "Editor"))
        for shared in [false, true] {
            let presence = DiskCleanApplicationPresence(inventory: { _ in
                .init(applications: shared ? [.init(path: root.resolve("Other.app").path, bundleID: "org.example.other",
                    name: "Other", executable: "Editor", rejection: nil)] : [], isComplete: true, issues: [])
            }, registered: { _ in false }, running: { _ in false })
            let validator = DiskCleanReviewValidator(policy: .init(homeDirectory: root.path),
                runner: FakeDiskCleanSubprocessRunner(), presence: presence)
            let rejection = await validator.rejection(path: path.path,
                evidence: .application(bundleID: id, roots: [], bundlePath: root.resolve("Missing.app").path,
                    isBundle: false, proof: proof))
            XCTAssertEqual(rejection != nil, shared)
        }
    }

    private func write(_ value: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: url)
    }
}
