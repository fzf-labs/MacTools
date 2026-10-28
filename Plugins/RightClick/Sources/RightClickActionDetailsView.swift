import SwiftUI
import MacToolsPluginKit

enum RightClickResourceEditorKind {
    case locations, applications, terminal, templates, icons

    init?(action: RightClickAction) {
        switch action {
        case .copyTo, .moveTo, .goTo, .addLocation: self = .locations
        case .openWith, .openPreferred: self = .applications
        case .terminal: self = .terminal
        case .newFile: self = .templates
        case .setIcon: self = .icons
        default: return nil
        }
    }
    var title: String {
        switch self { case .locations: "Locations"; case .applications: "Applications"; case .terminal: "Preferred Terminal"; case .templates: "Templates"; case .icons: "Folder Icons" }
    }
    var symbol: String {
        switch self { case .locations: "folder"; case .applications: "app"; case .terminal: "terminal"; case .templates: "doc.badge.plus"; case .icons: "photo" }
    }
    var addTitle: String {
        switch self { case .locations: "Add Location"; case .applications: "Add Application"; case .terminal: "Preferred Terminal"; case .templates: "Import Template"; case .icons: "Import Icon" }
    }
}

struct RightClickActionDetailsView: View {
    @ObservedObject var session: RightClickSettingsSession
    let action: RightClickAction
    let localization: PluginLocalization
    private typealias Spacing = PluginSettingsTheme.Spacing
    private typealias Typography = PluginSettingsTheme.Typography
    private func text(_ key: String) -> String { localization.string(key, defaultValue: key) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            if action == .newFile { newFileOptions }
            if let kind = RightClickResourceEditorKind(action: action) {
                RightClickResourceEditor(session: session, localization: localization, kind: kind)
            }
        }
    }

    private func optionToggle(_ key: String, value: Binding<Bool>) -> some View {
        HStack(spacing: Spacing.rowContentControl) {
            Text(text(key))
            Spacer(minLength: 0)
            Toggle(text(key), isOn: value).labelsHidden().toggleStyle(.switch)
        }
    }

    private var newFileOptions: some View {
        VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
            optionToggle("Ask for Name Before Creating", value: $session.configuration.askForName)
            optionToggle("Open After Creating", value: $session.configuration.openAfterCreating)
            RightClickSectionHeader(title: text("File Types"), symbol: "doc")
                .padding(.top, Spacing.controlCluster)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), alignment: .leading)], alignment: .leading, spacing: Spacing.sectionHeaderContent) {
                ForEach(RightClickNewFile.supportedExtensions, id: \.self) { ext in
                    Toggle(".\(ext)", isOn: Binding(get: { session.configuration.enabledFileExtensions.contains(ext) }, set: { enabled in
                        if enabled { session.configuration.enabledFileExtensions.append(ext) }
                        else { session.configuration.enabledFileExtensions.removeAll { $0 == ext } }
                    })).toggleStyle(.checkbox)
                }
            }
            .padding(.vertical, Spacing.controlCluster)
        }
        .font(Typography.rowDescription)
    }
}
