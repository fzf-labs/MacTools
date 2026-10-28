import SwiftUI
import MacToolsPluginKit

struct RightClickMenuLayoutView: View {
    @ObservedObject var session: RightClickSettingsSession
    let localization: PluginLocalization
    let configure: (RightClickAction) -> Void
    @State private var menuCategory = RightClickCategory.create
    @State private var menuSelection: RightClickAction?
    @State private var showsPreview = false
    @State private var previewScenario = "files"
    @State private var drag: RightClickMenuDrag?
    @StateObject private var dragSource = RightClickMenuDragSource()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private typealias Spacing = PluginSettingsTheme.Spacing
    private typealias Typography = PluginSettingsTheme.Typography
    private func text(_ key: String) -> String { localization.string(key, defaultValue: key) }
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
                previewControls.frame(maxWidth: .infinity, alignment: .trailing)
                Text(text("Drag to reorder."))
                    .font(Typography.rowDescription).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                menuArrangement(categoryWidth: min(220, max(150, min(840, geometry.size.width) * 0.32)))
            }
            .frame(maxWidth: 840, maxHeight: .infinity, alignment: .topLeading)
        }
        .onDisappear { showsPreview = false }
    }

    private var previewControls: some View {
        HStack(spacing: Spacing.rowContentControl) {
            Toggle(text("Show Icons"), isOn: $session.configuration.showIcons)
                .toggleStyle(.switch).font(Typography.rowDescription).fixedSize()
            Button { showsPreview.toggle() } label: {
                Label(text("Preview Menu"), systemImage: "eye")
            }
            .buttonStyle(.bordered).controlSize(.small).fixedSize()
            .popover(isPresented: $showsPreview, arrowEdge: .bottom) {
                RightClickMenuPreview(session: session, localization: localization, previewScenario: $previewScenario)
                    .frame(width: 320, height: 440)
                    .padding(Spacing.cardContent)
                    .controlSize(.small)
            }
        }
        .fixedSize()
    }

    private func menuArrangement(categoryWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
                sectionHeader("Category", symbol: "list.bullet")
                ScrollView { categoryList }
            }
            .frame(width: categoryWidth)
            VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
                sectionHeader(menuCategory.title, symbol: menuCategory.symbol)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(categoryActions(menuCategory)) { action in
                            menuActionRow(action)
                            if action != categoryActions(menuCategory).last { PluginSettingsListDivider() }
                        }
                    }
                    .pluginSettingsCardBackground(.standard)
                    .animation(reorderAnimation, value: displayedActions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var categoryList: some View {
        VStack(spacing: 0) {
            ForEach(displayedCategories) { group in
                HStack(spacing: Spacing.controlCluster) {
                    Button { menuCategory = group; menuSelection = nil } label: {
                        HStack(spacing: Spacing.controlCluster) {
                            if session.configuration.showIcons {
                                Image(systemName: group.symbol).frame(width: PluginSettingsTheme.Size.rowIcon)
                                    .accessibilityHidden(true)
                            }
                            Text(text(group.title)).lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(menuCategory == group ? Color.accentColor : .primary)
                    .accessibilityAddTraits(menuCategory == group ? .isSelected : [])
                    .onKeyPress(phases: .down) { press in
                        guard press.modifiers == [.command, .option] else { return .ignored }
                        if press.key == .upArrow { moveCategory(group, delta: -1); return .handled }
                        if press.key == .downArrow { moveCategory(group, delta: 1); return .handled }
                        return .ignored
                    }
                    dragHandle(item: .category(group), title: group.title, symbol: group.symbol)
                }
                .font(Typography.rowTitle)
                .padding(.horizontal, Spacing.rowHorizontal).padding(.vertical, Spacing.rowVertical)
                .background(menuCategory == group ? PluginSettingsTheme.Palette.sidebarSelectionBackground : Color.clear)
                .accessibilityAction(named: text("Move Up")) { moveCategory(group, delta: -1) }
                .accessibilityAction(named: text("Move Down")) { moveCategory(group, delta: 1) }
                .opacity(drag?.item == .category(group) ? 0.25 : 1)
                .overlay(alignment: .top) { insertionMarker(for: .category(group)) }
                .modifier(dropTarget(for: .category(group)))
                if group != displayedCategories.last { PluginSettingsListDivider() }
            }
        }
        .pluginSettingsCardBackground(.standard)
        .animation(reorderAnimation, value: displayedCategories)
    }

    private func menuActionRow(_ action: RightClickAction) -> some View {
        HStack(spacing: Spacing.controlCluster) {
            Button { menuSelection = action } label: {
                HStack(spacing: Spacing.controlCluster) {
                    if session.configuration.showIcons {
                        Image(systemName: action.symbol)
                            .foregroundStyle(menuSelection == action ? Color.accentColor : .secondary)
                            .frame(width: PluginSettingsTheme.Size.rowIcon)
                            .accessibilityHidden(true)
                    }
                    Text(text(action.title)).foregroundStyle(session.configuration.isEnabled(action) ? Color.primary : .secondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(menuSelection == action ? .isSelected : [])
            .onKeyPress(phases: .down) { press in
                guard press.modifiers == [.command, .option] else { return .ignored }
                if press.key == .upArrow { moveAction(action, delta: -1); return .handled }
                if press.key == .downArrow { moveAction(action, delta: 1); return .handled }
                return .ignored
            }
            if !session.configuration.isEnabled(action) {
                Text(text("Disabled")).font(Typography.statusBadge).foregroundStyle(.secondary)
            }
            dragHandle(item: .action(action), title: action.title, symbol: action.symbol)
        }
        .font(Typography.rowTitle)
        .pluginSettingsListRowPadding()
        .background(menuSelection == action ? PluginSettingsTheme.Palette.sidebarSelectionBackground : Color.clear)
        .contextMenu {
            Button(text("Move Up")) { moveAction(action, delta: -1) }.disabled(actionIndex(action) == 0)
            Button(text("Move Down")) { moveAction(action, delta: 1) }.disabled(actionIndex(action) == categoryActions(action.category).count - 1)
            Divider()
            Button(text("Function Settings")) { configure(action) }
        }
        .accessibilityAction(named: text("Move Up")) { moveAction(action, delta: -1) }
        .accessibilityAction(named: text("Move Down")) { moveAction(action, delta: 1) }
        .opacity(drag?.item == .action(action) ? 0.25 : 1)
        .overlay(alignment: .top) { insertionMarker(for: .action(action)) }
        .modifier(dropTarget(for: .action(action)))
    }

    private var displayedCategories: [RightClickCategory] { drag?.categories ?? session.configuration.orderedCategories }
    private var displayedActions: [RightClickAction] { drag?.actions ?? session.configuration.orderedActions }
    private var reorderAnimation: Animation? { reduceMotion ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.88) }

    private func sectionHeader(_ title: String, symbol: String) -> some View {
        RightClickSectionHeader(title: text(title), symbol: symbol, showsIcon: session.configuration.showIcons)
    }

    @ViewBuilder
    private func insertionMarker(for item: RightClickMenuDrag.Item) -> some View {
        if drag?.item == item {
            Capsule().fill(Color.accentColor).frame(height: 2)
                .padding(.horizontal, Spacing.rowHorizontal)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func dropTarget(for item: RightClickMenuDrag.Item) -> RightClickMenuDropTarget {
        RightClickMenuDropTarget(accepts: { drag?.accepts(item) == true }, hover: { after in
            guard var draft = drag, draft.accepts(item) else { return }
            draft.preview(at: item, after: after)
            if draft.categories != drag?.categories || draft.actions != drag?.actions { drag = draft }
        }, commit: commitDrag)
    }

    private func commitDrag() -> Bool {
        guard let draft = drag else { return false }
        defer { drag = nil }
        switch draft.item {
        case .category:
            guard session.configuration.orderedCategories == draft.originalCategories else { return false }
            if draft.categories != draft.originalCategories { session.configuration.categoryOrder = draft.categories }
        case .action:
            guard session.configuration.orderedActions == draft.originalActions else { return false }
            if draft.actions != draft.originalActions { session.configuration.actionOrder = draft.actions }
        }
        return true
    }

    private func moveCategory(_ category: RightClickCategory, delta: Int) {
        var order = session.configuration.orderedCategories
        guard let source = order.firstIndex(of: category), order.indices.contains(source + delta) else { return }
        order.swapAt(source, source + delta)
        session.configuration.categoryOrder = order
    }

    private func categoryActions(_ category: RightClickCategory) -> [RightClickAction] { displayedActions.filter { $0.category == category } }
    private func actionIndex(_ action: RightClickAction) -> Int { categoryActions(action.category).firstIndex(of: action) ?? 0 }
    private func moveAction(_ action: RightClickAction, delta: Int) {
        let values = categoryActions(action.category)
        let source = actionIndex(action)
        let target = source + delta
        guard values.indices.contains(target) else { return }
        var order = session.configuration.orderedActions
        guard let a = order.firstIndex(of: action), let b = order.firstIndex(of: values[target]) else { return }
        order.remove(at: a)
        order.insert(action, at: b)
        session.configuration.actionOrder = order
    }
    private func dragHandle(item: RightClickMenuDrag.Item, title: String, symbol: String) -> some View {
        RightClickMenuDragHandle(title: text(title), symbol: session.configuration.showIcons ? symbol : "", help: text("Drag to reorder."),
                                 reduceMotion: reduceMotion, source: dragSource, begin: {
            let draft = RightClickMenuDrag(item: item, configuration: session.configuration)
            drag = draft
            return draft.token
        }, cancel: { token in
            guard drag?.token == token else { return }
            withAnimation(reorderAnimation) { drag = nil }
        })
        .frame(width: PluginSettingsTheme.Size.controlHeight, height: PluginSettingsTheme.Size.controlHeight)
        .accessibilityHidden(true)
    }
}
