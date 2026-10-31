import Foundation
import XCTest
import MacToolsPluginKit
@testable import DiskCleanPlugin

final class DiskCleanDeveloperArtifactLocationsTests: XCTestCase {
    func testFindsProjectManifestsInArbitrarilyNamedFoldersAndKeepsBroadContainersOutOfPurgeRoots() throws {
        let home = try DiskCleanTempDirectory(name: "AutomaticProjects")
        defer { home.remove() }
        let projects = [("Documents/Client Work/Web", "package.json"), ("Desktop/Experiment", "Cargo.toml"),
            ("Unusual/SDK", "Package.swift"), ("Research/Model", "pyproject.toml"),
            ("Tools/Legacy", "setup.py"), ("Other/Android", "build.gradle.kts"),
            ("Services/Backend", "Backend.csproj"), ("Sites/Store", "composer.json"), ("Mobile/Client", "pubspec.yaml")]
        for (folder, manifest) in projects { try home.makeFile(folder + "/" + manifest, bytes: 8) }
        try home.makeFile("package.json", bytes: 8)
        try home.makeFile("Documents/package.json", bytes: 8)
        try home.makeFile("Documents/node_modules/Keep/package.json", bytes: 8)
        let locations = DiskCleanDeveloperArtifactLocations(home: home.path)
        let result = locations.resolve()
        XCTAssertEqual(Set(result.roots), Set(projects.map { home.resolve($0.0).path }))
        XCTAssertFalse(result.roots.contains(home.path))
        XCTAssertFalse(result.roots.contains(home.resolve("Documents").path))
        XCTAssertTrue(result.reservedRoots.contains(home.path))
        XCTAssertTrue(result.limitations.isEmpty)
        try home.makeFile("New Place/App/package.json", bytes: 8)
        XCTAssertTrue(locations.resolve().roots.contains(home.resolve("New Place/App").path))
    }

    func testExcludesSystemApplicationDependencyCloudHiddenAndLinkedTrees() throws {
        let home = try DiskCleanTempDirectory(name: "AutomaticProjectExclusions")
        defer { home.remove() }
        for folder in ["Library/Private", ".hidden/App", "Editor.app/Contents/Resources/app", "Dropbox/Private",
            "OneDrive-Team/Project", "Container/node_modules/Dependency", "Container/build/Output", "Applications/Example"] {
            try home.makeFile(folder + "/package.json", bytes: 8)
        }
        let outside = try DiskCleanTempDirectory(name: "AutomaticProjectsOutside")
        defer { outside.remove() }
        try outside.makeFile("package.json", bytes: 8)
        try home.makeSymlink("Linked", destination: outside.path)
        try home.makeDirectory("OnlyMarkerLink")
        try home.makeSymlink("OnlyMarkerLink/package.json", destination: outside.resolve("package.json").path)
        try home.makeDirectory("FakeMarker/package.json")
        let result = DiskCleanDeveloperArtifactLocations(home: home.path).resolve()
        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertTrue(result.limitations.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.resolve("package.json").path))
    }

    func testInaccessibleFolderIsReportedSeparatelyFromAnEmptySearch() throws {
        let home = try DiskCleanTempDirectory(name: "AutomaticProjectAccess")
        defer { home.remove() }
        XCTAssertTrue(DiskCleanDeveloperArtifactLocations(home: home.path).resolve().limitations.isEmpty)
        try home.makeFile("Client/Denied/package.json", bytes: 8)
        try home.denyAccess(to: "Client/Denied")
        let result = DiskCleanDeveloperArtifactLocations(home: home.path).resolve()
        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertEqual(result.limitations, [.scanRootUnreadable(path: home.resolve("Client/Denied").path, reason: .permissionDenied)])
    }

    func testSearchLimitsAndCancellationNeverLookLikeACompleteEmptySearch() throws {
        let home = try DiskCleanTempDirectory(name: "AutomaticProjectLimits")
        defer { home.remove() }
        try home.makeFile("Shallow/package.json", bytes: 8)
        try home.makeFile("Deep/Nested/package.json", bytes: 8)
        let depth = DiskCleanDeveloperArtifactLocations(home: home.path, limits: .init(maximumDepth: 1)).resolve()
        XCTAssertEqual(depth.roots, [home.resolve("Shallow").path])
        XCTAssertTrue(depth.limitations.contains(.developerSearchLimited))
        for locations in [DiskCleanDeveloperArtifactLocations(home: home.path, limits: .init(maximumEntries: 0)),
                          DiskCleanDeveloperArtifactLocations(home: home.path, limits: .init(timeout: 0)),
                          DiskCleanDeveloperArtifactLocations(home: home.path, isCancelled: { true })] {
            let result = locations.resolve()
            XCTAssertTrue(result.roots.isEmpty)
            XCTAssertTrue(result.limitations.contains(.developerSearchLimited))
        }
        let capped = DiskCleanDeveloperArtifactLocations(home: home.path, limits: .init(maximumProjects: 1)).resolve()
        XCTAssertEqual(capped.roots.count, 1)
        XCTAssertTrue(capped.limitations.contains(.developerSearchLimited))
    }

    func testProjectsNestedInARepositoryKeepItsDirtyStateAndNeverDefaultSelectArtifacts() async throws {
        let home = try DiskCleanTempDirectory(name: "AutomaticProjectGit")
        defer { home.remove() }
        try home.makeDirectory("Checkout/.git")
        try home.makeFile("Checkout/Packages/Website/package.json", bytes: 8)
        try home.makeFile("Checkout/Packages/Website/node_modules/cache", bytes: 8)
        let project = home.resolve("Checkout/Packages/Website").path
        let repository = home.resolve("Checkout").path
        let locations = DiskCleanDeveloperArtifactLocations(home: home.path).resolve()
        XCTAssertEqual(locations.repositories[project], repository)
        let runner = ScriptedDiskCleanSubprocessRunner(statusOutput: " M source.swift\n")
        let result = await DiskCleanDeveloperArtifactExpansion(
            scanner: .init(inspector: .init(runner: runner)), automaticHome: home.path)
            .expand(scope: .automaticProjects, catalog: .current, localization: .init(bundle: .main))
        let facts = try XCTUnwrap(result.hits.first?.facts)
        XCTAssertNil(facts.risk)
        XCTAssertTrue(facts.notes.contains(.repositoryHasChanges(repositoryPath: repository, reason: .uncommittedChanges)))
    }

    @MainActor
    func testAutomaticSearchStreamsOnlyReviewedArtifactsAndPreservesSourceFilesWhenCleaning() async throws {
        let home = try DiskCleanTempDirectory(name: "AutomaticProjectPipeline")
        defer { home.remove() }
        let source = try home.makeFile("Documents/Client Work/Web/package.json", bytes: 8)
        let artifact = try home.makeFile("Documents/Client Work/Web/node_modules/cache", bytes: 8).deletingLastPathComponent()
        let unrelated = try home.makeFile("Pictures/build/photo.jpg", bytes: 8)
        let policy = DiskCleanSafetyPolicy(homeDirectory: home.path)
        let engine = DiskCleanScanEngine(safetyPolicy: policy, runningAppLock: ProgrammableDiskCleanRunningAppLock(),
            developerArtifactExpansion: DiskCleanDeveloperArtifactExpansion(automaticHome: home.path))
        var found: [String] = []
        var scanned: DiskCleanScanArtifact?
        for try await event in engine.scan(scope: .automaticProjects, forceRefresh: true) {
            if case let .candidateFound(candidate) = event { found.append(candidate.id) }
            if case let .finished(summary) = event { scanned = summary.artifact }
        }
        let result = try XCTUnwrap(scanned)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(Set(found), Set(result.candidates.map(\.id)))
        XCTAssertEqual(result.candidates.map(\.path), [artifact.path])
        let plan = try DiskCleanPlanner.makePlan(artifact: result, selectedIDs: Set(found), mode: .trash, now: Date(), catalog: .current)
        let executor = DiskCleanExecutor(
            primitive: DiskCleanRemovalPrimitive(journal: .init(directory: home.resolve("Journal")), trash: FakeDiskCleanTrash()),
            safetyPolicy: policy, runningAppLock: ProgrammableDiskCleanRunningAppLock(), auditLog: .init(directory: home.resolve("History")))
        let removed = try await executor.execute(plan: plan)
        XCTAssertEqual(removed.removedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
