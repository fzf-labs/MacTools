import Foundation
import XCTest
@testable import DiskCleanPlugin

@MainActor
final class DiskCleanApplicationReviewModelTests: XCTestCase {
    func testSingleApplicationReviewClearsPriorSelectionAndKeepsPersonalDataOptIn() async throws {
        let root = try DiskCleanTempDirectory(name: "ApplicationReviewModel")
        defer { root.remove() }
        let suite = "ApplicationReviewModel-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for name in ["One", "Two"] {
            let directory = try root.makeDirectory("Apps/" + name + ".app/Contents")
            let id = "org.example." + name.lowercased()
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id,
                "CFBundlePackageType": "APPL", "CFBundleName": name], format: .xml, options: 0)
            try info.write(to: directory.appendingPathComponent("Info.plist"))
            try root.makeFile("Home/Library/Caches/" + id + "/cache", bytes: 4)
            try root.makeFile("Home/Library/Preferences/" + id + ".plist", bytes: 3)
            try root.makeFile("Home/Library/Application Support/" + id + "/session/Cookies", bytes: 3)
            try root.makeFile("Home/Library/Application Support/" + name + "/session/Cookies", bytes: 3)
        }
        let otherContents = try root.makeDirectory("Apps/Other.app/Contents")
        let otherInfo = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.other",
            "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try otherInfo.write(to: otherContents.appendingPathComponent("Info.plist"))
        try root.makeDirectory("Apps/Other.app/Contents/PlugIns/Incomplete.appex")
        let model = DiskCleanApplicationReviewModel(executor: RejectingApplicationExecutor(), readiness: .init(isReady: true),
            localization: .init(bundle: .main), roots: .init(store: .init(key: "roots", defaults: [root.resolve("Apps").path], preferences: defaults)))
        model.home = root.resolve("Home").path
        model.supplementsSystemInventory = false
        model.loadIfNeeded(leftovers: false)
        await waitUntil("inventory ready") { model.inventory != nil && !model.isPreparing }
        XCTAssertEqual(model.inventory?.applications.count, 3)
        await waitUntil("list size without opening an app") { model.applicationSizes["org.example.one"] != nil }
        XCTAssertGreaterThan(model.applicationSizes["org.example.one"] ?? 0, 0)
        XCTAssertNil(model.controller)
        XCTAssertTrue(model.rows.isEmpty)
        model.analyze("org.example.one", select: true)
        await waitUntil("first review ready") { model.controller?.snapshot.phase == .scanned && !model.isPreparing }
        XCTAssertTrue(model.isSelected("org.example.one"))
        let firstSize = try XCTUnwrap(model.applicationSizes["org.example.one"])
        let firstPersonal = try XCTUnwrap(model.rows.first { $0.requiresOwnershipReview })
        XCTAssertEqual(model.candidate(path: firstPersonal.path)?.isCleanable, true)
        XCTAssertFalse(model.candidate(path: firstPersonal.path).map { model.controller?.snapshot.selection.isSelected($0.id) == true } == true)
        model.selectPath(firstPersonal, selected: true)
        XCTAssertTrue(model.candidate(path: firstPersonal.path).map { model.controller?.snapshot.selection.isSelected($0.id) == true } == true)
        model.analyze("org.example.two", select: true)
        await waitUntil("second review ready") { model.activeOwner == "org.example.two" && model.controller?.snapshot.phase == .scanned && !model.isPreparing }
        XCTAssertFalse(model.isSelected("org.example.one"))
        XCTAssertEqual(model.applicationSizes["org.example.one"], firstSize)
        XCTAssertTrue(model.isSelected("org.example.two"))
        XCTAssertTrue(model.rows.allSatisfy { $0.bundleID == "org.example.two" })
        XCTAssertEqual(Set(model.reports.keys), ["org.example.one", "org.example.two"])
        XCTAssertEqual(model.reports["org.example.one"]?.claimsComplete, false)
        let selected = model.rows.filter { row in
            model.candidate(path: row.path).map { model.controller?.snapshot.selection.isSelected($0.id) == true } == true
        }
        XCTAssertEqual(selected.filter(\.isBundle).count, 1)
        XCTAssertEqual(selected.filter { !$0.isBundle && !$0.isPersonal }.count, 1)
        XCTAssertFalse(selected.contains(where: \.isPersonal))
        model.selectPath(firstPersonal, selected: true)
        XCTAssertEqual(model.activeOwner, "org.example.two")
        let personal = try XCTUnwrap(model.rows.first { $0.category == .support && !$0.requiresOwnershipReview })
        model.selectApplication("org.example.two", selected: false)
        XCTAssertFalse(model.isSelected("org.example.two"))
        model.selectPath(personal, selected: true)
        XCTAssertTrue(model.isSelected("org.example.two"))
        XCTAssertTrue(model.candidate(path: personal.path).map { model.controller?.snapshot.selection.isSelected($0.id) == true } == true)
        model.clearApplicationSelection()
        XCTAssertNil(model.activeOwner)
        XCTAssertNil(model.controller)
        XCTAssertTrue(model.rows.isEmpty)
        model.analyze("org.example.one", select: true)
        await waitUntil("cached review ready") { model.controller?.snapshot.phase == .scanned && !model.isPreparing }
        XCTAssertFalse(model.candidate(path: firstPersonal.path).map { model.controller?.snapshot.selection.isSelected($0.id) == true } == true)
        model.analyze("org.example.two", select: true)
        model.analyze("org.example.one", select: true)
        await waitUntil("rapid switch ready") { model.activeOwner == "org.example.one" && model.controller?.snapshot.phase == .scanned && !model.isPreparing }
        XCTAssertTrue(model.rows.allSatisfy { $0.bundleID == "org.example.one" })
        XCTAssertTrue(model.isSelected("org.example.one"))
        XCTAssertFalse(model.isSelected("org.example.two"))
        model.recheckCurrentApplication()
        XCTAssertEqual(model.activeOwner, "org.example.one")
        await waitUntil("detail refresh retains app and selection") { model.controller?.snapshot.phase == .scanned && !model.isPreparing }
        XCTAssertEqual(model.activeOwner, "org.example.one")
        XCTAssertTrue(model.isSelected("org.example.one"))
        let current = model.controller
        model.applicationStateDidChange(["org.example.unrelated"])
        XCTAssertTrue(model.controller === current)
        XCTAssertTrue(model.isSelected("org.example.one"))
        model.applicationStateDidChange(["org.example.one"])
        XCTAssertEqual(model.activeOwner, "org.example.one")
        await waitUntil("focused app refreshed") { model.controller?.snapshot.phase == .scanned && !model.isPreparing }
        XCTAssertTrue(model.rows.allSatisfy { $0.bundleID == "org.example.one" })
        XCTAssertTrue(model.isSelected("org.example.one"))
        model.invalidate()
        model.clearApplicationSelection()
        await waitUntil("refresh finishes without reviving closed review") { !model.isPreparing }
        XCTAssertNil(model.activeOwner)
        XCTAssertNil(model.controller)
        XCTAssertTrue(model.rows.isEmpty)
        model.cancel()
    }

    func testCachedLeftoverReviewReopensAfterClearingSelection() async throws {
        let root = try DiskCleanTempDirectory(name: "CachedLeftoverReview")
        defer { root.remove() }
        let suite = "CachedLeftoverReview-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let apps = try root.makeDirectory("Apps").path
        let id = "org.example.leftover-fixture"
        try root.makeFile("Home/Library/Caches/" + id + "/cache", bytes: 3)
        let model = DiskCleanApplicationReviewModel(executor: RejectingApplicationExecutor(), readiness: .init(isReady: true),
            localization: .init(bundle: .main), roots: .init(store: .init(key: "roots", defaults: [apps], preferences: defaults)))
        model.home = root.resolve("Home").path
        model.supplementsSystemInventory = false
        model.loadIfNeeded(leftovers: true)
        await waitUntil("leftover inventory ready") { !model.isPreparing && model.suspectedOwners.contains(id) }
        model.analyze(id)
        await waitUntil("leftover review ready") { model.controller?.snapshot.phase == .scanned && !model.isPreparing }
        XCTAssertFalse(model.rows.isEmpty)
        model.clearApplicationSelection()
        XCTAssertNil(model.controller)
        model.analyze(id)
        await waitUntil("cached leftover reopened") { model.controller?.snapshot.phase == .scanned && !model.isPreparing }
        let row = try XCTUnwrap(model.rows.first)
        model.selectPath(row, selected: true)
        XCTAssertTrue(model.candidate(path: row.path).map { model.controller?.snapshot.selection.isSelected($0.id) == true } == true)
        model.cancel()
    }

    func testMandatoryApplicationRootsSurviveStoredEmptySelection() throws {
        let root = try DiskCleanTempDirectory(name: "MandatoryRoots")
        defer { root.remove() }
        let suite = "MandatoryRoots-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let apps = try root.makeDirectory("Apps").path
        defaults.set([], forKey: "roots")
        let model = DiskCleanScanRoots(store: .init(key: "roots", defaults: [apps], preferences: defaults, preservesDefaults: true))
        XCTAssertEqual(model.paths, [apps])
    }

    func testPartialUninstallKeepsOnlyUnfinishedPathsForRetryAfterBundleRemoval() async throws {
        let root = try DiskCleanTempDirectory(name: "UninstallRetryModel")
        defer { root.remove() }
        let executor = RetryFixtureExecutor(trash: try root.makeDirectory("Trash"))
        let fixture = try reviewFixture(root: root, executor: executor, quitter: FixtureQuitter(succeedsGracefully: true))
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite); fixture.model.stop() }
        let model = fixture.model
        model.loadIfNeeded(leftovers: false)
        await waitUntil("retry inventory") { !model.isPreparing }
        model.analyze("org.example.retry", select: true)
        await waitUntil("retry review") { model.controller?.snapshot.phase == .scanned && !model.isPreparing }
        let data = try XCTUnwrap(model.rows.first { !$0.isBundle })
        model.selectPath(data, selected: true)
        model.uninstallCurrentApplication()
        await waitUntil("remaining data review") {
            model.lastExecutionResult?.failedCount == 1 && model.controller?.snapshot.phase == .scanned && !model.isPreparing
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.resolve("Apps/Retry.app").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))
        XCTAssertEqual(model.activeOwner, "org.example.retry")
        XCTAssertTrue(model.rows.allSatisfy { !$0.isBundle })
        XCTAssertTrue(model.canStartUninstall)
        model.selectPath(data, selected: false)
        model.selectPath(data, selected: true)
        XCTAssertTrue(model.canStartUninstall)
        model.uninstallCurrentApplication()
        await waitUntil("remaining data removed") { model.lastExecutionResult?.removedCount == 1 && model.lastExecutionResult?.failedCount == 0 && !model.isPreparing }
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))
        let plans = await executor.paths
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans.last, [data.path])
    }

    func testCancellationAfterBundleTrashRetainsUnprocessedDataForRetry() async throws {
        let root = try DiskCleanTempDirectory(name: "UninstallCancelledModel")
        defer { root.remove() }
        let executor = RetryFixtureExecutor(trash: try root.makeDirectory("Trash"), cancelAfterBundle: true)
        let fixture = try reviewFixture(root: root, executor: executor, quitter: FixtureQuitter(succeedsGracefully: true))
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite); fixture.model.stop() }
        let model = fixture.model
        model.loadIfNeeded(leftovers: false)
        await waitUntil("cancel inventory") { !model.isPreparing }
        model.analyze("org.example.retry", select: true)
        await waitUntil("cancel review") { model.controller?.snapshot.phase == .scanned && !model.isPreparing }
        let data = try XCTUnwrap(model.rows.first { !$0.isBundle })
        model.selectPath(data, selected: true)
        model.uninstallCurrentApplication()
        await waitUntil("bundle moved before cancellation") { model.controller?.snapshot.phase == .cleaning && !FileManager.default.fileExists(atPath: root.resolve("Apps/Retry.app").path) }
        model.cancel()
        await waitUntil("cancelled remainder is reviewable") { model.lastExecutionResult?.wasCancelled == true && model.controller?.snapshot.phase == .scanned && !model.isPreparing }
        XCTAssertEqual(model.lastExecutionResult?.removedCount, 1)
        XCTAssertEqual(model.lastExecutionResult?.skippedCount, 1)
        XCTAssertEqual(model.activeOwner, "org.example.retry")
        XCTAssertTrue(model.canStartUninstall)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))
    }

    func testDetailRefreshRetainsFocusAndSelectionWhenApplicationLocationTemporarilyDisappears() async throws {
        let root = try DiskCleanTempDirectory(name: "UninstallDetailUnavailable")
        defer { root.remove() }
        let fixture = try reviewFixture(root: root, executor: RejectingApplicationExecutor(), quitter: FixtureQuitter(succeedsGracefully: true))
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite); fixture.model.stop() }
        let model = fixture.model
        model.loadIfNeeded(leftovers: false)
        await waitUntil("unavailable inventory") { !model.isPreparing }
        model.analyze("org.example.retry", select: true)
        await waitUntil("unavailable review") { model.controller?.snapshot.phase == .scanned && !model.isPreparing }
        let selection = model.selectedIdentities
        try FileManager.default.moveItem(at: root.resolve("Apps/Retry.app"), to: root.resolve("Outside.app"))
        model.recheckCurrentApplication()
        await waitUntil("missing location handled in detail") { !model.isPreparing }
        XCTAssertEqual(model.activeOwner, "org.example.retry")
        XCTAssertEqual(model.focusedApplication?.bundleID, "org.example.retry")
        XCTAssertNotNil(model.operationError)
        XCTAssertEqual(model.selectedIdentities, selection)
        try FileManager.default.moveItem(at: root.resolve("Outside.app"), to: root.resolve("Apps/Retry.app"))
        model.recheckCurrentApplication()
        await waitUntil("location recovers without returning to list") { model.controller?.snapshot.phase == .scanned && !model.isPreparing }
        XCTAssertEqual(model.activeOwner, "org.example.retry")
        XCTAssertTrue(model.isSelected("org.example.retry"))
    }

    func testRefusedQuitPreservesSelectionAndForceQuitRequiresExplicitAction() async throws {
        let root = try DiskCleanTempDirectory(name: "UninstallQuitModel")
        defer { root.remove() }
        let executor = RetryFixtureExecutor(trash: try root.makeDirectory("Trash"), failsEveryItem: true)
        let quitter = FixtureQuitter(succeedsGracefully: false)
        let services = FixtureServiceManager()
        let fixture = try reviewFixture(root: root, executor: executor, quitter: quitter, services: services)
        let program = try root.makeFile("Apps/Retry.app/Contents/MacOS/Agent", bytes: 4).path
        let job = try root.makeDirectory("Home/Library/LaunchAgents").appendingPathComponent("org.example.retry.agent.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": "org.example.retry.agent", "ProgramArguments": [program]],
            format: .xml, options: 0).write(to: job)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite); fixture.model.stop() }
        let model = fixture.model
        model.loadIfNeeded(leftovers: false)
        await waitUntil("quit inventory") { !model.isPreparing }
        model.analyze("org.example.retry", select: true)
        await waitUntil("quit review") { model.controller?.snapshot.phase == .scanned && !model.isPreparing }
        model.uninstallCurrentApplication()
        await waitUntil("quit choice required") { model.needsForceQuit && !model.isResolving }
        let callsBeforeForce = await executor.paths
        XCTAssertTrue(callsBeforeForce.isEmpty)
        let servicesBeforeForce = await services.stopped
        XCTAssertTrue(servicesBeforeForce.isEmpty)
        XCTAssertTrue(model.isSelected("org.example.retry"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.resolve("Apps/Retry.app").path))
        model.beginUninstall(force: true)
        await waitUntil("explicit force attempted") { model.lastExecutionResult != nil && !model.isPreparing }
        let forces = await quitter.forces
        XCTAssertEqual(forces, [false, true])
        let stoppedServices = await services.stopped
        XCTAssertEqual(stoppedServices, [job.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.resolve("Apps/Retry.app").path))
    }

    private func reviewFixture(root: DiskCleanTempDirectory, executor: any DiskCleanExecuting,
                               quitter: any DiskCleanApplicationQuitting,
                               services: any DiskCleanApplicationServiceManaging = DiskCleanApplicationServices()) throws -> (model: DiskCleanApplicationReviewModel, defaults: UserDefaults, suite: String) {
        let suite = "RemediationModel-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let contents = try root.makeDirectory("Apps/Retry.app/Contents")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.retry", "CFBundlePackageType": "APPL"],
            format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try root.makeFile("Home/Library/Application Support/org.example.retry/settings", bytes: 4)
        let model = DiskCleanApplicationReviewModel(executor: executor, readiness: .init(isReady: true), localization: .init(bundle: .main),
            roots: .init(store: .init(key: "roots", defaults: [root.resolve("Apps").path], preferences: defaults)), quitter: quitter, services: services)
        model.home = root.resolve("Home").path
        model.supplementsSystemInventory = false
        return (model, defaults, suite)
    }
}

private struct RejectingApplicationExecutor: DiskCleanExecuting {
    func execute(plan: DiskCleanValidatedPlan) async throws -> DiskCleanExecutionResult {
        throw DiskCleanExecutionError.safetyRejected(path: "", reason: "Read-only test")
    }
}

private actor FixtureQuitter: DiskCleanApplicationQuitting {
    let succeedsGracefully: Bool
    var forces: [Bool] = []
    init(succeedsGracefully: Bool) { self.succeedsGracefully = succeedsGracefully }
    func quit(_ scope: DiskCleanApplicationProcessScope, force: Bool) async throws -> Bool {
        forces.append(force)
        return force || succeedsGracefully
    }
}

private actor FixtureServiceManager: DiskCleanApplicationServiceManaging {
    var stopped: [String] = []
    func stop(_ proof: DiskCleanApplicationServiceProof) async throws { stopped.append(proof.path) }
    func isStopped(_ proof: DiskCleanApplicationServiceProof) async throws -> Bool { true }
}

private actor RetryFixtureExecutor: DiskCleanExecuting {
    let trash: URL
    let failsEveryItem: Bool
    let cancellationGate: FixtureCancellationGate?
    var paths: [[String]] = []
    init(trash: URL, failsEveryItem: Bool = false, cancelAfterBundle: Bool = false) {
        self.trash = trash
        self.failsEveryItem = failsEveryItem
        self.cancellationGate = cancelAfterBundle ? FixtureCancellationGate() : nil
    }
    func execute(plan: DiskCleanValidatedPlan) async throws -> DiskCleanExecutionResult {
        paths.append(plan.items.map(\.path))
        var items: [DiskCleanExecutionItemResult] = []
        for item in plan.items {
            let fails = failsEveryItem || (paths.count == 1 && item.validation?.isApplicationBundle != true)
            if fails { items.append(.init(candidateID: item.candidateID, path: item.path, outcome: .failed(message: "Fixture permission denied"))) }
            else {
                let destination = trash.appendingPathComponent(UUID().uuidString)
                try FileManager.default.moveItem(atPath: item.path, toPath: destination.path)
                items.append(.init(candidateID: item.candidateID, path: item.path, outcome: .trashed(reclaimedBytes: item.estimatedBytes, stagedName: destination.lastPathComponent)))
                if let cancellationGate, paths.count == 1, item.validation?.isApplicationBundle == true {
                    await cancellationGate.wait()
                    return .init(itemResults: items, mode: .trash, wasCancelled: true)
                }
            }
        }
        return .init(itemResults: items, mode: .trash)
    }
}

private actor FixtureCancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() }
                else { self.continuation = continuation }
            }
        } onCancel: {
            Task { await self.open() }
        }
    }
    private func open() { continuation?.resume(); continuation = nil }
}
