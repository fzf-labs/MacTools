import SwiftUI
import MacToolsPluginKit

// MARK: - History entry

/// Status of a cleanup history entry.
///
/// Domain matches the `status` strings written to the audit log (`DiskCleanExecutor.status(of:)` and
/// `DiskCleanStagingReconciler.record(for:)`). Parse rather than display the raw string because
/// "which statuses need a pinned alert" is a product decision that needs a single home.
enum DiskCleanCleanupHistoryStatus: Equatable, Sendable {
    case ok
    case skipped
    case changedSinceScan
    case failed
    case partiallyDeleted
    case rollbackBlocked
    case reconciledRolledBack
    case reconciledAbsent
    case reconcileFailed
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "ok":
            self = .ok
        case "skipped":
            self = .skipped
        case "changedSinceScan":
            self = .changedSinceScan
        case "failed":
            self = .failed
        case "partiallyDeleted", "irreversibleStagedRetained":
            self = .partiallyDeleted
        case "rollbackBlocked":
            self = .rollbackBlocked
        case "reconciledRolledBack":
            self = .reconciledRolledBack
        // A missing parent directory and a missing staged object reach the same conclusion: nothing left to restore.
        case "reconciledAbsent", "reconciledParentMissing":
            self = .reconciledAbsent
        case "reconcileFailed":
            self = .reconcileFailed
        default:
            self = .unknown(rawValue)
        }
    }

    /// Honest terminal statuses that need a pinned alert (design §7.5, §13-M4-6).
    ///
    /// What they share: the disk still holds a staged object the user may not know about, or a deletion only finished halfway.
    /// Ordinary `failed`/`skipped` leave no residue and need not interrupt the user.
    var needsAttention: Bool {
        switch self {
        case .partiallyDeleted, .rollbackBlocked, .reconcileFailed:
            return true
        case .ok, .skipped, .changedSinceScan, .failed,
             .reconciledRolledBack, .reconciledAbsent, .unknown:
            return false
        }
    }

    var symbolName: String {
        switch self {
        case .ok:
            return "checkmark.circle.fill"
        case .skipped, .changedSinceScan:
            return "minus.circle"
        case .failed:
            return "xmark.circle"
        case .partiallyDeleted, .rollbackBlocked, .reconcileFailed:
            return "exclamationmark.triangle.fill"
        case .reconciledRolledBack:
            return "arrow.uturn.backward.circle"
        case .reconciledAbsent:
            return "circle"
        case .unknown:
            return "circle"
        }
    }

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .ok:
            return localization.string("history.status.ok", defaultValue: "已清理")
        case .skipped:
            return localization.string("history.status.skipped", defaultValue: "已跳过")
        case .changedSinceScan:
            return localization.string("history.status.changed", defaultValue: "内容已变化")
        case .failed:
            return localization.string("history.status.failed", defaultValue: "失败")
        case .partiallyDeleted:
            return localization.string("history.status.partiallyDeleted", defaultValue: "只删除了一部分")
        case .rollbackBlocked:
            return localization.string("history.status.rollbackBlocked", defaultValue: "无法放回原处")
        case .reconciledRolledBack:
            return localization.string("history.status.reconciledRolledBack", defaultValue: "启动时已放回")
        case .reconciledAbsent:
            return localization.string("history.status.reconciledAbsent", defaultValue: "上次已完成")
        case .reconcileFailed:
            return localization.string("history.status.reconcileFailed", defaultValue: "未完成，待处理")
        case let .unknown(rawValue):
            return rawValue
        }
    }
}

/// One cleanup history row. A display projection of an audit record.
struct DiskCleanCleanupHistoryEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let timestamp: Date
    let status: DiskCleanCleanupHistoryStatus
    let path: String?
    /// Staged name. In Trash mode, "Put Back" lands under this name, so it must be shown (design §7.4).
    let stagedName: String?
    let estimatedBytes: Int64?
    let errorMessage: String?

    var needsAttention: Bool { status.needsAttention }

    /// Audit record → display entry. **Attention-needed rows are pinned** (design §13-M4-6); the rest stay reverse-chronological.
    ///
    /// Pin rather than only tint red: `partiallyDeleted` / `rollbackBlocked` mean residue remains on disk;
    /// burying them among 200 history rows is the same as not saying it.
    static func entries(from records: [DiskCleanAuditLog.Record]) -> [DiskCleanCleanupHistoryEntry] {
        let entries = records.enumerated().map { index, record in
            DiskCleanCleanupHistoryEntry(
                id: index,
                timestamp: record.timestamp,
                status: DiskCleanCleanupHistoryStatus(rawValue: record.status),
                path: record.path,
                stagedName: record.stagedName,
                estimatedBytes: record.estimatedBytes,
                errorMessage: record.error
            )
        }
        return entries.filter(\.needsAttention) + entries.filter { !$0.needsAttention }
    }
}

// MARK: - Loading

/// Read seam for cleanup history. The audit log is on disk; loading must not block the main thread.
protocol DiskCleanCleanupHistoryProviding: Sendable {
    func recentEntries(limit: Int) async -> [DiskCleanCleanupHistoryEntry]
    func recentRuns(limit: Int) async -> [DiskCleanRunHistoryEntry]
}

extension DiskCleanCleanupHistoryProviding {
    func recentRuns(limit: Int) async -> [DiskCleanRunHistoryEntry] {
        []
    }
}

struct DiskCleanAuditLogHistoryProvider: DiskCleanCleanupHistoryProviding {
    let directory: URL

    func recentEntries(limit: Int) async -> [DiskCleanCleanupHistoryEntry] {
        let directory = directory
        let records = await Task.detached(priority: .utility) {
            DiskCleanAuditLog(directory: directory).recentRecords(limit: limit, excludingRunSummaries: true)
        }.value
        return DiskCleanCleanupHistoryEntry.entries(from: records)
    }

    func recentRuns(limit: Int) async -> [DiskCleanRunHistoryEntry] {
        let directory = directory
        return await Task.detached(priority: .utility) {
            DiskCleanAuditLog(directory: directory).recentRuns(limit: limit)
        }.value
    }
}

// MARK: - View

/// A visible, searchable history workspace; attention records remain pinned before filtering.
struct DiskCleanCleanupHistorySection: View {
    let localization: PluginLocalization
    let reloadToken: DiskCleanHistoryReloadToken
    @StateObject private var model: DiskCleanCleanupHistoryModel
    @State private var viewMode: HistoryViewMode = .runs
    @State private var query = ""
    @State private var isCopied = false

    private enum HistoryViewMode { case runs, items }

    init(provider: any DiskCleanCleanupHistoryProviding, localization: PluginLocalization,
         reloadToken: DiskCleanHistoryReloadToken) {
        self.localization = localization
        self.reloadToken = reloadToken
        _model = StateObject(wrappedValue: DiskCleanCleanupHistoryModel(provider: provider))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if attentionCount > 0 { attentionBanner; Divider() }
            if model.isLoading && !hasRecords {
                VStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    ProgressView().controlSize(.small)
                    Text(copy("detail.history.loading", "正在读取记录…"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasRecords {
                emptyState(copy("detail.history.empty", "还没有清理记录"), symbol: "clock.arrow.circlepath")
            } else if (viewMode == .runs && filteredRuns.isEmpty) || (viewMode == .items && filteredEntries.isEmpty) {
                VStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon)).foregroundStyle(.secondary)
                    Text(copy("settings.noMatchingRecords", "未找到匹配记录"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    Button(copy("settings.clearSearch", "清除搜索")) { query = "" }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(PluginSettingsTheme.Spacing.rowVertical)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if viewMode == .runs {
                            ForEach(filteredRuns) { run in
                                DiskCleanRunHistoryRow(run: run, localization: localization, expandsMatches: !query.isEmpty)
                                if run.id != filteredRuns.last?.id { PluginSettingsListDivider() }
                            }
                        } else {
                            ForEach(filteredEntries) { entry in
                                DiskCleanCleanupHistoryRow(entry: entry, localization: localization)
                                if entry.id != filteredEntries.last?.id { PluginSettingsListDivider() }
                            }
                        }
                    }
                }
            }
        }
        .frame(minHeight: 160, maxHeight: .infinity)
        .pluginSettingsCardBackground(.standard)
        .task(id: reloadToken) { await reload() }
        .task(id: isCopied) {
            guard isCopied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            isCopied = false
        }
    }

    private var hasRecords: Bool { !model.entries.isEmpty || !model.runs.isEmpty }
    private var filteredRuns: [DiskCleanRunHistoryEntry] {
        model.runs.filter { DiskCleanHistorySearch.matches($0, query: query, localization: localization) }
    }
    private var filteredEntries: [DiskCleanCleanupHistoryEntry] {
        model.entries.filter { DiskCleanHistorySearch.matches($0, query: query, localization: localization) }
    }
    private var attentionCount: Int {
        viewMode == .runs ? model.runs.filter(\.needsAttention).count : model.entries.filter(\.needsAttention).count
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                displayPicker
                if hasRecords { searchField }
                Spacer(minLength: 0)
                toolbarActions
            }
            VStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                HStack { displayPicker; Spacer(minLength: 0); toolbarActions }
                if hasRecords { searchField }
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var displayPicker: some View {
        Picker(copy("settings.historyDisplay", "显示方式"), selection: $viewMode) {
            Text(copy("settings.historyRuns", "按次汇总")).tag(HistoryViewMode.runs)
            Text(copy("settings.historyItems", "文件明细")).tag(HistoryViewMode.items)
        }
        .labelsHidden().controlSize(.small).fixedSize(horizontal: true, vertical: false)
        .disabled(!hasRecords)
    }

    private var searchField: some View {
        TextField(copy("settings.searchRecords", "搜索记录"), text: $query)
            .textFieldStyle(.roundedBorder).controlSize(.small)
            .frame(minWidth: 140, idealWidth: 200, maxWidth: .infinity)
            .accessibilityLabel(copy("settings.searchRecords", "搜索记录"))
            .onExitCommand { query = "" }
    }

    private var toolbarActions: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            if model.isLoading { ProgressView().controlSize(.small) }
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(model.isLoading)
                .help(copy("detail.history.reload", "刷新")).accessibilityLabel(copy("detail.history.reload", "刷新"))
            Menu {
                Button(copy("detail.history.copyDiagnostics", "复制诊断信息"), systemImage: "doc.on.doc") { copyDiagnostics() }
                    .disabled(model.isLoading || !hasRecords)
            } label: { Image(systemName: isCopied ? "checkmark" : "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(isCopied ? copy("detail.history.diagnosticsCopied", "已复制诊断信息") : copy("settings.moreActions", "更多操作"))
            .accessibilityLabel(copy("settings.moreActions", "更多操作"))
        }
        .font(PluginSettingsTheme.Typography.controlLabel)
    }

    private var attentionBanner: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Label(localization.format("settings.attentionRecords", defaultValue: "%d 条记录需要关注", attentionCount), systemImage: "exclamationmark.triangle.fill")
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.orange)
            Spacer(minLength: 0)
            Button(copy("settings.viewAttention", "查看")) {
                query = ""
                if model.entries.contains(where: \.needsAttention) { viewMode = .items }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .pluginSettingsListRowPadding()
    }

    private func emptyState(_ title: String, symbol: String) -> some View {
        VStack(spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Image(systemName: symbol).font(.system(size: PluginSettingsTheme.Size.emptyStateIcon))
            Text(title).font(PluginSettingsTheme.Typography.rowDescription)
        }
        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
    }

    private func reload() async {
        await model.reload()
        if model.runs.isEmpty && !model.entries.isEmpty { viewMode = .items }
    }

    private func copyDiagnostics() {
        let home = NSHomeDirectory()
        var lines = ["=== DiskClean Cleanup History Diagnostics ==="]
        for run in model.runs {
            let mode = run.isRecovery ? "Recovery" : (run.isTrash ? "Trash" : "Permanent")
            lines.append("Run [\(DiskCleanFormat.timestamp(run.timestamp))] Status: \(run.status), Mode: \(mode), Removed: \(run.itemsRemoved) items (\(run.bytesRemoved) bytes), Categories: \(run.categoriesCleaned.joined(separator: ", "))")
            for error in run.errorsEncountered { lines.append("  Error: " + error.replacingOccurrences(of: home, with: "~")) }
        }
        lines.append("\n=== Recent Items ===")
        for entry in model.entries.prefix(50) {
            lines.append("[\(entry.timestamp)] \((entry.path ?? "nil").replacingOccurrences(of: home, with: "~")) - Status: \(entry.status.symbolName) - \(entry.estimatedBytes ?? 0) bytes")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        isCopied = true
    }

    private func copy(_ key: String, _ fallback: String) -> String { localization.string(key, defaultValue: fallback) }
}

private struct DiskCleanCleanupHistoryRow: View {
    let entry: DiskCleanCleanupHistoryEntry
    let localization: PluginLocalization

    var body: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: entry.status.symbolName)
                .foregroundStyle(entry.needsAttention ? Color.orange : Color.secondary)
                .frame(width: PluginSettingsTheme.Size.rowIcon)
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? entry.status.title(localization: localization))
                        .font(PluginSettingsTheme.Typography.rowTitle).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let bytes = entry.estimatedBytes {
                        Text(DiskCleanFormat.approximateBytes(bytes, localization: localization))
                            .font(PluginSettingsTheme.Typography.monospacedValue).foregroundStyle(.secondary)
                    }
                }
                if let path = entry.path {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(path).textSelection(.enabled)
                }
                Text(entry.status.title(localization: localization) + " · " + DiskCleanFormat.timestamp(entry.timestamp))
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(entry.needsAttention ? Color.orange : Color.secondary)
                if let stagedName = entry.stagedName {
                    Text(localization.format("detail.history.stagedName", defaultValue: "暂存名：%@", stagedName))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(stagedName).textSelection(.enabled)
                }
                if let error = entry.errorMessage {
                    Text(error).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.orange)
                        .lineLimit(2).help(error).textSelection(.enabled)
                }
            }
        }
        .pluginSettingsListRowPadding()
    }
}

private struct DiskCleanRunHistoryRow: View {
    let run: DiskCleanRunHistoryEntry
    let localization: PluginLocalization
    let expandsMatches: Bool
    @State private var isExpanded: Bool

    init(run: DiskCleanRunHistoryEntry, localization: PluginLocalization, expandsMatches: Bool) {
        self.run = run
        self.localization = localization
        self.expandsMatches = expandsMatches
        _isExpanded = State(initialValue: expandsMatches || run.itemEntries.contains(where: \.needsAttention))
    }

    var body: some View {
        Group {
            if run.itemEntries.isEmpty { summary }
            else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    LazyVStack(spacing: 0) {
                        ForEach(run.itemEntries) { entry in
                            DiskCleanCleanupHistoryRow(entry: entry, localization: localization)
                            if entry.id != run.itemEntries.last?.id { PluginSettingsListDivider() }
                        }
                    }
                    .padding(.leading, PluginSettingsTheme.Spacing.rowHorizontal)
                } label: { summary }
                .padding(.leading, PluginSettingsTheme.Spacing.controlCluster)
            }
        }
        .onChange(of: expandsMatches) { _, expands in if expands { isExpanded = true } }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: run.symbolName)
                .foregroundStyle(run.needsAttention ? Color.orange : (run.isSuccessful ? Color.green : Color.secondary))
                .frame(width: PluginSettingsTheme.Size.rowIcon)
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                HStack(alignment: .firstTextBaseline) {
                    Text(run.isRecovery ? localization.string("detail.history.mode.recovery", defaultValue: "恢复检查")
                        : run.isTrash ? localization.string("detail.action.trash", defaultValue: "移到废纸篓")
                        : localization.string("detail.removalMode.permanent", defaultValue: "永久删除"))
                        .font(PluginSettingsTheme.Typography.rowTitle).lineLimit(1)
                    Spacer(minLength: 0)
                    if !run.isRecovery {
                        Text(DiskCleanFormat.approximateBytes(run.bytesRemoved, localization: localization))
                            .font(PluginSettingsTheme.Typography.monospacedValue).foregroundStyle(.secondary)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        status
                        Spacer(minLength: 0)
                        timestamp
                    }
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) { status; timestamp }
                }
                if !run.isRecovery {
                    Text(localization.format("detail.history.runItems", defaultValue: "清理 %d 项", run.itemsRemoved)
                        + (run.categoriesCleaned.isEmpty ? "" : " · " + run.categoryTitles(localization: localization).joined(separator: "、")))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                        .lineLimit(1).help(run.categoryTitles(localization: localization).joined(separator: "、"))
                }
                if let error = run.errorsEncountered.first {
                    Text(error).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.orange)
                        .lineLimit(2).help(error).textSelection(.enabled)
                }
            }
        }
        .pluginSettingsListRowPadding()
    }

    private var status: some View {
        Text(run.statusTitle(localization: localization)).font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(run.needsAttention ? Color.orange : Color.secondary)
    }
    private var timestamp: some View {
        Text(DiskCleanFormat.timestamp(run.timestamp)).font(PluginSettingsTheme.Typography.statusBadge).foregroundStyle(.secondary)
    }
}

extension DiskCleanRunHistoryEntry {
    var isSuccessful: Bool { !isRecovery && status == "ok" && !needsAttention }

    var symbolName: String {
        if needsAttention { return "exclamationmark.triangle.fill" }
        if isRecovery { return DiskCleanCleanupHistoryStatus(rawValue: status).symbolName }
        switch status {
        case "ok": return isTrash ? "trash" : "checkmark.circle.fill"
        case "cancelled": return "stop.circle"
        case "interrupted": return "pause.circle"
        case "completedWithErrors": return "exclamationmark.circle"
        default: return "questionmark.circle"
        }
    }

    func statusTitle(localization: PluginLocalization) -> String {
        if isRecovery { return DiskCleanCleanupHistoryStatus(rawValue: status).title(localization: localization) }
        switch status {
        case "ok": return localization.string("history.run.completed", defaultValue: "已完成")
        case "cancelled": return localization.string("history.run.cancelled", defaultValue: "已取消")
        case "interrupted": return localization.string("history.run.interrupted", defaultValue: "已中断")
        case "completedWithErrors": return localization.string("history.run.errors", defaultValue: "已完成，有错误")
        default: return localization.string("history.run.unknown", defaultValue: "状态未知")
        }
    }

    func categoryTitles(localization: PluginLocalization) -> [String] {
        categoriesCleaned.map { DiskCleanCategoryID(rawValue: $0)?.title(localization: localization) ?? $0 }
    }
}
