import AppKit
import SwiftUI
import MacToolsPluginKit

struct DiskCleanSettingsWorkspaceView: View {
    @ObservedObject var controller: DiskCleanController
    @ObservedObject var developerController: DiskCleanController
    @ObservedObject var installersController: DiskCleanController
    @ObservedObject var applications: DiskCleanApplicationReviewModel
    @ObservedObject var leftovers: DiskCleanApplicationReviewModel
    let history: any DiskCleanCleanupHistoryProviding
    let localization: PluginLocalization
    @State private var showsScanLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            DiskCleanRemovalSettingsView(controller: controller, localization: localization,
                otherControllers: [developerController, installersController], isBusy: controller.snapshot.isBusy || developerController.snapshot.isBusy || installersController.snapshot.isBusy)
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    DiskCleanSectionHeader(title: copy("settings.records", "记录"), symbolName: "clock.arrow.circlepath")
                    Spacer(minLength: 0)
                    Picker(copy("settings.records", "记录"), selection: $showsScanLog) {
                        Text(copy("settings.cleanupRecords", "清理记录")).tag(false)
                        Text(copy("detail.scanLog.title", "扫描日志")).tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                }
                if showsScanLog {
                    DiskCleanScanLogWorkspace(sources: scanSources, localization: localization)
                } else {
                    DiskCleanCleanupHistorySection(provider: history, localization: localization,
                        reloadToken: .init(results: [controller.snapshot.executionResult, developerController.snapshot.executionResult,
                            installersController.snapshot.executionResult, applications.lastExecutionResult, leftovers.lastExecutionResult],
                            isCleanupReady: controller.snapshot.isCleanupReady))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanSources: [DiskCleanScanLogSource] {
        [source(.caches, controller), source(.uninstall, applications.controller), source(.installers, installersController),
         source(.leftovers, leftovers.controller), source(.projects, developerController)]
    }

    private func source(_ destination: DiskCleanWorkspaceDestination, _ controller: DiskCleanController?) -> DiskCleanScanLogSource {
        .init(id: destination.rawValue, title: copy("workspace." + destination.rawValue, destination.title), controller: controller)
    }

    private func copy(_ key: String, _ fallback: String) -> String { localization.string(key, defaultValue: fallback) }
}

struct DiskCleanRemovalSettingsView: View {
    @ObservedObject var controller: DiskCleanController
    let localization: PluginLocalization
    var otherControllers: [DiskCleanController] = []
    var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            DiskCleanSectionHeader(title: copy("detail.settings.title", "清理设置"), symbolName: "gearshape")
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                        modeLabel
                        Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                        modePicker.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                        modeLabel
                        modePicker.fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .pluginSettingsListRowPadding(interactive: true)
            }
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var modeLabel: some View {
        PluginSettingsItem(title: copy("detail.removalMode.title", "删除方式"),
            description: controller.snapshot.removalMode == .trash
                ? copy("settings.trashSummary", "移到废纸篓，可恢复。")
                : copy("settings.permanentSummary", "直接删除，无法恢复。"),
            systemImage: controller.snapshot.removalMode == .trash ? "trash" : "trash.slash") { EmptyView() }
        .fixedSize(horizontal: false, vertical: true)
        .help(controller.snapshot.removalMode == .trash
            ? copy("detail.removalMode.trash.description", "移到废纸篓，清空后释放空间。放回时使用暂存名。")
            : copy("detail.removalMode.permanent.description", "直接删除，不进废纸篓，无法恢复。执行前需要再次确认。"))
    }

    private var modePicker: some View {
        Picker(copy("detail.removalMode.title", "删除方式"), selection: Binding(
            get: { controller.snapshot.removalMode }, set: { mode in
                ([controller] + otherControllers).forEach { $0.setRemovalMode(mode) }
            })) {
                Text(copy("detail.removalMode.trash", "废纸篓")).tag(DiskCleanRemovalMode.trash)
                Text(copy("detail.removalMode.permanent", "永久删除")).tag(DiskCleanRemovalMode.permanent)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .disabled(isBusy || controller.snapshot.isBusy)
    }

    private func copy(_ key: String, _ fallback: String) -> String { localization.string(key, defaultValue: fallback) }
}

private struct DiskCleanScanLogSource: Identifiable {
    let id: String
    let title: String
    let controller: DiskCleanController?
}

private struct DiskCleanScanLogWorkspace: View {
    let sources: [DiskCleanScanLogSource]
    let localization: PluginLocalization
    @State private var selectedSource = "caches"
    @State private var followsLatest = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Picker(localization.string("settings.logSource", defaultValue: "日志来源"), selection: $selectedSource) {
                    ForEach(sources) { source in Text(source.title).tag(source.id) }
                }
                .labelsHidden().controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                Text(localization.string("settings.currentSession", defaultValue: "本次会话"))
                    .font(PluginSettingsTheme.Typography.statusBadge).foregroundStyle(.secondary)
            }
            .pluginSettingsListRowPadding(interactive: true)
            Divider()
            if let controller = sources.first(where: { $0.id == selectedSource })?.controller {
                DiskCleanSettingsScanLogList(controller: controller, localization: localization, followsLatest: $followsLatest)
                    .id(selectedSource)
            } else {
                DiskCleanScanLogEmptyState(localization: localization)
            }
        }
        .frame(minHeight: 160, maxHeight: .infinity)
        .pluginSettingsCardBackground(.standard)
        .onAppear {
            if let latest = sources.filter({ $0.controller?.snapshot.scanLogEntries.isEmpty == false })
                .max(by: { ($0.controller?.snapshot.scanResult?.scannedAt ?? .distantPast) < ($1.controller?.snapshot.scanResult?.scannedAt ?? .distantPast) }) {
                selectedSource = latest.id
            }
        }
    }
}

private struct DiskCleanSettingsScanLogList: View {
    @ObservedObject var controller: DiskCleanController
    let localization: PluginLocalization
    @Binding var followsLatest: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                if controller.snapshot.isBusy { ProgressView().controlSize(.small) }
                Text(localization.format("settings.logCount", defaultValue: "%d 条", controller.snapshot.scanLogEntries.count))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Toggle(localization.string("settings.followLog", defaultValue: "自动滚动"), isOn: $followsLatest)
                    .toggleStyle(.checkbox).controlSize(.small)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(controller.snapshot.scanLogEntries.map(\.text).joined(separator: "\n"), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(localization.string("settings.copyLog", defaultValue: "复制日志"))
                .accessibilityLabel(localization.string("settings.copyLog", defaultValue: "复制日志"))
                .disabled(controller.snapshot.scanLogEntries.isEmpty)
            }
            .font(PluginSettingsTheme.Typography.rowDescription)
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, PluginSettingsTheme.Spacing.controlCluster)
            if controller.snapshot.scanLogEntries.isEmpty {
                DiskCleanScanLogEmptyState(localization: localization)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowVertical) {
                            ForEach(controller.snapshot.scanLogEntries) { entry in
                                HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                                    Image(systemName: DiskCleanFormat.logSymbolName(entry.tone))
                                        .foregroundStyle(DiskCleanFormat.logTint(entry.tone)).frame(width: PluginSettingsTheme.Size.rowIcon)
                                    Text(entry.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .font(PluginSettingsTheme.Typography.rowDescription).id(entry.id)
                            }
                        }
                        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
                    }
                    .onChange(of: controller.snapshot.scanLogEntries.last?.id, initial: true) { _, id in
                        if followsLatest, let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                    .onChange(of: followsLatest) { _, follows in
                        if follows, let id = controller.snapshot.scanLogEntries.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiskCleanScanLogEmptyState: View {
    let localization: PluginLocalization

    var body: some View {
        VStack(spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Image(systemName: "text.alignleft")
                .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon))
            Text(localization.string("detail.scanLog.empty", defaultValue: "点击扫描后显示实时进度"))
                .font(PluginSettingsTheme.Typography.rowDescription)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
    }
}
