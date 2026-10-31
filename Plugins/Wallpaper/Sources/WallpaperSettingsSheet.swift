import AppKit
import MacToolsPluginKit
import SwiftUI

@MainActor
struct WallpaperIntervalPicker: View {
    @ObservedObject var controller: WallpaperController
    var body: some View {
        Picker(controller.text("Interval"), selection: Binding(get: { controller.profile.interval }, set: { value in
            controller.configure { $0.interval = value }
        })) {
            ForEach([300.0, 900, 1_800, 3_600, 21_600, 43_200, 86_400], id: \.self) { seconds in
                Text(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)
                    .locale(PluginRuntimeLocalization.locale))).tag(seconds)
            }
        }
    }
}

@MainActor
struct WallpaperSettingsSheet: View {
    @ObservedObject var controller: WallpaperController
    @Environment(\.dismiss) private var dismiss
    private func t(_ key: String) -> String { controller.text(key) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(t("More Settings")).font(PluginSettingsTheme.Typography.sectionTitle)
                Spacer()
                Button(t("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(PluginSettingsTheme.Spacing.rowHorizontal)
            Form {
                Section(t("Rotation Settings")) {
                    Picker(t("Collection"), selection: Binding(get: { controller.profile.collection }, set: { value in
                        controller.configure { $0.collection = value }
                    })) {
                        Text(t("Local Photos")).tag(WallpaperCollection.local)
                        Text(t("Favorites")).tag(WallpaperCollection.favorites)
                        Text(t("Online Wallpapers")).tag(WallpaperCollection.wallhaven)
                    }
                    .frame(maxWidth: 440)
                    WallpaperIntervalPicker(controller: controller).frame(maxWidth: 440)
                    Toggle(t("Shuffle"), isOn: Binding(get: { controller.profile.shuffled }, set: { value in
                        controller.configure { $0.shuffled = value }
                    })).toggleStyle(.switch)
                }
                Section(t("Display")) {
                    if controller.displays.count > 1 || controller.state.selectedScope != "all" {
                        displayPicker
                    }
                    Picker(t("Image Fit"), selection: Binding(get: { controller.profile.fill }, set: { value in
                        controller.configure { $0.fill = value }
                    })) {
                        Text(t("Fill Screen")).tag(true); Text(t("Fit to Screen")).tag(false)
                    }.frame(maxWidth: 440)
                    if controller.displays.count > 1 || controller.state.independentDisplays {
                        Toggle(t("Independent Displays"), isOn: Binding(get: { controller.state.independentDisplays }, set: controller.setIndependent))
                            .toggleStyle(.switch)
                    }
                }
                Section(t("Manage Folders")) {
                    ForEach(controller.state.folders) { folder in folderRow(folder) }
                    Button(t("Add Folder")) { controller.addFolder() }
                }
                Section(t("Cache")) {
                    LabeledContent(t("Managed Images"), value: bytes(controller.usage.managed))
                    LabeledContent(t("Cache"), value: bytes(controller.usage.cached))
                    Picker(t("Cache Limit"), selection: Binding(get: { controller.state.cacheBudget }, set: controller.setCacheBudget)) {
                        Text("256 MB").tag(Int64(256 * 1_024 * 1_024))
                        Text("1 GB").tag(Int64(1_024 * 1_024 * 1_024))
                        Text("5 GB").tag(Int64(5 * 1_024 * 1_024 * 1_024))
                    }.frame(maxWidth: 440)
                    Button(t("Clear Cache")) { Task { await controller.cleanCache() } }.disabled(controller.busy)
                }
                Section {
                    Text(t("Rotation runs while MacTools is open. External changes pause rotation when detected. Other Spaces and the lock screen are not managed."))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 500, idealWidth: 560, maxWidth: 660, minHeight: 480, idealHeight: 580, maxHeight: 700)
        .buttonStyle(.bordered).controlSize(.small)
    }

    private var displayPicker: some View {
        Picker(t("Display"), selection: Binding(get: { controller.state.selectedScope }, set: controller.selectScope)) {
            if !controller.state.independentDisplays { Text(t("All Displays")).tag("all") }
            ForEach(controller.displays) { Text(controller.scopeTitle($0.id)).tag($0.id) }
            if controller.state.selectedScope != "all", !controller.displays.contains(where: { $0.id == controller.state.selectedScope }) {
                Text(t("Disconnected Display")).tag(controller.state.selectedScope)
            }
        }.frame(maxWidth: 440)
    }

    private func folderRow(_ folder: WallpaperFolder) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Label(folder.url.lastPathComponent, systemImage: "folder").font(PluginSettingsTheme.Typography.rowTitle)
                    Text(folder.url.path).font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Menu {
                    Button(t("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                    Button(t("Refresh")) { controller.scan() }
                    Divider()
                    Button(t("Remove Folder")) { controller.updateFolder(folder.id, remove: true) }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel(t("Manage Folders"))
                    .fixedSize()
            }
            if controller.folderIssues[folder.id] != nil {
                Label(t("The folder is unavailable or only partially scanned."), systemImage: "exclamationmark.triangle")
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.orange)
            }
            Toggle(t("Include in Rotation"), isOn: Binding(get: { folder.included }, set: { controller.updateFolder(folder.id, included: $0) }))
                .toggleStyle(.switch)
            Toggle(t("Include Subfolders"), isOn: Binding(get: { folder.recursive }, set: { controller.updateFolder(folder.id, recursive: $0) }))
                .toggleStyle(.switch)
        }
    }

    private func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(PluginRuntimeLocalization.locale))
    }
}
