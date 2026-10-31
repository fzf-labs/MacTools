import SwiftUI
import MacToolsPluginKit

struct DiskCleanApplicationCoverageView: View {
    let report: DiskCleanApplicationScanReport
    let localization: PluginLocalization
    @Environment(\.dismiss) private var dismiss
    @State private var attentionOnly = false
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowVertical) {
            HStack {
                Label(copy("title", "扫描覆盖"), systemImage: "checklist")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                Spacer()
                Button(copy("done", "完成")) { dismiss() }
                    .buttonStyle(.bordered).controlSize(.small).keyboardShortcut(.cancelAction)
            }
            Text(copy("scope", "仅表示下列位置的定位结果，内容检查见文件列表。"))
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            HStack {
                Label(copy(report.hasProductRule ? "adapted" : "generic", report.hasProductRule ? "通用规则与应用专用规则" : "仅通用规则 · 暂无专用适配"),
                      systemImage: report.hasProductRule ? "checkmark.seal" : "info.circle")
                Spacer()
                Text(localization.format("uninstall.coverage.locations", defaultValue: "%d 个位置", report.checks.count))
                    .monospacedDigit()
            }.font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            if !report.identityComplete {
                Label(copy("componentsUnidentified", "部分组件未识别"), systemImage: "info.circle")
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.orange)
            }
            HStack {
                TextField(copy("search", "搜索位置"), text: $search)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 160, idealWidth: 240, maxWidth: .infinity)
                Toggle(copy("attentionOnly", "仅看未完成"), isOn: $attentionOnly).toggleStyle(.checkbox)
            }.font(PluginSettingsTheme.Typography.rowDescription)
            List {
                ForEach(checks) { check in
                    HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                        Image(systemName: check.state.needsAttention ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(check.state.needsAttention ? Color.orange : Color.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                            Text(check.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(check.path)
                                .font(PluginSettingsTheme.Typography.rowTitle)
                            Text(check.category.title(localization) + " · " + sourceTitle(check.source))
                                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text(stateTitle(check.state)).font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(check.state.needsAttention ? Color.orange : Color.secondary)
                            .fixedSize()
                    }.padding(.vertical, PluginSettingsTheme.Spacing.controlCluster)
                }
            }.listStyle(.inset).overlay {
                if checks.isEmpty {
                    ContentUnavailableView(copy("empty", "没有符合条件的位置"), systemImage: "checklist")
                }
            }
        }
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
        .frame(minWidth: 480, idealWidth: 640, minHeight: 360, idealHeight: 480)
    }

    private var checks: [DiskCleanApplicationScanCheck] {
        report.checks.filter { (!attentionOnly || $0.state.needsAttention) && (search.isEmpty || $0.path.localizedStandardContains(search)) }
            .sorted {
                if $0.state.needsAttention != $1.state.needsAttention { return $0.state.needsAttention }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
    }

    private func stateTitle(_ state: DiskCleanApplicationScanCheck.State) -> String {
        switch state {
        case .checked: copy("checked", "已定位")
        case .missing: copy("missing", "已检查 · 未发现")
        case .permissionRequired: copy("denied", "无权限")
        case .incomplete: copy("incomplete", "未完成")
        case .unsupported: copy("unsupported", "未适配")
        }
    }

    private func sourceTitle(_ source: DiskCleanApplicationScanCheck.Source) -> String {
        switch source {
        case .bundleID: copy("source.bundleID", "Bundle ID")
        case .productRule: copy("source.productRule", "应用规则")
        case .name: copy("source.name", "名称候选 · 需核对")
        case .container: copy("source.container", "容器归属")
        case .system: copy("source.system", "系统组件 · 仅查看")
        case .identity: copy("source.identity", "组件归属")
        }
    }

    private func copy(_ key: String, _ fallback: String) -> String {
        localization.string("uninstall.coverage." + key, defaultValue: fallback)
    }
}
