import MacToolsPluginKit
import SwiftUI

@MainActor
struct WallpaperPreviewSheet: View {
    @ObservedObject var controller: WallpaperController
    let selection: WallpaperAsset
    @Environment(\.dismiss) private var dismiss
    @State private var savingFavorite = false
    @State private var savingImage = false

    private func t(_ key: String) -> String { controller.text(key) }
    private var asset: WallpaperAsset { controller.state.assets[selection.id] ?? selection }
    private var isWorking: Bool { controller.busy || savingFavorite || savingImage }
    private var isFavorite: Bool { controller.state.favorites.contains(asset.id) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                if isWorking {
                    HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                        ProgressView().controlSize(.small)
                        Text(t(controller.busy ? "Applying…" : "Saving…"))
                    }
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
                if let error = controller.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                WallpaperThumbnail(controller: controller, asset: asset)
                    .frame(maxWidth: .infinity).frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control))
                metadata
            }
            .padding(PluginSettingsTheme.Spacing.pagePadding)
        }
        .frame(minWidth: 600, idealWidth: 680, maxWidth: 760)
        .buttonStyle(.bordered).controlSize(.small)
    }

    private var toolbar: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Button {
                if controller.busy { controller.cancelOperation() }
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical).imageScale(.large)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            .help(t("Close")).accessibilityLabel(t("Close"))
            .disabled(savingImage)

            Text(asset.title)
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                .help(asset.title)

            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Button {
                    savingFavorite = true
                    Task { await controller.favorite(asset.id); savingFavorite = false }
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? .pink : .primary)
                }
                .help(t(isFavorite ? "Remove Favorite" : "Favorite"))
                .accessibilityLabel(t(isFavorite ? "Remove Favorite" : "Favorite"))

                if asset.pageURL != nil {
                    Button {
                        savingImage = true
                        Task { await controller.saveImage(asset); savingImage = false }
                    } label: { Image(systemName: "square.and.arrow.down") }
                    .help(t("Save Image…")).accessibilityLabel(t("Save Image…"))
                    Button { controller.openSource(asset) } label: { Image(systemName: "arrow.up.right.square") }
                        .help(t("View Source")).accessibilityLabel(t("View Source"))
                } else if asset.localURL != nil {
                    Button { controller.openSource(asset) } label: { Image(systemName: "folder") }
                        .help(t("Show in Finder")).accessibilityLabel(t("Show in Finder"))
                }
            }
            .disabled(isWorking)

            Button(t("Apply Wallpaper")) {
                Task {
                    if case .succeeded = await controller.execute("apply-asset", assetID: asset.id) { dismiss() }
                }
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            .disabled(isWorking)
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }

    private var metadata: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            if asset.width > 0, asset.height > 0 {
                Text("\(asset.width.formatted(.number.locale(PluginRuntimeLocalization.locale))) × \(asset.height.formatted(.number.locale(PluginRuntimeLocalization.locale)))")
                    .fixedSize()
            }
            Label(controller.scopeTitle(controller.state.selectedScope), systemImage: "display")
                .lineLimit(1)
            Spacer(minLength: 0)
            if asset.pageURL != nil {
                Text(asset.uploader.map { "Wallhaven · " + $0 } ?? "Wallhaven").lineLimit(1)
            }
        }
        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
    }
}
