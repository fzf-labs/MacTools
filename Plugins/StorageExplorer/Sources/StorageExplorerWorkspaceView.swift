import AppKit
import MacToolsPluginKit
import Quartz
import SwiftUI

public struct StorageExplorerWorkspaceView: View {
    @ObservedObject public var controller: StorageExplorerController
    public let localization: PluginLocalization
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var hoveredBreadcrumbIndex: Int?
    @State private var hoveredTreemapListRowID: String?
    @State private var hoveredTreemapSummary: StorageExplorerTreemapHoverSummary?
    @State private var isReviewDropTargeted = false
    @State private var compactShowsList = false
    @StateObject private var quickLookPresenter = StorageExplorerQuickLookPresenter()

    public init(controller: StorageExplorerController,
                localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.controller = controller
        self.localization = localization
    }

    private func text(_ key: String, _ fallback: String) -> String {
        localization.string("storageExplorer." + key, defaultValue: fallback)
    }

    public var body: some View {
        GeometryReader { geometry in
            workspace(width: geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private func workspace(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            if controller.rootItem != nil {
                navigationBar
                if controller.isScanning {
                    refreshStatus
                }
                explorer(width: width - PluginSettingsTheme.Spacing.section * 2)
                    .layoutPriority(1)
                reviewBar.layoutPriority(2)
            } else if controller.isScanning {
                StorageExplorerScanningView(
                    status: controller.status,
                    metric: controller.metric,
                    startedAt: controller.scanStartedAt,
                    scanningTitle: text("scanning", "正在扫描…"),
                    finalizingTitle: text("finalizing", "正在整理结果…"),
                    filesScannedFormat: text("filesScannedFormat", "已扫描 %d 个项目"),
                    elapsedSecondsFormat: text("elapsedSecondsFormat", "%.1f 秒"),
                    skippedCountFormat: text("skippedCount", "跳过 %d 项")
                )
                Button(text("cancel", "取消"), role: .cancel) { controller.cancelScan() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                VStack(spacing: PluginSettingsTheme.Spacing.section) {
                    Spacer(minLength: 0)
                    ContentUnavailableView(text("analysisReadyTitle", "查看空间占用"), systemImage: "internaldrive",
                        description: Text(text("analysisReadyDescription", "分析个人目录，查看空间分布并找出大文件。")))
                        .fixedSize(horizontal: false, vertical: true)
                    startAnalysisButton
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = controller.lastErrorMessage {
                Text(error).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red).textSelection(.enabled)
            }
            if let success = controller.lastSuccessMessage {
                Text(success).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            }
        }
        .padding(PluginSettingsTheme.Spacing.section)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $controller.isConfirmingTrash) {
            confirmation
                .environment(\.layoutDirection, layoutDirection)
                .environment(\.locale, locale)
        }
    }

    private func explorer(width: CGFloat) -> some View {
        VStack(spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            if width >= 760 {
                HSplitView {
                    treemapPanel(nodes: controller.hierarchyNodes)
                        .frame(minWidth: 380, idealWidth: width * 0.60, maxWidth: .infinity)
                    resultsPanel
                        .frame(minWidth: 320, idealWidth: width * 0.40, maxWidth: .infinity)
                }
            } else {
                Picker(text("viewMode", "视图"), selection: $compactShowsList) {
                    Text(text("spaceMap", "空间分布")).tag(false)
                    Text(text("results", "扫描结果")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)

                // Keep the map mounted so presentation readiness also completes in list mode.
                ZStack {
                    treemapPanel(nodes: controller.hierarchyNodes)
                        .opacity(compactShowsList ? 0 : 1)
                        .allowsHitTesting(!compactShowsList)
                        .disabled(compactShowsList)
                        .accessibilityHidden(compactShowsList)
                    resultsPanel
                        .opacity(compactShowsList ? 1 : 0)
                        .allowsHitTesting(compactShowsList)
                        .disabled(!compactShowsList)
                        .accessibilityHidden(!compactShowsList)
                }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .onChange(of: compactShowsList) { _, _ in
            hoveredTreemapSummary = nil
            hoveredTreemapListRowID = nil
        }
    }

    private var resultsPanel: some View {
        compactList
            .opacity(controller.isUpdatingPresentation ? 0.5 : 1)
            .allowsHitTesting(!controller.isUpdatingPresentation)
            .animation(.easeOut(duration: 0.16), value: controller.isUpdatingPresentation)
    }

    private var refreshStatus: some View {
        StorageExplorerRefreshStatusView(
            status: controller.status,
            metric: controller.metric,
            startedAt: controller.scanStartedAt,
            refreshingTitle: text("refreshing", "正在刷新扫描结果…"),
            finalizingTitle: text("finalizing", "正在整理结果…"),
            filesScannedFormat: text("filesScannedFormat", "已扫描 %d 个项目"),
            elapsedSecondsFormat: text("elapsedSecondsFormat", "%.1f 秒"),
            cancelTitle: text("cancel", "取消"),
            cancel: controller.cancelScan
        )
    }

    private func treemapPanel(nodes: [StorageExplorerHierarchyNode]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Label(text("spaceMap", "空间分布"), systemImage: "square.split.2x2")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                Spacer(minLength: 8)
                Text(StorageExplorerFormatting.bytes(controller.currentDirectory.map(controller.metric.bytes) ?? 0))
                    .font(PluginTypography.metric.font)
                    .lineLimit(1)
            }
            .padding(PluginSettingsTheme.Spacing.rowHorizontal)

            ZStack {
                StorageExplorerHierarchyTreemapView(
                    nodes: nodes,
                    layoutRevision: controller.hierarchyRevision,
                    selection: $controller.selectedPath,
                    hoveredListRowID: $hoveredTreemapListRowID,
                    hoveredSummary: $hoveredTreemapSummary,
                    emptyLabel: text("noSizedItems", "尚无可显示的大小"),
                    reviewCopy: reviewEligibilityCopy,
                    revealInFinderLabel: text("revealInFinder", "在访达中显示"),
                    open: openDirectory,
                    preview: showQuickLook,
                    toggleReview: { controller.toggleSelection(path: $0.path) },
                    reviewEligibility: controller.reviewEligibility,
                    revealInFinder: { controller.revealInFinder(path: $0.path) },
                    layoutReady: controller.presentationDidRender
                )
                .saturation(controller.isUpdatingPresentation ? 0.58 : 1)

                if controller.isUpdatingPresentation {
                    StorageExplorerTreemapUpdateEffect()
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(!controller.isUpdatingPresentation)
            .clipShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control))
            .padding(.horizontal, PluginSettingsTheme.Spacing.controlCluster)
            .animation(.easeOut(duration: 0.16), value: controller.isUpdatingPresentation)

            HStack {
                if controller.isUpdatingPresentation {
                    ProgressView().controlSize(.small)
                    Text(text("updatingTreemap", "正在更新空间图…"))
                } else if let hoveredTreemapSummary {
                    treemapHoverSummary(hoveredTreemapSummary)
                } else {
                    Text(text("selectToInspect", "选择图块或列表项目以查看详情。"))
                }
                Spacer(minLength: 0)
            }
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: 38)
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        }
        .pluginSettingsCardBackground(.standard)
    }

    private var startAnalysisButton: some View {
        Button { controller.scanHomeFolder() } label: {
            Label(text("startAnalysis", "开始分析"), systemImage: "magnifyingglass")
        }
        .buttonStyle(.borderedProminent).controlSize(.small)
        .disabled(controller.isExecutingTrash)
    }

    private var reviewEligibilityCopy: StorageExplorerReviewEligibilityCopy {
        StorageExplorerReviewEligibilityCopy(
            addToReview: text("addToReview", "加入审阅"),
            removeFromReview: text("removeFromReview", "移出审阅"),
            selected: text("reviewSelected", "已加入审阅。"),
            includedByParentFormat: text("reviewIncludedByParentFormat", "已随“%@”加入审阅。"),
            busy: text("updatingTreemap", "正在更新空间图…"),
            incompleteFormat: text(
                "reviewIncompleteFormat",
                "有 %d 个内容未能扫描。显示大小为最低估计，实际释放空间可能不同。"
            ),
            symlink: text(
                "symlinkReviewUnsupported",
                "符号链接不能加入审阅；请在访达中管理链接本身。"
            ),
            aggregate: text(
                "aggregateReviewUnsupported",
                "这是多个较小项目的合并视图，不能作为单个项目加入审阅。"
            ),
            cachedPreview: text(
                "cachedPreviewReviewUnavailable",
                "这是上次扫描的预览。请等待刷新完成后再加入审阅。"
            ),
            scanRoot: text("reviewScanRoot", "当前扫描文件夹本身不能加入审阅。"),
            protectedLocation: text("reviewProtected", "此位置受保护，不能移至废纸篓。"),
            unavailable: text("reviewUnavailable", "此项目不能加入审阅。")
        )
    }

    private var navigationBar: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.controlCluster) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Button {
                    controller.searchQuery = ""
                    controller.navigateUp()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(controller.navigationStack.count < 2 || controller.isExecutingTrash)
                .help(text("goUp", "返回上一级"))
                .accessibilityLabel(text("goUp", "返回上一级"))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(controller.navigationStack.enumerated()), id: \.element.path) { index, item in
                            if index > 0 {
                                Image(systemName: "chevron.forward")
                                    .font(PluginSettingsTheme.Typography.rowIcon)
                                    .foregroundStyle(.tertiary)
                            }
                            breadcrumbSegment(item, index: index)
                        }
                    }
                    .font(PluginSettingsTheme.Typography.rowTitle)
                }
                .layoutPriority(1)
                scanActions
                if !controller.isScanning, let root = controller.scanRootURL {
                    Button { controller.startScan(at: root) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(controller.isExecutingTrash)
                    .help(text("refresh", "刷新"))
                    .accessibilityLabel(text("refresh", "刷新"))
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            scanSummary
        }
    }

    private func treemapHoverSummary(_ summary: StorageExplorerTreemapHoverSummary) -> some View {
        let color: Color = switch summary.tone {
        case .normal: .secondary
        case .warning: .orange
        case .blocked: .red
        case .selected: .accentColor
        }
        return Label {
            HStack(spacing: 5) {
                Text(summary.title).fontWeight(.semibold)
                Text(summary.detail).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
        } icon: {
            Image(systemName: summary.systemImage)
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(summary.path)\n\(summary.detail)")
    }

    private func breadcrumbSegment(_ item: StorageItem, index: Int) -> some View {
        let isCurrent = index == controller.navigationStack.count - 1
        let size = StorageExplorerFormatting.bytes(controller.metric.bytes(item))
        return Button {
            controller.searchQuery = ""
            controller.navigateToBreadcrumb(at: index)
        } label: {
            Text(item.name.isEmpty ? "/" : item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .fontWeight(isCurrent ? .semibold : .regular)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Color.accentColor.opacity(isCurrent ? 0.12 : hoveredBreadcrumbIndex == index ? 0.09 : 0),
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering {
                hoveredBreadcrumbIndex = index
            } else if hoveredBreadcrumbIndex == index {
                hoveredBreadcrumbIndex = nil
            }
        }
        .help("\(item.path)\n\(size)")
        .accessibilityHint(String(format: text("openPath", "打开 %@"), locale: PluginRuntimeLocalization.locale, item.path))
    }

    private var scanSummary: some View {
        let skipped = controller.status.progress.skippedCount
        return HStack(spacing: 7) {
            if controller.isShowingCachedPreview, let previewDate = controller.cachedPreviewDate {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Label(
                        String(format: text("previousScanAgeFormat", "上次扫描：%@"), locale: PluginRuntimeLocalization.locale, relativeScanAge(
                            from: previewDate,
                            relativeTo: context.date
                        )),
                        systemImage: "clock.arrow.circlepath"
                    )
                }
            } else if controller.isScanning {
                Label(text("scanning", "正在扫描…"), systemImage: "arrow.triangle.2.circlepath")
            } else if let completedAt = controller.scanCompletedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(String(format: text("scanAgeFormat", "扫描时间：%@"), locale: PluginRuntimeLocalization.locale, relativeScanAge(
                        from: completedAt,
                        relativeTo: context.date
                    )))
                }
            }
            if skipped > 0 { skippedSummary(count: skipped) }
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    private func skippedSummary(count: Int) -> some View {
        Label(
            String(format: text("skippedCount", "跳过 %d 项"), locale: PluginRuntimeLocalization.locale, count),
            systemImage: "exclamationmark.circle"
        )
        .foregroundStyle(.orange)
        .help(String(format: text(
            "skippedDetailsMessage",
            "%d 个项目因权限、云端占位文件或文件系统边界而被跳过。显示的总大小可能偏低。"
        ), locale: PluginRuntimeLocalization.locale, count))
    }

    private var scanActions: some View {
        Menu {
            Button { controller.scanHomeFolder() } label: {
                Label(text("homeFolder", "个人目录"), systemImage: "house")
            }
            Button { controller.selectFolderAndScan() } label: {
                Label(text("selectFolder", "选择文件夹…"), systemImage: "folder.badge.plus")
            }
        } label: {
            Label(text("selectFolder", "选择文件夹…"), systemImage: "folder")
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .help(text("selectFolder", "选择文件夹…"))
        .disabled(controller.isExecutingTrash)
    }

    private var compactList: some View {
        let eligibilityCopy = reviewEligibilityCopy
        return GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(text("browseItems", "浏览项目"), systemImage: "list.bullet")
                        .font(PluginSettingsTheme.Typography.sectionTitle)
                    Spacer(minLength: 8)
                    Text(controller.matchingCount.formatted(.number.locale(locale)))
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                        .foregroundStyle(.secondary)
                }
                .padding(PluginSettingsTheme.Spacing.rowHorizontal)
                HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(text("search", "搜索…"), text: $controller.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 100, idealWidth: 220, maxWidth: .infinity)
                        .accessibilityLabel(text("search", "搜索…"))
                }
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                .padding(.bottom, PluginSettingsTheme.Spacing.sectionHeaderContent)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if controller.rows.isEmpty, !controller.searchQuery.isEmpty {
                            ContentUnavailableView.search(text: controller.searchQuery)
                        }
                        ForEach(controller.rows) { row in
                            compactListRow(row, eligibilityCopy: eligibilityCopy)
                        }
                        if controller.matchingCount > controller.rows.count {
                            Text(String(format: text("limitedRows", "显示前 %d 项，共 %d 项；搜索可缩小范围。"),
                                locale: locale, controller.rows.count, controller.matchingCount))
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                                .padding(PluginSettingsTheme.Spacing.controlCluster)
                        }
                    }
                    .padding(PluginSettingsTheme.Spacing.controlCluster)
                }
                .frame(minHeight: 0, maxHeight: .infinity)
                Divider()
                if let item = controller.inspectedItem {
                    VStack(spacing: 0) {
                        ScrollView {
                            inlineDetails(for: item)
                        }
                        inspectorActions(for: item)
                            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                            .padding(.bottom, PluginSettingsTheme.Spacing.rowVertical)
                    }
                    .frame(height: min(224, geometry.size.height * 0.46))
                } else {
                    Label(text("selectToInspect", "选择图块或列表项目以查看详情。"), systemImage: "cursorarrow")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
                }
            }
            .pluginSettingsCardBackground(.standard)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(text("results", "扫描结果"))
        }
    }

    private func compactListRow(
        _ row: StorageExplorerRow,
        eligibilityCopy: StorageExplorerReviewEligibilityCopy
    ) -> some View {
        let isTreemapHovered = listRowMatchesTreemapHover(row)
        let eligibility = controller.reviewEligibility(for: row.item)
        let backgroundColor = controller.selectedPath == row.id
            ? Color.accentColor.opacity(0.12)
            : isTreemapHovered ? Color.accentColor.opacity(0.14) : Color.clear
        let borderColor = isTreemapHovered ? Color.accentColor.opacity(0.7) : Color.clear
        let help = "\(row.item.path)\n\(eligibilityCopy.message(for: eligibility))"

        return HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Image(systemName: row.item.iconSystemName)
                .foregroundStyle(.secondary)
                .frame(width: PluginSettingsTheme.Size.rowIcon)
            Text(localizedName(row))
                .font(PluginSettingsTheme.Typography.rowTitle)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(row.sizeLabel)
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                Text(row.percentage)
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            Button {
                controller.toggleSelection(path: row.item.path)
            } label: {
                Image(systemName: eligibilityCopy.icon(for: eligibility))
                    .foregroundStyle(reviewEligibilityColor(for: eligibility))
            }
            .buttonStyle(.borderless)
            .disabled(!eligibility.canToggle)
            .help(eligibilityCopy.message(for: eligibility))
            .accessibilityLabel(eligibilityCopy.message(for: eligibility))
            if row.item.isDirectory && !row.item.isPackage {
                Button { openDirectory(row.item) } label: {
                    Image(systemName: "chevron.forward")
                }
                .buttonStyle(.borderless)
                .help(text("openFolder", "打开文件夹"))
                .accessibilityLabel(text("openFolder", "打开文件夹"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, PluginSettingsTheme.Spacing.controlCluster)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if row.item.isDirectory && !row.item.isPackage {
                openDirectory(row.item)
            } else {
                _ = showQuickLook(for: row.item)
            }
        }
        .onTapGesture { controller.selectedPath = row.id }
        .modifier(StorageExplorerListDragModifier(
            enabled: eligibility.canAdd,
            path: row.item.path
        ))
        .contextMenu {
            compactListContextMenu(row: row, eligibility: eligibility, eligibilityCopy: eligibilityCopy)
        }
        .focusable(true, interactions: .activate)
        .onKeyPress(.space) {
            showQuickLook(for: row.item) ? .handled : .ignored
        }
        .onKeyPress(.return) {
            guard row.item.isDirectory && !row.item.isPackage else { return .ignored }
            openDirectory(row.item)
            return .handled
        }
        .help(help)
    }

    @ViewBuilder
    private func compactListContextMenu(
        row: StorageExplorerRow,
        eligibility: StorageExplorerReviewEligibility,
        eligibilityCopy: StorageExplorerReviewEligibilityCopy
    ) -> some View {
        if eligibility.canToggle {
            let isSelected = eligibility == .selected
            Button {
                controller.toggleSelection(path: row.item.path)
            } label: {
                Label(
                    isSelected
                        ? text("removeFromReview", "移出审阅")
                        : text("addToReview", "加入审阅"),
                    systemImage: isSelected ? "minus.circle" : "plus.circle"
                )
            }
        } else {
            Button {} label: {
                Label(
                    eligibilityCopy.message(for: eligibility),
                    systemImage: eligibilityCopy.icon(for: eligibility)
                )
            }
            .disabled(true)
        }
        Divider()
        Button {
            controller.revealInFinder(path: row.item.path)
        } label: {
            Label(text("revealInFinder", "在访达中显示"), systemImage: "folder")
        }
    }

    private func localizedName(_ row: StorageExplorerRow) -> String {
        row.id == "type:package" ? text("applicationsAndPackages", "应用与软件包") : row.name
    }

    private func listRowMatchesTreemapHover(_ row: StorageExplorerRow) -> Bool {
        hoveredTreemapListRowID == row.item.path
    }

    private func reviewEligibilityColor(for eligibility: StorageExplorerReviewEligibility) -> Color {
        switch eligibility {
        case .eligible, .selected, .includedBySelectedParent:
            .accentColor
        case .incomplete, .unavailable, .cachedPreview:
            .orange
        case .scanRoot, .protectedLocation:
            .red
        case .busy, .symlink, .aggregate:
            .secondary
        }
    }

    private func openDirectory(_ item: StorageItem) {
        controller.searchQuery = ""
        controller.drillDown(to: item)
    }

    private func showQuickLook(for item: StorageItem) -> Bool {
        guard !item.isDirectory,
              !item.isSymlink,
              !item.isCloudPlaceholder,
              !item.path.hasPrefix("type:") else {
            return false
        }
        controller.selectedPath = item.path
        quickLookPresenter.show(item.url)
        return true
    }

    private func inlineDetails(for item: StorageItem) -> some View {
        let eligibility = controller.reviewEligibility(for: item)
        let eligibilityCopy = reviewEligibilityCopy
        return VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(item.name, systemImage: item.iconSystemName)
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                .lineLimit(1).truncationMode(.middle)
            Text(item.path)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: PluginSettingsTheme.Spacing.section) {
                detailMetric(text("allocatedSize", "占用空间"), bytes: item.allocatedSize)
                if item.size != item.allocatedSize {
                    detailMetric(text("logicalSize", "文件大小"), bytes: item.size)
                }
            }
            if item.isAccessDenied {
                Label(text("accessDenied", "无访问权限"), systemImage: "lock.fill")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.orange)
            }
            if item.isCloudPlaceholder {
                Label(text("cloudPlaceholder", "仅在云端"), systemImage: "icloud")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            if item.isIncomplete || !eligibility.canToggle {
                Label(eligibilityCopy.message(for: eligibility), systemImage: eligibilityCopy.icon(for: eligibility))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(reviewEligibilityColor(for: eligibility))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(inlineDetailsHelp(for: item))
    }

    private func inspectorActions(for item: StorageItem) -> some View {
        let eligibility = controller.reviewEligibility(for: item)
        let eligibilityCopy = reviewEligibilityCopy
        return HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Button { controller.revealInFinder(path: item.path) } label: {
                Label(text("revealInFinder", "在访达中显示"), systemImage: "folder")
            }
            if !item.isDirectory && !item.isSymlink && !item.isCloudPlaceholder {
                Button { _ = showQuickLook(for: item) } label: {
                    Image(systemName: "eye")
                }
                .help(text("preview", "预览"))
                .accessibilityLabel(text("preview", "预览"))
            }
            Spacer(minLength: 0)
            Button { controller.toggleSelection(path: item.path) } label: {
                Image(systemName: eligibilityCopy.icon(for: eligibility))
            }
            .disabled(!eligibility.canToggle)
            .help(eligibilityCopy.message(for: eligibility))
            .accessibilityLabel(eligibilityCopy.message(for: eligibility))
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    private func detailMetric(_ title: String, bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Text(title)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            Text(StorageExplorerFormatting.bytes(bytes))
                .font(PluginSettingsTheme.Typography.monospacedValue)
        }
    }

    private func inlineDetailsHelp(for item: StorageItem) -> String {
        var lines = [item.path]
        lines.append("\(text("allocatedSize", "占用空间")): \(StorageExplorerFormatting.bytes(item.allocatedSize))")
        lines.append("\(text("logicalSize", "文件大小")): \(StorageExplorerFormatting.bytes(item.size))")
        if item.isHardLinked {
            lines.append(String(format: text(
                "hardLinkNotice",
                "此文件有 %d 个硬链接；移除最后一个链接后才会释放空间。"
            ), locale: PluginRuntimeLocalization.locale, item.hardLinkCount))
        }
        if item.isAccessDenied { lines.append(text("accessDenied", "无访问权限")) }
        if item.isCloudPlaceholder { lines.append(text("cloudPlaceholder", "仅在云端")) }
        if item.isSymlink {
            lines.append(text("symlinkReviewUnsupported", "符号链接不能加入审阅；请在访达中管理链接本身。"))
        }
        if item.isIncomplete { lines.append(text("incomplete", "大小尚不完整")) }
        lines.append(reviewEligibilityCopy.message(for: controller.reviewEligibility(for: item)))
        lines.append(text("spaceNote", "占用空间不等于可释放空间；共享数据和废纸篓会影响实际可用容量。"))
        return lines.joined(separator: "\n")
    }

    private var reviewBar: some View {
        HStack(spacing: 10) {
            Image(systemName: isReviewDropTargeted
                ? "arrow.down.circle.fill"
                : controller.basket.isEmpty ? "tray.and.arrow.down" : "checkmark.circle.fill")
                .foregroundStyle(isReviewDropTargeted
                    ? Color.accentColor
                    : controller.basket.isEmpty ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if controller.basket.isEmpty {
                    Text(text("dropToReview", "拖到这里以加入审阅"))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                    Text(text("dropToReviewDescription", "也可以点按项目旁的加号。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                } else {
                    Text(String(format: text("selectedItemsFormat", "已选 %d 个项目（共 %@）"), locale: PluginRuntimeLocalization.locale, controller.basket.count,
                        StorageExplorerFormatting.bytes(controller.totalSelectedBytes)))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle).monospacedDigit()
                        .lineLimit(1).truncationMode(.middle)
                    Text(controller.selectedItemsForReview.prefix(3).map(\.name).joined(separator: " · "))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if !controller.basket.isEmpty {
                Button(text("clearSelection", "取消选择")) { controller.clearSelection() }
                    .disabled(controller.isUpdatingPresentation || controller.isExecutingTrash)
            }
            Button(text("review", "审阅…")) { controller.confirmTrash() }
                .buttonStyle(.borderedProminent)
                .disabled(controller.reviewAvailability != .ready)
                .help(reviewAvailabilityHelp)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .pluginSettingsCardBackground(.standard)
        .overlay {
            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card)
                .strokeBorder(isReviewDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .dropDestination(for: String.self) { paths, _ in
            isReviewDropTargeted = false
            guard !controller.isUpdatingPresentation else { return false }
            let eligibleItems = paths.compactMap { path -> StorageItem? in
                guard let item = controller.snapshot.items[path],
                      controller.reviewEligibility(for: item).canAdd else { return nil }
                return item
            }
            var accepted = false
            for item in eligibleItems {
                if !controller.basket.contains(item.path) {
                    controller.toggleSelection(path: item.path)
                    accepted = accepted || controller.basket.contains(item.path)
                }
            }
            return accepted
        } isTargeted: { isTargeted in
            isReviewDropTargeted = isTargeted && !controller.isUpdatingPresentation
        }
        .animation(.easeOut(duration: 0.12), value: isReviewDropTargeted)
    }

    private func relativeScanAge(from date: Date, relativeTo referenceDate: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }

    private var reviewAvailabilityHelp: String {
        switch controller.reviewAvailability {
        case .empty:
            return text("reviewEmptyHelp", "先将项目加入审阅。")
        case .scanning:
            return text("reviewScanningHelp", "扫描完成后可以审阅。")
        case .cachedPreview:
            return text("cachedPreviewReviewUnavailable", "这是上次扫描的预览。请等待刷新完成后再加入审阅。")
        case .updating:
            return text("updatingTreemap", "正在更新空间图…")
        case .executing:
            return text("reviewExecutingHelp", "正在将所选项目移至废纸篓。")
        case .ready:
            return text("reviewReadyHelp", "检查所选项目，然后移至废纸篓。")
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            Label(text("confirmTrashTitle", "移至废纸篓确认"), systemImage: "trash")
                .font(PluginSettingsTheme.Typography.sectionTitle)
            Text(text("confirmTrashMessage", "所选项目将移至 macOS 废纸篓，可从废纸篓恢复。"))
            List(controller.reviewItems) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                    Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if item.isIncomplete {
                        Label(
                            String(format: text(
                                "reviewIncompleteFormat",
                                "有 %d 个内容未能扫描。显示大小为最低估计，实际释放空间可能不同。"
                            ), locale: PluginRuntimeLocalization.locale, max(1, item.skippedCount)),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.orange)
                    }
                }
            }.frame(height: 220)
            Text(String(format: text("selectedItemsFormat", "已选 %d 个项目（共 %@）"), locale: PluginRuntimeLocalization.locale, controller.reviewItems.count,
                StorageExplorerFormatting.bytes(controller.reviewItems.reduce(0) { $0 + controller.metric.bytes($1) })))
            HStack {
                Spacer()
                Button(text("cancel", "取消"), role: .cancel) { controller.isConfirmingTrash = false }
                Button(text("moveToTrash", "移至废纸篓…"), role: .destructive) { Task { await controller.executeTrash() } }
                    .disabled(controller.isExecutingTrash)
            }
        }.padding(24).frame(width: 540)
            .interactiveDismissDisabled(controller.isExecutingTrash)
    }
}

@MainActor
private final class StorageExplorerQuickLookPresenter: NSObject, ObservableObject,
    @preconcurrency QLPreviewPanelDataSource {
    private var previewURL: URL?

    func show(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}

private struct StorageExplorerListDragModifier: ViewModifier {
    let enabled: Bool
    let path: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.draggable(path)
        } else {
            content
        }
    }
}

private struct StorageExplorerScanningView: View {
    @ObservedObject var status: StorageExplorerScanStatus
    let metric: StorageExplorerMetric
    let startedAt: Date?
    let scanningTitle: String
    let finalizingTitle: String
    let filesScannedFormat: String
    let elapsedSecondsFormat: String
    let skippedCountFormat: String

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(status.progress.phase == .finalizing ? finalizingTitle : scanningTitle)
                .font(PluginSettingsTheme.Typography.sectionTitle)
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                HStack(spacing: 18) {
                    Text(StorageExplorerFormatting.bytes(
                        metric == .logical ? status.progress.bytesScanned : status.progress.allocatedBytesScanned
                    ))
                        .frame(width: 110, alignment: .trailing)
                    Text(String(format: filesScannedFormat, locale: PluginRuntimeLocalization.locale, status.progress.filesScanned))
                        .frame(width: 170, alignment: .leading)
                    Text(String(
                        format: elapsedSecondsFormat,
                        locale: PluginRuntimeLocalization.locale,
                        displayedElapsed(at: context.date)
                    ))
                        .frame(width: 64, alignment: .trailing)
                }
                .font(PluginSettingsTheme.Typography.rowDescription)
                .monospacedDigit()
            }
            if status.progress.skippedCount > 0 {
                Label(String(format: skippedCountFormat, locale: PluginRuntimeLocalization.locale, status.progress.skippedCount),
                      systemImage: "exclamationmark.circle")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func displayedElapsed(at date: Date) -> TimeInterval {
        StorageExplorerElapsedClock.elapsed(
            startedAt: startedAt,
            reported: status.progress.elapsed,
            now: date
        )
    }
}

private struct StorageExplorerRefreshStatusView: View {
    @ObservedObject var status: StorageExplorerScanStatus
    let metric: StorageExplorerMetric
    let startedAt: Date?
    let refreshingTitle: String
    let finalizingTitle: String
    let filesScannedFormat: String
    let elapsedSecondsFormat: String
    let cancelTitle: String
    let cancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.progress.phase == .finalizing ? finalizingTitle : refreshingTitle)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    HStack(spacing: 8) {
                        Text(StorageExplorerFormatting.bytes(
                            metric == .logical ? status.progress.bytesScanned : status.progress.allocatedBytesScanned
                        ))
                        Text(String(format: filesScannedFormat, locale: PluginRuntimeLocalization.locale, status.progress.filesScanned))
                        Text(String(
                            format: elapsedSecondsFormat,
                            locale: PluginRuntimeLocalization.locale,
                            StorageExplorerElapsedClock.elapsed(
                                startedAt: startedAt,
                                reported: status.progress.elapsed,
                                now: context.date
                            )
                        ))
                    }
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                Spacer(minLength: 8)
                Button(cancelTitle, role: .cancel, action: cancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.10))
        }
    }
}

private struct StorageExplorerTreemapUpdateEffect: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweepToTrailingEdge = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.primary.opacity(0.075)

                if !reduceMotion {
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity(0.04),
                            Color.white.opacity(0.24),
                            Color.white.opacity(0.04),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(
                        width: max(140, geometry.size.width * 0.34),
                        height: geometry.size.height * 1.35
                    )
                    .rotationEffect(.degrees(9))
                    .offset(x: sweepOffset(for: geometry.size.width))
                    .blendMode(.screen)
                }

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.42), lineWidth: 2)
            }
            .compositingGroup()
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.45).repeatForever(autoreverses: false)) {
                    sweepToTrailingEdge = true
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func sweepOffset(for width: CGFloat) -> CGFloat {
        sweepToTrailingEdge ? width * 0.68 : -width * 0.68
    }
}

enum StorageExplorerElapsedClock {
    static func elapsed(startedAt: Date?, reported: TimeInterval, now: Date) -> TimeInterval {
        max(reported, startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
}
