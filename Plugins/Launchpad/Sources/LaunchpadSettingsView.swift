import SwiftUI
import MacToolsPluginKit

/// Launcher settings. Host renders the page header; this view starts at the first
/// group (per the settings spec). Bindings write straight through to the persisted
/// `LaunchpadPreferences`.
struct LaunchpadSettingsView: View {
    enum SectionKind {
        case window
        case appearance
        case background
        case grid
        case sorting
        case hiddenApps
    }

    @ObservedObject var preferences: LaunchpadPreferences
    /// Observed so the sorting group appears / disappears as the custom layout is created or reset.
    @ObservedObject var layoutStore: LaunchpadLayoutStore
    let localization: PluginLocalization
    let sectionKind: SectionKind
    var retainedApplicationName: (String) -> String? = { _ in nil }

    private var isAutoColumns: Binding<Bool> {
        Binding(
            get: { preferences.columns == LaunchpadPreferences.autoColumns },
            set: { preferences.columns = $0 ? LaunchpadPreferences.autoColumns : 7 }
        )
    }

    @ViewBuilder
    var body: some View {
        switch sectionKind {
        case .window:
            windowSection
        case .appearance:
            appearanceSection
        case .background:
            backgroundSection
        case .grid:
            gridSection
        case .sorting:
            sortSection
        case .hiddenApps:
            hiddenSection
        }
    }

    /// Only shown once the user has dragged into a custom order (`layout != nil`); resetting
    /// removes the layout key → back to alphabetical, and the group disappears.
    @ViewBuilder
    private var sortSection: some View {
        if layoutStore.layout != nil {
            section(
                title: localization.string("settings.sorting.title", defaultValue: "排序"),
                icon: "arrow.up.arrow.down"
            ) {
                row(
                    title: localization.string("settings.sorting.customOrder.title", defaultValue: "自定义排序"),
                    description: localization.string(
                        "settings.sorting.customOrder.description",
                        defaultValue: "已手动调整过应用顺序"
                    )
                ) {
                    Button(localization.string("settings.sorting.restoreAlphabetical", defaultValue: "恢复字母序")) {
                        layoutStore.resetToAlphabetical()
                    }
                        .controlSize(.small)
                }
            }
        }
    }

    private var sortedHiddenIDs: [String] {
        preferences.hiddenAppIDs.sorted {
            appName(for: $0).localizedCaseInsensitiveCompare(appName(for: $1)) == .orderedAscending
        }
    }

    /// Hidden ids are absolute paths; derive a display name without needing the catalog
    /// (the app may even be uninstalled).
    private func appName(for id: String) -> String {
        retainedApplicationName(id) ?? URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent
    }

    @ViewBuilder
    private var hiddenSection: some View {
        if !preferences.hiddenAppIDs.isEmpty {
            let ids = sortedHiddenIDs
            section(title: localization.string("settings.hiddenApps.title", defaultValue: "隐藏的应用"), icon: "eye.slash") {
                VStack(spacing: PluginSettingsTheme.Spacing.rowVertical) {
                    ForEach(ids, id: \.self) { id in
                        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                            Text(appName(for: id))
                                .font(PluginSettingsTheme.Typography.rowTitle)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                            Button(localization.string("settings.hiddenApps.restore", defaultValue: "恢复")) {
                                preferences.unhide(id)
                            }
                                .controlSize(.small)
                        }
                        if id != ids.last { Divider() }
                    }
                    Divider()
                    HStack {
                        Spacer()
                        Button(localization.string("settings.hiddenApps.restoreAll", defaultValue: "全部恢复")) {
                            preferences.unhideAll()
                        }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var windowSection: some View {
        section(title: localization.string("settings.window.title", defaultValue: "窗口"), icon: "macwindow") {
            VStack(spacing: PluginSettingsTheme.Spacing.rowVertical) {
                row(
                    title: localization.string("settings.window.mode.title", defaultValue: "唤出方式"),
                    description: preferences.windowMode == .fullscreen
                        ? localization.string(
                            "settings.window.mode.fullscreenDescription",
                            defaultValue: "铺满当前屏幕，点击空白处关闭"
                        )
                        : localization.string(
                            "settings.window.mode.compactDescription",
                            defaultValue: "屏幕中央的浮窗，点击窗外关闭"
                        )
                ) {
                    Picker("", selection: $preferences.windowMode) {
                        ForEach(LaunchpadPreferences.WindowMode.allCases) { mode in
                            Text(mode.label(localization: localization)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // Intrinsic width (see the glass-style picker below) so the
                    // 2-segment control never overflows its card on either language.
                    .fixedSize()
                }
                Divider()
                row(
                    title: localization.string("settings.hotCorner.title", defaultValue: "热区唤起"),
                    description: localization.string(
                        "settings.hotCorner.description",
                        defaultValue: "光标停在所选屏幕角落即唤出启动台"
                    )
                ) {
                    Picker("", selection: $preferences.hotCorner) {
                        ForEach(LaunchpadPreferences.HotCorner.allCases) { corner in
                            Text(corner.label(localization: localization)).tag(corner)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                // Window-size slider (ruling A6): only meaningful in compact mode, so it
                // shows conditionally — same expand pattern as the fixed-columns stepper.
                if preferences.windowMode == .compact {
                    Divider()
                    row(
                        title: localization.string("settings.window.size.title", defaultValue: "窗口大小"),
                        description: localization.string(
                            "settings.window.size.description",
                            defaultValue: "紧凑窗口占屏幕的比例"
                        )
                    ) {
                        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                            PluginSettingsSlider(
                                value: compactScaleBinding,
                                in: Double(LaunchpadPreferences.minCompactScale)
                                    ... Double(LaunchpadPreferences.maxCompactScale),
                                step: 1
                            )
                            .frame(minWidth: 120, idealWidth: 160, maxWidth: 200)
                            Text(
                                localization.format(
                                    "settings.window.size.value",
                                    defaultValue: "%d%%",
                                    preferences.compactScalePercent
                                )
                            )
                            .font(PluginSettingsTheme.Typography.monospacedValue)
                            .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Appearance (design §3.2)

    private var showsAppNamesBinding: Binding<Bool> {
        Binding(
            get: { !preferences.hidesAppNames },
            set: { preferences.hidesAppNames = !$0 }
        )
    }

    private var iconSizeBinding: Binding<Double> {
        Binding(
            get: { Double(preferences.iconSize) },
            set: { preferences.iconSize = Int($0.rounded()) }
        )
    }

    private var compactScaleBinding: Binding<Double> {
        Binding(
            get: { Double(preferences.compactScalePercent) },
            set: { preferences.compactScalePercent = Int($0.rounded()) }
        )
    }

    /// Appearance group (features 7+8+9). Changes take effect the next time the launcher
    /// is summoned (the overlay snapshots the resolved metrics at `open()`); the layout
    /// preview in the first row tracks every published preference live — pure math, no IO.
    private var appearanceSection: some View {
        section(
            title: localization.string("settings.appearance.title", defaultValue: "外观"),
            icon: "paintbrush"
        ) {
            VStack(spacing: PluginSettingsTheme.Spacing.rowVertical) {
                LaunchpadLayoutPreviewView(preferences: preferences, localization: localization)
                Divider()
                row(
                    title: localization.string(
                        "settings.appearance.showNames.title",
                        defaultValue: "显示应用名称"
                    ),
                    description: localization.string(
                        "settings.appearance.showNames.description",
                        defaultValue: "关闭后仅显示图标，排列更紧凑"
                    )
                ) {
                    Toggle("", isOn: showsAppNamesBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                Divider()
                row(
                    title: localization.string(
                        "settings.appearance.iconSize.title",
                        defaultValue: "图标大小"
                    ),
                    description: localization.string(
                        "settings.appearance.iconSize.description",
                        defaultValue: "每页行列数随之变化"
                    )
                ) {
                    HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                        PluginSettingsSlider(
                            value: iconSizeBinding,
                            in: Double(LaunchpadPreferences.minIconSize)
                                ... Double(LaunchpadPreferences.maxIconSize),
                            step: Double(LaunchpadPreferences.iconSizeStep)
                        )
                        .frame(minWidth: 160, idealWidth: 200, maxWidth: 240)
                        Text(
                            localization.format(
                                "settings.appearance.iconSize.value",
                                defaultValue: "%d pt",
                                preferences.iconSize
                            )
                        )
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                        .frame(width: 52, alignment: .trailing)
                    }
                }
                Divider()
                row(
                    title: localization.string(
                        "settings.appearance.labelSize.title",
                        defaultValue: "标签字号"
                    ),
                    description: localization.string(
                        "settings.appearance.labelSize.description",
                        defaultValue: "与图标大小协调缩放"
                    )
                ) {
                    Picker("", selection: $preferences.labelSize) {
                        ForEach(LaunchpadLabelSize.allCases) { size in
                            Text(size.label(localization: localization)).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // Intrinsic width; see the background-style picker note — a fixed frame
                    // lets NSSegmentedControl overdraw past the card on wider languages.
                    .fixedSize()
                }
                Divider()
                row(
                    title: localization.string(
                        "settings.appearance.labelWeight.title",
                        defaultValue: "标签字重"
                    ),
                    description: localization.string(
                        "settings.appearance.labelWeight.description",
                        defaultValue: "应用名称与文件夹标题共用"
                    )
                ) {
                    Picker("", selection: $preferences.labelWeight) {
                        ForEach(LaunchpadLabelWeight.allCases) { weight in
                            Text(weight.label(localization: localization)).tag(weight)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                row(
                    title: localization.string(
                        "settings.appearance.labelColor.title",
                        defaultValue: "标签颜色"
                    ),
                    description: localization.string(
                        "settings.appearance.labelColor.description",
                        defaultValue: "深色背景下可选浅色更清晰"
                    )
                ) {
                    Picker("", selection: $preferences.labelColor) {
                        ForEach(LaunchpadLabelColor.allCases) { color in
                            Text(color.label(localization: localization)).tag(color)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 110)
                }
            }
        }
    }

    // MARK: - Background (design §5.3)

    private var dimPercentBinding: Binding<Double> {
        Binding(
            get: { Double(preferences.backgroundDimPercent) },
            set: { preferences.backgroundDimPercent = Int($0.rounded()) }
        )
    }

    private var backgroundStyleDescription: String {
        switch preferences.backgroundStyle {
        case .clear:
            localization.string(
                "settings.background.style.clearDescription",
                defaultValue: "更通透，桌面清晰可见"
            )
        case .standard:
            localization.string(
                "settings.background.style.standardDescription",
                defaultValue: "默认观感，均衡的玻璃质感"
            )
        case .deep:
            localization.string(
                "settings.background.style.deepDescription",
                defaultValue: "更暗更沉浸，聚焦图标"
            )
        case .custom:
            localization.string(
                "settings.background.style.customDescription",
                defaultValue: "自选材质与暗化程度"
            )
        }
    }

    private var backgroundSection: some View {
        section(
            title: localization.string("settings.background.title", defaultValue: "背景"),
            icon: "circle.lefthalf.filled"
        ) {
            VStack(spacing: PluginSettingsTheme.Spacing.rowVertical) {
                backgroundPreviewCard
                Divider()
                row(
                    title: localization.string("settings.background.style.title", defaultValue: "玻璃风格"),
                    description: backgroundStyleDescription
                ) {
                    Picker("", selection: $preferences.backgroundStyle) {
                        ForEach(LaunchpadBackgroundStyle.allCases) { style in
                            Text(style.label(localization: localization)).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // Take the control's intrinsic width instead of a hardcoded
                    // value: a 4-segment control's intrinsic minimum (~250pt) is
                    // wider than the old 224, so NSSegmentedControl overdrew past
                    // the frame and spilled out of the card. fixedSize adapts to
                    // the label language (zh/en) and the row's trailing Spacer
                    // keeps it inside the card.
                    .fixedSize()
                }
                if preferences.backgroundStyle == .custom {
                    Divider()
                    row(
                        title: localization.string("settings.background.material.title", defaultValue: "玻璃材质"),
                        description: localization.string(
                            "settings.background.material.description",
                            defaultValue: "背景玻璃的取样材质"
                        )
                    ) {
                        Picker("", selection: $preferences.backgroundMaterial) {
                            ForEach(LaunchpadGlassMaterial.allCases) { material in
                                Text(material.label(localization: localization)).tag(material)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                    Divider()
                    row(
                        title: localization.string("settings.background.dim.title", defaultValue: "背景暗化"),
                        description: localization.string(
                            "settings.background.dim.description",
                            defaultValue: "数值越大背景越暗"
                        )
                    ) {
                        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                            PluginSettingsSlider(
                                value: dimPercentBinding,
                                in: Double(LaunchpadBackgroundDim.percentRange.lowerBound)
                                    ... Double(LaunchpadBackgroundDim.percentRange.upperBound),
                                step: 1
                            )
                            .frame(minWidth: 120, idealWidth: 160, maxWidth: 200)
                            Text(
                                localization.format(
                                    "settings.background.dim.value",
                                    defaultValue: "%d%%",
                                    preferences.backgroundDimPercent
                                )
                            )
                            .font(PluginSettingsTheme.Typography.monospacedValue)
                            .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    /// Inline glass preview (G6): the settings window taking key always closes the overlay,
    /// so tuning would otherwise be blind. A desktop-ish gradient underlay + the SAME recipe
    /// glass (within-window, so it samples the gradient) + the dim layer — live, since it
    /// binds the published preferences directly. Gradient and recipe fill are shared with
    /// the layout preview's canvas (`LaunchpadDesktopMockGradient` / `LaunchpadRecipeGlassFill`
    /// in LaunchpadGlassBackdrop.swift) — one implementation, per ruling G6.
    private var backgroundPreviewCard: some View {
        ZStack {
            LaunchpadDesktopMockGradient()
            // Soft shapes give the blur something legible to chew on.
            Circle()
                .fill(.white.opacity(0.55))
                .frame(width: 46, height: 46)
                .offset(x: -64, y: -10)
            Circle()
                .fill(Color(red: 0.18, green: 0.65, blue: 0.45).opacity(0.8))
                .frame(width: 34, height: 34)
                .offset(x: 52, y: 16)
            LaunchpadRecipeGlassFill(recipe: preferences.backgroundRecipe)
        }
        .frame(width: 220, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card, style: .continuous))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            localization.string(
                "settings.background.preview.accessibility",
                defaultValue: "背景玻璃效果预览"
            )
        )
    }

    private var gridSection: some View {
        section(title: localization.string("settings.grid.title", defaultValue: "网格"), icon: "square.grid.3x3") {
            VStack(spacing: PluginSettingsTheme.Spacing.rowVertical) {
                row(
                    title: localization.string("settings.grid.autoColumns.title", defaultValue: "自动列数"),
                    description: localization.string(
                        "settings.grid.autoColumns.description",
                        defaultValue: "按窗口宽度自动排布"
                    )
                ) {
                    Toggle("", isOn: isAutoColumns)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if preferences.columns != LaunchpadPreferences.autoColumns {
                    Divider()
                    row(
                        title: localization.string("settings.grid.columns.title", defaultValue: "每行图标"),
                        description: localization.string(
                            "settings.grid.columns.description",
                            defaultValue: "固定每行的应用数量"
                        )
                    ) {
                        Stepper(
                            value: $preferences.columns,
                            in: LaunchpadPreferences.minColumns...LaunchpadPreferences.maxColumns
                        ) {
                            Text(
                                localization.format(
                                    "settings.grid.columns.value",
                                    defaultValue: "%d 个",
                                    preferences.columns
                                )
                            )
                                .font(PluginSettingsTheme.Typography.monospacedValue)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        title _: String,
        icon _: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .pluginSettingsListRowPadding()
    }

    private func row<Control: View>(
        title: String,
        description: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title).font(PluginSettingsTheme.Typography.rowTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
            control()
        }
    }
}
