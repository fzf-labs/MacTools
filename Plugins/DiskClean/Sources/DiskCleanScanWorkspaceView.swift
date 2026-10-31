import SwiftUI
import MacToolsPluginKit

struct DiskCleanScanWorkspaceView: View {
    @ObservedObject var controller: DiskCleanController
    let localization: PluginLocalization
    @State private var expandedCategories: Set<DiskCleanCategoryID> = [.installers, .developerArtifacts]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { controller.scan() } label: {
                    Label(localization.string("applications.scan", defaultValue: "扫描"), systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!snapshot.canScan)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .padding(PluginSettingsTheme.Spacing.rowHorizontal)
            Divider()
            if let error = snapshot.errorMessage {
                Text(error).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red)
                    .padding(PluginSettingsTheme.Spacing.rowHorizontal)
            }
            if let limitations = snapshot.scanResult?.limitations, !limitations.isEmpty {
                DisclosureGroup {
                    ForEach(Array(limitations.enumerated()), id: \.offset) { _, limitation in
                        Text(DiskCleanFormat.limitation(limitation, localization: localization))
                    }
                } label: {
                    Label(localization.string("detail.limited.title", defaultValue: "本次扫描不完整"), systemImage: "exclamationmark.triangle")
                }
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.orange)
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
            }
            if groups.isEmpty {
                VStack {
                    Spacer()
                    ContentUnavailableView(emptyTitle, systemImage: "internaldrive")
                    if needsAuthorization {
                        Button(localization.string("detail.fda.openSettings", defaultValue: "前往授权")) {
                            DiskCleanFullDiskAccessGuide.openSettings()
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    DiskCleanCategoryListView(groups: groups, selection: snapshot.selection,
                        outcomesByCandidateID: outcomes, localization: localization,
                        isInteractionEnabled: !snapshot.isBusy,
                        onToggleCandidate: { controller.setCandidateSelected($0, isSelected: $1) },
                        onToggleCategory: { controller.setCategorySelection($0, isSelected: $1) },
                        expandedCategories: $expandedCategories)
                        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
                }
            }
            if let result = snapshot.executionResult {
                DiskCleanWorkspaceResult(result: result, localization: localization)
            }
            Divider()
            DiskCleanWorkspaceFooter(snapshot: snapshot, localization: localization,
                actionTitle: localization.string(snapshot.removalMode == .trash ? "detail.action.trash" : "detail.confirm.confirm",
                    defaultValue: snapshot.removalMode == .trash ? "移到废纸篓" : "永久删除"),
                onClean: { controller.clean() }, onCancel: { controller.cancelCurrentOperation() })
        }
        .confirmationDialog(DiskCleanFormat.confirmationTitle(snapshot, localization: localization),
                            isPresented: Binding(get: { snapshot.phase == .confirming }, set: { if !$0 { controller.cancelPendingClean() } }),
                            titleVisibility: .visible) {
            Button(localization.string("detail.confirm.confirm", defaultValue: "永久删除"), role: .destructive) { controller.confirmPendingClean() }
            Button(localization.string("applications.cancel", defaultValue: "取消"), role: .cancel) { controller.cancelPendingClean() }
        } message: {
            Text(localization.string("detail.confirm.message", defaultValue: "永久删除不进废纸篓，无法恢复。"))
        }
    }

    private var snapshot: DiskCleanControllerSnapshot { controller.snapshot }
    private var groups: [DiskCleanCategoryGroup] {
        DiskCleanCategoryGroup.groups(candidates: snapshot.scanResult?.candidates ?? [], selection: snapshot.selection)
    }
    private var outcomes: [String: DiskCleanExecutionItemResult.Outcome] {
        Dictionary((snapshot.executionResult?.itemResults ?? []).map { ($0.candidateID, $0.outcome) }, uniquingKeysWith: { first, _ in first })
    }
    private var needsAuthorization: Bool {
        (snapshot.scanResult?.limitations ?? []).contains {
            if case .fdaRestricted = $0 { return true }
            if case .scanRootUnreadable(_, .permissionDenied) = $0 { return true }
            return false
        }
    }
    private var hasUnreadableRoots: Bool {
        if case .rootsUnreadable = DiskCleanSectionGuidance.resolve(snapshot) { return true }
        return false
    }
    private var emptyTitle: String {
        if snapshot.phase == .scanning { return localization.string("controller.subtitle.scanning", defaultValue: "正在扫描") }
        if needsAuthorization { return localization.string("ui.needsAccess", defaultValue: "需要访问权限") }
        if hasUnreadableRoots { return localization.string("detail.section.rootsUnreadable.title", defaultValue: "有文件夹已无法读取") }
        if snapshot.scanResult != nil { return localization.string("detail.candidates.empty", defaultValue: "没有发现可清理项目") }
        return localization.string("detail.selection.idle", defaultValue: "尚未扫描")
    }
}

struct DiskCleanWorkspaceFooter: View {
    let snapshot: DiskCleanControllerSnapshot?
    let localization: PluginLocalization
    let actionTitle: String
    var isPreparing = false
    var selectionSummary: String? = nil
    var activityTitle: String? = nil
    var sizeSummary: String? = nil
    var actionEnabled: Bool? = nil
    let onClean: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            if isPreparing || snapshot?.isBusy == true { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(status).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary).lineLimit(1)
                if let snapshot, !snapshot.selection.isEmpty {
                    Text(sizeSummary ?? DiskCleanFormat.bytes(snapshot.selection.selectedEstimatedBytes))
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                }
            }
            Spacer(minLength: 0)
            if isPreparing || snapshot?.isBusy == true {
                Button(localization.string("applications.cancel", defaultValue: "取消"), action: onCancel)
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Button(actionTitle, action: onClean)
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!(actionEnabled ?? (snapshot?.canClean == true)) || isPreparing)
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }

    private var status: String {
        if isPreparing || snapshot?.phase == .scanning { return activityTitle ?? localization.string("controller.subtitle.scanning", defaultValue: "正在扫描") }
        if snapshot?.phase == .cleaning { return localization.string("controller.subtitle.cleaning", defaultValue: "正在清理") }
        if snapshot?.isResultExpired == true { return localization.string("applications.expired", defaultValue: "结果已过期，请重新扫描") }
        if snapshot?.isResultStale == true { return localization.string("detail.selection.stale", defaultValue: "清理范围已变化，请重新扫描") }
        return selectionSummary ?? localization.format("ui.selectedCount", defaultValue: "已选 %d 项", snapshot?.selection.selectedCount ?? 0)
    }
}

struct DiskCleanWorkspaceResult: View {
    let result: DiskCleanExecutionResult
    let localization: PluginLocalization

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowVertical) {
            ForEach(result.attentionResults, id: \.candidateID) { item in
                DiskCleanBanner(symbolName: "exclamationmark.triangle.fill", tint: .orange,
                    title: DiskCleanFormat.attentionTitle(item.outcome, localization: localization),
                    lines: [item.path, DiskCleanFormat.attentionGuidance(item.outcome, localization: localization)]
                        + (DiskCleanFormat.stagedName(of: item.outcome).map { [$0] } ?? []))
            }
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                if result.wasCancelled {
                    Label(localization.string("detail.result.cancelledTitle", defaultValue: "已停止的清理结果"), systemImage: "stop.circle")
                }
                Text(localization.string(result.mode == .trash ? "detail.result.trashed" : "detail.result.removed",
                    defaultValue: result.mode == .trash ? "已移到废纸篓" : "已删除") + " \(result.removedCount)")
                Text(localization.string("detail.result.skipped", defaultValue: "已跳过") + " \(result.skippedCount)")
                Text(localization.string("detail.result.failed", defaultValue: "未完成") + " \(result.failedCount)")
            }
            .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }
}
