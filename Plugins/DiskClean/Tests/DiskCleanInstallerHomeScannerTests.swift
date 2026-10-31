import Foundation
import XCTest
@testable import DiskCleanPlugin

final class DiskCleanInstallerHomeScannerTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    func testExpandedSearchStreamsEachCandidateOnceAndUsesTheReviewedTrashPipeline() async throws {
        let root = try DiskCleanTempDirectory(name: "InstallerHomePipeline")
        defer { root.remove() }
        let downloaded = try root.makeFile("Downloads/Nested/Old.pkg", bytes: 8)
        let desktop = try root.makeFile("Desktop/KeepUnlessSelected.pkg", bytes: 8)
        let excluded = try root.makeFile("Library/Private/Keep.pkg", bytes: 8)
        let date = observedAt
        for file in [downloaded, desktop] {
            try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(-30 * 24 * 60 * 60)], ofItemAtPath: file.path)
        }
        let policy = DiskCleanSafetyPolicy(homeDirectory: root.path)
        let engine = DiskCleanScanEngine(safetyPolicy: policy, runningAppLock: ProgrammableDiskCleanRunningAppLock(),
            installerExpansion: DiskCleanInstallerExpansion(homeScanner: .init(home: root.path, now: { date })))
        var discovered: [String] = []
        var artifact: DiskCleanScanArtifact?
        for try await event in engine.scan(scope: .installers, forceRefresh: true) {
            if case let .candidateFound(candidate) = event { discovered.append(candidate.id) }
            if case let .finished(summary) = event { artifact = summary.artifact }
        }
        let reviewed = try XCTUnwrap(artifact)
        XCTAssertEqual(discovered.count, 2)
        XCTAssertEqual(Set(discovered), Set(reviewed.candidates.map(\.id)))
        XCTAssertEqual(reviewed.candidates.filter(DiskCleanSelectionModel.isSelectedByDefault).map(\.path), [downloaded.path])
        let plan = try DiskCleanPlanner.makePlan(artifact: reviewed, selectedIDs: Set(reviewed.candidates.map(\.id)),
            mode: .trash, now: Date(), catalog: .current)
        let executor = DiskCleanExecutor(
            primitive: DiskCleanRemovalPrimitive(journal: .init(directory: root.resolve("Journal")), trash: FakeDiskCleanTrash()),
            safetyPolicy: policy, runningAppLock: ProgrammableDiskCleanRunningAppLock(), auditLog: .init(directory: root.resolve("History")))
        let result = try await executor.execute(plan: plan)
        XCTAssertEqual(result.removedCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: excluded.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloaded.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: desktop.path))
    }

    func testFindsNestedInstallersPrioritizesCommonFoldersAndSelectsOnlyOldDownloadPackages() throws {
        let root = try DiskCleanTempDirectory(name: "InstallerHome")
        defer { root.remove() }
        let files = ["Downloads/Nested/Old.pkg", "Downloads/Fresh.pkg", "Downloads/Backup.dmg", "Downloads/System.iso",
                     "Desktop/Tool.pkg", "Documents/Archive/Tool.xip", "Other/Keep.pkg", "AtHome.pkg"]
        for name in files {
            let file = try root.makeFile(name, bytes: 8)
            let age: TimeInterval = name.contains("Fresh") ? 60 : 30 * 24 * 60 * 60
            try FileManager.default.setAttributes([.modificationDate: observedAt.addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        let recorder = InstallerDiscoveryRecorder()
        let date = observedAt
        let report = DiskCleanInstallerHomeScanner(home: root.path, now: { date }).scan { recorder.append($0) }
        XCTAssertEqual(Set(report.candidates.map(\.path)), Set(files.map { root.resolve($0).path }))
        XCTAssertEqual(report.candidates.filter(\.isSelectedByDefault).map(\.path), [root.resolve("Downloads/Nested/Old.pkg").path])
        let discovery = recorder.candidates
        XCTAssertEqual(discovery.count, files.count)
        let common = discovery.indices.filter { discovery[$0].path.contains("/Downloads/") || discovery[$0].path.contains("/Desktop/") || discovery[$0].path.contains("/Documents/") }
        let other = discovery.indices.filter { !common.contains($0) }
        XCTAssertLessThan(try XCTUnwrap(common.max()), try XCTUnwrap(other.min()))
        XCTAssertTrue(report.reservedRoots.contains(root.path))
        XCTAssertTrue(report.limitations.isEmpty)
    }

    func testSkipsPrivatePackageDependencyCloudAndLinkedTreesAndInspectsZIPMetadata() throws {
        let root = try DiskCleanTempDirectory(name: "InstallerHomeExclusions")
        defer { root.remove() }
        let excluded = ["Library/Cache/Old.pkg", ".private/Old.pkg", "Applications/Tool.app/Contents/Old.pkg",
            "Desktop/Other.app/Contents/Old.pkg", "Documents/Project/node_modules/module/Old.pkg", "Documents/Project/build/Old.pkg",
            "Dropbox/Old.pkg", "OneDrive-Team/Old.pkg", "Downloads/Box/Old.pkg", "Photos.photoslibrary/Old.pkg"]
        for path in excluded { try root.makeFile(path, bytes: 8) }
        let outside = try DiskCleanTempDirectory(name: "InstallerOutsideHome")
        defer { outside.remove() }
        try outside.makeFile("Outside.pkg", bytes: 8)
        try root.makeSymlink("Desktop/Linked", destination: outside.path)
        try root.makeSymlink("Downloads/Linked.pkg", destination: outside.resolve("Outside.pkg").path)
        try root.makeDirectory("Downloads/Package.pkg/Contents")
        try Data("plist".utf8).write(to: root.resolve("Downloads/Package.pkg/Contents/Info.plist"))
        try root.makeFile("Downloads/Package.pkg/Contents/Archive.bom", bytes: 8)
        try root.makeFile("Downloads/Package.pkg/Contents/Embedded.pkg", bytes: 8)
        try DiskCleanInstallerArchiveTests.archive(names: ["Tool.app/Contents/Info.plist"]).write(to: root.resolve("Downloads/Tool.zip"))
        try DiskCleanInstallerArchiveTests.archive(names: ["Pictures/photo.jpg"]).write(to: root.resolve("Downloads/Photos.zip"))
        let report = DiskCleanInstallerHomeScanner(home: root.path).scan()
        XCTAssertEqual(Set(report.candidates.map(\.path)), Set([root.resolve("Downloads/Package.pkg").path, root.resolve("Downloads/Tool.zip").path]))
    }

    func testUnreadableSubfolderIsReportedWithoutDiscardingOtherDiscoveries() throws {
        let root = try DiskCleanTempDirectory(name: "InstallerHomePermission")
        defer { root.remove() }
        try root.makeFile("Downloads/Readable.pkg", bytes: 8)
        try root.makeFile("Documents/Denied/Hidden.pkg", bytes: 8)
        try root.denyAccess(to: "Documents/Denied")
        let report = DiskCleanInstallerHomeScanner(home: root.path).scan()
        XCTAssertEqual(report.candidates.map(\.path), [root.resolve("Downloads/Readable.pkg").path])
        XCTAssertTrue(report.limitations.contains(.scanRootUnreadable(path: root.resolve("Documents/Denied").path, reason: .permissionDenied)))
    }

    func testDepthEntryDeadlineAndCancellationLimitsDoNotClaimAnEmptyCompleteScan() throws {
        let root = try DiskCleanTempDirectory(name: "InstallerHomeLimits")
        defer { root.remove() }
        try root.makeFile("Downloads/Visible.pkg", bytes: 8)
        try root.makeFile("Downloads/Deeper/Hidden.pkg", bytes: 8)
        let depth = DiskCleanInstallerHomeScanner(home: root.path, limits: .init(maximumDepth: 1)).scan()
        XCTAssertEqual(depth.candidates.map(\.path), [root.resolve("Downloads/Visible.pkg").path])
        XCTAssertTrue(depth.limitations.contains(.installerSearchLimited))
        for scanner in [DiskCleanInstallerHomeScanner(home: root.path, limits: .init(maximumEntries: 0)),
                        DiskCleanInstallerHomeScanner(home: root.path, limits: .init(timeout: 0)),
                        DiskCleanInstallerHomeScanner(home: root.path, isCancelled: { true })] {
            let report = scanner.scan()
            XCTAssertTrue(report.candidates.isEmpty)
            XCTAssertTrue(report.limitations.contains(.installerSearchLimited))
        }
    }

    func testReplacingQueuedDirectoryWithALinkNeverTraversesTheReplacement() throws {
        let root = try DiskCleanTempDirectory(name: "InstallerHomeReplacement")
        defer { root.remove() }
        let outside = try DiskCleanTempDirectory(name: "InstallerHomeReplacementOutside")
        defer { outside.remove() }
        try outside.makeFile("Keep.pkg", bytes: 8)
        try root.makeFile("Downloads/Trigger.pkg", bytes: 8)
        try root.makeDirectory("Documents")
        let documents = root.resolve("Documents").path
        let destination = outside.path
        let report = DiskCleanInstallerHomeScanner(home: root.path).scan { _ in
            try? FileManager.default.removeItem(atPath: documents)
            try? FileManager.default.createSymbolicLink(atPath: documents, withDestinationPath: destination)
        }
        XCTAssertEqual(report.candidates.map(\.path), [root.resolve("Downloads/Trigger.pkg").path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.resolve("Keep.pkg").path))
        XCTAssertTrue(report.limitations.contains(.scanRootUnreadable(path: documents, reason: .walkError)))
    }
}

private final class InstallerDiscoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DiskCleanInstallerCandidate] = []
    var candidates: [DiskCleanInstallerCandidate] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ candidates: [DiskCleanInstallerCandidate]) { lock.lock(); defer { lock.unlock() }; values += candidates }
}
