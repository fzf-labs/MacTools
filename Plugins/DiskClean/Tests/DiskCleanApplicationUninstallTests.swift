import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

@MainActor
final class DiskCleanApplicationUninstallTests: XCTestCase {
    func testUnknownSizeRequiresIndependentCompleteInspectionAndNeverAllowsUnsupportedVolumes() throws {
        let root = try DiskCleanTempDirectory(name: "UninstallUnknownSize")
        defer { root.remove() }
        let path = try root.makeFile("Apps/Fixture.app/data", bytes: 5).deletingLastPathComponent().path
        let now = Date()
        let identity = try XCTUnwrap(DiskCleanPlanFactory.currentIdentity(ofItemAt: path))
        func candidate(validation: DiskCleanReviewValidation, inspection: DiskCleanApplicationInspection?, reason: DiskCleanScanCompleteness.PartialReason) -> DiskCleanCandidate {
            .init(id: "app", targetID: "fixture", legacyRuleID: "fixture", category: .applications, path: path,
                risk: .medium, safety: .allowed, sizeResult: .unavailable(reasons: [reason], observedAt: now),
                validation: validation, applicationInspection: inspection)
        }
        let evidence = DiskCleanReviewValidation.application(bundleID: "org.example.fixture", roots: [], bundlePath: path, isBundle: true)
        let inspection = DiskCleanApplicationInspection(identity: identity, observedAt: now)
        let inspected = candidate(validation: evidence, inspection: inspection, reason: .timedOut)
        XCTAssertTrue(inspected.isCleanable)
        let plan = try DiskCleanPlanner.makePlan(artifact: .init(scope: .review, candidates: [inspected], reservedRootPaths: [], limitations: [],
            startedAt: now, finishedAt: now), selectedIDs: [inspected.id], mode: .trash, now: now,
            catalog: .init(targets: [.test(id: "fixture", reservedRootPaths: [])]))
        XCTAssertEqual(plan.items.first?.rootIdentity, identity)
        XCTAssertFalse(candidate(validation: evidence, inspection: nil, reason: .timedOut).isCleanable)
        XCTAssertFalse(candidate(validation: .cache(bundleID: "org.example.fixture"), inspection: inspection, reason: .timedOut).isCleanable)
        XCTAssertFalse(candidate(validation: evidence, inspection: inspection, reason: .unsupportedVolume).isCleanable)
        XCTAssertFalse(candidate(validation: evidence, inspection: inspection, reason: .crossedMountPoint).isCleanable)
    }

    func testPlanOrdersBundlesBeforeDataAndRejectsPermanentUninstall() throws {
        let (candidates, catalog) = reviewedCandidates()
        let plan = try DiskCleanPlanner.makePlan(artifact: DiskCleanPlanFactory.artifact(candidates: candidates),
            selectedIDs: Set(candidates.map(\.id)), mode: .trash, now: DiskCleanPlanFactory.observedAt, catalog: catalog)
        XCTAssertEqual(plan.items.first?.path, "/Applications/Fixture.app")
        XCTAssertNotNil(plan.items.last?.validation)
        XCTAssertThrowsError(try DiskCleanPlanner.makePlan(artifact: DiskCleanPlanFactory.artifact(candidates: candidates),
            selectedIDs: Set(candidates.map(\.id)), mode: .permanent, now: DiskCleanPlanFactory.observedAt, catalog: catalog))
    }

    func testFailedBundleCannotAuthorizeAssociatedDataRemoval() async throws {
        let (candidates, catalog) = reviewedCandidates()
        let plan = try DiskCleanPlanner.makePlan(artifact: DiskCleanPlanFactory.artifact(candidates: candidates),
            selectedIDs: Set(candidates.map(\.id)), mode: .trash, now: DiskCleanPlanFactory.observedAt, catalog: catalog)
        let root = try DiskCleanTempDirectory(name: "UninstallExecutor")
        defer { root.remove() }
        let primitive = FakeDiskCleanRemovalPrimitive(defaultDisposition: .failed(reason: "permission denied"))
        let executor = DiskCleanExecutor(primitive: primitive,
            safetyPolicy: .init(homeDirectory: root.path, whitelistStore: .init(homeDirectory: root.path, includeDefaults: false)),
            runningAppLock: ProgrammableDiskCleanRunningAppLock(), auditLog: DiskCleanAuditLog(directory: root.url),
            now: { DiskCleanPlanFactory.observedAt }, reviewValidator: ApplicationDataStillOwned())
        let result = try await executor.execute(plan: plan)
        XCTAssertEqual(primitive.removedPaths, ["/Applications/Fixture.app"])
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.skippedCount, 1)
    }

    func testReinstallationOrIncompletePresenceBlocksLeftoverDeletion() async throws {
        let root = try DiskCleanTempDirectory(name: "LeftoverPresence")
        defer { root.remove() }
        let path = try root.makeFile("Library/Caches/org.example.fixture/cache", bytes: 4).deletingLastPathComponent().path
        let id = "org.example.fixture"
        for state in ["installed", "incomplete", "registered", "absent"] {
            let presence = DiskCleanApplicationPresence(inventory: { _ in
                .init(applications: state == "installed" ? [.init(path: "/Applications/New.app", bundleID: id,
                    name: "New", executable: nil, rejection: nil)] : [], isComplete: state != "incomplete", issues: [])
            }, registered: { _ in state == "registered" }, running: { _ in false })
            let validator = DiskCleanReviewValidator(policy: .init(homeDirectory: root.path), presence: presence)
            let rejection = await validator.rejection(path: path, evidence: .leftover(bundleID: id, roots: []))
            XCTAssertEqual(rejection == nil, state == "absent", state)
        }
    }

    func testRealStagingUninstallsFixtureAndPreservesDataWhenAnotherCopyExists() async throws {
        for keepsCopy in [false, true] {
            let root = try DiskCleanTempDirectory(name: "UninstallFlow")
            defer { root.remove() }
            let app = try root.makeDirectory("Apps/Fixture.app/Contents").deletingLastPathComponent()
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.fixture",
                "CFBundlePackageType": "APPL", "SMPrivilegedExecutables": ["org.example.helper": "identifier helper"],
                "SUInstallerLauncherService": "org.example.updater"], format: .xml, options: 0)
            try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
            let updater = try root.makeDirectory("Apps/Fixture.app/Contents/Frameworks/Updater.app/Contents")
            let updaterInfo = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.updater"], format: .xml, options: 0)
            try updaterInfo.write(to: updater.appendingPathComponent("Info.plist"))
            let data = try root.makeFile("Home/Library/Caches/org.example.fixture/cache", bytes: 6).deletingLastPathComponent()
            let now = Date()
            let candidates = try [data, app].map { url in
                DiskCleanCandidate(id: url.path, targetID: "fixture", legacyRuleID: "fixture", category: .applications,
                    path: url.path, risk: .medium, safety: .allowed,
                    sizeResult: .testComplete(bytes: 6, identity: try XCTUnwrap(DiskCleanPlanFactory.currentIdentity(ofItemAt: url.path)), observedAt: now),
                    validation: .application(bundleID: "org.example.fixture", roots: [root.resolve("Apps").path],
                        bundlePath: app.path, isBundle: url == app))
            }
            let plan = try DiskCleanPlanner.makePlan(artifact: .init(scope: .review, candidates: candidates,
                reservedRootPaths: [], limitations: [], startedAt: now, finishedAt: now),
                selectedIDs: Set(candidates.map(\.id)), mode: .trash, now: now,
                catalog: .init(targets: [.test(id: "fixture", reservedRootPaths: [])]))
            let presence = DiskCleanApplicationPresence(inventory: { _ in
                .init(applications: keepsCopy ? [.init(path: root.resolve("Apps/Other.app").path, bundleID: "org.example.fixture",
                    name: "Other", executable: nil, rejection: nil)] : [], isComplete: true, issues: [])
            }, registered: { _ in false }, running: { _ in false })
            let policy = DiskCleanSafetyPolicy(homeDirectory: root.resolve("Home").path,
                whitelistStore: .init(homeDirectory: root.resolve("Home").path, includeDefaults: false))
            let primitive = DiskCleanRemovalPrimitive(journal: .init(directory: root.resolve("Journal")), trash: FakeDiskCleanTrash())
            let executor = DiskCleanExecutor(primitive: primitive, safetyPolicy: policy,
                runningAppLock: ProgrammableDiskCleanRunningAppLock(), auditLog: .init(directory: root.resolve("History")),
                reviewValidator: DiskCleanReviewValidator(policy: policy, runner: IdleApplicationProcesses(), presence: presence))
            let result = try await executor.execute(plan: plan)
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
            XCTAssertEqual(FileManager.default.fileExists(atPath: data.path), keepsCopy)
            XCTAssertEqual(result.removedCount, keepsCopy ? 1 : 2)
            XCTAssertEqual(result.failedCount, 0)
        }
    }

    func testDefaultRetentionDoesNotBlockDiscoveryPlanningOrExecutionOfUninstall() async throws {
        let root = try DiskCleanTempDirectory(name: "UninstallRetention")
        defer { root.remove() }
        let id = "JetBrains.Fixture"
        let app = try root.makeDirectory("Apps/Fixture.app/Contents").deletingLastPathComponent()
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id,
            "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try root.makeFile("Apps/Fixture.app/Contents/.DS_Store", bytes: 8)
        let cache = try root.makeFile("Home/Library/Caches/JetBrains.Fixture/cache", bytes: 6).deletingLastPathComponent()
        try root.makeFile("Home/Library/Caches/JetBrains.Fixture/.DS_Store", bytes: 8)
        let home = root.resolve("Home").path
        let lexicalHome = "/Users/uninstall-retention-fixture"
        let logicalCache = lexicalHome + "/Library/Caches/JetBrains.Fixture"
        let policy = DiskCleanSafetyPolicy(homeDirectory: home, whitelistStore: .init(homeDirectory: lexicalHome))
        XCTAssertFalse(policy.safetyStatus(for: cache.path, alsoChecking: [logicalCache]).isCleanable)
        let review = await DiskCleanApplicationReviewBuilder(home: home, roots: [root.resolve("Apps").path], leftovers: false,
            inventorySnapshot: .init(applications: [.init(path: app.path, bundleID: id, name: "Fixture",
                executable: nil, rejection: nil)], isComplete: true, issues: [])).prepare()
        let catalog = DiskCleanRuleCatalogV2(targets: review.targets)
        // Exercise lexical retention rules while all filesystem writes stay inside the temporary directory.
        let hits = review.hits.map { hit in
            DiskCleanTargetHit(target: hit.target, item: hit.item,
                logicalPaths: hit.logicalPaths + (hit.item.path == cache.path ? [logicalCache] : []),
                specificity: hit.specificity, facts: hit.facts)
        }
        let engine = DiskCleanScanEngine(catalog: catalog, safetyPolicy: policy,
            runningAppLock: ProgrammableDiskCleanRunningAppLock(),
            reviewExpansion: DiskCleanPreparedReviewExpansion(hits: hits))
        var artifact: DiskCleanScanArtifact?
        for try await event in engine.scan(scope: .review, forceRefresh: true) {
            if case let .finished(summary) = event { artifact = summary.artifact }
        }
        let scanned = try XCTUnwrap(artifact)
        let selected = scanned.candidates.filter { [app.path, cache.path].contains($0.path) }
        XCTAssertEqual(selected.count, 2)
        XCTAssertTrue(selected.allSatisfy(\.isCleanable), "\(selected.map(\.safety))")
        let plan = try DiskCleanPlanner.makePlan(artifact: scanned, selectedIDs: Set(selected.map(\.id)),
            mode: .trash, now: Date(), catalog: catalog)
        let presence = DiskCleanApplicationPresence(inventory: { _ in
            .init(applications: [], isComplete: true, issues: [])
        }, registered: { _ in false }, running: { _ in false })
        let executor = DiskCleanExecutor(
            primitive: DiskCleanRemovalPrimitive(journal: .init(directory: root.resolve("Journal")), trash: FakeDiskCleanTrash()),
            safetyPolicy: policy, runningAppLock: ProgrammableDiskCleanRunningAppLock(),
            auditLog: .init(directory: root.resolve("History")),
            reviewValidator: DiskCleanReviewValidator(policy: policy, runner: IdleApplicationProcesses(), presence: presence))
        let result = try await executor.execute(plan: plan)
        XCTAssertEqual(result.removedCount, 2, "\(result.itemResults)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testManagedApplicationBundleStillProtectsWhitelistedAndSensitiveContents() async throws {
        let root = try DiskCleanTempDirectory(name: "ManagedBundleProtection")
        defer { root.remove() }
        let contents = try root.makeDirectory("Apps/Fixture.app/Contents")
        let app = contents.deletingLastPathComponent()
        let id = "org.example.fixture"
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id,
            "SMPrivilegedExecutables": ["org.example.helper": "identifier helper"]], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        try root.makeFile("Apps/Fixture.app/Contents/Helpers/Updater.app/.DS_Store", bytes: 4)
        let evidence = DiskCleanReviewValidation.application(bundleID: id, roots: [root.resolve("Apps").path], bundlePath: app.path, isBundle: true)
        let whitelist = DiskCleanWhitelistStore(homeDirectory: root.path, includeDefaults: false,
            customRules: [DiskCleanWhitelistStore.finderMetadataSentinel])
        let protected = DiskCleanReviewValidator(policy: .init(homeDirectory: root.path, whitelistStore: whitelist), runner: IdleApplicationProcesses())
        let whitelistedRejection = await protected.rejection(path: app.path, evidence: evidence)
        XCTAssertNotNil(whitelistedRejection)
        try root.makeFile("Apps/Fixture.app/Contents/Resources/.ssh/key", bytes: 4)
        let ordinary = DiskCleanReviewValidator(policy: .init(homeDirectory: root.path,
            whitelistStore: .init(homeDirectory: root.path, includeDefaults: false)), runner: IdleApplicationProcesses())
        let sensitiveRejection = await ordinary.rejection(path: app.path, evidence: evidence)
        XCTAssertNotNil(sensitiveRejection)
    }

    func testMainOwnedDataUsesScopedClaimsAtExecutionWithoutUnlockingSharedOrUnprovenFiles() async throws {
        for state in ["unrelated", "shared", "unproven", "privateComponent", "sharedComponent", "unverifiedComponent"] {
            let root = try DiskCleanTempDirectory(name: "MainOwnershipExecution")
            defer { root.remove() }
            let id = "org.example.original"
            let isComponent = state.hasSuffix("Component")
            let ownerID = isComponent ? id + ".helper" : id
            let isShared = state == "shared" || state == "sharedComponent"
            let canRemove = state == "unrelated" || state == "privateComponent"
            let app = try root.makeDirectory("Apps/Original.app/Contents").deletingLastPathComponent()
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id,
                "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
            let helper = try root.makeDirectory("Other.app/Contents/PlugIns/Helper.appex/Contents")
            if isShared {
                let helperInfo = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": ownerID], format: .xml, options: 0)
                try helperInfo.write(to: helper.appendingPathComponent("Info.plist"))
            }
            let other = DiskCleanInstalledApplication(path: root.resolve("Other.app").path, bundleID: "org.example.other",
                name: "Other", executable: nil, rejection: nil)
            let claims = DiskCleanApplicationIdentity.otherClaims(excluding: id, applications: [other])
            XCTAssertEqual(claims.complete, isShared)
            let relativeData = isComponent ? "Home/Library/Containers/" + UUID().uuidString : "Home/Library/Caches/" + ownerID
            let data = try root.makeFile(relativeData + "/cache", bytes: 6).deletingLastPathComponent()
            if isComponent {
                let metadata = try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": ownerID], format: .xml, options: 0)
                try metadata.write(to: data.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
                try root.makeFile(relativeData + "/session/Cookies", bytes: 3)
            }
            let installed = DiskCleanInstalledApplication(path: app.path, bundleID: id, name: "Original", executable: nil, rejection: nil)
            var identity = DiskCleanApplicationIdentity.read(bundleID: id, copies: [installed])
            identity.ids.insert(ownerID)
            if isComponent && state != "unverifiedComponent" { identity.verifiedPrivateIDs.insert(ownerID) }
            let resolved = DiskCleanApplicationOwnership(home: root.resolve("Home").path, includeContainers: true)
                .resolve(bundleID: id, identity: identity, otherOwners: claims.ids, claimsComplete: claims.complete)
            var proof = try XCTUnwrap(resolved.associations.first { $0.path == data.path }?.proof)
            if state == "unproven" { proof.mainBundleID = nil }
            let now = Date()
            let candidates = try [data, app].map { url in
                DiskCleanCandidate(id: url.path, targetID: "fixture", legacyRuleID: "fixture", category: .applications,
                    path: url.path, risk: .medium, safety: .allowed,
                    sizeResult: .testComplete(bytes: 6, identity: try XCTUnwrap(DiskCleanPlanFactory.currentIdentity(ofItemAt: url.path)), observedAt: now),
                    validation: .application(bundleID: id, roots: [root.resolve("Apps").path], bundlePath: app.path,
                        isBundle: url == app, proof: url == app ? nil : proof))
            }
            let plan = try DiskCleanPlanner.makePlan(artifact: .init(scope: .review, candidates: candidates,
                reservedRootPaths: [], limitations: [], startedAt: now, finishedAt: now),
                selectedIDs: Set(candidates.map(\.id)), mode: .trash, now: now,
                catalog: .init(targets: [.test(id: "fixture", reservedRootPaths: [])]))
            let presence = DiskCleanApplicationPresence(inventory: { _ in
                .init(applications: [other], isComplete: true, issues: [])
            }, registered: { _ in false }, running: { _ in false })
            let policy = DiskCleanSafetyPolicy(homeDirectory: root.resolve("Home").path,
                whitelistStore: .init(homeDirectory: root.resolve("Home").path, includeDefaults: false))
            let executor = DiskCleanExecutor(
                primitive: DiskCleanRemovalPrimitive(journal: .init(directory: root.resolve("Journal")), trash: FakeDiskCleanTrash()),
                safetyPolicy: policy, runningAppLock: ProgrammableDiskCleanRunningAppLock(), auditLog: .init(directory: root.resolve("History")),
                reviewValidator: DiskCleanReviewValidator(policy: policy, runner: IdleApplicationProcesses(), presence: presence))
            let result = try await executor.execute(plan: plan)
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
            XCTAssertEqual(FileManager.default.fileExists(atPath: data.path), !canRemove, state)
            XCTAssertEqual(result.removedCount, canRemove ? 2 : 1, state)
        }
    }

    func testSelectedOwnedSessionsMoveToTrashButNewSensitiveFilesRetainData() async throws {
        for addsSensitiveFile in [false, true] {
            let root = try DiskCleanTempDirectory(name: "OwnedSessionUninstall")
            defer { root.remove() }
            let id = "org.example.sessionapp"
            let app = try root.makeDirectory("Apps/Editor.app/Contents").deletingLastPathComponent()
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id,
                "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
            let data = try root.makeFile("Home/Library/Application Support/" + id + "/session/Cookies", bytes: 4)
                .deletingLastPathComponent().deletingLastPathComponent()
            let identity = DiskCleanApplicationIdentity.read(bundleID: id, copies: [.init(path: app.path,
                bundleID: id, name: "Editor", executable: nil, rejection: nil)])
            let resolved = DiskCleanApplicationOwnership(home: root.resolve("Home").path).resolve(bundleID: id, identity: identity)
            let proof = try XCTUnwrap(resolved.associations.first { $0.path == data.path }?.proof)
            XCTAssertTrue(proof.allowsPersonalSessionRemoval)
            let now = Date()
            let candidates = try [app, data].map { url in
                DiskCleanCandidate(id: url.path, targetID: "fixture", legacyRuleID: "fixture", category: .applications,
                    path: url.path, risk: .medium, safety: .allowed,
                    sizeResult: .testComplete(bytes: 4, identity: try XCTUnwrap(DiskCleanPlanFactory.currentIdentity(ofItemAt: url.path)), observedAt: now),
                    validation: .application(bundleID: id, roots: [], bundlePath: app.path, isBundle: url == app,
                        proof: url == app ? nil : proof))
            }
            let plan = try DiskCleanPlanner.makePlan(artifact: .init(scope: .review, candidates: candidates,
                reservedRootPaths: [], limitations: [], startedAt: now, finishedAt: now),
                selectedIDs: Set(candidates.map(\.id)), mode: .trash, now: now,
                catalog: .init(targets: [.test(id: "fixture", reservedRootPaths: [])]))
            if addsSensitiveFile { try root.makeFile("Home/Library/Application Support/" + id + "/session/access_token", bytes: 4) }
            let presence = DiskCleanApplicationPresence(inventory: { _ in .init(applications: [], isComplete: true, issues: []) },
                registered: { _ in false }, running: { _ in false })
            let policy = DiskCleanSafetyPolicy(homeDirectory: root.resolve("Home").path)
            let executor = DiskCleanExecutor(
                primitive: DiskCleanRemovalPrimitive(journal: .init(directory: root.resolve("Journal")), trash: FakeDiskCleanTrash()),
                safetyPolicy: policy, runningAppLock: ProgrammableDiskCleanRunningAppLock(), auditLog: .init(directory: root.resolve("History")),
                reviewValidator: DiskCleanReviewValidator(policy: policy, runner: IdleApplicationProcesses(), presence: presence))
            let result = try await executor.execute(plan: plan)
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
            XCTAssertEqual(FileManager.default.fileExists(atPath: data.path), addsSensitiveFile)
            XCTAssertEqual(result.removedCount, addsSensitiveFile ? 1 : 2)
        }
    }

    private func reviewedCandidates() -> ([DiskCleanCandidate], DiskCleanRuleCatalogV2) {
        let paths = ["/Users/fixture/Library/Caches/org.example.fixture", "/Applications/Fixture.app"]
        let candidates = paths.enumerated().map { index, path in
            DiskCleanCandidate(id: path, targetID: "fixture", legacyRuleID: "fixture", category: .applications,
                path: path, risk: .medium, safety: .allowed,
                sizeResult: .testComplete(bytes: 8, identity: .test(), observedAt: DiskCleanPlanFactory.observedAt),
                validation: .application(bundleID: "org.example.fixture", roots: ["/Applications"],
                                         bundlePath: "/Applications/Fixture.app", isBundle: index == 1))
        }
        return (candidates, .init(targets: [.test(id: "fixture", reservedRootPaths: [])]))
    }
}

private struct ApplicationDataStillOwned: DiskCleanReviewValidating {
    func rejection(path: String, evidence: DiskCleanReviewValidation) async -> String? {
        evidence.isApplicationBundle ? nil : "Application still owns this data"
    }
}

private struct IdleApplicationProcesses: DiskCleanSubprocessRunning {
    func run(executablePath: String, arguments: [String], timeout: Duration) async throws -> DiskCleanSubprocessResult {
        .init(exitCode: 0, standardOutput: Data())
    }
}
