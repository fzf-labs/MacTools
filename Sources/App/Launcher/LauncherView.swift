import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

struct LauncherRootView: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency
    @State private var aliasPresented = false
    @State private var alias = ""
    @State private var aliasID: String?
    @State private var aliasTitle = ""
    @State private var aliasError = false
    @ObservedObject private var localization = PluginRuntimeLocalization.source

    var body: some View {
        VStack(spacing: PluginPaletteMetrics.contentSpacing) {
            LauncherDragArea().frame(width: 72, height: 15).background(Capsule().fill(.tertiary).frame(height: 4))
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                CommandPaletteSearchField(text: $model.query, placeholder: LauncherText.search,
                    accessibilityLabel: LauncherText.search, accessibilityIdentifier: "mactools.launcher.search", focusRequestID: model.focusRequestID,
                    onCommand: { command in
                        switch command {
                        case let .moveSelection(offset): model.moveSelection(offset)
                        case .submit: model.activate()
                        case .alternateSubmit: model.actionsVisible = true
                        case .cancel: model.back()
                        }
                    }, preservesText: { _ in false }, onMarkedTextChange: { _ in })
                if model.isBusy { ProgressView().controlSize(.small) }
                Button(action: model.showSettings) { Image(systemName: "gearshape") }.buttonStyle(.plain).help(LauncherText.settings)
            }.padding(PluginPaletteMetrics.searchHorizontalPadding)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: PluginPaletteMetrics.searchCornerRadius))
            ScrollViewReader { proxy in
                List(selection: $model.selectedID) {
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.results) { result in
                                HStack(spacing: PluginPaletteMetrics.rowContentSpacing) {
                                    if case let .application(app) = result.target {
                                        Image(nsImage: model.host.applicationCatalog.icon(for: app)).resizable().scaledToFit().frame(width: 28, height: 28).accessibilityHidden(true)
                                    } else { Image(systemName: result.systemImage).frame(width: 28).accessibilityHidden(true) }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.title).font(PluginTypography.body.font).lineLimit(1)
                                        if !result.subtitle.isEmpty { Text(result.subtitle).font(PluginTypography.caption.font).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer(minLength: 4)
                                    Text(result.category.title).font(PluginTypography.caption.font).foregroundStyle(.secondary)
                                    if model.preferences.personalization.favorites.contains(result.id) { Image(systemName: "star.fill").foregroundStyle(.secondary).accessibilityLabel(LauncherText.favorite) }
                                    if let number = model.results.prefix(9).firstIndex(where: { $0.id == result.id }) { Text("⌘\(number + 1)").foregroundStyle(.tertiary) }
                                }.padding(.vertical, 4).contentShape(Rectangle())
                                    .onTapGesture(count: 2) { model.selectedID = result.id; model.activate() }
                                    .accessibilityAction { model.selectedID = result.id; model.activate() }
                                    .tag(result.id).id(result.id)
                            }
                        } header: { if !section.title.isEmpty { Text(section.title) } }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .overlay { if model.results.isEmpty { Text(model.query.isEmpty ? LauncherText.emptyHome : LauncherText.noResults).foregroundStyle(.secondary) } }
                    .onChange(of: model.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            }
            if let feedback = model.feedback {
                Text(feedback).font(PluginTypography.caption.font).foregroundStyle(.secondary).textSelection(.enabled)
                if model.canRecoverSettings { Button(LauncherText.openSystemSettings) { model.recoverSystemSettings() }.controlSize(.small) }
                else if case let .action(reference)? = model.selected?.target, model.host.canPresentActionOwner(for: reference) {
                    Button(LauncherText.settings) { model.dismiss(); _ = model.host.presentActionOwner(for: reference) }.controlSize(.small)
                }
            }
            Divider()
            HStack {
                Text(LauncherText.title).foregroundStyle(.secondary)
                Spacer()
                Button(LauncherText.actions + " ⌘K") { model.actionsVisible.toggle() }
                    .buttonStyle(.borderless).disabled(model.selected == nil)
                    .popover(isPresented: $model.actionsVisible, arrowEdge: .bottom) { actionPanel.padding().frame(width: 260) }
            }.font(PluginTypography.caption.font)
        }.padding(PluginPaletteMetrics.contentPadding)
            .background { PluginPaletteSurface(reducesTransparency: reducesTransparency) }
            .environment(\.locale, PluginRuntimeLocalization.locale)
            .environment(\.layoutDirection, StandaloneCommandPaletteRootView.layoutDirection(for: PluginRuntimeLocalization.locale))
            .sheet(isPresented: $aliasPresented, onDismiss: { model.isSuspended = false }) {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    Text(LauncherText.alias).font(PluginSettingsTheme.Typography.sectionTitle)
                    TextField(LauncherText.alias, text: $alias).frame(width: 280)
                    if aliasError { Text(LauncherText.aliasConflict).foregroundStyle(.red) }
                    HStack {
                        Button(LauncherText.cancel) { aliasPresented = false }.keyboardShortcut(.cancelAction)
                        Button(LauncherText.save) {
                            guard let id = aliasID else { return }
                            if model.preferences.setAlias(alias, for: id, title: aliasTitle) { aliasPresented = false } else { aliasError = true }
                        }.keyboardShortcut(.defaultAction)
                    }
                }.padding().environment(\.locale, PluginRuntimeLocalization.locale)
            }
    }
    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected = model.selected {
                ForEach(selected.actions) { action in
                    Button { model.activate(actionID: action.id) } label: { Label(action.title, systemImage: action.systemImage) }
                }
                Divider()
                Button(model.preferences.personalization.favorites.contains(selected.id) ? LauncherText.remove : LauncherText.favorite) { model.favorite(); model.actionsVisible = false }
                Button(LauncherText.alias) {
                    aliasID = selected.id; aliasTitle = selected.title; alias = model.preferences.personalization.aliases[selected.id] ?? ""
                    aliasError = false; model.actionsVisible = false; model.isSuspended = true; aliasPresented = true
                }
                Button(LauncherText.hide) { model.hideSelected(); model.actionsVisible = false }
                if case let .action(reference) = selected.target {
                    PluginShortcutRecorder(title: selected.title, displayText: model.host.actionShortcutSettingsItem(for: reference)?.bindingText ?? "",
                        onRecord: { binding in
                            switch model.host.setActionShortcutBinding(binding, to: reference) {
                            case .success: return .accepted
                            case let .failure(error): return .rejected(error.localizedDescription)
                            }
                        }, onBeginRecording: { model.isSuspended = true }, onEndRecording: { model.isSuspended = false })
                }
            }
        }.buttonStyle(.borderless)
    }
}

private struct LauncherDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}
