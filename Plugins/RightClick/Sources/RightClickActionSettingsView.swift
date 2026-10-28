import SwiftUI
import MacToolsPluginKit

struct RightClickActionSettingsView: View {
    @ObservedObject var session: RightClickSettingsSession
    let localization: PluginLocalization
    let category: RightClickCategory
    @Binding var expandedAction: RightClickAction?
    @Binding var revealAction: RightClickAction?
    private typealias Spacing = PluginSettingsTheme.Spacing
    private var actions: [RightClickAction] {
        session.configuration.orderedActions.filter { $0.category == category }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(actions) { action in
                        RightClickActionSettingsRow(session: session, localization: localization, action: action,
                                                    expanded: Binding(get: { expandedAction == action }, set: { expandedAction = $0 ? action : nil }))
                            .id(action)
                        if action != actions.last { PluginSettingsListDivider() }
                    }
                }
                .pluginSettingsCardBackground(.standard)
                .padding(.bottom, Spacing.rowVertical)
            }
            .onChange(of: revealAction, initial: true) { _, action in
                guard let action else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(action, anchor: .top)
                    if revealAction == action { revealAction = nil }
                }
            }
        }
    }
}

private struct RightClickActionSettingsRow: View {
    @ObservedObject var session: RightClickSettingsSession
    let localization: PluginLocalization
    let action: RightClickAction
    @Binding var expanded: Bool
    private typealias Spacing = PluginSettingsTheme.Spacing
    private typealias Typography = PluginSettingsTheme.Typography
    private func text(_ key: String) -> String { localization.string(key, defaultValue: key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.rowContentControl) {
                if hasSettings {
                    Button { expanded.toggle() } label: { actionLabel }
                        .buttonStyle(.plain).help(text("Configure"))
                        .accessibilityValue(text(expanded ? "Expanded" : "Collapsed"))
                } else {
                    actionLabel
                }
                Toggle(text(action.title), isOn: Binding(get: { session.configuration.isEnabled(action) }, set: { session.configuration.setEnabled(action, $0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            .pluginSettingsListRowPadding(interactive: true)
            if hasSettings && expanded {
                Divider().padding(.horizontal, Spacing.rowHorizontal)
                RightClickActionDetailsView(session: session, action: action, localization: localization)
                    .padding(Spacing.rowHorizontal)
            }
        }
    }

    private var hasSettings: Bool { RightClickResourceEditorKind(action: action) != nil }

    private var actionLabel: some View {
        HStack(spacing: Spacing.rowContentControl) {
            RightClickActionIcon(symbol: action.symbol)
            VStack(alignment: .leading, spacing: Spacing.rowTitleDescription) {
                Text(text(action.title)).font(Typography.rowTitle).foregroundStyle(.primary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                if let description = actionDescription {
                    Text(description).font(Typography.rowDescription).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if hasSettings {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(Typography.statusBadge).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var actionDescription: String? {
        switch action {
        case .newFile: session.configuration.enabledFileExtensions.prefix(6).map { "." + $0 }.joined(separator: " · ")
        case .copyTo, .moveTo, .goTo, .addLocation:
            session.configuration.locations.isEmpty ? text("Choose a destination folder.") : session.configuration.locations.map(\.name).joined(separator: " · ")
        case .terminal: session.configuration.terminal.title
        case .openWith:
            session.configuration.openWithApps.isEmpty ? text("Application is unavailable.") : session.configuration.openWithApps.map(\.name).joined(separator: " · ")
        case .openPreferred:
            session.configuration.openWithApps.first { $0.id == session.configuration.preferredAppID }?.name ?? text("Application is unavailable.")
        case .copyPath: "/Users/…/Notes.txt"
        case .copyRelative: "Project/Notes.txt"
        case .copyShell: "Project/My\\ Notes.txt"
        case .copyURL: "file:///Users/…/Notes.txt"
        case .convertImage: "PNG · JPEG · HEIC · TIFF"
        case .resizeImage: text("Original files are kept.")
        case .dissolve: text("Move direct children to the parent folder.")
        case .rename: text("Preview names before applying changes.")
        case .undo: session.configuration.undoAvailable ? nil : text("There is no operation to undo.")
        case .setIcon: session.configuration.resources.contains { $0.kind == .icon && $0.enabled } ? nil : text("Import a folder icon below.")
        default: nil
        }
    }
}
