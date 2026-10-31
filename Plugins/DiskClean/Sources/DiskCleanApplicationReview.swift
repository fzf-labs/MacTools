import Combine
import AppKit
import Foundation
import MacToolsPluginKit

struct DiskCleanPreparedReviewExpansion: DiskCleanExternalExpanding {
    var hits: [DiskCleanTargetHit] = []
    var roots: [String] = []
    func expand(scope: DiskCleanScanScope, catalog: DiskCleanRuleCatalogV2,
                localization: PluginLocalization) async -> DiskCleanExternalExpansion {
        var result = DiskCleanExternalExpansion()
        result.hits = hits
        result.reservedRootPaths = roots
        return result
    }
}

struct DiskCleanApplicationReviewRow: Identifiable, Sendable {
    let path: String
    let bundleID: String
    let title: String
    let isBundle: Bool
    let isPersonal: Bool
    let evidence: String
    var category: DiskCleanApplicationFileCategory = .application
    var manualReason: String? = nil
    var logicalPaths: [String] = []
    var requiresOwnershipReview = false
    var id: String { path }
}

struct DiskCleanPreparedApplicationReview: Sendable {
    let rows: [DiskCleanApplicationReviewRow]
    let targets: [DiskCleanRuleTarget]
    let hits: [DiskCleanTargetHit]
    let issues: [String]
    var coverage: [String: [DiskCleanApplicationFileCategory: DiskCleanApplicationCoverage]] = [:]
    var reports: [String: DiskCleanApplicationScanReport] = [:]
}

extension DiskCleanPreparedApplicationReview {
    func reinspected(home: String, extended: Bool, localization: PluginLocalization = .init(bundle: .main)) async -> Self {
        var refreshed: [DiskCleanTargetHit] = []
        for hit in hits {
            if Task.isCancelled { break }
            var facts = hit.facts
            let proof: DiskCleanApplicationProof?
            let isBundle: Bool
            if case let .application(_, _, _, bundle, value) = facts.validation { proof = value; isBundle = bundle }
            else { proof = nil; isBundle = false }
            let review = DiskCleanContentReview(policy: DiskCleanSafetyPolicy(homeDirectory: home).forReview(facts.validation), protectsPersonalContents: !isBundle,
                maximumEntries: extended ? 1_000_000 : 250_000, timeout: extended ? 90 : 20,
                applicationSessionScope: proof.flatMap { DiskCleanApplicationSessionScope(path: hit.item.path, home: home, proof: $0) },
                logicalRoots: hit.logicalPaths, localization: localization)
            let checked = await diskCleanBackground { review.inspect(path: hit.item.path) }
            facts.rejection = rows.first { $0.path == hit.item.path }?.manualReason ?? proof?.rejection(at: hit.item.path) ?? checked.rejection
            facts.applicationInspection = checked.inspection
            refreshed.append(.init(target: hit.target, item: hit.item, logicalPaths: hit.logicalPaths, specificity: hit.specificity, facts: facts))
        }
        return .init(rows: rows, targets: targets, hits: refreshed, issues: issues, coverage: coverage, reports: reports)
    }
}

/// Builds a review only; actual writes remain behind DiskCleanPlanner and DiskCleanExecutor.
struct DiskCleanApplicationReviewBuilder: Sendable {
    let home: String
    let roots: [String]
    let leftovers: Bool
    var inventorySnapshot: DiskCleanApplicationInventoryResult? = nil
    var selectedOwners: Set<String>? = nil
    var extendedInspection = false
    var claimsSnapshot: DiskCleanApplicationClaimsSnapshot? = nil
    var localization: PluginLocalization = .init(bundle: .main)

    func prepare(onDiscovery: (@Sendable (DiskCleanPreparedApplicationReview) -> Void)? = nil) async -> DiskCleanPreparedApplicationReview {
        let inventory: DiskCleanApplicationInventoryResult
        if let inventorySnapshot { inventory = inventorySnapshot }
        else { inventory = await DiskCleanApplicationInventory(roots: roots, supplementsSystemInventory: true).scan() }
        let ownership = DiskCleanApplicationOwnership(home: home, includeContainers: DiskCleanFullDiskAccessProbe.shared.hasFullDiskAccess)
        var rows: [DiskCleanApplicationReviewRow] = []
        var targets: [DiskCleanRuleTarget] = []
        var hits: [DiskCleanTargetHit] = []
        var coverage: [String: [DiskCleanApplicationFileCategory: DiskCleanApplicationCoverage]] = [:]
        var reports: [String: DiskCleanApplicationScanReport] = [:]
        let installed = Set(inventory.applications.map(\.bundleID))
        let ids: Set<String>
        if leftovers {
            ids = await diskCleanBackground { ownership.suspectedBundleIDs() }.subtracting(installed)
        } else { ids = installed }
        for id in ids.intersection(selectedOwners ?? ids).sorted() {
            if Task.isCancelled { break }
            if leftovers {
                if await DiskCleanApplicationInventory.hasRegisteredCopy(bundleID: id) { continue }
            }
            let copies = inventory.applications.filter { $0.bundleID == id }
            var entries: [(DiskCleanApplicationReviewRow, String?, DiskCleanReviewValidation)] = []
            for app in copies where !leftovers {
                entries.append((.init(path: app.path, bundleID: id, title: app.name, isBundle: true,
                                      isPersonal: false, evidence: "应用 Bundle ID：" + id), app.rejection,
                                .application(bundleID: id, roots: roots, bundlePath: app.path, isBundle: true)))
            }
            let resolved = await diskCleanBackground {
                let claims = claimsSnapshot?.otherClaims(excluding: id)
                    ?? DiskCleanApplicationIdentity.otherClaims(excluding: id, applications: inventory.applications)
                return ownership.resolve(bundleID: id, identity: DiskCleanApplicationIdentity.read(bundleID: id, copies: copies),
                    applicationName: copies.first?.name, otherOwners: claims.ids, claimsComplete: claims.complete,
                    otherExecutables: Set(inventory.applications.filter { $0.bundleID != id }.compactMap(\.executable)),
                    otherNames: DiskCleanApplicationNameCandidate.claimedNames(by: inventory.applications, excluding: id))
            }
            coverage[id] = resolved.coverage
            var report = resolved.report
            for app in copies {
                report.record(path: app.path, category: .application, source: .bundleID, state: .checked)
            }
            reports[id] = report
            for association in resolved.associations {
                let evidence: DiskCleanReviewValidation = leftovers
                    ? .leftover(bundleID: id, roots: roots, proof: association.proof)
                    : .application(bundleID: id, roots: roots, bundlePath: copies.first?.path ?? "", isBundle: false, proof: association.proof)
                let row = DiskCleanApplicationReviewRow(path: association.path, bundleID: id,
                    title: URL(fileURLWithPath: association.path).lastPathComponent,
                    isBundle: false, isPersonal: association.isPersonal, evidence: association.evidence,
                    category: association.category, manualReason: association.manualReason, logicalPaths: association.logicalPaths,
                    requiresOwnershipReview: association.proof?.nameCandidate != nil)
                entries.append((row, association.manualReason ?? (inventory.isComplete ? nil : "安装清单不完整，关联数据仅供查看"), evidence))
            }
            onDiscovery?(.init(rows: entries.map { $0.0 }, targets: [], hits: [], issues: inventory.issues, coverage: coverage, reports: reports))
            for (row, initialRejection, evidence) in entries {
                let target = DiskCleanRuleTarget(id: "application." + row.path, legacyRuleID: "application.review",
                    category: .applications, risk: .medium, kind: .external,
                    reservedRootPaths: roots + ownership.reservedRoots, lockedByBundleIDs: [id],
                    explanation: .init(whyMatched: row.evidence,
                        consequence: row.isBundle ? "应用将移到废纸篓。" : (row.isPersonal ? "设置与个人数据需要时无法自动重建。" : "缓存会在下次使用时重建。"),
                        safetyTier: row.isPersonal ? .sensitive : .moderate,
                        title: row.title, owner: id))
                var rejection = initialRejection
                var inspection: DiskCleanApplicationInspection?
                if initialRejection == nil {
                    // Other copies are reviewed as a group at execution, not mistaken for active use here.
                    let applicationProof: DiskCleanApplicationProof?
                    if case let .application(_, _, _, false, proof) = evidence { applicationProof = proof }
                    else { applicationProof = nil }
                    let sessionScope = applicationProof.flatMap { DiskCleanApplicationSessionScope(path: row.path, home: home, proof: $0) }
                    let review = DiskCleanContentReview(policy: DiskCleanSafetyPolicy(homeDirectory: home).forReview(evidence),
                        protectsPersonalContents: !row.isBundle,
                        maximumEntries: extendedInspection ? 1_000_000 : 250_000,
                        timeout: extendedInspection ? 90 : 20,
                        applicationSessionScope: sessionScope, logicalRoots: row.logicalPaths, localization: localization)
                    let checked = await diskCleanBackground { review.inspect(path: row.path) }
                    rejection = rejection ?? checked.rejection
                    if !leftovers { inspection = checked.inspection }
                }
                if leftovers, await DiskCleanApplicationInventory.isRunning(bundleID: id) { rejection = "应用仍在运行" }
                rows.append(row)
                targets.append(target)
                hits.append(.init(target: target, item: .init(path: row.path,
                    isDirectory: (try? URL(fileURLWithPath: row.path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                    isSymlink: false, resolvedSymlinkTarget: nil), logicalPaths: row.logicalPaths.isEmpty ? [row.path] : row.logicalPaths, specificity: 0,
                    facts: .init(risk: .medium, rejection: rejection, validation: evidence, applicationInspection: inspection)))
            }
        }
        return .init(rows: rows, targets: targets, hits: hits, issues: inventory.issues, coverage: coverage, reports: reports)
    }
}

/// A fixed store prevents the global permanent-delete preference affecting uninstall.
struct DiskCleanTrashOnlyModeStore: DiskCleanRemovalModeStoring {
    func load() -> DiskCleanRemovalMode { .trash }
    func save(_ mode: DiskCleanRemovalMode) {}
}

@MainActor
final class DiskCleanApplicationReviewModel: ObservableObject {
    @Published private(set) var controller: DiskCleanController?
    @Published private(set) var rows: [DiskCleanApplicationReviewRow] = []
    @Published private(set) var lastExecutionResult: DiskCleanExecutionResult?
    @Published private(set) var inventory: DiskCleanApplicationInventoryResult?
    @Published private(set) var isPreparing = false
    @Published private(set) var isLoadingInventory = false
    @Published private(set) var issues: [String] = []
    @Published private(set) var coverage: [String: [DiskCleanApplicationFileCategory: DiskCleanApplicationCoverage]] = [:]
    @Published private(set) var reports: [String: DiskCleanApplicationScanReport] = [:]
    @Published private(set) var suspectedOwners = Set<String>()
    @Published private(set) var analyzingOwners = Set<String>()
    @Published private(set) var activeOwner: String?
    @Published private(set) var applicationSizes: [String: Int64] = [:]
    @Published private(set) var isResolving = false
    @Published private(set) var operationError: String?
    @Published var needsForceQuit = false
    @Published private(set) var runningOwners = Set<String>()
    @Published private(set) var sizingOwners = Set<String>()
    @Published private(set) var focusedApplication: DiskCleanInstalledApplication?
    private var prepared: [String: DiskCleanPreparedApplicationReview] = [:]
    private var queue: [String] = []
    private var pendingSelection = Set<String>()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var hasLoaded = false
    private var isLeftovers = false
    private let executor: any DiskCleanExecuting
    private let readiness: DiskCleanCleanupReadiness
    private let localization: PluginLocalization
    private let quitter: any DiskCleanApplicationQuitting
    private let services: any DiskCleanApplicationServiceManaging
    private var remediationTask: Task<Void, Never>?
    private var selectionToRestore: [String: DiskCleanRootIdentity] = [:]
    private var shouldCleanAfterReview = false
    private var usesExtendedInspection = false
    private var retryReview: DiskCleanPreparedApplicationReview?
    private var retryApplication: DiskCleanInstalledApplication?
    private var retrySelection: [String: DiskCleanRootIdentity] = [:]
    private var deferredResults: [DiskCleanExecutionItemResult] = []
    private var deferredIdentities: [String: DiskCleanRootIdentity] = [:]
    private var submittedPaths = Set<String>()
    private var continuingOwner: String?
    private let sizeCache = DiskCleanSizeCache()
    private var claimsTask: Task<DiskCleanApplicationClaimsSnapshot, Never>?
    private var listSizingTask: Task<Void, Never>?
    let roots: DiskCleanScanRoots
    var home = NSHomeDirectory()
    var supplementsSystemInventory = true
    var onInventoryChange: (() -> Void)?

    init(executor: any DiskCleanExecuting, readiness: DiskCleanCleanupReadiness,
         localization: PluginLocalization, roots: DiskCleanScanRoots,
         quitter: any DiskCleanApplicationQuitting = DiskCleanApplicationProcesses(),
         services: any DiskCleanApplicationServiceManaging = DiskCleanApplicationServices()) {
        self.executor = executor
        self.readiness = readiness
        self.localization = localization
        self.roots = roots
        self.quitter = quitter
        self.services = services
    }

    func loadIfNeeded(leftovers: Bool) {
        guard !hasLoaded else { return }
        scan(leftovers: leftovers)
    }

    func scan(leftovers: Bool, preservingResult: Bool = false, keepingOwner: String? = nil,
              restoringSelection: [String: DiskCleanRootIdentity] = [:], continueUninstall: Bool = false,
              extendedInspection: Bool = false) {
        guard controller?.snapshot.phase != .cleaning else { return }
        let focused = keepingOwner.flatMap { owner in
            inventory?.applications.first { $0.bundleID == owner }
                ?? (focusedApplication?.bundleID == owner ? focusedApplication : nil)
                ?? (retryApplication?.bundleID == owner ? retryApplication : nil)
        }
        cancel()
        focusedApplication = focused
        selectionToRestore = restoringSelection
        shouldCleanAfterReview = continueUninstall
        deferredResults = []
        deferredIdentities = [:]
        isResolving = continueUninstall
        usesExtendedInspection = extendedInspection
        operationError = nil
        hasLoaded = true
        if !preservingResult { lastExecutionResult = nil }
        isLeftovers = leftovers
        prepared = [:]
        activeOwner = keepingOwner
        applicationSizes = [:]
        suspectedOwners = []
        coverage = [:]
        reports = [:]
        rows = []
        controller = nil
        isPreparing = true
        isLoadingInventory = true
        let id = generation
        let inventoryReader = DiskCleanApplicationInventory(roots: roots.paths, supplementsSystemInventory: supplementsSystemInventory)
        claimsTask?.cancel()
        listSizingTask?.cancel()
        sizingOwners = []
        task = Task { [weak self] in
            let result = await inventoryReader.scan()
            guard let self, !Task.isCancelled, generation == id else { return }
            inventory = result
            claimsTask = Task { await diskCleanBackground { DiskCleanApplicationClaimsSnapshot.read(result.applications) } }
            if !leftovers { startListSizing(result.applications) }
            runningOwners = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            onInventoryChange?()
            issues = result.issues
            if leftovers {
                let ownership = DiskCleanApplicationOwnership(home: home, includeContainers: DiskCleanFullDiskAccessProbe.shared.hasFullDiskAccess)
                let owners = await diskCleanBackground { ownership.suspectedBundleIDs() }
                let claims = await diskCleanBackground {
                    DiskCleanApplicationIdentity.otherClaims(excluding: "", applications: result.applications)
                }
                guard !Task.isCancelled, generation == id else { return }
                suspectedOwners = Set(owners.filter { !DiskCleanApplicationIdentity.hasPotentialOwner($0, in: claims.ids) })
            }
            isPreparing = false
            isLoadingInventory = false
            if let owner = activeOwner {
                let exists = leftovers ? suspectedOwners.contains(owner) : result.applications.contains { $0.bundleID == owner }
                if exists { analyze(owner) }
                else if let retryReview, retryApplication?.bundleID == owner {
                    isPreparing = true
                    let refreshed = await retryReview.reinspected(home: home, extended: true, localization: localization)
                    guard !Task.isCancelled, generation == id else { return }
                    prepared[owner] = refreshed
                    coverage.merge(refreshed.coverage, uniquingKeysWith: { _, new in new })
                    reports.merge(refreshed.reports, uniquingKeysWith: { _, new in new })
                    publishReview()
                }
                else {
                    isResolving = false
                    shouldCleanAfterReview = false
                    operationError = localization.string("uninstall.appUnavailable", defaultValue: "应用位置无法读取或已不存在，请重新检查")
                }
            }
        }
    }

    func clearApplicationSelection() {
        guard controller?.snapshot.phase != .cleaning else { return }
        activeOwner = nil
        focusedApplication = nil
        guard !isLoadingInventory else { return }
        let previous = controller
        controller = nil
        cancel()
        previous?.cancelCurrentOperation()
        activeOwner = nil
        rows = []
    }

    func analyze(_ owner: String, select: Bool = false) {
        guard inventory != nil, !isLoadingInventory, controller?.snapshot.phase != .cleaning else { return }
        if !isLeftovers, prepared[owner] == nil, retryApplication?.bundleID == owner,
           inventory?.applications.contains(where: { $0.bundleID == owner }) == false {
            scan(leftovers: false, preservingResult: true, keepingOwner: owner, restoringSelection: retrySelection, extendedInspection: true)
            return
        }
        if !isLeftovers && activeOwner != owner {
            clearApplicationSelection()
            activeOwner = owner
        }
        if isLeftovers { activeOwner = owner }
        if !isLeftovers { focusedApplication = inventory?.applications.first { $0.bundleID == owner } ?? focusedApplication }
        if !isLeftovers, controller == nil {
            rows = inventory?.applications.filter { $0.bundleID == owner }.map {
                .init(path: $0.path, bundleID: owner, title: $0.name, isBundle: true, isPersonal: false, evidence: "应用 Bundle ID：" + owner)
            } ?? []
        }
        if select { pendingSelection.insert(owner) }
        if prepared[owner] != nil {
            if controller == nil {
                isPreparing = true
                publishReview()
            } else if select { selectApplication(owner, selected: true) }
            return
        }
        guard !analyzingOwners.contains(owner) else { return }
        analyzingOwners.insert(owner)
        queue.append(owner)
        processNext()
    }

    private func processNext() {
        guard !isPreparing, controller?.snapshot.isBusy != true, !queue.isEmpty, let inventory else { return }
        isPreparing = true
        let owner = queue.removeFirst()
        let id = generation
        var builder = DiskCleanApplicationReviewBuilder(home: home, roots: roots.paths, leftovers: isLeftovers,
            inventorySnapshot: inventory, selectedOwners: [owner], extendedInspection: usesExtendedInspection, localization: localization)
        task = Task { [weak self] in
            builder.claimsSnapshot = await self?.claimsTask?.value
            guard !Task.isCancelled else { return }
            let review = await builder.prepare { [weak self] preview in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id, self.activeOwner == owner,
                          !self.isLeftovers, self.isPreparing, self.controller == nil else { return }
                    self.rows = preview.rows
                    self.coverage.merge(preview.coverage, uniquingKeysWith: { _, new in new })
                    self.reports.merge(preview.reports, uniquingKeysWith: { _, new in new })
                }
            }
            guard let self, !Task.isCancelled, generation == id else { return }
            prepared[owner] = review
            if isLeftovers && review.rows.isEmpty { suspectedOwners.remove(owner) }
            coverage.merge(review.coverage, uniquingKeysWith: { _, new in new })
            reports.merge(review.reports, uniquingKeysWith: { _, new in new })
            analyzingOwners.remove(owner)
            publishReview()
        }
    }

    private func publishReview() {
        let previousPaths = Set((controller?.snapshot.scanResult?.candidates ?? []).filter {
            controller?.snapshot.selection.isSelected($0.id) == true
        }.map(\.path))
        let reviews: [DiskCleanPreparedApplicationReview]
        if isLeftovers { reviews = prepared.keys.sorted().compactMap { prepared[$0] } }
        else { reviews = activeOwner.flatMap { prepared[$0] }.map { [$0] } ?? [] }
        let reviewGeneration = generation
        var seen = Set<String>()
        let mergedRows = reviews.flatMap(\.rows).filter { seen.insert($0.path).inserted }
        let sharedPaths = Dictionary(grouping: reviews.flatMap(\.rows), by: \.path).filter {
            Set($0.value.map(\.bundleID)).count > 1
        }.keys
        let shared = Set(sharedPaths)
        let allHits = reviews.flatMap(\.hits)
        seen = []
        let hits = allHits.filter { seen.insert($0.item.path).inserted }.map { hit in
            guard shared.contains(hit.item.path) else { return hit }
            var facts = hit.facts
            facts.rejection = "多个应用使用相同文件"
            return DiskCleanTargetHit(target: hit.target, item: hit.item, logicalPaths: hit.logicalPaths,
                specificity: hit.specificity, facts: facts)
        }
        seen = []
        let targets = reviews.flatMap(\.targets).filter { seen.insert($0.id).inserted }
        let catalog = DiskCleanRuleCatalogV2(targets: targets)
        for hit in hits {
            if let measurement = hit.facts.applicationInspection?.measurement {
                sizeCache.store(path: hit.item.path, result: measurement, now: Date())
            }
        }
        let published = DiskCleanPreparedApplicationReview(rows: mergedRows, targets: targets, hits: hits, issues: issues,
            coverage: coverage, reports: reports)
        let child = DiskCleanController(engine: DiskCleanScanEngine(catalog: catalog, safetyPolicy: .init(homeDirectory: home), sizeCache: sizeCache,
            reviewExpansion: DiskCleanPreparedReviewExpansion(hits: hits, roots: Array(Set(roots.paths + targets.flatMap { $0.expandedReservedRootPaths() }))), localization: localization),
            executor: executor, initialSnapshot: .init(phase: .idle, scope: .review, scanResult: nil,
                executionResult: nil, isResultStale: false, errorMessage: nil), localization: localization,
            removalModeStore: DiskCleanTrashOnlyModeStore(), catalog: catalog, cleanupReadiness: readiness)
        var restoresSelection = true
        var handledExecution = false
        child.onStateChange = { [weak self, weak child] in
            guard let self, let child, self.controller === child, self.generation == reviewGeneration else { return }
            if let execution = child.snapshot.executionResult, !handledExecution {
                handledExecution = true
                let reported = Set(execution.itemResults.map(\.path))
                let cancelled = execution.wasCancelled ? submittedPaths.subtracting(reported).map { path in
                    DiskCleanExecutionItemResult(candidateID: candidate(path: path)?.id ?? path, path: path,
                        outcome: .skipped(.protected(reason: "已取消，尚未处理")))
                } : []
                submittedPaths = []
                let result = DiskCleanExecutionResult(itemResults: execution.itemResults + deferredResults + cancelled,
                    mode: execution.mode, wasCancelled: execution.wasCancelled)
                let deferred = deferredIdentities
                deferredResults = []
                deferredIdentities = [:]
                lastExecutionResult = result
                Task { [weak self] in
                    await Task.yield()
                    guard let self, self.controller === child, self.generation == reviewGeneration else { return }
                    self.finishAttempt(result, review: published, child: child, deferred: deferred)
                }
            }
            if child.snapshot.phase == .scanned, !isLeftovers, let owner = activeOwner {
                let bundles = rows.filter { $0.bundleID == owner && $0.isBundle }
                let candidates = bundles.compactMap { candidate(path: $0.path) }
                let value = !candidates.isEmpty && candidates.count == bundles.count
                    && candidates.allSatisfy { $0.sizeResult?.completeness.isComplete == true }
                    ? candidates.reduce(Int64(0)) { $0 + $1.estimatedBytes } : nil
                if applicationSizes[owner] != value { applicationSizes[owner] = value }
            }
            if restoresSelection, child.snapshot.phase == .scanned {
                restoresSelection = false
                for candidate in child.snapshot.scanResult?.candidates ?? [] where previousPaths.contains(candidate.path) {
                    child.setCandidateSelected(candidate.id, isSelected: true)
                }
                let restoring = selectionToRestore
                selectionToRestore = [:]
                for candidate in child.snapshot.scanResult?.candidates ?? [] {
                    guard let expected = restoring[candidate.path], let current = candidate.removalIdentity,
                          expected.devid == current.devid, expected.fileID == current.fileID, expected.fileType == current.fileType else { continue }
                    child.setCandidateSelected(candidate.id, isSelected: true)
                }
                let owners = pendingSelection
                pendingSelection = []
                for owner in owners { selectApplication(owner, selected: true) }
                isPreparing = false
                let clean = shouldCleanAfterReview
                shouldCleanAfterReview = false
                isResolving = false
                if clean {
                    deferredResults = restoring.keys.compactMap { path in
                        guard let expected = restoring[path] else { return nil }
                        let item = candidate(path: path)
                        if let item, child.snapshot.selection.isSelected(item.id) { return nil }
                        let changed = item?.removalIdentity.map { $0.devid != expected.devid || $0.fileID != expected.fileID || $0.fileType != expected.fileType } ?? true
                        return .init(candidateID: item?.id ?? path, path: path,
                            outcome: changed ? .changedSinceScan : .skipped(item?.safety ?? .invalid(reason: "文件无法读取")))
                    }
                    deferredIdentities = restoring.filter { path, _ in deferredResults.contains { $0.path == path } }
                    if !child.snapshot.selection.isEmpty && (hasSelectedApplication || isContinuingUninstall) {
                        submittedPaths = Set(selectedIdentities.keys)
                        child.clean()
                    } else { operationError = localization.string("uninstall.selectionChanged", defaultValue: "应用文件已变化，请重新选择后卸载") }
                }
                processNext()
            }
            if restoresSelection, child.snapshot.phase == .idle && child.snapshot.errorMessage != nil {
                restoresSelection = false
                isPreparing = false
                pendingSelection = []
                isResolving = false
                shouldCleanAfterReview = false
            }
            if !child.snapshot.isBusy, !restoresSelection, !isPreparing { processNext() }
            objectWillChange.send()
        }
        rows = mergedRows
        controller = child
        child.scan()
    }

    func selectApplication(_ owner: String, selected: Bool) {
        if !isLeftovers && activeOwner != owner {
            if selected { analyze(owner, select: true) }
            return
        }
        if !selected { pendingSelection.remove(owner) }
        guard let child = controller else { if selected { analyze(owner, select: true) }; return }
        let appRows = rows.filter { $0.bundleID == owner && $0.isBundle }
        guard !appRows.isEmpty else { return }
        for row in appRows {
            if let candidate = candidate(path: row.path) { child.setCandidateSelected(candidate.id, isSelected: selected) }
        }
        let allSelected = appRows.allSatisfy { candidate(path: $0.path).map { child.snapshot.selection.isSelected($0.id) } == true }
        for row in rows where row.bundleID == owner && !row.isBundle {
            if let candidate = candidate(path: row.path), !row.isPersonal || !allSelected {
                child.setCandidateSelected(candidate.id, isSelected: allSelected && !row.isPersonal)
            }
        }
    }

    func selectPath(_ row: DiskCleanApplicationReviewRow, selected: Bool) {
        guard isLeftovers || row.bundleID == activeOwner,
              let child = controller, let item = candidate(path: row.path) else { return }
        if selected && !isLeftovers && !isContinuingUninstall && !row.isBundle && !isSelected(row.bundleID) {
            selectApplication(row.bundleID, selected: true)
            guard isSelected(row.bundleID) else { return }
        }
        child.setCandidateSelected(item.id, isSelected: selected)
        if row.isBundle {
            let allSelected = isSelected(row.bundleID)
            for related in rows where related.bundleID == row.bundleID && !related.isBundle {
                if let candidate = candidate(path: related.path), !related.isPersonal || !allSelected {
                    child.setCandidateSelected(candidate.id, isSelected: allSelected && !related.isPersonal)
                }
            }
        }
    }

    func uninstallCurrentApplication() {
        beginUninstall(force: false)
    }

    func beginUninstall(force: Bool) {
        guard !isLeftovers, !isPreparing, !isResolving, let owner = activeOwner, let child = controller,
              canStartUninstall else { return }
        let selected = child.snapshot.scanResult?.candidates.filter { child.snapshot.selection.isSelected($0.id) } ?? []
        let ownerRows = rows.filter { $0.bundleID == owner }
        guard !selected.isEmpty, selected.allSatisfy({ item in ownerRows.contains { $0.path == item.path || item.logicalPaths.contains($0.path) } }),
              hasSelectedApplication || isContinuingUninstall else { return }
        let intent = selectedIdentities
        let applicationPaths = inventory?.applications.filter { $0.bundleID == owner }.map(\.path) ?? []
        let proofs = servicesForSelection
        isResolving = true
        operationError = nil
        needsForceQuit = false
        remediationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !proofs.isEmpty, !force {
                    let stopped = try await quitter.quit(.init(bundleID: owner, applicationPaths: applicationPaths), force: false)
                    guard stopped else { isResolving = false; needsForceQuit = true; return }
                }
                for proof in proofs { try Task.checkCancellation(); try await services.stop(proof) }
                let stopped = try await quitter.quit(.init(bundleID: owner, applicationPaths: applicationPaths,
                    programPaths: Set(proofs.map(\.program))), force: force)
                try Task.checkCancellation()
                guard stopped else { isResolving = false; needsForceQuit = true; return }
                scan(leftovers: false, preservingResult: true, keepingOwner: owner,
                    restoringSelection: intent, continueUninstall: true, extendedInspection: true)
            } catch {
                guard !Task.isCancelled else { return }
                isResolving = false
                operationError = error.localizedDescription
            }
        }
    }

    func candidate(path: String) -> DiskCleanCandidate? {
        controller?.snapshot.scanResult?.candidates.first { $0.path == path || $0.logicalPaths.contains(path) }
    }

    func isSelected(_ owner: String) -> Bool {
        let bundles = rows.filter { $0.bundleID == owner && $0.isBundle }
        return !bundles.isEmpty && bundles.allSatisfy { row in
            candidate(path: row.path).map { controller?.snapshot.selection.isSelected($0.id) == true } == true
        }
    }

    func applicationStateDidChange(_ bundleIDs: Set<String>) {
        runningOwners = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        guard !isResolving else { return }
        guard let owner = activeOwner else {
            if isLeftovers && !suspectedOwners.isDisjoint(with: bundleIDs) { invalidate() }
            return
        }
        let proofOwners = prepared[owner]?.hits.compactMap { hit -> String? in
            guard let validation = hit.facts.validation else { return nil }
            switch validation {
            case let .application(_, _, _, _, proof), let .leftover(_, _, proof): return proof?.ownerID
            default: return nil
            }
        } ?? []
        let affected = bundleIDs.contains { id in
            id.caseInsensitiveCompare(owner) == .orderedSame || id.lowercased().hasPrefix(owner.lowercased() + ".")
                || proofOwners.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
        }
        if affected { invalidate() }
    }

    func invalidate() {
        guard !isResolving, controller?.snapshot.phase != .cleaning else { return }
        let reload = hasLoaded
        let reviewingOwner = activeOwner
        let intent = selectedIdentities
        cancel()
        prepared = [:]
        activeOwner = nil
        rows = []
        controller = nil
        coverage = [:]
        reports = [:]
        if reload { scan(leftovers: isLeftovers, keepingOwner: reviewingOwner, restoringSelection: intent) }
    }

    func cancel() {
        if controller?.snapshot.phase == .cleaning {
            controller?.cancelCurrentOperation()
            return
        }
        generation = UUID()
        task?.cancel()
        task = nil
        controller?.cancelCurrentOperation()
        queue = []
        pendingSelection = []
        analyzingOwners = []
        isPreparing = false
        isLoadingInventory = false
        remediationTask?.cancel()
        remediationTask = nil
        isResolving = false
        shouldCleanAfterReview = false
        selectionToRestore = [:]
        needsForceQuit = false
    }

    func stop() {
        cancel()
        generation = UUID()
        task?.cancel()
        claimsTask?.cancel()
        claimsTask = nil
        listSizingTask?.cancel()
        listSizingTask = nil
        sizingOwners = []
    }

    var canStartUninstall: Bool {
        guard !isPreparing, !isResolving, let snapshot = controller?.snapshot,
              snapshot.phase == .scanned, snapshot.isCleanupReady, !snapshot.selection.isEmpty else { return false }
        return hasSelectedApplication || isContinuingUninstall
    }

    private var isContinuingUninstall: Bool { activeOwner != nil && continuingOwner == activeOwner }

    var hasSelectedApplication: Bool {
        rows.contains { $0.isBundle && $0.bundleID == activeOwner && candidate(path: $0.path).map { controller?.snapshot.selection.isSelected($0.id) == true } == true }
    }

    var selectedIdentities: [String: DiskCleanRootIdentity] {
        if controller == nil { return selectionToRestore }
        var result: [String: DiskCleanRootIdentity] = [:]
        for candidate in controller?.snapshot.scanResult?.candidates ?? [] where controller?.snapshot.selection.isSelected(candidate.id) == true {
            if let identity = candidate.removalIdentity { result[candidate.path] = identity }
        }
        return result
    }

    var retainedApplication: DiskCleanInstalledApplication? { retryApplication }

    var requiresServiceAuthorization: Bool { servicesForSelection.contains { $0.domain == "system" && $0.target != nil } }
    var willStopServices: Bool { servicesForSelection.contains { $0.target != nil } }

    private var servicesForSelection: [DiskCleanApplicationServiceProof] {
        guard let owner = activeOwner else { return [] }
        let selectedPaths = Set(selectedIdentities.keys)
        let selectedBundles = rows.filter { $0.isBundle && selectedPaths.contains($0.path) }.map(\.path)
        let allProofs = prepared[owner]?.hits.compactMap { hit -> DiskCleanApplicationServiceProof? in
            guard hit.facts.rejection == nil, candidate(path: hit.item.path)?.safety.isCleanable == true,
                  case let .application(_, _, _, _, proof) = hit.facts.validation else { return nil }
            return proof?.service
        } ?? []
        let programs = Set(allProofs.filter { selectedPaths.contains($0.path) }.map(\.program))
        return allProofs.filter { proof in
            selectedPaths.contains(proof.path) || (proof.target != nil && (programs.contains(proof.program)
                || selectedBundles.contains { proof.program.hasPrefix($0 + "/Contents/") }))
        }
    }

    private func startListSizing(_ applications: [DiskCleanInstalledApplication]) {
        let groups = Dictionary(grouping: applications, by: \.bundleID).filter { $0.value.contains { $0.indexedBytes == nil } }
        sizingOwners = Set(groups.keys)
        listSizingTask = Task(priority: .utility) { [weak self] in
            for owner in groups.keys.sorted() {
                guard let self else { return }
                while isPreparing || isResolving {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
                if Task.isCancelled { return }
                var total: Int64 = 0
                var complete = true
                for app in groups[owner] ?? [] {
                    let result = await DiskCleanWorkerPool.shared.size(ofItemAt: app.path,
                        using: DiskCleanCachingSizer(base: DiskCleanFastWalker(), cache: sizeCache),
                        deadline: Date().addingTimeInterval(15))
                    if Task.isCancelled { return }
                    complete = complete && result.completeness.isComplete
                    total += result.estimatedBytes
                }
                if complete { applicationSizes[owner] = total }
                sizingOwners.remove(owner)
            }
        }
    }

    func recheckCurrentApplication() {
        guard !isResolving, controller?.snapshot.isBusy != true, let owner = activeOwner else { return }
        scan(leftovers: isLeftovers, preservingResult: true, keepingOwner: owner,
            restoringSelection: selectedIdentities, extendedInspection: true)
    }

    private func finishAttempt(_ result: DiskCleanExecutionResult, review: DiskCleanPreparedApplicationReview, child: DiskCleanController,
                               deferred: [String: DiskCleanRootIdentity]) {
        guard !isLeftovers, let owner = activeOwner else { scan(leftovers: isLeftovers, preservingResult: true); return }
        let unfinished = Set(result.itemResults.compactMap { item -> String? in
            switch item.outcome {
            case .skipped, .failed, .changedSinceScan: item.path
            default: nil
            }
        })
        guard !unfinished.isEmpty else {
            retryReview = nil
            retryApplication = nil
            retrySelection = [:]
            continuingOwner = nil
            scan(leftovers: false, preservingResult: true)
            return
        }
        retryApplication = inventory?.applications.first { $0.bundleID == owner } ?? retryApplication
        if result.itemResults.contains(where: { item in
            review.rows.contains { $0.path == item.path && $0.isBundle } && {
                if case .trashed = item.outcome { return true }; return false
            }()
        }) { continuingOwner = owner }
        retryReview = .init(rows: review.rows.filter { unfinished.contains($0.path) },
            targets: review.targets.filter { target in review.hits.contains { $0.target.id == target.id && unfinished.contains($0.item.path) } },
            hits: review.hits.filter { unfinished.contains($0.item.path) }, issues: [], coverage: review.coverage, reports: review.reports)
        let intent = Dictionary(uniqueKeysWithValues: (child.snapshot.scanResult?.candidates ?? []).compactMap { candidate -> (String, DiskCleanRootIdentity)? in
            guard unfinished.contains(candidate.path), let identity = candidate.removalIdentity else { return nil }
            return (candidate.path, deferred[candidate.path] ?? identity)
        })
        retrySelection = intent
        scan(leftovers: false, preservingResult: true, keepingOwner: owner, restoringSelection: intent, extendedInspection: true)
    }
}
