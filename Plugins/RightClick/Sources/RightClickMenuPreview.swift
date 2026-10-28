import SwiftUI
import MacToolsPluginKit

struct RightClickMenuPreview: View {
    @ObservedObject var session: RightClickSettingsSession
    let localization: PluginLocalization
    @Binding var previewScenario: String
    private typealias Spacing = PluginSettingsTheme.Spacing
    private typealias Typography = PluginSettingsTheme.Typography
    private func text(_ key: String) -> String { localization.string(key, defaultValue: key) }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
            RightClickSectionHeader(title: text("Menu Preview"), symbol: "menubar.rectangle")
            Picker(text("Selection"), selection: $previewScenario) {
                Text(text("Folder Background")).tag("background")
                Text(text("One File")).tag("file")
                Text(text("Multiple Files")).tag("files")
                Text(text("Folder")).tag("folder")
                Text(text("Images")).tag("images")
            }
            .font(Typography.rowDescription)
            .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Spacing.controlCluster) {
                Image(systemName: previewScenario == "images" ? "photo" : previewScenario == "folder" || previewScenario == "background" ? "folder.fill" : "doc.on.doc")
                    .foregroundStyle(Color.accentColor)
                Text(previewScenario == "files" ? "Notes.txt, Report.pdf" : previewScenario == "images" ? "Photo.png" : previewScenario == "file" ? "Notes.txt" : "Project")
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(Typography.rowDescription).foregroundStyle(.secondary)
            .padding(.vertical, Spacing.controlCluster)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "cursorarrow.click.2").foregroundStyle(.secondary)
                        Text("MacTools").font(Typography.emphasizedRowTitle)
                        Spacer(minLength: 0)
                    }
                    .padding(Spacing.sectionHeaderContent)
                    Divider().padding(.horizontal, Spacing.controlCluster)
                    let entries = RightClickMenuBuilder.entries(configuration: previewConfiguration, selection: previewSelection, localize: text)
                    if entries.isEmpty {
                        Text(text("No actions for this selection.")).foregroundStyle(.secondary)
                            .font(Typography.rowDescription).padding(Spacing.cardContent)
                    }
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        previewEntry(entry)
                    }
                }
                .padding(Spacing.rowTitleDescription)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pluginSettingsCardBackground(.standard)
                Text(text("Preview only. Your files are unchanged."))
                    .font(Typography.rowDescription).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.controlCluster)
            }
            .frame(maxHeight: .infinity, alignment: .top)

        }
    }

    private var previewConfiguration: RightClickConfiguration {
        var config = session.configuration
        config.menuEnabled = true
        return config
    }
    private var previewSelection: RightClickSelection {
        let directory = URL(fileURLWithPath: "/Example", isDirectory: true)
        var items: [RightClickSelectionItem] = []
        switch previewScenario {
        case "file": items = [.init(url: directory.appendingPathComponent("Notes.txt"), isDirectory: false)]
        case "files": items = ["Notes.txt", "Report.pdf"].map { .init(url: directory.appendingPathComponent($0), isDirectory: false) }
        case "folder": items = [.init(url: directory.appendingPathComponent("Project"), isDirectory: true)]
        case "images": items = [.init(url: directory.appendingPathComponent("Photo.png"), isDirectory: false, isImage: true)]
        default: break
        }
        return RightClickSelection(items: items, directory: directory, relativeBase: directory)
    }
    private func previewEntry(_ entry: RightClickMenuEntry) -> AnyView {
        let label = HStack(spacing: Spacing.controlCluster) {
            if session.configuration.showIcons { Image(systemName: entry.symbol).foregroundStyle(.secondary).frame(width: PluginSettingsTheme.Size.rowIcon) }
            Text(entry.title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(Typography.rowTitle)
        .padding(.vertical, Spacing.controlCluster)
        if entry.children.isEmpty { return AnyView(label.padding(.horizontal, Spacing.sectionHeaderContent)) }
        return AnyView(DisclosureGroup {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entry.children.enumerated()), id: \.offset) { _, child in previewEntry(child) }
            }
        } label: { label }
        .padding(.horizontal, Spacing.sectionHeaderContent))
    }

}
