import Foundation
import XCTest
import MacToolsPluginKit
@testable import DiskCleanPlugin

@MainActor
final class DiskCleanCleanupHistoryModelTests: XCTestCase {
    func testOlderReadCannotReplaceTheLatestHistorySnapshot() async {
        let provider = DelayedCleanupHistoryProvider()
        let model = DiskCleanCleanupHistoryModel(provider: provider)
        let first = Task { await model.reload() }
        await provider.waitForFirstRead()
        await model.reload()
        XCTAssertEqual(model.entries.map(\.path), ["/new/cache"])
        await provider.finishFirstRead()
        await first.value
        XCTAssertEqual(model.entries.map(\.path), ["/new/cache"])
        XCTAssertFalse(model.isLoading)
    }

    func testSearchFindsRecoveryPathsStagedNamesAndErrorsInsideRunDetails() {
        let localization = PluginLocalization(bundle: .main)
        let item = DiskCleanCleanupHistoryEntry(id: 1, timestamp: .distantPast, status: .rollbackBlocked,
            path: "/Users/Fixture/Library/Caches/Example", stagedName: ".mactools-staged-recovery",
            estimatedBytes: 42, errorMessage: "Permission denied")
        let run = DiskCleanRunHistoryEntry(id: "run", timestamp: .distantPast, isTrash: true, status: "completedWithErrors",
            categoriesCleaned: [], itemsRemoved: 0, bytesRemoved: 0, needsAttention: true, itemEntries: [item])
        for query in ["example", "STAGED-recovery", "permission", "  "] {
            XCTAssertTrue(DiskCleanHistorySearch.matches(item, query: query, localization: localization))
            XCTAssertTrue(DiskCleanHistorySearch.matches(run, query: query, localization: localization))
        }
        XCTAssertFalse(DiskCleanHistorySearch.matches(item, query: "unrelated", localization: localization))
        XCTAssertFalse(DiskCleanHistorySearch.matches(run, query: "unrelated", localization: localization))
        XCTAssertTrue(item.needsAttention)
        XCTAssertTrue(run.needsAttention)
    }
}

private actor DelayedCleanupHistoryProvider: DiskCleanCleanupHistoryProviding {
    private var reads = 0
    private var pending: CheckedContinuation<[DiskCleanCleanupHistoryEntry], Never>?
    private var ready: CheckedContinuation<Void, Never>?

    func recentEntries(limit: Int) async -> [DiskCleanCleanupHistoryEntry] {
        reads += 1
        if reads == 1 {
            return await withCheckedContinuation { continuation in
                pending = continuation
                ready?.resume()
                ready = nil
            }
        }
        return [entry("/new/cache")]
    }
    func recentRuns(limit: Int) async -> [DiskCleanRunHistoryEntry] { [] }
    func waitForFirstRead() async {
        if pending != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func finishFirstRead() {
        pending?.resume(returning: [entry("/old/cache")])
        pending = nil
    }
    private func entry(_ path: String) -> DiskCleanCleanupHistoryEntry {
        .init(id: 1, timestamp: .distantPast, status: .ok, path: path, stagedName: nil, estimatedBytes: 42, errorMessage: nil)
    }
}
