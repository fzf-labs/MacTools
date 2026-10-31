import AppKit
import Darwin
import SwiftUI
import MacToolsPluginKit

struct DiskCleanApplicationReviewView: View {
    @ObservedObject var model: DiskCleanApplicationReviewModel
    let isLeftovers: Bool
    let localization: PluginLocalization
    @State private var search = ""
    @State private var largestFirst = false
    @State private var inspectedRow: DiskCleanApplicationReviewRow?
    @State private var confirmsRemoval = false
    @State private var showsCoverage = false
    @State private var collapsedSections: [String: Set<String>] = [:]
    @State private var showsUnfinished = true
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !model.issues.isEmpty {
                DisclosureGroup {
                    ForEach(model.issues, id: \.self) { Text($0).textSelection(.enabled) }
                } label: { Label(copy("detail.limited.title", "本次扫描不完整"), systemImage: "exclamationmark.triangle") }
                    .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.orange)
                    .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                    .padding(.vertical, PluginSettingsTheme.Spacing.controlCluster)
            }
            if let result = model.lastExecutionResult {
                DiskCleanWorkspaceResult(result: result, localization: localization)
                unfinishedItems(result)
            }
            if let error = model.operationError ?? model.controller?.snapshot.errorMessage {
                HStack {
                    Text(localizedReason(error)).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button(copy("uninstall.recheck", "重新检查")) { model.recheckCurrentApplication() }
                        .buttonStyle(.bordered).controlSize(.small).disabled(model.isPreparing || isWriting)
                }.padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            }
            GeometryReader { geometry in
                if geometry.size.width >= 800 {
                    HStack(spacing: 0) {
                        applicationList.frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
                        Divider()
                        if let inspectedOwner { review(inspectedOwner, showsBack: false) }
                        else { ContentUnavailableView(copy("uninstall.chooseApp", "选择应用查看关联文件"), systemImage: "app.badge") }
                    }
                } else if let inspectedOwner {
                    review(inspectedOwner, showsBack: true)
                } else { applicationList }
            }
            Divider()
            DiskCleanWorkspaceFooter(snapshot: model.controller?.snapshot, localization: localization,
                actionTitle: uninstallTitle,
                isPreparing: model.isPreparing || model.isResolving,
                selectionSummary: isLeftovers ? nil : inspectedOwner.map(ownerName),
                activityTitle: model.isResolving ? copy("uninstall.preparing", "正在准备卸载") : nil,
                sizeSummary: selectedRows.contains(where: { model.candidate(path: $0.path)?.sizeResult?.completeness.isComplete != true })
                    ? copy("uninstall.sizeUnknown", "大小未知") : nil,
                actionEnabled: isLeftovers ? nil : model.canStartUninstall,
                onClean: {
                    guard isLeftovers || inspectedOwner == model.activeOwner else { return }
                    confirmsRemoval = true
                }, onCancel: { model.cancel() })
        }
        .task { model.loadIfNeeded(leftovers: isLeftovers) }
        .onChange(of: model.suspectedOwners) { _, owners in
            if isLeftovers, !model.isLoadingInventory, let inspectedOwner, !owners.contains(inspectedOwner) { self.inspectedOwner = nil }
        }
        .onChange(of: search) { _, _ in inspectedOwner = nil }
        .onChange(of: model.isPreparing) { _, preparing in if preparing { inspectedRow = nil } }
        .onChange(of: model.isResolving) { _, resolving in if resolving { inspectedRow = nil } }
        .popover(item: $inspectedRow) { row in fileDetails(row) }
        .sheet(isPresented: $confirmsRemoval) { confirmation.environment(\.locale, locale).environment(\.layoutDirection, layoutDirection) }
        .confirmationDialog(copy("uninstall.quitFailed", "应用尚未退出"), isPresented: $model.needsForceQuit) {
            Button(copy("uninstall.forceQuit", "强制退出并继续"), role: .destructive) { model.beginUninstall(force: true) }
            Button(copy("applications.cancel", "取消"), role: .cancel) {}
        } message: { Text(copy("uninstall.forceQuitWarning", "强制退出可能丢失未保存的更改。")) }
        .sheet(isPresented: $showsCoverage) {
            if let owner = inspectedOwner, let report = model.reports[owner] {
                DiskCleanApplicationCoverageView(report: report, localization: localization)
                    .environment(\.locale, locale).environment(\.layoutDirection, layoutDirection)
            }
        }
    }

    private var inspectedOwner: String? {
        get { model.activeOwner }
        nonmutating set {
            if let owner = newValue { model.analyze(owner, select: !isLeftovers) }
            else { model.clearApplicationSelection() }
        }
    }

    private var uninstallTitle: String {
        if isLeftovers { return copy("applications.trash", "移到废纸篓") }
        if let owner = inspectedOwner, model.runningOwners.contains(where: { $0.caseInsensitiveCompare(owner) == .orderedSame }) {
            return copy("uninstall.quitAndUninstall", "退出并卸载")
        }
        if model.requiresServiceAuthorization || selectedRows.contains(where: { access(($0.path as NSString).deletingLastPathComponent, W_OK | X_OK) != 0 }) {
            return copy("uninstall.authorizeAndUninstall", "授权并卸载")
        }
        if model.retainedApplication?.bundleID == inspectedOwner, inspectedOwner != nil {
            return copy("uninstall.retry", "重试卸载")
        }
        return copy("ui.uninstall", "卸载")
    }

    @ViewBuilder
    private func unfinishedItems(_ result: DiskCleanExecutionResult) -> some View {
        let items = result.itemResults.filter { item in
            switch item.outcome {
            case .trashed, .removed: false
            default: true
            }
        }
        if !items.isEmpty {
            DisclosureGroup(copy("uninstall.unfinishedItems", "未完成项目"), isExpanded: $showsUnfinished) {
                ScrollView {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowVertical) {
                        ForEach(items, id: \.candidateID) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                                    Text(item.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                                    Text(unfinishedReason(item)).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: {
                                    Image(systemName: "folder")
                                }.buttonStyle(.bordered).controlSize(.small).help(copy("applications.reveal", "在访达中显示"))
                            }
                        }
                    }
                }.frame(maxHeight: 140)
            }
            .font(PluginSettingsTheme.Typography.rowDescription)
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        }
    }

    private func unfinishedReason(_ item: DiskCleanExecutionItemResult) -> String {
        switch item.outcome {
        case let .failed(message), let .partiallyDeleted(_, message), let .rollbackBlocked(_, message): return localizedReason(message)
        case .changedSinceScan: return copy("uninstall.fileChanged", "文件已变化，请重新检查")
        case let .skipped(safety):
            switch safety {
            case let .protected(reason), let .invalid(reason), let .requiresAdmin(reason): return localizedReason(reason)
            case let .whitelisted(rule): return protectedRule(path: item.path, rule: rule)
            case let .inUse(name): return name
            case .allowed: return copy("detail.result.skipped", "已跳过")
            }
        case .removed, .trashed: return ""
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) { searchField; Spacer(minLength: 0); toolbarActions }
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowVertical) {
                searchField
                HStack { Spacer(minLength: 0); toolbarActions }
            }
        }
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
    }

    private var searchField: some View {
        TextField(copy("ui.search", "搜索应用"), text: $search)
            .textFieldStyle(.roundedBorder).frame(minWidth: 120, idealWidth: 200, maxWidth: 300)
            .disabled(isWriting)
    }

    private var toolbarActions: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Picker(copy("uninstall.sort.title", "排序"), selection: $largestFirst) {
                Text(copy("uninstall.sort.name", "按名称")).tag(false)
                Text(copy("uninstall.sort.size", "按大小")).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel(copy("uninstall.sort.title", "排序"))
            .frame(minWidth: 160, idealWidth: 180, maxWidth: 220)
            Button {
                if inspectedOwner != nil { model.recheckCurrentApplication() }
                else { model.scan(leftovers: isLeftovers) }
            } label: { Label(copy("uninstall.refresh", "刷新"), systemImage: "arrow.clockwise") }
            .disabled(model.isPreparing || isWriting || model.controller?.snapshot.isBusy == true)
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    private var applicationList: some View {
        Group {
            if owners.isEmpty {
                if model.inventory == nil || model.isPreparing {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(copy("applications.empty", "未发现可审阅的项目"), systemImage: "app.dashed")
                }
            } else {
                List(selection: Binding(get: { inspectedOwner }, set: { owner in
                    if let owner { inspectedOwner = owner }
                })) {
                    ForEach(owners) { owner in
                        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                            if let app = owner.app {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 28, height: 28)
                                    .accessibilityHidden(true)
                            } else { Image(systemName: "folder").pluginSettingsRowIconStyle() }
                            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                                Text(owner.name).font(PluginSettingsTheme.Typography.rowTitle).lineLimit(1)
                                if let app = owner.app {
                                    Text([app.version.isEmpty ? copy("uninstall.versionUnknown", "版本未知") : app.version,
                                          app.isHomebrew ? "Homebrew" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            if model.analyzingOwners.contains(owner.id) || (applicationBytes(owner.id) == nil && model.sizingOwners.contains(owner.id)) { ProgressView().controlSize(.small) }
                            else {
                                Text(applicationBytes(owner.id).map(DiskCleanFormat.bytes) ?? copy("uninstall.sizeUnknown", "大小未知"))
                                    .font(PluginSettingsTheme.Typography.monospacedValue).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(PluginSettingsTheme.Typography.rowIcon).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, PluginSettingsTheme.Spacing.controlCluster)
                        .contentShape(Rectangle())
                        .tag(owner.id)
                    }
                }
                .listStyle(.inset)
                .disabled(isWriting || model.isLoadingInventory)
            }
        }
    }

    private func review(_ owner: String, showsBack: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                if showsBack {
                    Button { inspectedOwner = nil } label: { Image(systemName: "chevron.backward") }
                        .help(copy("uninstall.back", "返回应用列表"))
                        .buttonStyle(.bordered).controlSize(.small).disabled(isWriting)
                }
                Text(ownerName(owner)).font(PluginSettingsTheme.Typography.emphasizedRowTitle).lineLimit(1)
                Spacer()
                if model.reports[owner] != nil {
                    Button { showsCoverage = true } label: {
                        Label(copy("uninstall.coverage.title", "扫描覆盖"), systemImage: "checklist")
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                if model.analyzingOwners.contains(owner) || (model.isPreparing && model.activeOwner == owner) {
                    ProgressView().controlSize(.small)
                }
                else if model.coverage[owner] == nil {
                    Button(copy("uninstall.refresh", "刷新")) { model.recheckCurrentApplication() }
                        .buttonStyle(.bordered).controlSize(.small).disabled(model.isPreparing || isWriting)
                }
            }
            .padding(PluginSettingsTheme.Spacing.rowHorizontal)
            if let app = model.inventory?.applications.first(where: { $0.bundleID == owner }), let rejection = applicationRejection(owner) {
                HStack {
                    Text(rejection).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    Spacer()
                    Button(copy("uninstall.manage", "前往处理")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                .padding(.bottom, PluginSettingsTheme.Spacing.rowVertical)
            }
            List {
                ForEach(DiskCleanApplicationFileCategory.allCases) { category in
                    categorySection(category, owner: owner)
                }
                let manual = model.rows.filter { $0.bundleID == owner && isManualComponent($0) }
                if !manual.isEmpty {
                    DisclosureGroup(isExpanded: sectionExpansion("manual", owner: owner)) {
                        ForEach(manual) { fileRow($0) }
                    } label: {
                        Label(copy("uninstall.manual", "需手动处理"), systemImage: "hand.raised")
                            .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func categorySection(_ category: DiskCleanApplicationFileCategory, owner: String) -> some View {
        let rows = model.rows.filter { $0.bundleID == owner && $0.category == category && !isManualComponent($0) }
        let selectable = rows.filter(canSelect)
        if !rows.isEmpty {
            DisclosureGroup(isExpanded: sectionExpansion(category.rawValue, owner: owner)) {
                ForEach(rows) { fileRow($0) }
            } label: {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Toggle("", isOn: Binding(get: {
                        !selectable.isEmpty && selectable.allSatisfy { row in
                            model.candidate(path: row.path).map { model.controller?.snapshot.selection.isSelected($0.id) == true } == true
                        }
                    }, set: { selected in
                        if category == .application { model.selectApplication(owner, selected: selected) }
                        else { for row in selectable { model.selectPath(row, selected: selected) } }
                    }))
                    .labelsHidden().toggleStyle(.checkbox).accessibilityLabel(category.title(localization))
                    .disabled(selectable.isEmpty)
                    Label(category.title(localization), systemImage: category.symbol)
                        .font(PluginSettingsTheme.Typography.rowTitle)
                    Spacer(minLength: 0)
                    if model.coverage[owner] == nil {
                        Text("—").foregroundStyle(.secondary)
                    } else if let state = model.coverage[owner]?[category], state != .checked {
                        Label(coverageTitle(category, owner: owner), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange).lineLimit(1)
                    } else if rows.contains(where: { model.candidate(path: $0.path)?.sizeResult?.completeness.isComplete != true }) {
                        Text(copy("uninstall.sizeUnknown", "大小未知")).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(localization.format("detail.category.candidateCount", defaultValue: "%d 项", rows.count))
                            .foregroundStyle(.secondary)
                    }
                    measuredSize(rows, coverage: model.coverage[owner]?[category])
                }
                .font(PluginSettingsTheme.Typography.rowDescription)
                .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
            }
        }
    }

    private func sectionExpansion(_ section: String, owner: String) -> Binding<Bool> {
        Binding(get: {
            !collapsedSections[owner, default: []].contains(section)
        }, set: { expanded in
            if expanded { collapsedSections[owner]?.remove(section) }
            else { collapsedSections[owner, default: []].insert(section) }
        })
    }

    private func fileRow(_ row: DiskCleanApplicationReviewRow) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Toggle(row.isBundle ? URL(fileURLWithPath: row.path).lastPathComponent : row.title,
                isOn: Binding(get: {
                    model.candidate(path: row.path).map { model.controller?.snapshot.selection.isSelected($0.id) == true } == true
                }, set: { model.selectPath(row, selected: $0) }))
                .toggleStyle(.checkbox).font(PluginSettingsTheme.Typography.rowTitle)
                .lineLimit(1).truncationMode(.middle).disabled(!canSelect(row)).help(row.path)
            Spacer(minLength: 0)
            if showsLock(row) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).help(reason(row))
            } else if row.requiresOwnershipReview {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    .help(copy("uninstall.nameCandidate", "按名称匹配 · 请确认归属"))
            } else if row.isPersonal {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                    .help(copy("applications.personal", "个人数据 · 默认保留"))
            }
            measuredSize([row])
            Button { inspectedRow = row } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(copy("ui.details", "详情"))
        }
        .padding(.vertical, PluginSettingsTheme.Spacing.controlCluster)
    }

    private func fileDetails(_ row: DiskCleanApplicationReviewRow) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Text(row.title).font(PluginSettingsTheme.Typography.emphasizedRowTitle)
            Text(row.path).textSelection(.enabled)
            Text(row.evidence == "应用专属后台组件" ? copy("uninstall.serviceOwned", "应用专属后台组件") : row.evidence).foregroundStyle(.secondary).textSelection(.enabled)
            if !canSelect(row) { Text(reason(row)).foregroundStyle(.orange) }
            else if row.requiresOwnershipReview {
                Text(copy("uninstall.nameCandidate", "按名称匹配 · 请确认归属")).foregroundStyle(.orange)
            } else if row.isPersonal { Text(copy("applications.personal", "个人数据 · 默认保留")).foregroundStyle(.secondary) }
            Button(copy("applications.reveal", "在访达中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
            }.buttonStyle(.bordered).controlSize(.small)
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .padding(PluginSettingsTheme.Spacing.rowHorizontal).frame(width: 360, alignment: .leading)
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            Label(isLeftovers ? copy("applications.confirm", "将所选项目移到废纸篓？")
                : localization.format("uninstall.confirmSingle", defaultValue: "卸载 %@？", inspectedOwner.map(ownerName) ?? ""), systemImage: "trash")
                .font(PluginSettingsTheme.Typography.sectionTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowVertical) {
                    if isLeftovers {
                        ForEach(Array(selectedOwners).sorted(), id: \.self) { owner in
                            Text(ownerName(owner)).font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        }
                    }
                    ForEach(DiskCleanApplicationFileCategory.allCases) { category in
                        let rows = selectedRows.filter { $0.category == category }
                        if !rows.isEmpty {
                            HStack {
                                Text(category.title(localization))
                                Spacer()
                                Text(localization.format("detail.category.candidateCount", defaultValue: "%d 项", rows.count))
                                measuredSize(rows)
                            }
                        }
                    }
                    if !isLeftovers, model.inventory?.applications.contains(where: { selectedOwners.contains($0.bundleID) && $0.isHomebrew }) == true {
                        Label(copy("uninstall.homebrewReceiptRetained", "Homebrew 安装记录将保留"), systemImage: "shippingbox")
                            .foregroundStyle(.secondary)
                    }
                    if !isLeftovers, model.willStopServices {
                        Label(copy("uninstall.stopServices", "所需后台服务将先停止"), systemImage: "gearshape.2")
                            .foregroundStyle(.secondary)
                    }
                    if model.rows.contains(where: { selectedOwners.contains($0.bundleID) && isManualComponent($0) }) {
                        Label(copy("uninstall.manual", "需手动处理"), systemImage: "hand.raised")
                            .foregroundStyle(.orange)
                    }
                    let candidates = selectedRows.filter(\.requiresOwnershipReview)
                    if !candidates.isEmpty {
                        Label(copy("uninstall.reviewNames", "请确认以下关联文件属于此应用"), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                        ForEach(candidates) { row in
                            Text(row.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    if selectedRows.contains(where: \.isPersonal) {
                        Label(copy("uninstall.personalWarning", "包含所选设置与个人数据"), systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }
            }.frame(maxHeight: 260)
            HStack {
                Spacer()
                Button(copy("applications.cancel", "取消")) { confirmsRemoval = false }.keyboardShortcut(.cancelAction)
                Button(copy("applications.trash", "移到废纸篓")) {
                    confirmsRemoval = false
                    if isLeftovers { model.controller?.clean() }
                    else { model.uninstallCurrentApplication() }
                }.buttonStyle(.borderedProminent).disabled(isLeftovers ? model.controller?.snapshot.canClean != true : !model.canStartUninstall)
            }
            .controlSize(.small)
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .padding(PluginSettingsTheme.Spacing.pagePadding).frame(width: 440)
    }

    private func measuredSize(_ rows: [DiskCleanApplicationReviewRow], coverage: DiskCleanApplicationCoverage? = nil) -> some View {
        let candidates = rows.compactMap { model.candidate(path: $0.path) }
        let complete = candidates.count == rows.count && candidates.allSatisfy { $0.sizeResult?.completeness.isComplete == true }
        let bytes = candidates.reduce(0) { $0 + $1.estimatedBytes }
        let partial = coverage != nil && coverage != .checked
        let size = complete && (!rows.isEmpty || coverage == .checked) && (!partial || bytes > 0)
            ? (partial ? "≥ " : "") + DiskCleanFormat.bytes(bytes) : "—"
        return Text(size).font(PluginSettingsTheme.Typography.monospacedValue).foregroundStyle(.secondary)
            .frame(width: 86, alignment: .trailing)
    }

    private func showsLock(_ row: DiskCleanApplicationReviewRow) -> Bool {
        row.manualReason != nil || (model.controller?.snapshot.phase == .scanned && model.candidate(path: row.path)?.isCleanable == false)
    }

    private func canSelect(_ row: DiskCleanApplicationReviewRow) -> Bool {
        guard !model.isPreparing, !model.isResolving, model.controller?.snapshot.phase == .scanned,
              row.manualReason == nil, model.candidate(path: row.path)?.isCleanable == true else { return false }
        return true
    }

    private func reason(_ row: DiskCleanApplicationReviewRow) -> String {
        if model.isPreparing { return copy("uninstall.analyzing", "正在分析") }
        guard isLeftovers || row.bundleID == model.activeOwner else {
            return copy("uninstall.reviewUpdated", "文件列表已更新，请重新查看")
        }
        if let reason = row.manualReason { return localizedReason(reason) }
        if let candidate = model.candidate(path: row.path) {
            switch candidate.safety {
            case let .protected(reason), let .invalid(reason): return localizedReason(reason)
            case let .inUse(name): return name
            case .requiresAdmin: return copy("applications.admin", "需要管理员权限")
            case let .whitelisted(rule): return protectedRule(path: row.path, rule: rule)
            case .allowed: break
            }
            if candidate.sizeResult?.completeness.isComplete != true {
                return copy("uninstall.sizeIncomplete", "大小检查未完成")
            }
        }
        return copy("uninstall.reviewUpdated", "文件列表已更新，请重新查看")
    }

    private func protectedRule(path: String, rule: String) -> String {
        if isLeftovers { return copy("badge.whitelisted", "白名单") }
        return localization.format("uninstall.protectedRule", defaultValue: "用户保护的文件：%@（规则：%@）", path, rule)
    }

    private func localizedReason(_ reason: String) -> String {
        switch reason {
        case "已取消，尚未处理": return copy("uninstall.notProcessed", "已取消，尚未处理")
        case "后台组件位置已变化", "后台服务配置已变化，请重新检查", "辅助组件签名已变化":
            return copy("uninstall.fileChanged", "文件已变化，请重新检查")
        case "无法访问父目录，请检查访问权限", "文件无法读取", "无法读取目录或磁盘不受支持", "文件类型或下载状态不支持":
            return copy("uninstall.accessRequired", "无法读取此位置，请检查访问权限或磁盘状态")
        case "磁盘不可写或不支持移到废纸篓": return copy("uninstall.diskUnavailable", "磁盘不可写或不支持移到废纸篓")
        case "后台服务仍在运行，请重试卸载", "辅助组件仍在运行，请重试卸载":
            return copy("uninstall.serviceRunning", "后台组件仍在运行，请重试卸载")
        case "无法确认后台服务状态，请重试": return copy("uninstall.serviceUnknown", "无法确认后台服务状态，请重新检查")
        case "废纸篓操作结果无法确认，请在访达中检查": return copy("uninstall.trashUnknown", "废纸篓操作结果无法确认，请在访达中检查")
        default: break
        }
        if reason == DiskCleanApplicationOwnershipCheck.incomplete.rejection {
            return copy("uninstall.componentOwnershipUnknown", "无法确认此组件是否由其他应用共用")
        }
        return reason
    }

    private func coverageTitle(_ category: DiskCleanApplicationFileCategory, owner: String) -> String {
        guard let coverage = model.coverage[owner]?[category] else {
            return model.analyzingOwners.contains(owner) ? copy("uninstall.analyzing", "正在分析") : copy("detail.limited.title", "本次扫描不完整")
        }
        switch coverage {
        case .checked: return copy("uninstall.noFiles", "未发现关联文件")
        case .permissionRequired: return copy("ui.needsAccess", "需要访问权限")
        case .incomplete: return copy("detail.limited.title", "本次扫描不完整")
        }
    }

    private func applicationRejection(_ owner: String) -> String? {
        if let rejection = model.inventory?.applications.first(where: { $0.bundleID == owner })?.rejection { return rejection }
        guard let row = model.rows.first(where: { $0.bundleID == owner && $0.isBundle }),
              let candidate = model.candidate(path: row.path) else { return nil }
        switch candidate.safety {
        case let .protected(reason), let .invalid(reason): return reason
        case let .inUse(name): return name
        case .requiresAdmin: return copy("applications.admin", "需要管理员权限")
        case let .whitelisted(rule): return protectedRule(path: row.path, rule: rule)
        case .allowed: return nil
        }
    }

    private func isManualComponent(_ row: DiskCleanApplicationReviewRow) -> Bool {
        row.manualReason != nil && (row.path.hasPrefix("/Library/") || row.path.contains("/Library/LaunchAgents/"))
    }
    private var isWriting: Bool { model.isResolving || model.controller?.snapshot.phase == .cleaning }
    private var selectedRows: [DiskCleanApplicationReviewRow] {
        model.rows.filter { row in model.candidate(path: row.path).map { model.controller?.snapshot.selection.isSelected($0.id) == true } == true }
    }
    private var selectedOwners: Set<String> { Set(selectedRows.map(\.bundleID)) }
    private func ownerName(_ owner: String) -> String {
        model.inventory?.applications.first { $0.bundleID == owner }?.name
            ?? (model.focusedApplication?.bundleID == owner ? model.focusedApplication?.name : nil)
            ?? (model.retainedApplication?.bundleID == owner ? model.retainedApplication?.name : nil) ?? owner
    }
    private struct Owner: Identifiable {
        let id: String
        let name: String
        let app: DiskCleanInstalledApplication?
    }
    private func applicationBytes(_ owner: String) -> Int64? {
        let paths = model.rows.filter { $0.bundleID == owner && (isLeftovers || $0.isBundle) }
        let candidates = paths.compactMap { model.candidate(path: $0.path) }
        if !candidates.isEmpty, candidates.count == paths.count, candidates.allSatisfy({ $0.sizeResult?.completeness.isComplete == true }) {
            return candidates.reduce(0) { $0 + $1.estimatedBytes }
        }
        if let cached = model.applicationSizes[owner] { return cached }
        let apps = model.inventory?.applications.filter { $0.bundleID == owner } ?? []
        guard !apps.isEmpty, apps.allSatisfy({ $0.indexedBytes != nil }) else { return nil }
        return apps.reduce(0) { $0 + ($1.indexedBytes ?? 0) }
    }

    private var owners: [Owner] {
        let groups = Dictionary(grouping: model.inventory?.applications ?? [], by: \.bundleID)
        var ids = isLeftovers ? model.suspectedOwners : Set(groups.keys)
        if !isLeftovers, let retained = model.retainedApplication { ids.insert(retained.bundleID) }
        if !isLeftovers, let focused = model.focusedApplication, focused.bundleID == inspectedOwner { ids.insert(focused.bundleID) }
        return ids.map { Owner(id: $0, name: ownerName($0), app: groups[$0]?.first
            ?? (model.focusedApplication?.bundleID == $0 ? model.focusedApplication : nil)) }
            .filter { search.isEmpty || ($0.name + $0.id).localizedCaseInsensitiveContains(search) }
            .sorted { leftOwner, rightOwner in
                if largestFirst {
                    let leftBytes = applicationBytes(leftOwner.id) ?? -1
                    let rightBytes = applicationBytes(rightOwner.id) ?? -1
                    if leftBytes != rightBytes { return leftBytes > rightBytes }
                }
                return leftOwner.name.localizedStandardCompare(rightOwner.name) == .orderedAscending
            }
    }
    private func copy(_ key: String, _ fallback: String) -> String { localization.string(key, defaultValue: fallback) }
}
