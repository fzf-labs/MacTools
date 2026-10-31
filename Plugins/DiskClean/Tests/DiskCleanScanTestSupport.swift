import Foundation
import os
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DiskCleanPlugin

// MARK: - Result and identity factories

extension DiskCleanRootIdentity {
    static func test(
        devid: UInt64 = 1,
        fileID: UInt64 = 2,
        mtime: Date = Date(timeIntervalSince1970: 1_000),
        fileType: DiskCleanRootIdentity.FileType = .directory
    ) -> DiskCleanRootIdentity {
        DiskCleanRootIdentity(devid: devid, fileID: fileID, mtime: mtime, fileType: fileType)
    }
}

extension DiskCleanSizeResult {
    static func testComplete(
        bytes: Int64 = 100,
        fileCount: Int = 1,
        identity: DiskCleanRootIdentity = .test(),
        observedAt: Date = Date(timeIntervalSince1970: 10_000)
    ) -> DiskCleanSizeResult {
        DiskCleanSizeResult(
            estimatedBytes: bytes,
            fileCount: fileCount,
            completeness: .complete,
            rootIdentity: identity,
            observedAt: observedAt
        )
    }

    static func testPartial(
        reasons: Set<DiskCleanScanCompleteness.PartialReason>,
        bytes: Int64 = 0,
        identity: DiskCleanRootIdentity? = nil,
        observedAt: Date = Date(timeIntervalSince1970: 10_000)
    ) -> DiskCleanSizeResult {
        DiskCleanSizeResult(
            estimatedBytes: bytes,
            fileCount: 0,
            completeness: .partial(reasons: reasons),
            rootIdentity: identity,
            observedAt: observedAt
        )
    }
}

extension DiskCleanFileItem {
    static func testDirectory(_ path: String) -> DiskCleanFileItem {
        DiskCleanFileItem(path: path, isDirectory: true, isSymlink: false, resolvedSymlinkTarget: nil)
    }

    static func testFile(_ path: String) -> DiskCleanFileItem {
        DiskCleanFileItem(path: path, isDirectory: false, isSymlink: false, resolvedSymlinkTarget: nil)
    }
}

extension DiskCleanRuleTarget {
    /// P2 synthetic target. `external` is mutually exclusive with glob/provider, so a dedicated factory rather than another parameter.
    static func testExternal(
        id: String,
        category: DiskCleanCategoryID = .developerArtifacts,
        risk: DiskCleanRisk = .medium,
        reservedRootPaths: [String] = []
    ) -> DiskCleanRuleTarget {
        DiskCleanRuleTarget(
            id: id,
            legacyRuleID: id,
            category: category,
            risk: risk,
            kind: .external,
            reservedRootPaths: reservedRootPaths
        )
    }

    static func test(
        id: String,
        legacyRuleID: String? = nil,
        category: DiskCleanCategoryID = .appCaches,
        risk: DiskCleanRisk = .low,
        globs: [String] = [],
        provider: (any DiskCleanDynamicRuleProviding)? = nil,
        reservedRootPaths: [String] = ["/reserved"],
        requiresFullDiskAccess: Bool = false,
        lockedByBundleIDs: [String] = [],
        skipWhenProcessIsRunning: [String] = []
    ) -> DiskCleanRuleTarget {
        DiskCleanRuleTarget(
            id: id,
            legacyRuleID: legacyRuleID ?? id,
            category: category,
            risk: risk,
            kind: provider.map { DiskCleanRuleTarget.Kind.dynamic(provider: $0) } ?? .path(globs: globs),
            reservedRootPaths: reservedRootPaths,
            requiresFullDiskAccess: requiresFullDiskAccess,
            lockedByBundleIDs: lockedByBundleIDs,
            skipWhenProcessIsRunning: skipWhenProcessIsRunning
        )
    }
}

// MARK: - Programmable filesystem

/// Pure in-memory filesystem. Engine expansion only needs "glob → hits" and "path → direct children" tables.
final class FakeDiskCleanFileSystem: DiskCleanFileSystemProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var itemsByPattern: [String: [DiskCleanFileItem]] = [:]
    private var childrenByPath: [String: [DiskCleanFileItem]] = [:]
    private var patternErrors: [String: Error] = [:]
    private var unlistablePaths: Set<String> = []

    func setItems(_ items: [DiskCleanFileItem], forPattern pattern: String) {
        lock.withLock { itemsByPattern[pattern] = items }
    }

    func setChildren(_ children: [DiskCleanFileItem], of path: String) {
        lock.withLock { childrenByPath[path] = children }
    }

    func setError(_ error: Error, forPattern pattern: String) {
        lock.withLock { patternErrors[pattern] = error }
    }

    func markUnlistable(_ path: String) {
        lock.withLock { _ = unlistablePaths.insert(path) }
    }

    func expandPathPattern(_ pattern: String) throws -> [DiskCleanFileItem] {
        let (items, error) = lock.withLock { (itemsByPattern[pattern] ?? [], patternErrors[pattern]) }
        if let error { throw error }
        return items
    }

    func itemInfo(at path: String) throws -> DiskCleanFileItem? {
        lock.withLock { itemsByPattern.values.flatMap { $0 }.first { $0.path == path } }
    }

    func directChildren(of path: String) throws -> [DiskCleanFileItem] {
        let (children, isUnlistable) = lock.withLock {
            (childrenByPath[path] ?? [], unlistablePaths.contains(path))
        }
        if isUnlistable { throw FakeFileSystemError.unlistable(path) }
        return children
    }

    func removeItem(at path: String) throws {}

    func deduplicatedParentChildPaths(_ paths: [String]) -> [String] {
        paths
    }

    enum FakeFileSystemError: Error, Equatable {
        case unlistable(String)
    }
}

struct FakeDiskCleanExpansionError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

struct FakeFailingDynamicRuleProvider: DiskCleanDynamicRuleProviding {
    let error: Error

    init(error: Error = FakeDiskCleanExpansionError(message: "provider exploded")) {
        self.error = error
    }

    func expand() async throws -> [DiskCleanFileItem] {
        throw error
    }
}

struct FakeStaticDynamicRuleProvider: DiskCleanDynamicRuleProviding {
    let items: [DiskCleanFileItem]

    func expand() async throws -> [DiskCleanFileItem] {
        items
    }
}

// MARK: - Sizing execution seam

/// Programmable sizing executor: records concurrency peak, request order, and deadlines; can inject delay and circuit-break state.
///
/// No real threads, so concurrency limits test the **engine TaskGroup sliding window**, not WorkerPool thread count.
final class FakeDiskCleanSizingExecutor: DiskCleanSizingExecuting, @unchecked Sendable {
    private struct State {
        var resultsByPath: [String: DiskCleanSizeResult] = [:]
        var defaultResult: DiskCleanSizeResult = .testComplete()
        var requestedPaths: [String] = []
        var deadlines: [Date] = []
        var active = 0
        var peakConcurrency = 0
        var isCircuitBroken = false
        var abandonedThreads = 0
    }

    private let lock = NSLock()
    private var state = State()
    /// Artificial per-call delay so concurrent tasks actually overlap.
    let delay: Duration?

    init(delay: Duration? = nil) {
        self.delay = delay
    }

    func setResult(_ result: DiskCleanSizeResult, forPath path: String) {
        lock.withLock { state.resultsByPath[path] = result }
    }

    func setDefaultResult(_ result: DiskCleanSizeResult) {
        lock.withLock { state.defaultResult = result }
    }

    func setPoolState(isCircuitBroken: Bool, abandonedThreads: Int) {
        lock.withLock {
            state.isCircuitBroken = isCircuitBroken
            state.abandonedThreads = abandonedThreads
        }
    }

    var requestedPaths: [String] { lock.withLock { state.requestedPaths } }
    var deadlines: [Date] { lock.withLock { state.deadlines } }
    var peakConcurrency: Int { lock.withLock { state.peakConcurrency } }
    var isCircuitBroken: Bool { lock.withLock { state.isCircuitBroken } }
    var abandonedThreads: Int { lock.withLock { state.abandonedThreads } }

    func size(
        ofItemAt path: String,
        using sizer: any DiskCleanDirectorySizing,
        deadline: Date
    ) async -> DiskCleanSizeResult {
        lock.withLock {
            state.requestedPaths.append(path)
            state.deadlines.append(deadline)
            state.active += 1
            state.peakConcurrency = max(state.peakConcurrency, state.active)
        }
        if let delay {
            try? await Task.sleep(for: delay)
        }
        return lock.withLock {
            state.active -= 1
            return state.resultsByPath[path] ?? state.defaultResult
        }
    }
}

/// Runs the sizer on the caller thread, not a pool. Used to verify engine and cache-decorator wiring.
///
/// `now` is injected separately: the real sizing-context clock belongs to WorkerPool (the engine cannot pass its own),
/// so TTL tests must supply time in the same coordinate system as the cache write.
struct DirectDiskCleanSizingExecutor: DiskCleanSizingExecuting {
    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    var isCircuitBroken: Bool { false }
    var abandonedThreads: Int { 0 }

    func size(
        ofItemAt path: String,
        using sizer: any DiskCleanDirectorySizing,
        deadline: Date
    ) async -> DiskCleanSizeResult {
        sizer.size(
            ofItemAt: path,
            context: DiskCleanSizingContext(deadline: deadline, now: now)
        )
    }
}

/// Path-keyed sizer that returns preset results and records paths actually invoked (cache hits should not call it).
final class FakeDiskCleanSizer: DiskCleanDirectorySizing, @unchecked Sendable {
    private let lock = NSLock()
    private var resultsByPath: [String: DiskCleanSizeResult] = [:]
    private var invokedPaths: [String] = []
    /// Blocking duration. Verifies the real timeout path "item deadline expires → partial([.timedOut])".
    let blockingDuration: TimeInterval

    init(blockingDuration: TimeInterval = 0) {
        self.blockingDuration = blockingDuration
    }

    func setResult(_ result: DiskCleanSizeResult, forPath path: String) {
        lock.withLock { resultsByPath[path] = result }
    }

    var calledPaths: [String] { lock.withLock { invokedPaths } }

    func size(ofItemAt path: String, context: DiskCleanSizingContext) -> DiskCleanSizeResult {
        lock.withLock { invokedPaths.append(path) }
        if blockingDuration > 0 {
            Thread.sleep(forTimeInterval: blockingDuration)
        }
        return lock.withLock { resultsByPath[path] } ?? .testComplete()
    }
}

struct FakeDiskCleanRootIdentityProbe: DiskCleanRootIdentityProbing {
    let identitiesByPath: [String: DiskCleanRootIdentity]

    func identity(ofItemAt path: String) -> DiskCleanRootIdentity? {
        identitiesByPath[path]
    }
}

// MARK: - Running-app snapshot

struct FakeDiskCleanRunningAppLock: DiskCleanRunningAppSnapshotting {
    let snapshot: DiskCleanRunningAppSnapshot

    init(snapshot: DiskCleanRunningAppSnapshot = DiskCleanRunningAppSnapshot()) {
        self.snapshot = snapshot
    }

    func makeSnapshot(processNames: [String]) async -> DiskCleanRunningAppSnapshot {
        snapshot
    }
}

struct FakeDiskCleanFullDiskAccess: DiskCleanFullDiskAccessProbing {
    let hasFullDiskAccess: Bool
}

/// Programmable file-readability probe. Authorization-matrix tests never touch real TCC-protected files.
struct FakeDiskCleanFileReadability: DiskCleanFileReadabilityProbing {
    /// Set of openable paths. Anything outside is "cannot open", covering both denied and missing files —
    /// the probe itself does not distinguish (neither proves FDA).
    let openablePaths: Set<String>
    /// Records probe order to assert "stop after the first success".
    private let probed = OSAllocatedUnfairLock<[String]>(initialState: [])

    init(openablePaths: Set<String> = []) {
        self.openablePaths = openablePaths
    }

    var probedPaths: [String] { probed.withLock { $0 } }

    func canOpenForReading(atPath path: String) -> Bool {
        probed.withLock { $0.append(path) }
        return openablePaths.contains(path)
    }
}

// MARK: - P2 expansion seam

/// Programmable non-rule expansion source. Lets P2 candidates run the full pipeline without touching the filesystem.
struct FakeDiskCleanExternalExpansion: DiskCleanExternalExpanding {
    var hits: [DiskCleanTargetHit] = []
    var reservedRootPaths: [String] = []
    var limitations: [DiskCleanScanLimitation] = []
    var logMessages: [DiskCleanScanLogMessage] = []

    func expand(
        scope: DiskCleanScanScope,
        catalog: DiskCleanRuleCatalogV2,
        localization: PluginLocalization
    ) async -> DiskCleanExternalExpansion {
        var expansion = DiskCleanExternalExpansion()
        expansion.hits = hits
        expansion.reservedRootPaths = reservedRootPaths
        expansion.limitations = limitations
        expansion.logMessages = logMessages
        return expansion
    }
}

// MARK: - Subprocess seam

/// Programmable subprocess: records call args and returns output or throws on demand.
final class FakeDiskCleanSubprocessRunner: DiskCleanSubprocessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executablePath: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recordedInvocations: [Invocation] = []
    private let result: Result<DiskCleanSubprocessResult, Error>

    init(exitCode: Int32 = 0, standardOutput: String = "") {
        self.result = .success(
            DiskCleanSubprocessResult(
                exitCode: exitCode,
                standardOutput: Data(standardOutput.utf8)
            )
        )
    }

    init(error: Error) {
        self.result = .failure(error)
    }

    var invocations: [Invocation] { lock.withLock { recordedInvocations } }

    func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration
    ) async throws -> DiskCleanSubprocessResult {
        lock.withLock {
            recordedInvocations.append(Invocation(executablePath: executablePath, arguments: arguments))
        }
        return try result.get()
    }
}

// MARK: - Test clock

/// Manually advanced clock. Expiry gates are time-driven; tests must drive the transition without waiting 300s.
final class TestDiskCleanClock: DiskCleanClock, @unchecked Sendable {
    private struct Waiter {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Date
    private var waiters: [Waiter] = []

    init(now: Date = Date(timeIntervalSince1970: 10_000)) {
        self.current = now
    }

    var now: Date { lock.withLock { current } }

    func sleep(until deadline: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let shouldResumeImmediately = lock.withLock { () -> Bool in
                guard current < deadline else { return true }
                waiters.append(Waiter(deadline: deadline, continuation: continuation))
                return false
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }

    func advance(by interval: TimeInterval) {
        advance(to: now.addingTimeInterval(interval))
    }

    func advance(to date: Date) {
        let due = lock.withLock { () -> [Waiter] in
            current = date
            let due = waiters.filter { $0.deadline <= date }
            waiters.removeAll { $0.deadline <= date }
            return due
        }
        for waiter in due {
            waiter.continuation.resume()
        }
    }
}

// MARK: - Controlled engine

/// Test-driven event stream for operationID generations, throttled publish, and expiry clocks —
/// behaviors that depend on still being unfinished at a precise moment.
final class ControlledDiskCleanScanEngine: DiskCleanScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<DiskCleanScanEvent, Error>.Continuation?
    private var scanCalls: [(scope: DiskCleanScanScope, forceRefresh: Bool)] = []
    private var isTerminated = false

    var scanCallCount: Int { lock.withLock { scanCalls.count } }
    var lastForceRefresh: Bool? { lock.withLock { scanCalls.last?.forceRefresh } }
    var lastScope: DiskCleanScanScope? { lock.withLock { scanCalls.last?.scope } }
    var lastChoices: Set<DiskCleanChoice>? { lock.withLock { scanCalls.last?.scope.choices } }
    var didTerminate: Bool { lock.withLock { isTerminated } }

    func scan(
        scope: DiskCleanScanScope,
        forceRefresh: Bool
    ) -> AsyncThrowingStream<DiskCleanScanEvent, Error> {
        lock.withLock {
            scanCalls.append((scope: scope, forceRefresh: forceRefresh))
            isTerminated = false
        }
        return AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.isTerminated = true }
            }
        }
    }

    func emit(_ event: DiskCleanScanEvent) {
        lock.withLock { continuation }?.yield(event)
    }

    func finish() {
        lock.withLock { continuation }?.finish()
    }

    func fail(with error: Error) {
        lock.withLock { continuation }?.finish(throwing: error)
    }
}

/// Call-recording executor fake. The executor only accepts `ValidatedPlan`, so the fake records received plans.
final class FakeDiskCleanExecutor: DiskCleanExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [DiskCleanValidatedPlan] = []
    private var failure: Error?
    private let result: DiskCleanExecutionResult?

    init(failure: Error? = nil, result: DiskCleanExecutionResult? = nil) {
        self.failure = failure
        self.result = result
    }

    var callCount: Int { lock.withLock { plans.count } }
    var lastPlan: DiskCleanValidatedPlan? { lock.withLock { plans.last } }
    var lastSelectedIDs: Set<DiskCleanCandidate.ID>? {
        lock.withLock { plans.last.map { Set($0.items.map(\.candidateID)) } }
    }
    var lastMode: DiskCleanRemovalMode? { lock.withLock { plans.last?.mode } }

    func execute(plan: DiskCleanValidatedPlan) async throws -> DiskCleanExecutionResult {
        let failure = lock.withLock { () -> Error? in
            plans.append(plan)
            return self.failure
        }
        if let failure { throw failure }
        if let result { return result }
        return DiskCleanExecutionResult(
            itemResults: plan.items.map {
                DiskCleanExecutionItemResult(
                    candidateID: $0.candidateID,
                    path: $0.path,
                    outcome: plan.mode == .trash
                        ? .trashed(reclaimedBytes: $0.estimatedBytes, stagedName: ".mactools-staged-test")
                        : .removed(reclaimedBytes: $0.estimatedBytes)
                )
            },
            mode: plan.mode
        )
    }
}

/// In-memory removal-mode store. Real implementation writes `UserDefaults`; tests never touch user prefs.
final class InMemoryDiskCleanRemovalModeStore: DiskCleanRemovalModeStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var mode: DiskCleanRemovalMode

    init(mode: DiskCleanRemovalMode = .trash) {
        self.mode = mode
    }

    var savedMode: DiskCleanRemovalMode { lock.withLock { mode } }

    func load() -> DiskCleanRemovalMode { lock.withLock { mode } }

    func save(_ mode: DiskCleanRemovalMode) {
        lock.withLock { self.mode = mode }
    }
}

// MARK: - Async assertion helpers

/// Poll until a condition holds. Async state transitions (throttled publish, expiry tasks) cannot be asserted with fixed sleeps.
@MainActor
func waitUntil(
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ description: String,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("wait timed out: \(description)", file: file, line: line)
}
