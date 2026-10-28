import SwiftUI
import MacToolsPluginKit

enum RightClickSettingsTab: String, CaseIterable, Identifiable {
    case functions, menu
    var id: Self { self }
    var title: String { switch self { case .functions: "Function Settings"; case .menu: "Menu Layout" } }
}

struct RightClickWorkspaceView: View {
    @ObservedObject var session: RightClickSettingsSession
    let localization: PluginLocalization
    @State private var tab = RightClickSettingsTab.functions
    @State private var category = RightClickCategory.create
    @State private var expandedAction: RightClickAction?
    @State private var revealAction: RightClickAction?

    private typealias Spacing = PluginSettingsTheme.Spacing
    private typealias Typography = PluginSettingsTheme.Typography
    private func text(_ key: String) -> String { localization.string(key, defaultValue: key) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
            toolbar
            if let error = session.error {
                HStack(alignment: .top, spacing: Spacing.rowContentControl) {
                    Label(text(error), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if session.needsSaveRetry { Button(text("Retry")) { session.saveDraft() } }
                }
                .font(Typography.rowDescription).padding(Spacing.cardContent)
                .pluginSettingsCardBackground(.standard)
            }
            // Keep both native scroll hierarchies mounted so tab changes preserve
            // scroll offsets, expanded editors, menu selections, and preview state.
            ZStack(alignment: .topLeading) {
                functions
                    .opacity(tab == .functions ? 1 : 0)
                    .allowsHitTesting(tab == .functions)
                    .disabled(session.isWorking || tab != .functions)
                    .accessibilityElement(children: .contain)
                    .accessibilityHidden(tab != .functions)
                RightClickMenuLayoutView(session: session, localization: localization, configure: showSettings)
                    .opacity(tab == .menu ? 1 : 0)
                    .allowsHitTesting(tab == .menu)
                    .disabled(session.isWorking || tab != .menu)
                    .accessibilityElement(children: .contain)
                    .accessibilityHidden(tab != .menu)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    private var toolbar: some View {
        HStack(spacing: Spacing.rowContentControl) {
            Picker("", selection: $tab) {
                ForEach(RightClickSettingsTab.allCases) { Text(text($0.title)).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            .accessibilityLabel(text("Function Settings") + ", " + text("Menu Layout"))
            Spacer(minLength: 0)
            if session.isWorking {
                ProgressView().controlSize(.small).accessibilityLabel(text("Processing files…"))
            }
            Menu {
                Button(text("Import Templates and Icons")) { commands.importPackage() }
                Button(text("Export Templates and Icons")) { commands.exportPackage() }.disabled(session.configuration.resources.isEmpty)
            } label: { Image(systemName: "ellipsis") }
            .menuIndicator(.hidden).fixedSize().accessibilityLabel(text("Templates and Icons Package"))
            .disabled(session.isWorking)
        }
    }

    private var functions: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 620 {
                HStack(alignment: .top, spacing: Spacing.section) {
                    navigation.frame(width: 140)
                    actionSettings
                }
            } else {
                VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
                    Picker(text("Category"), selection: Binding(get: { category }, set: navigate)) {
                        ForEach(RightClickCategory.allCases) { Text(text($0.title)).tag($0) }
                    }
                    .fixedSize().accessibilityLabel(text("Category"))
                    actionSettings
                }
            }
        }
    }

    private var navigation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.rowTitleDescription) {
                ForEach(RightClickCategory.allCases) { item in
                    RightClickNavigationRow(title: text(item.title), symbol: item.symbol,
                                            selected: category == item) { navigate(item) }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var actionSettings: some View {
        VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
            RightClickSectionHeader(title: text(category.title), symbol: category.symbol)
            RightClickActionSettingsView(session: session, localization: localization, category: category,
                                         expandedAction: $expandedAction, revealAction: $revealAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var commands: RightClickResourceCommands { .init(session: session, localization: localization) }

    private func navigate(_ category: RightClickCategory) {
        guard self.category != category else { return }
        expandedAction = nil
        revealAction = nil
        self.category = category
    }

    private func showSettings(_ action: RightClickAction) {
        category = action.category
        expandedAction = RightClickResourceEditorKind(action: action) == nil ? nil : action
        revealAction = action
        tab = .functions
    }
}
