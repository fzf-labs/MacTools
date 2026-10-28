import AppKit
import ImageIO
import SwiftUI
import MacToolsPluginKit

struct RightClickNavigationRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Image(systemName: symbol).frame(width: PluginSettingsTheme.Size.rowIcon)
                Text(title).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .font(PluginSettingsTheme.Typography.rowTitle)
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .padding(.horizontal, PluginSettingsTheme.Spacing.sectionHeaderContent)
            .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
            .background(selected ? PluginSettingsTheme.Palette.sidebarSelectionBackground : hovering ? PluginSettingsTheme.Palette.sidebarHoverBackground : Color.clear,
                        in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct RightClickIconThumbnail: View {
    let url: URL
    let fallback: NSImage?
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let image = thumbnail ?? fallback { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .frame(width: PluginSettingsTheme.Size.metricIcon, height: PluginSettingsTheme.Size.metricIcon)
        .accessibilityHidden(true)
        .task(id: url) {
            thumbnail = nil
            let sourceURL = url
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 144
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled, let image else { return }
            thumbnail = NSImage(cgImage: image, size: .zero)
        }
    }
}

struct RightClickSectionHeader: View {
    let title: String
    let symbol: String
    var showsIcon = true
    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Group {
                if showsIcon { Label(title, systemImage: symbol) }
                else { Text(title) }
            }
            .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

struct RightClickActionIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(PluginSettingsTheme.Typography.rowTitle).foregroundStyle(Color.accentColor)
            .frame(width: PluginSettingsTheme.Size.controlHeight, height: PluginSettingsTheme.Size.controlHeight)
            .background(PluginSettingsTheme.Palette.activeControlBackground, in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control))
            .accessibilityHidden(true)
    }
}

struct RightClickEmptyState: View {
    let title: String
    let symbol: String
    let description: String
    var body: some View {
        VStack(spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Image(systemName: symbol).font(.system(size: PluginSettingsTheme.Size.emptyStateIcon)).foregroundStyle(.tertiary)
            Text(title).font(PluginSettingsTheme.Typography.sectionTitle)
            Text(description).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .frame(maxWidth: .infinity, minHeight: 140)
    }
}
