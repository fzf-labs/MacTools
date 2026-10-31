import MacToolsPluginKit
import SwiftUI

@MainActor
struct WallpaperQuickView: View {
    @ObservedObject var controller: WallpaperController
    let isPreview: Bool
    let openSettings: () -> Void
    @Environment(\.pluginComponentTheme) private var theme
    @Environment(\.pluginPresentationIsVisible) private var visible

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(controller.text("Wallpaper"), systemImage: "photo.on.rectangle")
                    .font(PluginTypography.body.font)
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .help(controller.text("Open Wallpaper Settings"))
                    .accessibilityLabel(controller.text("Open Wallpaper Settings"))
            }
            if !isPreview, visible, let asset = controller.currentAsset {
                WallpaperThumbnail(controller: controller, asset: asset).frame(height: 100).clipped()
                Text(asset.title).font(PluginTypography.caption.font).lineLimit(1)
            } else {
                Image(systemName: "photo").font(.largeTitle).frame(maxWidth: .infinity).frame(height: 100)
                    .foregroundStyle(theme.text.secondary)
            }
            Picker(controller.text("Display"), selection: Binding(get: { controller.state.selectedScope }, set: controller.selectScope)) {
                if !controller.state.independentDisplays { Text(controller.text("All Displays")).tag("all") }
                ForEach(controller.displays) { Text(controller.scopeTitle($0.id)).tag($0.id) }
            }.labelsHidden().frame(maxWidth: .infinity)
            HStack {
                Button { Task { _ = await controller.execute("previous") } } label: { Image(systemName: "backward.end") }
                    .help(controller.text("Previous Wallpaper")).accessibilityLabel(controller.text("Previous Wallpaper"))
                    .disabled(!controller.canGoBack)
                Button { Task { _ = await controller.execute("next") } } label: { Image(systemName: "forward.end") }
                    .help(controller.text("Next Wallpaper")).accessibilityLabel(controller.text("Next Wallpaper"))
                if let asset = controller.currentAsset {
                    Button { Task { await controller.favorite(asset.id) } } label: {
                        Image(systemName: controller.state.favorites.contains(asset.id) ? "heart.fill" : "heart")
                    }.help(controller.text("Favorite")).accessibilityLabel(controller.text("Favorite"))
                }
                Spacer(minLength: 0)
                Toggle(controller.text("Automatic Rotation"), isOn: Binding(get: { controller.profile.enabled }, set: { value in
                    Task { _ = await controller.setRotation(value) }
                })).labelsHidden().toggleStyle(.switch).help(controller.text("Automatic Rotation"))
            }
        }
        .padding(12)
        .foregroundStyle(theme.text.primary)
        .background(theme.surfaces.card, in: RoundedRectangle(cornerRadius: 12))
        .controlSize(.small).buttonStyle(.bordered)
        .disabled(isPreview || !controller.ready || controller.busy)
    }
}
