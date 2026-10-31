import Foundation
import XCTest
@testable import DiskCleanPlugin

@MainActor
final class DiskCleanApplicationTrashTests: XCTestCase {
    func testFileReferenceTrashesReviewedObjectWithoutDeletingAPathReplacement() async throws {
        let root = try DiskCleanTempDirectory(name: "ApplicationNativeTrash")
        defer { root.remove() }
        let source = try root.makeFile("Apps/Fixture.app/data", bytes: 5).deletingLastPathComponent()
        let now = Date()
        let identity = try XCTUnwrap(DiskCleanPlanFactory.currentIdentity(ofItemAt: source.path))
        let candidate = DiskCleanCandidate(id: "app", targetID: "fixture", legacyRuleID: "fixture", category: .applications,
            path: source.path, risk: .medium, safety: .allowed,
            sizeResult: .testComplete(bytes: 5, identity: identity, observedAt: now),
            validation: .application(bundleID: "org.example.fixture", roots: [], bundlePath: source.path, isBundle: true))
        let plan = try DiskCleanPlanner.makePlan(artifact: .init(scope: .review, candidates: [candidate], reservedRootPaths: [],
            limitations: [], startedAt: now, finishedAt: now), selectedIDs: [candidate.id], mode: .trash, now: now,
            catalog: .init(targets: [.test(id: "fixture", reservedRootPaths: [])]))
        let destination = root.resolve("Trash/Fixture.app")
        try root.makeDirectory("Trash")
        let replacement = source.path
        let recycler = ReferenceFixtureRecycler(source: source, destination: destination, replacement: true)
        let result = await DiskCleanApplicationTrash(recycler: recycler).remove(try XCTUnwrap(plan.items.first))
        guard case .trashed = result else { return XCTFail("The reviewed object should move to the fixture Trash: \(result)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("data").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement + "/replacement"))
        let referenceUsed = await recycler.usedFileReference
        XCTAssertTrue(referenceUsed)
    }

    func testReplacementBeforeSubmissionAndPermissionCancellationDoNotDeleteFiles() async throws {
        let root = try DiskCleanTempDirectory(name: "ApplicationNativeTrashBoundary")
        defer { root.remove() }
        let source = try root.makeFile("Apps/Fixture.app/data", bytes: 5).deletingLastPathComponent()
        let now = Date()
        let candidate = DiskCleanCandidate(id: "app", targetID: "fixture", legacyRuleID: "fixture", category: .applications,
            path: source.path, risk: .medium, safety: .allowed,
            sizeResult: .testComplete(bytes: 5, identity: try XCTUnwrap(DiskCleanPlanFactory.currentIdentity(ofItemAt: source.path)), observedAt: now),
            validation: .application(bundleID: "org.example.fixture", roots: [], bundlePath: source.path, isBundle: true))
        let plan = try DiskCleanPlanner.makePlan(artifact: .init(scope: .review, candidates: [candidate], reservedRootPaths: [],
            limitations: [], startedAt: now, finishedAt: now), selectedIDs: [candidate.id], mode: .trash, now: now,
            catalog: .init(targets: [.test(id: "fixture", reservedRootPaths: [])]))
        let item = try XCTUnwrap(plan.items.first)
        let cancelled = await DiskCleanApplicationTrash(recycler: CancellingFixtureRecycler()).remove(item)
        guard case .failed = cancelled else { return XCTFail("Cancellation must not be reported as removal") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try FileManager.default.moveItem(at: source, to: root.resolve("Original.app"))
        try root.makeFile("Apps/Fixture.app/replacement", bytes: 3)
        let changed = await DiskCleanApplicationTrash(recycler: CancellingFixtureRecycler()).remove(item)
        XCTAssertEqual(changed, .changedSinceScan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("replacement").path))
    }
}

private actor ReferenceFixtureRecycler: DiskCleanApplicationRecycling {
    let source: URL
    let destination: URL
    let replacement: Bool
    var usedFileReference = false
    init(source: URL, destination: URL, replacement: Bool) {
        self.source = source
        self.destination = destination
        self.replacement = replacement
    }
    func recycle(reference: DiskCleanApplicationTrashReference) async throws -> URL {
        usedFileReference = reference.isFileReference
        if replacement {
            try FileManager.default.moveItem(at: source, to: source.deletingLastPathComponent().appendingPathComponent("Original.app"))
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data([1]).write(to: source.appendingPathComponent("replacement"))
        }
        guard let resolved = reference.resolvedPath else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.moveItem(at: URL(fileURLWithPath: resolved), to: destination)
        return destination
    }
}

private struct CancellingFixtureRecycler: DiskCleanApplicationRecycling {
    func recycle(reference: DiskCleanApplicationTrashReference) async throws -> URL { throw CocoaError(.userCancelled) }
}
