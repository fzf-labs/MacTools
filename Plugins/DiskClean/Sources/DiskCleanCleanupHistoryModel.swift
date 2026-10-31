import Combine
import Foundation
import MacToolsPluginKit

@MainActor
final class DiskCleanCleanupHistoryModel: ObservableObject {
    @Published private(set) var entries: [DiskCleanCleanupHistoryEntry] = []
    @Published private(set) var runs: [DiskCleanRunHistoryEntry] = []
    @Published private(set) var isLoading = false
    private let provider: any DiskCleanCleanupHistoryProviding
    private var generation = UUID()

    init(provider: any DiskCleanCleanupHistoryProviding) { self.provider = provider }

    func reload() async {
        let id = UUID()
        generation = id
        isLoading = true
        async let items = provider.recentEntries(limit: 100)
        async let operations = provider.recentRuns(limit: 100)
        let (newEntries, newRuns) = await (items, operations)
        guard generation == id else { return }
        isLoading = false
        guard !Task.isCancelled else { return }
        entries = newEntries.filter(\.needsAttention) + newEntries.filter { !$0.needsAttention }
        runs = newRuns.filter(\.needsAttention) + newRuns.filter { !$0.needsAttention }
    }
}

struct DiskCleanHistoryReloadToken: Equatable {
    var results: [DiskCleanExecutionResult?] = []
    var isCleanupReady = true
}

enum DiskCleanHistorySearch {
    static func matches(_ entry: DiskCleanCleanupHistoryEntry, query: String, localization: PluginLocalization) -> Bool {
        contains(query, in: [entry.path, entry.stagedName, entry.errorMessage, entry.status.title(localization: localization)])
    }

    static func matches(_ run: DiskCleanRunHistoryEntry, query: String, localization: PluginLocalization) -> Bool {
        contains(query, in: [run.statusTitle(localization: localization), DiskCleanFormat.timestamp(run.timestamp)]
            + run.categoryTitles(localization: localization) + run.errorsEncountered)
            || run.itemEntries.contains { matches($0, query: query, localization: localization) }
    }

    private static func contains(_ query: String, in values: [String?]) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || values.compactMap { $0 }.contains { $0.localizedStandardContains(query) }
    }
}
