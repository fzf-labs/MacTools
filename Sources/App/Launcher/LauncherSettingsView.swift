import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

struct LauncherSettingsView: View {
    @StateObject private var model: LauncherSettingsModel
    let category: LauncherCategory?

    init(host: PluginHost, category: LauncherCategory? = nil) {
        self.category = category
        _model = StateObject(wrappedValue: LauncherSettingsModel(host: host))
    }

    var body: some View { LauncherSettingsContent(model: model, category: category) }
}

private struct LauncherSettingsEntryGroup: Identifiable {
    let id: String
    let title: String
    let entries: [LauncherResult]
}

private enum LauncherSettingsRow: Identifiable {
    case heading(LauncherSettingsEntryGroup)
    case entry(LauncherResult)

    var id: String {
        switch self {
        case let .heading(group): "heading." + group.id
        case let .entry(entry): entry.id
        }
    }
}

private enum LauncherSettingsMetrics {
    static let iconSize: CGFloat = 24
    static let rowHeight: CGFloat = 36
    static let aliasWidth: CGFloat = 140
}

private struct LauncherSettingsContent: View {
    @ObservedObject var model: LauncherSettingsModel
    @ObservedObject private var preferences: LauncherPreferences
    @ObservedObject private var catalog: ApplicationCatalog
    let category: LauncherCategory?
    @State private var filter = ""
    @State private var showingScopes = false

    init(model: LauncherSettingsModel, category: LauncherCategory?) {
        self.model = model
        self.category = category
        _preferences = ObservedObject(wrappedValue: model.preferences)
        _catalog = ObservedObject(wrappedValue: model.catalog)
    }

    var body: some View {
        let snapshot = model.results(for: category)
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = snapshot.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
                || (preferences.personalization.aliases[$0.id]?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.keywords.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }.sorted {
            $0.subtitle == $1.subtitle ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : $0.subtitle.localizedStandardCompare($1.subtitle) == .orderedAscending
        }
        let groups = Dictionary(grouping: entries, by: { $0.pluginID ?? "" }).map { id, values in
            LauncherSettingsEntryGroup(id: id, title: values.first.map { $0.subtitle.isEmpty ? $0.title : $0.subtitle } ?? id, entries: values)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })

        let tableRows: [LauncherSettingsRow] = category == .pluginFeatures || category == .systemOperations
            ? groups.flatMap { [.heading($0)] + $0.entries.map(LauncherSettingsRow.entry) }
            : entries.map(LauncherSettingsRow.entry)

        return SettingsGroupedFormLayout(widthPolicy: .general) { widths in
            if let category {
                Section {
                    Toggle(category.title, isOn: sourceBinding(category))
                        .toggleStyle(.switch)
                        .help(LauncherText.sourceHint)
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                    if category == .applications || category == .systemSettings {
                        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                            if category == .applications { Button(LauncherText.searchScopes) { showingScopes = true } }
                            Spacer()
                            if isRefreshing { ProgressView().controlSize(.small) }
                            Button(LauncherText.refresh) {
                                if category == .applications { catalog.refresh() }
                                else { model.host.systemSettingsCatalog.refresh(force: true) }
                            }.disabled(isRefreshing)
                        }
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                    }
                }
                Section {
                    TextField("", text: $filter, prompt: Text(LauncherText.filterItems))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel(LauncherText.filterItems)
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                    if isRefreshing && entries.isEmpty {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .settingsGroupedFormRowWidth(widths.sectionLayout)
                    } else if entries.isEmpty {
                        Text(query.isEmpty ? (category == .applications ? LauncherText.noApplications : LauncherText.noAvailableItems) : LauncherText.tryAnotherSearch)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .settingsGroupedFormRowWidth(widths.sectionLayout)
                    } else {
                        SettingsEmbeddedRows(elements: tableRows, rowHeight: LauncherSettingsMetrics.rowHeight) { row in
                            Group {
                                switch row {
                                case let .heading(group):
                                    Text(group.title)
                                        .font(PluginSettingsTheme.Typography.sectionTitle)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                case let .entry(entry):
                                    entryRow(entry)
                                }
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                    }
                }
            } else {
                generalSections(entries: entries, byID: byID, width: widths.sectionLayout)
            }
        }
        .id(category?.rawValue ?? "general")
        .buttonStyle(.bordered)
        .controlSize(.small)
        .task(id: category) {
            filter = ""
            if category == .applications { catalog.loadIfNeeded() }
            if category == nil || category == .systemSettings { model.host.systemSettingsCatalog.loadIfNeeded() }
        }
        .sheet(isPresented: $showingScopes) { LauncherSearchScopesView(catalog: catalog) }
    }

    private var isRefreshing: Bool {
        category == .applications ? catalog.isRefreshing : category == .systemSettings && model.host.systemSettingsCatalog.isRefreshing
    }

    private func sourceBinding(_ category: LauncherCategory) -> Binding<Bool> {
        Binding(get: { !preferences.personalization.disabledSources.contains(category.rawValue) }, set: { enabled in
            preferences.update {
                if enabled { $0.disabledSources.remove(category.rawValue) }
                else { $0.disabledSources.insert(category.rawValue) }
            }
        })
    }

    @ViewBuilder
    private func generalSections(entries: [LauncherResult], byID: [String: LauncherResult], width: CGFloat) -> some View {
        let favorites = preferences.personalization.favorites.compactMap { byID[$0] }
        let recent = Array(entries.filter { preferences.usage[$0.id] != nil }.sorted {
            (preferences.usage[$0.id]?.lastUsed ?? .distantPast) > (preferences.usage[$1.id]?.lastUsed ?? .distantPast)
        }.prefix(8))

        Section {
            LabeledContent(LauncherText.openLauncher) {
                Button(LauncherText.open) { model.host.appPresentationHandler?(.toggleLauncher) }
            }
            .settingsGroupedFormRowWidth(width)
            if let item = model.host.appShortcutItems.first(where: { $0.action == .openLauncher }) {
                LabeledContent(LauncherText.shortcut) {
                    HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                        PluginShortcutRecorder(title: LauncherText.openLauncher, displayText: item.bindingText,
                            onRecord: { binding in
                                if let error = model.host.setAppShortcutBindingAndReturnError(binding, for: .openLauncher) { return .rejected(error) }
                                return .accepted
                            })
                        if item.canClear {
                            Button { model.host.clearAppShortcut(.openLauncher) } label: { Image(systemName: "xmark") }
                                .help(LauncherText.remove).accessibilityLabel(LauncherText.remove)
                        }
                    }
                }
                .settingsGroupedFormRowWidth(width)
            }
        }
        Section(LauncherText.favorite) {
            if favorites.isEmpty {
                Text(LauncherText.noFavorites).foregroundStyle(.secondary).help(LauncherText.favoritesHint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsGroupedFormRowWidth(width)
            } else {
                SettingsEmbeddedRows(elements: favorites, rowHeight: LauncherSettingsMetrics.rowHeight) { entry in
                    HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                        resultLabel(entry)
                        Spacer()
                        Button {
                            preferences.update { p in
                                if let visibleIndex = favorites.firstIndex(where: { $0.id == entry.id }), visibleIndex > 0,
                                   let index = p.favorites.firstIndex(of: entry.id),
                                   let previousIndex = p.favorites.firstIndex(of: favorites[visibleIndex - 1].id) {
                                    p.favorites.swapAt(index, previousIndex)
                                }
                            }
                        } label: { Image(systemName: "arrow.up") }
                        .disabled(favorites.first?.id == entry.id)
                        .help(LauncherText.moveUp).accessibilityLabel(LauncherText.moveUp)
                        Button { preferences.toggleFavorite(entry.id) } label: { Image(systemName: "minus") }
                            .help(LauncherText.remove).accessibilityLabel(LauncherText.remove)
                    }
                    .frame(minHeight: LauncherSettingsMetrics.rowHeight)
                    .overlay(alignment: .bottom) { Divider() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
                .settingsGroupedFormRowWidth(width)
            }
        }
        Section(LauncherText.recent) {
            if recent.isEmpty {
                Text(LauncherText.noRecent).foregroundStyle(.secondary).help(LauncherText.recentHint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsGroupedFormRowWidth(width)
            } else {
                ForEach(recent) { entry in resultLabel(entry).settingsGroupedFormRowWidth(width) }
            }
            HStack {
                Button(LauncherText.clearHistory) { preferences.clearUsage() }.disabled(preferences.usage.isEmpty)
                Spacer()
                Button(LauncherText.restoreHidden) { preferences.update { $0.hidden = [] } }
                    .disabled(preferences.personalization.hidden.isEmpty)
            }
            .settingsGroupedFormRowWidth(width)
        }
    }

    private func entryRow(_ entry: LauncherResult) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            resultLabel(entry)
            Spacer(minLength: PluginSettingsTheme.Spacing.controlCluster)
            LauncherSettingsAliasField(entry: entry, preferences: preferences)
            Toggle(entry.title, isOn: Binding(
                get: { !preferences.personalization.hidden.contains(entry.id) },
                set: { enabled in
                    preferences.update {
                        if enabled { $0.hidden.remove(entry.id) } else { $0.hidden.insert(entry.id) }
                    }
                }))
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel(entry.title)
                .help(LauncherText.sourceHint)
        }
        .frame(minHeight: LauncherSettingsMetrics.rowHeight)
        .overlay(alignment: .bottom) { Divider() }
        .contextMenu {
            Button(preferences.personalization.favorites.contains(entry.id) ? LauncherText.removeFavorite : LauncherText.favorite) {
                preferences.toggleFavorite(entry.id)
            }
        }
    }

    private func resultLabel(_ entry: LauncherResult) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Group {
                if case let .application(app) = entry.target {
                    Image(nsImage: catalog.icon(for: app)).resizable().scaledToFit()
                } else {
                    Image(systemName: entry.systemImage).foregroundStyle(.secondary)
                }
            }
            .frame(width: LauncherSettingsMetrics.iconSize, height: LauncherSettingsMetrics.iconSize)
            .accessibilityHidden(true)
            Text(entry.title).font(PluginTypography.body.font).lineLimit(1)
            if preferences.personalization.favorites.contains(entry.id) {
                Image(systemName: "star.fill").font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary).accessibilityLabel(LauncherText.favorite)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(entry.title + (entry.subtitle.isEmpty ? "" : "\n" + entry.subtitle))
    }
}

private struct LauncherSettingsAliasField: View {
    let entry: LauncherResult
    @ObservedObject var preferences: LauncherPreferences
    @State private var alias = ""
    @State private var hasError = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            TextField("", text: $alias, prompt: Text(LauncherText.alias))
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($isFocused)
                .accessibilityLabel(entry.title + ": " + LauncherText.alias)
                .onSubmit(save)
                .onExitCommand {
                    alias = preferences.personalization.aliases[entry.id] ?? ""
                    hasError = false
                    isFocused = false
                }
            if hasError {
                Text(LauncherText.aliasConflict).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red)
            }
        }
        .frame(width: LauncherSettingsMetrics.aliasWidth)
        .onAppear { alias = preferences.personalization.aliases[entry.id] ?? "" }
        .onChange(of: isFocused) { _, focused in if !focused { save() } }
        .onChange(of: preferences.personalization.aliases[entry.id]) { _, value in alias = value ?? "" }
    }

    private func save() {
        guard alias != (preferences.personalization.aliases[entry.id] ?? "") else { hasError = false; return }
        hasError = !preferences.setAlias(alias, for: entry.id, title: entry.title)
    }
}

private struct LauncherSearchScopesView: View {
    @ObservedObject var catalog: ApplicationCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var choosingScope = false

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            Label(LauncherText.searchScopes, systemImage: "folder").font(PluginSettingsTheme.Typography.sectionTitle)
            List {
                Section(LauncherText.defaultScopes) {
                    ForEach(ApplicationScanner.defaultSearchRoots, id: \.self) { path in scopeRow(path, removable: false) }
                }
                if !catalog.additionalSearchRoots.isEmpty {
                    Section(LauncherText.additionalScopes) {
                        ForEach(catalog.additionalSearchRoots, id: \.self) { path in scopeRow(path, removable: true) }
                    }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).pluginSettingsCardBackground(.standard)
            HStack {
                Button(LauncherText.addScope) { choosingScope = true }
                Spacer()
                Button(LauncherText.done) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(PluginSettingsTheme.Spacing.pagePadding)
        .frame(width: 600, height: 460)
        .background(SettingsStyle.contentBackground)
        .buttonStyle(.bordered).controlSize(.small)
        .onExitCommand { dismiss() }
        .fileImporter(isPresented: $choosingScope, allowedContentTypes: [.folder, .applicationBundle], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { for url in urls { _ = catalog.addSearchRoot(url) } }
        }
    }

    private func scopeRow(_ path: String, removable: Bool) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Label(path, systemImage: path.hasSuffix(".app") ? "app" : "folder")
                .font(PluginSettingsTheme.Typography.rowDescription).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).help(path)
            Spacer()
            if removable {
                Button { catalog.removeSearchRoot(path) } label: { Image(systemName: "minus.circle") }
                    .help(LauncherText.remove).accessibilityLabel(LauncherText.remove)
            }
        }
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }
}
