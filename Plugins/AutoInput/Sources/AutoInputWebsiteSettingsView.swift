import SwiftUI
import MacToolsPluginKit

struct AutoInputWebsiteSettingsView: View {
    @ObservedObject var store: AutoInputStore
    @ObservedObject var controller: AutoInputController
    let localization: PluginLocalization
    let onChange: () -> Void
    @State private var editingRule: AutoInputWebsiteRule?
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localization.string(
                "settings.websites.description",
                defaultValue: "按网站切换输入法，优先于应用规则。需要辅助功能权限。"
            ))
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)
            .pluginSettingsListRowPadding()

            ForEach(Array(store.websiteRules.enumerated()), id: \.element.id) { index, rule in
                PluginSettingsListDivider()
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Toggle(rule.pattern, isOn: Binding(
                        get: { store.websiteRules.first(where: { $0.id == rule.id })?.isEnabled ?? false },
                        set: { enabled in
                            var updated = rule
                            updated.isEnabled = enabled
                            store.upsertWebsiteRule(updated)
                            onChange()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(Text(rule.pattern))
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(rule.pattern)
                            .font(PluginSettingsTheme.Typography.rowTitle)
                            .lineLimit(1)
                            .help(rule.pattern)
                        Text(ruleSubtitle(rule))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        store.moveWebsiteRule(id: rule.id, offset: -1)
                        onChange()
                    } label: {
                        Label(localization.string("settings.websites.moveUp", defaultValue: "上移"), systemImage: "arrow.up")
                    }
                    .disabled(index == 0)
                    Button {
                        store.moveWebsiteRule(id: rule.id, offset: 1)
                        onChange()
                    } label: {
                        Label(localization.string("settings.websites.moveDown", defaultValue: "下移"), systemImage: "arrow.down")
                    }
                    .disabled(index == store.websiteRules.count - 1)
                    Button { editingRule = rule } label: {
                        Label(localization.string("settings.websites.edit", defaultValue: "编辑"), systemImage: "pencil")
                    }
                    Button {
                        store.removeWebsiteRule(id: rule.id)
                        onChange()
                    } label: {
                        Label(localization.string("settings.websites.delete", defaultValue: "删除"), systemImage: "trash")
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pluginSettingsListRowPadding(interactive: true)
            }

            PluginSettingsListDivider()
            HStack {
                Text(localization.string(
                    "settings.websites.order",
                    defaultValue: "按顺序匹配首条可用规则。编辑地址栏时暂停网站规则。"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    var rule = AutoInputWebsiteRule()
                    rule.inputSourceID = controller.sources.first(where: { $0.id == controller.currentSourceID })?.id
                        ?? controller.sources.first?.id ?? ""
                    editingRule = rule
                } label: {
                    Label(localization.string("settings.rules.add", defaultValue: "添加"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.sources.isEmpty)
            }
            .pluginSettingsListRowPadding(interactive: true)
        }
        .pluginSettingsSearchAnchor(pluginID: "auto-input", entryID: AutoInputSettingsSearchEntryID.websites)
        .sheet(item: $editingRule) { rule in
            AutoInputWebsiteRuleEditor(rule: rule, sources: controller.sources, localization: localization) { updated in
                guard store.upsertWebsiteRule(updated) == .committed else { onChange(); return false }
                onChange()
                return true
            }
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection)
        }
    }

    private func ruleSubtitle(_ rule: AutoInputWebsiteRule) -> String {
        let browser = AutoInputBrowser.supported.first(where: { $0.id == rule.browserBundleIdentifier })?.name
            ?? localization.string("settings.websites.allBrowsers", defaultValue: "所有支持的浏览器")
        let source = controller.sources.first(where: { $0.id == rule.inputSourceID })?.name
            ?? localization.string("settings.source.unavailable", defaultValue: "输入法不可用")
        return "\(browser) · \(source)"
    }
}

private struct AutoInputWebsiteRuleEditor: View {
    @State var rule: AutoInputWebsiteRule
    let sources: [AutoInputSource]
    let localization: PluginLocalization
    let save: (AutoInputWebsiteRule) -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Form {
                Picker(localization.string("settings.websites.browser", defaultValue: "浏览器"), selection: $rule.browserBundleIdentifier) {
                    Text(localization.string("settings.websites.allBrowsers", defaultValue: "所有支持的浏览器")).tag("")
                    if !rule.browserBundleIdentifier.isEmpty,
                       !AutoInputBrowser.supports(rule.browserBundleIdentifier) {
                        Text(rule.browserBundleIdentifier).tag(rule.browserBundleIdentifier)
                    }
                    ForEach(AutoInputBrowser.supported) { browser in Text(browser.name).tag(browser.id) }
                }
                Picker(localization.string("settings.websites.match", defaultValue: "匹配方式"), selection: $rule.match) {
                    Text(localization.string("settings.websites.domainSuffix", defaultValue: "域名及子域名"))
                        .tag(AutoInputWebsiteMatch.domainSuffix)
                    Text(localization.string("settings.websites.domain", defaultValue: "仅此域名"))
                        .tag(AutoInputWebsiteMatch.domain)
                    Text(localization.string("settings.websites.urlRegex", defaultValue: "URL 正则表达式"))
                        .tag(AutoInputWebsiteMatch.urlRegex)
                }
                TextField(localization.string("settings.websites.pattern", defaultValue: "域名或表达式"), text: $rule.pattern)
                    .textFieldStyle(.roundedBorder)
                Picker(localization.string("settings.rules.inputSource.title", defaultValue: "输入法"), selection: $rule.inputSourceID) {
                    if !rule.inputSourceID.isEmpty, !sources.contains(where: { $0.id == rule.inputSourceID }) {
                        Text(localization.string("settings.source.unavailable", defaultValue: "输入法不可用"))
                            .tag(rule.inputSourceID)
                    }
                    ForEach(sources) { source in Text(source.name).tag(source.id) }
                }
                Text(localization.string("settings.websites.hint", defaultValue: "输入域名，例如 example.com；正则表达式匹配完整网页 URL。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                if !rule.pattern.isEmpty, !rule.isValid {
                    Text(localization.string("settings.websites.invalidPattern", defaultValue: "请输入有效域名或正则表达式（最多 512 个字符）。"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(localization.string("settings.websites.cancel", defaultValue: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(localization.string("settings.websites.save", defaultValue: "保存")) {
                    rule.pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    if save(rule) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!rule.isValid)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.bottom, PluginSettingsTheme.Spacing.rowVertical)
        }
        .frame(width: 540, height: 360)
    }
}
