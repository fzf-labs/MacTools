import Foundation

// MARK: - Removal mode

/// Removal mode (design §7.4). Both modes use the freeze primitive; they differ only in post-freeze disposition.
enum DiskCleanRemovalMode: String, CaseIterable, Equatable, Sendable {
    /// Move to Trash (default). Recoverable; single-step execution.
    case trash
    /// Permanent delete. Irreversible; requires confirming two-step confirmation.
    case permanent
}

/// Persistence seam for removal mode.
protocol DiskCleanRemovalModeStoring: Sendable {
    func load() -> DiskCleanRemovalMode
    func save(_ mode: DiskCleanRemovalMode)
}

/// `UserDefaults` is thread-safe but not marked Sendable; same treatment as the existing
/// `LocalDiskCleanFileSystem` in the repo.
struct UserDefaultsDiskCleanRemovalModeStore: DiskCleanRemovalModeStoring, @unchecked Sendable {
    static let defaultsKey = "DiskClean.removalMode"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> DiskCleanRemovalMode {
        defaults.string(forKey: Self.defaultsKey)
            .flatMap(DiskCleanRemovalMode.init(rawValue:)) ?? .trash
    }

    func save(_ mode: DiskCleanRemovalMode) {
        defaults.set(mode.rawValue, forKey: Self.defaultsKey)
    }
}

// MARK: - Plan errors

enum DiskCleanPlanError: LocalizedError, Equatable {
    /// Selection includes a missing or non-cleanable candidate.
    case invalidSelection(candidateID: String)
    /// Selection is empty.
    case emptySelection
    /// Candidate's target is missing from the catalog (artifact/catalog version mismatch).
    case unknownTarget(targetID: String)
    /// Planned path is an ancestor of an exclusion / reserved prefix—deleting it would swallow an unreviewed subtree.
    case ancestorViolation(plannedPath: String, protectedPath: String)
    /// Result expired (§4.4 expiry gate).
    case resultExpired

    var errorDescription: String? {
        switch self {
        case let .invalidSelection(candidateID):
            return "选择包含不可清理的候选：\(candidateID)"
        case .emptySelection:
            return "没有可执行的清理项"
        case let .unknownTarget(targetID):
            return "规则目录缺少 target：\(targetID)"
        case let .ancestorViolation(plannedPath, protectedPath):
            return "计划路径 \(plannedPath) 覆盖受保护路径 \(protectedPath)"
        case .resultExpired:
            return "扫描结果已过期，请重新扫描"
        }
    }
}

// MARK: - Validated plan

/// Non-forgeable deletion plan (design §6.1).
///
/// `init` is **fileprivate**: only same-file `DiskCleanPlanner.makePlan` can construct it
/// (ticket-mint pattern); the executor accepts only this type. Exclusion set and reserved prefixes
/// are **verification evidence carried by the plan**; executor preflight re-runs the ancestor
/// assertion independently from them (§7.1) and need not trust Planner to be defect-free.
struct DiskCleanValidatedPlan: Equatable, Sendable {
    struct PlanItem: Equatable, Sendable {
        let candidateID: DiskCleanCandidate.ID
        /// Physical path (no symlink ancestors, §13-6). Deletion uses this.
        let path: String
        /// All pre-physical aliases preserved for lexical safety rechecks (whitelist / sensitive).
        let logicalPaths: [String]
        let rootIdentity: DiskCleanRootIdentity
        let observedAt: Date
        let targetID: String
        let legacyRuleID: String
        let category: DiskCleanCategoryID
        let estimatedBytes: Int64
        /// Target declarations needed for lock checks, copied from the catalog at mint time so
        /// the execution side need not re-query the catalog.
        let lockedByBundleIDs: [String]
        let skipWhenProcessIsRunning: [String]
        var validation: DiskCleanReviewValidation? = nil

        var parentPath: String {
            (path as NSString).deletingLastPathComponent
        }

        var name: String {
            (path as NSString).lastPathComponent
        }

        var safetyCheckPaths: [String] {
            logicalPaths.filter { $0 != path }
        }
    }

    let items: [PlanItem]
    /// Frozen removal mode. Mode changes during confirming invalidate the whole plan rather than rewrite this value.
    let mode: DiskCleanRemovalMode
    let totalEstimatedBytes: Int64
    /// Frozen earliest observation time. Execution preflight rechecks the expiry gate from this (§7.1 item 1).
    let minObservedAt: Date
    /// Verification evidence: paths of all unplanned candidates + locked/protected/whitelist/partial paths.
    let exclusionPaths: [String]
    /// Verification evidence: reserved roots of skipped / failed targets (unscanned subtrees treated as present).
    let reservedPrefixes: [String]
    let mintedAt: Date

    fileprivate init(
        items: [PlanItem],
        mode: DiskCleanRemovalMode,
        minObservedAt: Date,
        exclusionPaths: [String],
        reservedPrefixes: [String],
        mintedAt: Date
    ) {
        self.items = items
        self.mode = mode
        self.totalEstimatedBytes = items.reduce(0) { $0 + max($1.estimatedBytes, 0) }
        self.minObservedAt = minObservedAt
        self.exclusionPaths = exclusionPaths
        self.reservedPrefixes = reservedPrefixes
        self.mintedAt = mintedAt
    }

    var itemCount: Int { items.count }

    var expiryDeadline: Date {
        DiskCleanScanFreshness.deadline(minObservedAt: minObservedAt)
    }
}

/// UI-facing plan summary. Snapshots carry only this; the full plan stays in Controller private state.
struct DiskCleanPendingPlanSummary: Equatable, Sendable {
    let itemCount: Int
    let totalEstimatedBytes: Int64
    let mode: DiskCleanRemovalMode
}

// MARK: - Planner

/// Sole minting point for plans.
@MainActor
enum DiskCleanPlanner {
    /// Mint a plan. Any validation failure `throw`s—no plan means zero deletions.
    ///
    /// Exclusion set and reserved prefixes always derive from `artifact`; the caller (Controller)
    /// can only subtract via `selectedIDs`, cannot forge evidence, and cannot omit reserved prefixes.
    static func makePlan(
        artifact: DiskCleanScanArtifact,
        selectedIDs: Set<DiskCleanCandidate.ID>,
        mode: DiskCleanRemovalMode,
        now: Date,
        catalog: DiskCleanRuleCatalogV2 = .current
    ) throws -> DiskCleanValidatedPlan {
        guard !selectedIDs.isEmpty else {
            throw DiskCleanPlanError.emptySelection
        }

        let targetsByID = Dictionary(
            catalog.targets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var items: [DiskCleanValidatedPlan.PlanItem] = []
        items.reserveCapacity(selectedIDs.count)
        var minObservedAt = Date.distantFuture

        // Preserve artifact candidate order for selected items so execution and display stay consistent and reproducible.
        for candidate in artifact.candidates where selectedIDs.contains(candidate.id) {
            guard candidate.isCleanable,
                  let observedAt = candidate.observedAt,
                  let rootIdentity = candidate.removalIdentity else {
                throw DiskCleanPlanError.invalidSelection(candidateID: candidate.id)
            }
            guard let target = targetsByID[candidate.targetID] else {
                throw DiskCleanPlanError.unknownTarget(targetID: candidate.targetID)
            }

            minObservedAt = min(minObservedAt, observedAt)
            items.append(
                DiskCleanValidatedPlan.PlanItem(
                    candidateID: candidate.id,
                    path: candidate.path,
                    logicalPaths: candidate.logicalPaths,
                    rootIdentity: rootIdentity,
                    observedAt: observedAt,
                    targetID: candidate.targetID,
                    legacyRuleID: candidate.legacyRuleID,
                    category: candidate.category,
                    estimatedBytes: candidate.estimatedBytes,
                    lockedByBundleIDs: target.lockedByBundleIDs,
                    skipWhenProcessIsRunning: target.skipWhenProcessIsRunning,
                    validation: candidate.validation
                )
            )
        }

        if mode != .trash, let item = items.first(where: { $0.validation?.requiresTrash == true }) {
            throw DiskCleanPlanError.invalidSelection(candidateID: item.candidateID)
        }
        // Bundle moves precede associated data, including multiple copies in a batch.
        items = items.filter { $0.validation?.isApplicationBundle == true }
            + items.filter { $0.validation?.isApplicationBundle != true }

        // Some submitted ids are not in the artifact → unauthorized selection; reject entirely.
        // Compare sets, not counts: duplicate ids in the artifact could make counts match while
        // still hiding a miss.
        let plannedIDs = Set(items.map(\.candidateID))
        guard plannedIDs == selectedIDs else {
            let unknownID = selectedIDs.first { !plannedIDs.contains($0) } ?? "?"
            throw DiskCleanPlanError.invalidSelection(candidateID: unknownID)
        }

        // Expiry check (§6.1 item 4).
        guard now < DiskCleanScanFreshness.deadline(minObservedAt: minObservedAt) else {
            throw DiskCleanPlanError.resultExpired
        }

        // Exclusion set: paths of all unplanned candidates. Locked/protected/whitelist/partial are
        // included naturally—they are not cleanable and thus never planned.
        let exclusionPaths = artifact.candidates
            .filter { !plannedIDs.contains($0.id) }
            .map(\.path)
        let reservedPrefixes = artifact.reservedRootPaths

        // Ancestor assertion (§6.1 item 3).
        try assertNoAncestorViolation(
            plannedPaths: items.map(\.path),
            exclusionPaths: exclusionPaths,
            reservedPrefixes: reservedPrefixes
        )

        return DiskCleanValidatedPlan(
            items: items,
            mode: mode,
            minObservedAt: minObservedAt,
            exclusionPaths: exclusionPaths,
            reservedPrefixes: reservedPrefixes,
            mintedAt: now
        )
    }

    /// Ancestor assertion: no planned path may equal, or be an ancestor of, any protected path.
    ///
    /// Executor preflight re-runs the same assertion with plan-carried evidence (§7.1 item 3),
    /// sharing this implementation. `nonisolated`: pure value-type computation; the executor
    /// re-running it off the main thread should not be forced back onto the main actor.
    nonisolated static func assertNoAncestorViolation(
        plannedPaths: [String],
        exclusionPaths: [String],
        reservedPrefixes: [String]
    ) throws {
        let protectedPaths = exclusionPaths + reservedPrefixes
        for planned in plannedPaths {
            let prefix = planned.hasSuffix("/") ? planned : planned + "/"
            for protectedPath in protectedPaths {
                if protectedPath == planned || protectedPath.hasPrefix(prefix) {
                    throw DiskCleanPlanError.ancestorViolation(
                        plannedPath: planned,
                        protectedPath: protectedPath
                    )
                }
            }
        }
    }
}
