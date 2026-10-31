import AppKit
import SwiftUI
import MacToolsPluginKit

enum DiskCleanWorkspaceDestination: String, CaseIterable, Identifiable {
    case caches, uninstall, installers, leftovers, projects, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .caches: return "垃圾清理"
        case .installers: return "安装包清理"
        case .projects: return "项目清理"
        case .uninstall: return "应用卸载"
        case .leftovers: return "疑似应用残留"
        case .settings: return "设置与记录"
        }
    }
    var symbol: String {
        switch self {
        case .caches: return "sparkles"
        case .installers: return "shippingbox"
        case .projects: return "hammer"
        case .uninstall: return "app.badge"
        case .leftovers: return "folder.badge.questionmark"
        case .settings: return "clock.arrow.circlepath"
        }
    }
    var tint: Color {
        switch self {
        case .caches: return .blue
        case .installers: return .orange
        case .projects: return .purple
        case .uninstall: return .teal
        case .leftovers: return .orange
        case .settings: return .secondary
        }
    }
}

struct DiskCleanWorkspaceView: View {
    let controller: DiskCleanController
    let developerController: DiskCleanController
    let installersController: DiskCleanController
    let applications: DiskCleanApplicationReviewModel
    let leftovers: DiskCleanApplicationReviewModel
    let localization: PluginLocalization
    let history: any DiskCleanCleanupHistoryProviding
    @State private var destination: DiskCleanWorkspaceDestination? = .caches

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $destination) {
                Section {
                    ForEach(DiskCleanWorkspaceDestination.allCases.filter { $0 != .settings }) { item in navigation(item) }
                }
                Section {
                    navigation(.settings)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.vertical, PluginSettingsTheme.Spacing.controlCluster)
            .background(.background)
            .frame(minWidth: 164, idealWidth: 180, maxWidth: 200)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 420)
    }

    private func navigation(_ item: DiskCleanWorkspaceDestination) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Image(systemName: item.symbol)
                .font(PluginSettingsTheme.Typography.rowTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: PluginSettingsTheme.Size.controlHeight, height: PluginSettingsTheme.Size.controlHeight)
                .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control))
                .accessibilityHidden(true)
            Text(copy("workspace." + item.rawValue, item.title))
                .font(destination == item
                    ? PluginSettingsTheme.Typography.emphasizedRowTitle
                    : PluginSettingsTheme.Typography.rowTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .help(copy("workspace." + item.rawValue, item.title))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.controlCluster)
        .padding(.vertical, PluginSettingsTheme.Spacing.controlCluster)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowSeparator(.hidden)
        .tag(item)
    }

    @ViewBuilder
    private var content: some View {
        switch destination ?? .caches {
        case .uninstall:
            DiskCleanApplicationReviewView(model: applications, isLeftovers: false, localization: localization)
        case .leftovers:
            DiskCleanApplicationReviewView(model: leftovers, isLeftovers: true, localization: localization)
        case .caches:
            DiskCleanScanWorkspaceView(controller: controller, localization: localization)
        case .projects:
            DiskCleanScanWorkspaceView(controller: developerController, localization: localization)
        case .installers:
            DiskCleanScanWorkspaceView(controller: installersController, localization: localization)
        case .settings:
            DiskCleanSettingsWorkspaceView(controller: controller, developerController: developerController,
                installersController: installersController, applications: applications, leftovers: leftovers,
                history: history, localization: localization)
        }
    }
    private func copy(_ key: String, _ fallback: String) -> String { localization.string(key, defaultValue: fallback) }
}
