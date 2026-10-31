import AppKit
import MacToolsPluginKit
import SwiftUI

@MainActor
struct WallpaperWorkspace: View {
    @ObservedObject var controller: WallpaperController
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var section = "local"
    @State private var selected: WallpaperAsset?
    @State private var localQuery = ""
    @State private var onlineQuery = ""
    @State private var folderID = "local"
    @State private var categories = "100"
    @State private var sorting = "toplist"
    @State private var orientation = "landscape"
    @State private var matchResolution = true
    @State private var showSettings = false

    private func t(_ key: String) -> String { controller.text(key) }
    private var remoteQuery: WallpaperQuery {
        let displays = controller.targets(controller.state.selectedScope)
        return WallpaperQuery(keywords: onlineQuery.isEmpty ? "landscape" : onlineQuery,
                              categories: categories, sorting: sorting, orientation: orientation,
                              minimumWidth: matchResolution ? displays.map(\.width).max() ?? 0 : 0,
                              minimumHeight: matchResolution ? displays.map(\.height).max() ?? 0 : 0)
    }
    private var assets: [WallpaperAsset] {
        controller.assets(in: section == "local" ? folderID : section,
                          query: section == "wallhaven" ? "" : localQuery)
    }
    private var isLoading: Bool {
        !controller.ready || (section == "wallhaven" ? controller.searching : controller.scanning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            playbackBar
            if let asset = controller.currentAsset { currentWallpaper(asset) }
            sourceBar
            if section == "wallhaven" { discoveryBar }
            else if section == "local", !controller.state.folders.isEmpty { folderBar }
            if let error = controller.error { errorNotice(error) }
            gallery
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .sheet(item: $selected) { asset in
            WallpaperPreviewSheet(controller: controller, selection: asset)
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection)
        }
        .sheet(isPresented: $showSettings) {
            WallpaperSettingsSheet(controller: controller)
                .environment(\.locale, locale)
                .environment(\.layoutDirection, layoutDirection)
        }
        .onChange(of: section) { _, value in
            if value == "wallhaven", controller.searchIDs.isEmpty { search() }
        }
        .onChange(of: onlineQuery) { _, _ in search() }
        .onChange(of: categories) { _, _ in search() }
        .onChange(of: sorting) { _, _ in search() }
        .onChange(of: orientation) { _, _ in search() }
        .onChange(of: matchResolution) { _, _ in search() }
        .onChange(of: controller.state.selectedScope) { _, _ in search() }
        .onChange(of: controller.ready) { _, ready in
            if ready, section == "wallhaven", controller.searchIDs.isEmpty { search() }
        }
        .onChange(of: controller.state.folders.map(\.id)) { _, ids in
            if folderID != "local", !ids.contains(where: { $0.uuidString == folderID }) { folderID = "local" }
        }
    }

    private var playbackBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                rotationControl
                Spacer(minLength: PluginSettingsTheme.Spacing.controlCluster)
                playbackActions
            }
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                rotationControl
                HStack { playbackActions; Spacer() }
            }
        }
    }

    private var rotationControl: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Toggle(t("Automatic Rotation"), isOn: Binding(get: { controller.profile.enabled }, set: setRotation))
                .toggleStyle(.switch)
                .fixedSize()
                .disabled(!controller.ready || controller.busy || (!controller.profile.enabled && assets.isEmpty))
            if controller.profile.enabled {
                WallpaperIntervalPicker(controller: controller)
                    .frame(minWidth: 170, idealWidth: 200, maxWidth: 240)
                    .disabled(controller.busy)
            }
        }
    }

    @ViewBuilder private var playbackActions: some View {
        if controller.busy {
            ProgressView().controlSize(.small)
            Button(t("Cancel")) { controller.cancelOperation() }
        } else {
            Button { useVisibleCollection(); Task { _ = await controller.execute("next") } } label: {
                Label(t("Change Wallpaper"), systemImage: "shuffle")
            }
            .disabled(!controller.ready || assets.isEmpty)
        }
        Button { showSettings = true } label: { Label(t("More Settings"), systemImage: "ellipsis") }
            .disabled(!controller.ready)
    }

    private func currentWallpaper(_ asset: WallpaperAsset) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowHorizontal) {
            WallpaperThumbnail(controller: controller, asset: asset, fillsFrame: true)
                .frame(width: 112, height: 70).clipShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control))
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(t("Current Wallpaper")).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                Text(asset.title).font(PluginSettingsTheme.Typography.emphasizedRowTitle).lineLimit(1)
                Text(controller.scopeTitle(controller.state.selectedScope))
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { selected = asset } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help(t("Preview Wallpaper")).accessibilityLabel(t("Preview Wallpaper"))
        }
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
        .pluginSettingsCardBackground(.standard)
    }

    private var sourceBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowHorizontal) { sourcePicker; Spacer(minLength: 0); searchField }
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) { sourcePicker; searchField }
        }
    }

    private var sourcePicker: some View {
        Picker(t("Collection"), selection: $section) {
            Text(t("Local Photos")).tag("local")
            Text(t("Online Wallpapers")).tag("wallhaven")
            Text(t("Favorites")).tag("favorites")
            Text(t("History")).tag("history")
        }
        .pickerStyle(.segmented).labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 300, idealWidth: 360, maxWidth: 440, alignment: .leading)
    }

    private var searchField: some View {
        TextField(t("Search"), text: section == "wallhaven" ? $onlineQuery : $localQuery)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 130, idealWidth: 180, maxWidth: 240)
    }

    private var folderBar: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            if controller.state.folders.count > 1 {
                Picker(t("Local Folders"), selection: $folderID) {
                    Text(t("All")).tag("local")
                    ForEach(controller.state.folders) { Text($0.url.lastPathComponent).tag($0.id.uuidString) }
                }.labelsHidden().frame(minWidth: 140, idealWidth: 180, maxWidth: 240)
            } else if let folder = controller.state.folders.first {
                Label(folder.url.lastPathComponent, systemImage: "folder")
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary).lineLimit(1)
            }
            if !controller.folderIssues.isEmpty {
                Button { showSettings = true } label: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.orange).help(t("The folder is unavailable or only partially scanned."))
                    .accessibilityLabel(t("Manage Folders"))
            }
            Spacer()
            Button(t("Add Folder")) { controller.addFolder() }
        }
    }

    private var discoveryBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) { topics; Spacer(); filterMenu }
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.controlCluster) { topics; filterMenu }
        }
    }

    private var topics: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            ForEach([("Nature", "nature"), ("Cities", "city"), ("Minimal", "minimal")], id: \.0) { title, term in
                Button(t(title)) { onlineQuery = term }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker(t("Category"), selection: $categories) {
                Text(t("General")).tag("100"); Text(t("Anime")).tag("010"); Text(t("People")).tag("001"); Text(t("All")).tag("111")
            }
            Picker(t("Sort"), selection: $sorting) {
                Text(t("Popular")).tag("toplist"); Text(t("Latest")).tag("date_added"); Text(t("Random")).tag("random")
            }
            Picker(t("Orientation"), selection: $orientation) {
                Text(t("Landscape")).tag("landscape"); Text(t("Portrait")).tag("portrait"); Text(t("All")).tag("all")
            }
            Toggle(t("Match Display Resolution"), isOn: $matchResolution)
            Divider()
            Button(t("Refresh"), action: search)
        } label: { Label(t("Filters"), systemImage: "line.3.horizontal.decrease") }
    }

    private var galleryIdentity: [String] {
        [section, section == "local" ? folderID : "",
         section == "wallhaven" ? remoteQuery.identity : localQuery]
    }

    private var gallery: some View {
        let visibleAssets = assets
        return Group {
            if visibleAssets.isEmpty {
                emptyState.frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 300), spacing: PluginSettingsTheme.Spacing.rowHorizontal)],
                                  spacing: PluginSettingsTheme.Spacing.rowHorizontal) {
                            ForEach(visibleAssets) { asset in wallpaperTile(asset) }
                        }
                        .padding(2)
                        HStack {
                            Text(t("Click an image to preview it."))
                            Spacer()
                            if section == "wallhaven" { Text("Wallhaven") }
                        }
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary).padding(.top, 8)
                        if section == "wallhaven", !controller.searching, controller.currentPage > 0, controller.currentPage < controller.lastPage {
                            Button(t("Load More")) { controller.search(remoteQuery, more: true) }.padding(.vertical, 8)
                        }
                        if isLoading { ProgressView().controlSize(.small).padding(.vertical, 8) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Each collection owns its scroll viewport; a shorter result must never inherit an old offset.
        .id(galleryIdentity)
    }

    private func wallpaperTile(_ asset: WallpaperAsset) -> some View {
        Button { selected = asset } label: {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                WallpaperThumbnail(controller: controller, asset: asset, fillsFrame: true)
                    .aspectRatio(16.0 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control))
                    .overlay(alignment: .topTrailing) {
                        if controller.currentAsset?.id == asset.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .tint)
                                .padding(8).accessibilityLabel(t("Current Wallpaper"))
                        }
                    }
                HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    Text(asset.title).lineLimit(1)
                    Spacer(minLength: 0)
                    if controller.state.favorites.contains(asset.id) { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                }
                .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(asset.title).accessibilityLabel(t("Preview Wallpaper") + ": " + asset.title)
    }

    @ViewBuilder private var emptyState: some View {
        if isLoading {
            VStack(spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                ProgressView()
                Text(t("Loading…")).foregroundStyle(.secondary)
            }
        } else if section == "wallhaven" {
            emptyMessage("No Matching Wallpapers", description: "Try another search or relax the resolution filter.", symbol: "magnifyingglass") {
                Button(t("Retry"), action: search)
                if matchResolution { Button(t("Relax Filters")) { matchResolution = false } }
            }
        } else if !localQuery.isEmpty {
            emptyMessage("No Matching Wallpapers", description: "Try a different keyword.", symbol: "magnifyingglass") {
                Button(t("Clear Search")) { localQuery = "" }
            }
        } else if section == "favorites" {
            emptyMessage("No Favorites Yet", description: "Save wallpapers you like with the heart button.", symbol: "heart") {
                Button(t("Browse Online Wallpapers")) { section = "wallhaven" }.buttonStyle(.borderedProminent)
            }
        } else if section == "history" {
            emptyMessage("No Wallpaper History Yet", description: "Wallpapers you apply will appear here.", symbol: "clock") {
                Button(t("Browse Online Wallpapers")) { section = "wallhaven" }
            }
        } else {
            emptyMessage("Choose Your First Wallpaper", description: "Add a photo folder or explore online wallpapers.", symbol: "photo.on.rectangle.angled") {
                Button(t("Add Folder")) { controller.addFolder() }.buttonStyle(.borderedProminent)
                Button(t("Browse Online Wallpapers")) { section = "wallhaven" }
            }
        }
    }

    private func emptyMessage<Actions: View>(_ title: String, description: String, symbol: String,
                                            @ViewBuilder actions: () -> Actions) -> some View {
        ContentUnavailableView {
            Label(t(title), systemImage: symbol)
        } description: {
            Text(t(description))
        } actions: {
            actions()
        }
    }

    private func errorNotice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private func search() { if section == "wallhaven" { controller.search(remoteQuery) } }

    private func useVisibleCollection() {
        switch section {
        case "wallhaven":
            if controller.profile.collection != .wallhaven || controller.profile.query != remoteQuery { controller.useQuery(remoteQuery) }
        case "favorites":
            if controller.profile.collection != .favorites { controller.configure { $0.collection = .favorites } }
        case "local":
            if controller.profile.collection != .local { controller.configure { $0.collection = .local } }
        default: break
        }
    }

    private func setRotation(_ enabled: Bool) {
        if enabled { useVisibleCollection() }
        Task { _ = await controller.setRotation(enabled) }
    }
}

@MainActor
struct WallpaperThumbnail: View {
    @ObservedObject var controller: WallpaperController
    let asset: WallpaperAsset
    var fillsFrame = false
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: fillsFrame ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .clipped()
        .task(id: asset.id + (asset.managedName ?? "")) {
            guard let data = await controller.thumbnail(asset), !Task.isCancelled else { return }
            image = NSImage(data: data)
        }
        .accessibilityHidden(true)
    }
}
