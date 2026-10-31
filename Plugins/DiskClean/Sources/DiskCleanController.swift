import Combine
import Foundation
import MacToolsPluginKit

enum DiskCleanControllerPhase: Equatable, Sendable {
    case idle
    case scanning
    case scanned
    /// Second step of permanent delete (design §8.4). The plan is cast and frozen, waiting for user confirmation.
    case confirming
    case cleaning
    case completed
}

/// Time source for the expiry gate (injectable Clock from design §4.4).
///
/// Expiry must be **time-driven**: buttons grey out when the threshold hits, not only when the user next clicks.
/// So besides "what time is it now" we need "sleep until", so tests can drive the transition without really waiting 300s.
/// The confirmation window (§8.4) reuses the same clock.
protocol DiskCleanClock: Sendable {
    var now: Date { get }
    func sleep(until deadline: Date) async throws
}

struct DiskCleanSystemClock: DiskCleanClock {
    var now: Date { Date() }

    func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        // The upper bound is defensive only: the expiry window is 300s and cannot approach overflow.
        let nanoseconds = min(interval, 86_400) * 1_000_000_000
        try await Task.sleep(nanoseconds: UInt64(nanoseconds))
    }
}

struct DiskCleanControllerSnapshot: Equatable, Sendable {
    let phase: DiskCleanControllerPhase
    /// Current scan scope. Rules segment uses checked groups; purge segment uses configured roots; installer segment has no parameters.
    let scope: DiskCleanScanScope
    let scanResult: DiskCleanScanResult?
    let executionResult: DiskCleanExecutionResult?
    /// Selected scan scope no longer matches the result.
    let isResultStale: Bool
    /// Expiry gate has fired (design §4.4). Mis-operation protection, not TOCTOU protection.
    let isResultExpired: Bool
    let errorMessage: String?
    let scanLogEntries: [DiskCleanScanLogEntry]
    /// Current removal mode. The plan freezes the value at cast time; changing this invalidates a pending plan.
    let removalMode: DiskCleanRemovalMode
    /// Frozen summary of the pending plan. Non-nil only in the `confirming` phase; the full plan stays in Controller private state.
    let pendingPlan: DiskCleanPendingPlanSummary?
    /// Read-only projection of authoritative selection state (design §8.1). Menu bar and detail page read the same copy.
    let selection: DiskCleanSelectionProjection
    /// False until startup journal reconciliation finishes.
    let isCleanupReady: Bool

    init(
        phase: DiskCleanControllerPhase,
        scope: DiskCleanScanScope,
        scanResult: DiskCleanScanResult?,
        executionResult: DiskCleanExecutionResult?,
        isResultStale: Bool,
        isResultExpired: Bool = false,
        errorMessage: String?,
        scanLogEntries: [DiskCleanScanLogEntry] = [],
        removalMode: DiskCleanRemovalMode = .trash,
        pendingPlan: DiskCleanPendingPlanSummary? = nil,
        selection: DiskCleanSelectionProjection = .empty,
        isCleanupReady: Bool = true
    ) {
        self.phase = phase
        self.scope = scope
        self.scanResult = scanResult
        self.executionResult = executionResult
        self.isResultStale = isResultStale
        self.isResultExpired = isResultExpired
        self.errorMessage = errorMessage
        self.scanLogEntries = scanLogEntries
        self.removalMode = removalMode
        self.pendingPlan = pendingPlan
        self.selection = selection
        self.isCleanupReady = isCleanupReady
    }

    /// Checked groups for the rules segment. Other segments have no group concept and return an empty set.
    var selectedChoices: Set<DiskCleanChoice> {
        scope.choices
    }

    var subtitle: String {
        subtitle()
    }

    func subtitle(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch phase {
        case .idle:
            return localization.string("controller.subtitle.idle", defaultValue: "选择清理范围")
        case .scanning:
            return localization.string("controller.subtitle.scanning", defaultValue: "正在扫描")
        case .scanned:
            if isResultStale {
                return localization.string("controller.subtitle.stale", defaultValue: "清理范围已变化")
            }
            if isResultExpired {
                return localization.string("controller.subtitle.expired", defaultValue: "结果已过期，请重新扫描")
            }
            return scanResult.map {
                localization.format(
                    "controller.subtitle.scannedCount",
                    defaultValue: "%d 项可清理",
                    $0.cleanableCandidates.count
                )
            } ?? localization.string("controller.subtitle.scanned", defaultValue: "扫描完成")
        case .confirming:
            return localization.string("controller.subtitle.confirming", defaultValue: "等待确认永久清理")
        case .cleaning:
            return localization.string("controller.subtitle.cleaning", defaultValue: "正在清理")
        case .completed:
            return localization.string("controller.subtitle.completed", defaultValue: "清理完成")
        }
    }

    var isBusy: Bool {
        phase == .scanning || phase == .cleaning
    }

    /// Disable scan when scope is empty: rules segment means no group checked; purge segment means no folder added yet.
    /// Both cases need UI guidance rather than a button that does nothing.
    var canScan: Bool {
        !isBusy && phase != .confirming && !scope.isEmpty
    }

    /// Can clean = has a result, result is fresh, startup recovery finished, **and the user currently has a selection**.
    /// When the selection is empty the button greys out rather than meaning "clean everything"—menu bar and detail page share one selection.
    var canClean: Bool {
        phase == .scanned
            && !isResultStale
            && !isResultExpired
            && !selection.isEmpty
            && isCleanupReady
    }

    static let initial = DiskCleanControllerSnapshot(
        phase: .idle,
        scope: .rules(choices: Set(DiskCleanChoice.allCases)),
        scanResult: nil,
        executionResult: nil,
        isResultStale: false,
        errorMessage: nil
    )
}

@MainActor
protocol DiskCleanControlling: AnyObject {
    var onStateChange: (() -> Void)? { get set }
    var snapshot: DiskCleanControllerSnapshot { get }

    /// Replace the whole scan scope. Purge-segment root add/remove goes through here.
    func setScope(_ scope: DiskCleanScanScope)
    /// Group checkbox for the rules segment. No-op under non-rules scopes.
    func setChoice(_ choice: DiskCleanChoice, isSelected: Bool)
    func setRemovalMode(_ mode: DiskCleanRemovalMode)
    func setCandidateSelected(_ candidateID: DiskCleanCandidate.ID, isSelected: Bool)
    /// Category-level select all (`true` = all low-risk items in the category) / deselect all.
    func setCategorySelection(_ category: DiskCleanCategoryID, isSelected: Bool)
    func scan()
    /// Clean the current selection. Takes no id parameter—there is one authoritative selection (design §8.1).
    func clean()
    func confirmPendingClean()
    func cancelPendingClean()
    func cancelCurrentOperation()
}

/// State machine + event-stream consumption + expiry clock + confirmation window.
///
/// Four mechanisms kept as-is:
/// - **operationID generation**: each operation gets a new UUID; events and completion from stale operations are dropped,
///   so a "tail from the previous scan" cannot pollute the new round.
/// - **Throttled publish**: scan events arrive one-by-one but snapshots publish in ~250ms batches (AGENTS.md high-frequency-source exception),
///   otherwise every candidate would force a host rebuild.
/// - **Ring log cap**: keep at most 500 entries.
/// - **Single snapshot exit**: every state publish goes through `publish`; `removalMode` and `pendingPlan`
///   always derive from Controller private state, so no branch can forget a pending plan.
@MainActor
final class DiskCleanController: ObservableObject, DiskCleanControlling {
    /// Snapshot publish interval during scans (~250ms throttle from design §8.2).
    private static let scanFlushIntervalNanoseconds: UInt64 = 250_000_000
    private static let maximumLogEntries = 500
    /// Confirmation window cap (design §8.4). Actual window is `min(60s, remaining expiry time)`.
    static let confirmationWindow: TimeInterval = 60

    var onStateChange: (() -> Void)?

    @Published private(set) var snapshot: DiskCleanControllerSnapshot {
        didSet {
            onStateChange?()
        }
    }

    private let engine: any DiskCleanScanning
    private let executor: any DiskCleanExecuting
    private let localization: PluginLocalization
    private let clock: any DiskCleanClock
    private let removalModeStore: any DiskCleanRemovalModeStoring
    /// Look up target lock declarations when casting a plan. Inject the same catalog as `DiskCleanScanEngine`.
    private let catalog: DiskCleanRuleCatalogV2
    private let cleanupReadiness: DiskCleanCleanupReadiness

    private var currentTask: Task<Void, Never>?
    private var currentOperationID: UUID?
    private var scanFlushTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var confirmationTask: Task<Void, Never>?
    private var nextLogEntryID = 1

    private var removalMode: DiskCleanRemovalMode
    /// Frozen pending plan. Must be nil outside the `confirming` phase.
    private var pendingPlan: DiskCleanValidatedPlan?
    /// Authoritative selection state (design §8.1). Views only receive the read-only projection derived in `publish`.
    private var selection = DiskCleanSelectionModel()

    /// Authoritative candidate set while scanning. The snapshot is a projection; throttling only affects publish timing, not correctness.
    private var liveCandidates: [DiskCleanCandidate] = []
    private var liveCandidateIndexByID: [DiskCleanCandidate.ID: Int] = [:]
    private var pendingLogMessages: [DiskCleanScanLogMessage] = []
    private var needsScanFlush = false

    init(
        engine: any DiskCleanScanning = DiskCleanScanEngine(),
        executor: any DiskCleanExecuting = DiskCleanExecutor(),
        initialSnapshot: DiskCleanControllerSnapshot = .initial,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        clock: any DiskCleanClock = DiskCleanSystemClock(),
        removalModeStore: any DiskCleanRemovalModeStoring = UserDefaultsDiskCleanRemovalModeStore(),
        catalog: DiskCleanRuleCatalogV2 = .current,
        cleanupReadiness: DiskCleanCleanupReadiness = DiskCleanCleanupReadiness(isReady: true)
    ) {
        self.engine = engine
        self.executor = executor
        self.localization = localization
        self.clock = clock
        self.removalModeStore = removalModeStore
        self.catalog = catalog
        self.cleanupReadiness = cleanupReadiness
        self.removalMode = removalModeStore.load()
        snapshot = DiskCleanControllerSnapshot(
            phase: initialSnapshot.phase,
            scope: initialSnapshot.scope,
            scanResult: initialSnapshot.scanResult,
            executionResult: initialSnapshot.executionResult,
            isResultStale: initialSnapshot.isResultStale,
            isResultExpired: initialSnapshot.isResultExpired,
            errorMessage: initialSnapshot.errorMessage,
            scanLogEntries: initialSnapshot.scanLogEntries,
            removalMode: removalModeStore.load(),
            isCleanupReady: cleanupReadiness.ready
        )
    }

    /// Called when startup reconciliation finishes so Clean re-evaluates readiness.
    func refreshCleanupReadiness() {
        publish(
            phase: snapshot.phase,
            scope: snapshot.scope,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: snapshot.isResultStale,
            isResultExpired: snapshot.isResultExpired,
            errorMessage: snapshot.errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
    }

    deinit {
        currentTask?.cancel()
        scanFlushTask?.cancel()
        expiryTask?.cancel()
        confirmationTask?.cancel()
    }

    func invalidateResult() {
        guard snapshot.phase != .cleaning else { return }
        cancelCurrentOperation()
        publish(phase: snapshot.phase, scope: snapshot.scope, scanResult: snapshot.scanResult,
                executionResult: snapshot.executionResult, isResultStale: true,
                isResultExpired: snapshot.isResultExpired, errorMessage: nil, scanLogEntries: snapshot.scanLogEntries)
    }

    func setScope(_ scope: DiskCleanScanScope) {
        guard scope != snapshot.scope else { return }

        // When scope changes, a frozen plan no longer matches what the user sees—invalidate it; do not silently keep it (§8.4).
        discardPendingPlan()

        publish(
            phase: snapshot.phase == .confirming ? .scanned : snapshot.phase,
            scope: scope,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: isStale(scanResult: snapshot.scanResult, scope: scope),
            isResultExpired: snapshot.isResultExpired,
            errorMessage: snapshot.errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
    }

    /// Silently ignore under non-rules scopes: groups only exist for the rules segment; faking a `.rules` scope for them
    /// would replace the whole segment's scan scope.
    func setChoice(_ choice: DiskCleanChoice, isSelected: Bool) {
        guard case var .rules(nextChoices) = snapshot.scope else { return }
        if isSelected {
            nextChoices.insert(choice)
        } else {
            nextChoices.remove(choice)
        }
        setScope(.rules(choices: nextChoices))
    }

    func setCandidateSelected(_ candidateID: DiskCleanCandidate.ID, isSelected: Bool) {
        guard let index = liveCandidateIndexByID[candidateID] else { return }
        // Unselectable candidates are rejected by the model itself—UI disable is only a hint; the real gate is here.
        guard selection.setCandidate(liveCandidates[index], isSelected: isSelected) else { return }
        publishSelectionChange()
    }

    func setCategorySelection(_ category: DiskCleanCategoryID, isSelected: Bool) {
        selection.setCategory(category, isSelected: isSelected)
        publishSelectionChange()
    }

    /// Shared follow-up after selection changes: invalidate any frozen plan and republish the snapshot.
    ///
    /// A frozen plan matches the selection the user saw at confirm time; once selection changes it no longer matches any user intent (§8.4).
    private func publishSelectionChange() {
        let wasConfirming = snapshot.phase == .confirming
        discardPendingPlan()
        publish(
            phase: wasConfirming ? .scanned : snapshot.phase,
            scope: snapshot.scope,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: snapshot.isResultStale,
            isResultExpired: snapshot.isResultExpired,
            errorMessage: snapshot.errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
    }

    func setRemovalMode(_ mode: DiskCleanRemovalMode) {
        guard mode != removalMode else { return }
        removalMode = mode
        removalModeStore.save(mode)

        // Removal mode is one of the fields frozen into the plan; changing it must invalidate a pending plan (§8.4).
        let wasConfirming = snapshot.phase == .confirming
        discardPendingPlan()
        publish(
            phase: wasConfirming ? .scanned : snapshot.phase,
            scope: snapshot.scope,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: snapshot.isResultStale,
            isResultExpired: snapshot.isResultExpired,
            errorMessage: snapshot.errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
    }

    func scan() {
        guard snapshot.canScan else { return }

        // Rescans after expiry must bypass the cache, or "expired → rescan → hit old cache → still expired" loops forever (design §4.3).
        let forceRefresh = snapshot.isResultExpired
        cancelTaskOnly()
        discardPendingPlan()

        let scope = snapshot.scope
        let operationID = UUID()
        currentOperationID = operationID
        nextLogEntryID = 1
        liveCandidates = []
        liveCandidateIndexByID = [:]
        pendingLogMessages = []
        needsScanFlush = false
        // Candidate IDs are stable across scans; without reset, previous checks would silently carry into new results.
        selection.reset()

        publish(
            phase: .scanning,
            scope: scope,
            scanResult: nil,
            executionResult: nil,
            isResultStale: false,
            isResultExpired: false,
            errorMessage: nil,
            scanLogEntries: [
                makeLogEntry(
                    DiskCleanScanLogMessage(
                        text: localization.format(
                            "scanLog.started",
                            defaultValue: "开始扫描：%@",
                            scopeDescription(scope)
                        ),
                        tone: .info
                    )
                )
            ]
        )
        startScanFlushLoop(operationID: operationID)

        let stream = engine.scan(scope: scope, forceRefresh: forceRefresh)
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    guard isCurrentOperation(operationID) else { return }
                    handle(event, operationID: operationID, scope: scope)
                }
                guard isCurrentOperation(operationID) else { return }
                finishOperation(operationID)
            } catch is CancellationError {
                guard isCurrentOperation(operationID) else { return }
                publishCancelledScan(scope: scope)
                finishOperation(operationID)
            } catch {
                guard isCurrentOperation(operationID) else { return }
                publishFailedScan(scope: scope, error: error)
                finishOperation(operationID)
            }
        }
    }

    /// Cleanup entry. Cast plan → Trash executes immediately / permanent goes to confirmation (design §8.4).
    ///
    /// The cleanup set comes straight from the authoritative selection model: menu bar and detail page do not each hold their own idea of "what to clean".
    func clean() {
        guard snapshot.canClean, let scanResult = snapshot.scanResult else { return }
        // The Planner's only input is the scan artifact. No artifact (interrupted scan, stale projection) means no plan and no deletion.
        guard let artifact = scanResult.artifact else { return }

        // First line of the §3.1 invariant: candidates with unresolved or partial size must **never** enter the cleanup set.
        // The selection model already refuses to check them; this intersection is a backstop against projection/candidate drift.
        // (Planner and executor each have another gate.)
        let cleanableIDs = Set(scanResult.cleanableCandidates.map(\.id))
        let selectedIDs = cleanableIDs.intersection(snapshot.selection.selectedIDs)
        guard !selectedIDs.isEmpty else { return }

        let plan: DiskCleanValidatedPlan
        do {
            plan = try DiskCleanPlanner.makePlan(
                artifact: artifact,
                selectedIDs: selectedIDs,
                mode: removalMode,
                now: clock.now,
                catalog: catalog
            )
        } catch {
            // Cast failure = zero deletions. Report the reason honestly; do not degrade it into a partial cleanup.
            publish(
                phase: .scanned,
                scope: snapshot.scope,
                scanResult: scanResult,
                executionResult: nil,
                isResultStale: snapshot.isResultStale,
                isResultExpired: isExpired(scanResult),
                errorMessage: Self.userFacingMessage(for: error),
                scanLogEntries: snapshot.scanLogEntries
            )
            return
        }

        switch plan.mode {
        case .trash:
            // The freeze primitive is recoverable, so Trash runs in one step with no second confirmation.
            startExecution(plan: plan, scanResult: scanResult)
        case .permanent:
            enterConfirming(plan: plan, scanResult: scanResult)
        }
    }

    func confirmPendingClean() {
        guard snapshot.phase == .confirming,
              let plan = pendingPlan,
              let scanResult = snapshot.scanResult else { return }
        startExecution(plan: plan, scanResult: scanResult)
    }

    func cancelPendingClean() {
        guard snapshot.phase == .confirming else { return }
        invalidatePendingPlan(errorMessage: nil)
    }

    func cancelCurrentOperation() {
        let phase = snapshot.phase
        let scope = snapshot.scope
        let scanLogEntries = snapshot.scanLogEntries

        switch phase {
        case .confirming:
            invalidatePendingPlan(errorMessage: nil)
        case .scanning:
            cancelTaskOnly()
            publish(
                phase: .idle,
                scope: scope,
                scanResult: nil,
                executionResult: nil,
                isResultStale: false,
                isResultExpired: false,
                errorMessage: nil,
                scanLogEntries: scanLogEntries + [
                    makeLogEntry(
                        DiskCleanScanLogMessage(
                            text: localization.string("scanLog.stopped", defaultValue: "扫描已停止"),
                            tone: .warning
                        )
                    )
                ]
            )
        case .cleaning:
            // Request cancel only. Keep `currentTask` / `currentOperationID` so the
            // execution task can still publish `.scanned` / `.completed` when the current
            // item finishes. Clearing the operation ID here would leave the UI stuck on
            // `.cleaning` forever after the task returns.
            currentTask?.cancel()
        case .idle, .scanned, .completed:
            cancelTaskOnly()
        }
    }

    // MARK: - Confirmation and execution

    private func enterConfirming(plan: DiskCleanValidatedPlan, scanResult: DiskCleanScanResult) {
        pendingPlan = plan
        publish(
            phase: .confirming,
            scope: snapshot.scope,
            scanResult: scanResult,
            executionResult: nil,
            isResultStale: snapshot.isResultStale,
            isResultExpired: false,
            errorMessage: nil,
            scanLogEntries: snapshot.scanLogEntries
        )

        // The confirmation window must not cross the expiry moment: cast at 299s + 60s confirm would land past the gate.
        let deadline = min(clock.now.addingTimeInterval(Self.confirmationWindow), plan.expiryDeadline)
        confirmationTask?.cancel()
        confirmationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled, snapshot.phase == .confirming else { return }
            invalidatePendingPlan(
                errorMessage: localization.string(
                    "controller.error.confirmationExpired",
                    defaultValue: "确认已超时，请重新发起清理"
                )
            )
        }
    }

    /// Invalidate the pending plan and return to `scanned`.
    private func invalidatePendingPlan(errorMessage: String?) {
        discardPendingPlan()
        publish(
            phase: .scanned,
            scope: snapshot.scope,
            scanResult: snapshot.scanResult,
            executionResult: nil,
            isResultStale: snapshot.isResultStale,
            isResultExpired: snapshot.scanResult.map(isExpired) ?? false,
            errorMessage: errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
    }

    private func discardPendingPlan() {
        pendingPlan = nil
        confirmationTask?.cancel()
        confirmationTask = nil
    }

    private func startExecution(plan: DiskCleanValidatedPlan, scanResult: DiskCleanScanResult) {
        cancelTaskOnly()
        discardPendingPlan()

        let scope = snapshot.scope
        let operationID = UUID()
        currentOperationID = operationID
        publish(
            phase: .cleaning,
            scope: scope,
            scanResult: scanResult,
            executionResult: nil,
            isResultStale: false,
            isResultExpired: false,
            errorMessage: nil,
            scanLogEntries: snapshot.scanLogEntries
        )

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let executionResult = try await executor.execute(plan: plan)
                guard isCurrentOperation(operationID) else { return }
                publishCleaning(
                    phase: .completed,
                    scope: scope,
                    scanResult: scanResult,
                    executionResult: executionResult,
                    errorMessage: nil
                )
                finishOperation(operationID)
            } catch is CancellationError {
                guard isCurrentOperation(operationID) else { return }
                publishCleaning(
                    phase: .scanned,
                    scope: scope,
                    scanResult: scanResult,
                    executionResult: nil,
                    errorMessage: nil
                )
                finishOperation(operationID)
            } catch {
                // Preflight failure means zero deletions; report the reason honestly (§7.1).
                guard isCurrentOperation(operationID) else { return }
                publishCleaning(
                    phase: .scanned,
                    scope: scope,
                    scanResult: scanResult,
                    executionResult: nil,
                    errorMessage: Self.userFacingMessage(for: error)
                )
                finishOperation(operationID)
            }
        }
    }

    // MARK: - Event consumption

    private func handle(
        _ event: DiskCleanScanEvent,
        operationID: UUID,
        scope: DiskCleanScanScope
    ) {
        switch event {
        case let .log(message):
            pendingLogMessages.append(message)
            needsScanFlush = true

        case let .candidateFound(candidate):
            liveCandidateIndexByID[candidate.id] = liveCandidates.count
            liveCandidates.append(candidate)
            needsScanFlush = true

        case let .candidateSized(candidateID, result):
            guard let index = liveCandidateIndexByID[candidateID] else { return }
            liveCandidates[index] = liveCandidates[index].applying(result)
            needsScanFlush = true

        case .categoryFinished:
            // Do not consume: per-item "calculating" badges already explain progress; adding a category-level spinner
            // would only restate the same thing. Keep the event for P2 segments (§10) that finish per category.
            break

        case let .finished(summary):
            publishFinishedScan(summary: summary, scope: scope)
        }
    }

    private func startScanFlushLoop(operationID: UUID) {
        scanFlushTask?.cancel()
        scanFlushTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.scanFlushIntervalNanoseconds)
                } catch {
                    return
                }
                guard let self, isCurrentOperation(operationID) else { return }
                flushScanUpdates(operationID: operationID)
            }
        }
    }

    private func flushScanUpdates(operationID: UUID) {
        guard needsScanFlush, isCurrentOperation(operationID), snapshot.phase == .scanning else { return }
        needsScanFlush = false

        publish(
            phase: .scanning,
            scope: snapshot.scope,
            scanResult: DiskCleanScanResult(
                scope: snapshot.scope,
                candidates: liveCandidates,
                scannedAt: clock.now
            ),
            executionResult: nil,
            isResultStale: false,
            isResultExpired: false,
            errorMessage: nil,
            scanLogEntries: scanLogEntries(adding: drainPendingLogMessages(), to: snapshot.scanLogEntries)
        )
    }

    private func publishFinishedScan(summary: DiskCleanScanSummary, scope: DiskCleanScanScope) {
        needsScanFlush = false
        let artifact = summary.artifact
        liveCandidates = artifact.candidates
        liveCandidateIndexByID = Dictionary(
            artifact.candidates.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        let scanResult = DiskCleanScanResult(
            scope: scope,
            candidates: artifact.candidates,
            scannedAt: artifact.finishedAt,
            limitations: artifact.limitations,
            artifact: artifact
        )
        publish(
            phase: .scanned,
            scope: snapshot.scope,
            scanResult: scanResult,
            executionResult: nil,
            isResultStale: isStale(scanResult: scanResult, scope: snapshot.scope),
            isResultExpired: isExpired(scanResult),
            errorMessage: nil,
            scanLogEntries: scanLogEntries(adding: drainPendingLogMessages(), to: snapshot.scanLogEntries)
        )
        scheduleExpiry(for: scanResult)
    }

    private func publishCancelledScan(scope: DiskCleanScanScope) {
        publish(
            phase: .idle,
            scope: scope,
            scanResult: nil,
            executionResult: nil,
            isResultStale: false,
            isResultExpired: false,
            errorMessage: nil,
            scanLogEntries: scanLogEntries(adding: drainPendingLogMessages(), to: snapshot.scanLogEntries)
        )
    }

    private func publishFailedScan(scope: DiskCleanScanScope, error: Error) {
        let message = Self.userFacingMessage(for: error)
        publish(
            phase: .idle,
            scope: scope,
            scanResult: nil,
            executionResult: nil,
            isResultStale: false,
            isResultExpired: false,
            errorMessage: message,
            scanLogEntries: scanLogEntries(
                adding: drainPendingLogMessages() + [
                    DiskCleanScanLogMessage(
                        text: localization.format("scanLog.failed", defaultValue: "扫描失败：%@", message),
                        tone: .error
                    )
                ],
                to: snapshot.scanLogEntries
            )
        )
    }

    private func publishCleaning(
        phase: DiskCleanControllerPhase,
        scope: DiskCleanScanScope,
        scanResult: DiskCleanScanResult,
        executionResult: DiskCleanExecutionResult?,
        errorMessage: String?
    ) {
        publish(
            phase: phase,
            scope: scope,
            scanResult: scanResult,
            executionResult: executionResult,
            isResultStale: false,
            isResultExpired: phase == .scanned ? isExpired(scanResult) : false,
            errorMessage: errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
        // Returning to scanned means the result can be used again, so the expiry clock must be re-armed.
        if phase == .scanned {
            scheduleExpiry(for: scanResult)
        }
    }

    // MARK: - Snapshot publish

    /// Single exit for snapshots. `removalMode`, `pendingPlan`, and `selection` always derive from private state.
    ///
    /// The selection projection is computed here (not passed in by callers), so it always matches this publish's candidate set—
    /// no branch can publish new candidates while carrying an old selection.
    private func publish(
        phase: DiskCleanControllerPhase,
        scope: DiskCleanScanScope,
        scanResult: DiskCleanScanResult?,
        executionResult: DiskCleanExecutionResult?,
        isResultStale: Bool,
        isResultExpired: Bool,
        errorMessage: String?,
        scanLogEntries: [DiskCleanScanLogEntry]
    ) {
        snapshot = DiskCleanControllerSnapshot(
            phase: phase,
            scope: scope,
            scanResult: scanResult,
            executionResult: executionResult,
            isResultStale: isResultStale,
            isResultExpired: isResultExpired,
            errorMessage: errorMessage,
            scanLogEntries: scanLogEntries,
            removalMode: removalMode,
            pendingPlan: pendingPlan.map {
                DiskCleanPendingPlanSummary(
                    itemCount: $0.itemCount,
                    totalEstimatedBytes: $0.totalEstimatedBytes,
                    mode: $0.mode
                )
            },
            selection: selection.projection(for: scanResult?.candidates ?? []),
            isCleanupReady: cleanupReadiness.ready
        )
    }

    // MARK: - Expiry gate

    /// Time-driven expiry transition (design §4.4): fire `onStateChange` when the threshold hits,
    /// so menu-bar buttons and the detail page grey out together without waiting for a user action.
    private func scheduleExpiry(for scanResult: DiskCleanScanResult) {
        expiryTask?.cancel()
        expiryTask = nil

        guard let deadline = scanResult.expiryDeadline, clock.now < deadline else { return }

        expiryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            markResultExpired()
        }
    }

    private func markResultExpired() {
        // The confirm window never crosses expiry, but if both fire together order is undefined: if expiry wins, invalidate the plan here.
        if snapshot.phase == .confirming {
            discardPendingPlan()
        }
        guard snapshot.phase == .scanned || snapshot.phase == .confirming, !snapshot.isResultExpired else { return }
        publish(
            phase: .scanned,
            scope: snapshot.scope,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: snapshot.isResultStale,
            isResultExpired: true,
            errorMessage: snapshot.errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
    }

    private func isExpired(_ scanResult: DiskCleanScanResult) -> Bool {
        guard let deadline = scanResult.expiryDeadline else { return false }
        return clock.now >= deadline
    }

    // MARK: - Teardown and helpers

    private func cancelTaskOnly() {
        currentTask?.cancel()
        currentTask = nil
        currentOperationID = nil
        scanFlushTask?.cancel()
        scanFlushTask = nil
        expiryTask?.cancel()
        expiryTask = nil
    }

    private func finishOperation(_ operationID: UUID) {
        guard isCurrentOperation(operationID) else { return }
        currentTask = nil
        currentOperationID = nil
        scanFlushTask?.cancel()
        scanFlushTask = nil
    }

    private func drainPendingLogMessages() -> [DiskCleanScanLogMessage] {
        defer { pendingLogMessages.removeAll(keepingCapacity: true) }
        return pendingLogMessages
    }

    private func scanLogEntries(
        adding messages: [DiskCleanScanLogMessage],
        to existingEntries: [DiskCleanScanLogEntry]
    ) -> [DiskCleanScanLogEntry] {
        guard !messages.isEmpty else { return existingEntries }

        var entries = existingEntries
        entries.reserveCapacity(min(existingEntries.count + messages.count, Self.maximumLogEntries))
        for message in messages {
            entries.append(makeLogEntry(message))
        }
        if entries.count > Self.maximumLogEntries {
            entries.removeFirst(entries.count - Self.maximumLogEntries)
        }
        return entries
    }

    private func makeLogEntry(_ message: DiskCleanScanLogMessage) -> DiskCleanScanLogEntry {
        defer { nextLogEntryID += 1 }
        return DiskCleanScanLogEntry(
            id: nextLogEntryID,
            text: message.text,
            tone: message.tone
        )
    }

    /// Scope description for the scan-started log line.
    private func scopeDescription(_ scope: DiskCleanScanScope) -> String {
        let separator = localization.string("list.separator", defaultValue: "、")
        switch scope {
        case let .rules(choices):
            return DiskCleanChoice.allCases
                .filter { choices.contains($0) }
                .map { $0.title(localization: localization) }
                .joined(separator: separator)
        case let .developerArtifacts(roots):
            return roots.joined(separator: separator)
        case .automaticProjects:
            return DiskCleanCategoryID.developerArtifacts.title(localization: localization)
        case .review:
            return "应用审阅"
        case .installers:
            return DiskCleanCategoryID.installers.title(localization: localization)
        }
    }

    private func isCurrentOperation(_ operationID: UUID) -> Bool {
        currentOperationID == operationID
    }

    /// Result no longer matches the current scope. The purge segment therefore also prompts "please rescan" after roots change—
    /// same idea as changing groups on the rules segment.
    private func isStale(
        scanResult: DiskCleanScanResult?,
        scope: DiskCleanScanScope
    ) -> Bool {
        guard let scanResult else { return false }
        return scanResult.scope != scope
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
