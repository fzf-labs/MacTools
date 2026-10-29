import SwiftUI
import MacToolsPluginKit

struct PluginFilterBarView: View {
    @Binding var searchText: String
    @Binding var selectedFilter: PluginCategoryFilter
    @Binding var activationFilter: PluginActivationFilter
    @Binding var sortMode: PluginMarketplaceSortMode
    @FocusState.Binding var isSearchFocused: Bool
    let countsByFilter: [PluginCategoryFilter: Int]
    var searchPrompt: String = AppL10n.plugins("plugin.filter.searchPrompt", defaultValue: "搜索插件名称或简介")

    var body: some View {
        SettingsSearchFilterBar(
            searchText: $searchText,
            isSearchFocused: $isSearchFocused,
            searchPrompt: searchPrompt,
            clearSearchHelp: AppL10n.plugins(
                "plugin.filter.clearSearch",
                defaultValue: "清除搜索"
            )
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowHorizontal) {
                    categoryMenu
                    activationMenu
                    Spacer(minLength: 0)
                    sortMenu
                }
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: PluginSettingsTheme.Spacing.rowHorizontal) {
                            categoryMenu
                            activationMenu
                        }
                        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                            categoryMenu
                            activationMenu
                        }
                    }
                    sortMenu
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var categoryMenu: some View {
        let title = FeatureL10n.string("分类")
        return SettingsFilterMenu(
            title: title, value: categoryTitle(selectedFilter), systemImage: "square.grid.2x2"
        ) {
            Picker(title, selection: $selectedFilter) {
                ForEach(visibleFilters) { filter in
                    Text(categoryTitle(filter)).tag(filter)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .accessibilityIdentifier("mactools.marketplace.category-filter")
    }

    private func categoryTitle(_ filter: PluginCategoryFilter) -> String {
        let count = (countsByFilter[filter] ?? 0).formatted(.number.locale(PluginRuntimeLocalization.locale))
        return "\(filter.displayName) (\(count))"
    }

    private var activationMenu: some View {
        let title = AppL10n.plugins("plugin.filter.status", defaultValue: "状态")
        return SettingsFilterMenu(
            title: title, value: activationFilter.displayName, systemImage: "line.3.horizontal.decrease.circle"
        ) {
            Picker(title, selection: $activationFilter) {
                ForEach(PluginActivationFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .accessibilityIdentifier("mactools.marketplace.activation-filter")
    }

    private var sortMenu: some View {
        let title = AppL10n.plugins("plugin.marketplace.sort.label", defaultValue: "排序")
        return SettingsFilterMenu(
            title: title, value: sortMode.displayName, systemImage: "arrow.up.arrow.down"
        ) {
            Picker(title, selection: $sortMode) {
                ForEach(PluginMarketplaceSortMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .help(AppL10n.plugins("plugin.marketplace.sort.help", defaultValue: "调整市场列表排序，不影响菜单栏功能顺序。"))
    }

    private var visibleFilters: [PluginCategoryFilter] {
        var filters: [PluginCategoryFilter] = [.all]

        for category in PluginCategory.orderedCases {
            let filter = PluginCategoryFilter.category(category)
            if (countsByFilter[filter] ?? 0) > 0 || filter == selectedFilter {
                filters.append(filter)
            }
        }

        return filters
    }
}

struct SettingsFilterMenu<Content: View>: View {
    let title: String
    let value: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Image(systemName: systemImage)
                    .foregroundStyle(.blue)
                Text(title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(value)
                    .font(PluginSettingsTheme.Typography.rowTitle)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
        .menuStyle(.borderedButton)
        .menuIndicator(.visible)
        .controlSize(.regular)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

struct SettingsSearchFilterBar<Filters: View>: View {
    @Binding private var searchText: String
    @FocusState.Binding private var isSearchFocused: Bool
    private let searchPrompt: String
    private let clearSearchHelp: String
    private let searchAccessibilityIdentifier: String?
    private let filters: Filters

    init(
        searchText: Binding<String>,
        isSearchFocused: FocusState<Bool>.Binding,
        searchPrompt: String,
        clearSearchHelp: String,
        searchAccessibilityIdentifier: String? = nil,
        @ViewBuilder filters: () -> Filters
    ) {
        _searchText = searchText
        _isSearchFocused = isSearchFocused
        self.searchPrompt = searchPrompt
        self.clearSearchHelp = clearSearchHelp
        self.searchAccessibilityIdentifier = searchAccessibilityIdentifier
        self.filters = filters()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            filters
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)

            searchTextField

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(clearSearchHelp)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsStyle.fieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var searchTextField: some View {
        let field = TextField(searchPrompt, text: $searchText)
            .textFieldStyle(.plain)
            .font(PluginSettingsTheme.Typography.rowTitle)
            .focused($isSearchFocused)

        if let searchAccessibilityIdentifier {
            field.accessibilityIdentifier(searchAccessibilityIdentifier)
        } else {
            field
        }
    }
}

struct SettingsFilterChipsRow<Chips: View>: View {
    let accessibilityLabel: String
    private let chips: Chips

    init(
        accessibilityLabel: String,
        @ViewBuilder chips: () -> Chips
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.chips = chips()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chips
            }
            .padding(.vertical, 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct SettingsFilterChip: View {
    let title: String
    let systemImage: String
    let iconTint: Color
    let count: Int
    let isSelected: Bool
    var accessibilityIdentifier: String? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: PluginSystemImage.resolvedName(systemImage))
                    .font(PluginSettingsTheme.Typography.secondaryLabel.weight(.semibold))
                    .foregroundStyle(iconColor)

                Text(title)
                    .font(PluginSettingsTheme.Typography.secondaryLabel.weight(.medium))
                    .foregroundStyle(textColor)

                Text("\(count)")
                    .font(PluginSettingsTheme.Typography.statusBadge.weight(.semibold))
                    .foregroundStyle(countTextColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(countBackground)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(chipBackground)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .modifier(OptionalAccessibilityIdentifier(identifier: accessibilityIdentifier))
    }

    private var iconColor: Color {
        isSelected ? .white : iconTint
    }

    private var textColor: Color {
        isSelected ? .white : .primary
    }

    private var countTextColor: Color {
        isSelected ? .white : .secondary
    }

    private var countBackground: Color {
        if isSelected {
            return Color.white.opacity(0.22)
        }

        return Color(nsColor: .quaternaryLabelColor).opacity(0.7)
    }

    private var chipBackground: Color {
        if isSelected {
            return Color.accentColor
        }

        if isHovered {
            return SettingsStyle.recessedControlBackground.opacity(0.72)
        }

        return SettingsStyle.recessedControlBackground.opacity(0.42)
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
