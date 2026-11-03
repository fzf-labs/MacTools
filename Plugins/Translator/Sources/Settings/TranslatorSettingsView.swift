import SwiftUI
import MacToolsPluginKit

struct TranslatorSettingsView: View {
    @State private var firstLanguage: TranslatorLanguage
    @State private var secondLanguage: TranslatorLanguage
    @State private var profiles: [TranslatorProviderProfile]
    @State private var apiKeys: [String: String]
    @State private var savedLanguagePair: TranslatorLanguagePair
    @State private var selectedProfileID: String?
    @State private var message: String?
    @State private var messageIsError = false

    private let localization: PluginLocalization
    private let languagePair: TranslatorLanguagePair
    private let onSave: ([TranslatorProviderProfile], [String: String], TranslatorLanguagePair) -> String?
    private let onMakeNewProfile: ([TranslatorProviderProfile]) -> TranslatorProviderProfile

    init(
        profiles: [TranslatorProviderProfile],
        apiKeys: [String: String],
        languagePair: TranslatorLanguagePair,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        onSave: @escaping ([TranslatorProviderProfile], [String: String], TranslatorLanguagePair) -> String?,
        onMakeNewProfile: @escaping ([TranslatorProviderProfile]) -> TranslatorProviderProfile
    ) {
        _firstLanguage = State(initialValue: languagePair.first)
        _secondLanguage = State(initialValue: languagePair.second)
        _profiles = State(initialValue: profiles.isEmpty ? [TranslatorProviderProfile.defaultProfile(localization: localization)] : profiles)
        _apiKeys = State(initialValue: apiKeys)
        _savedLanguagePair = State(initialValue: languagePair)
        _selectedProfileID = State(initialValue: profiles.first?.id ?? TranslatorProviderProfile.defaultID)
        self.localization = localization
        self.languagePair = languagePair
        self.onSave = onSave
        self.onMakeNewProfile = onMakeNewProfile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            languageSection
            providerListSection
            providerDetailSection
            actions
        }
        .onChange(of: languagePair) { _, pair in
            firstLanguage = pair.first
            secondLanguage = pair.second
            savedLanguagePair = pair
            message = nil
            messageIsError = false
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(localization.string("settings.language.title", defaultValue: "偏好语言"), icon: "character.book.closed")

            VStack(spacing: 0) {
                fieldRow(
                    title: localization.string("settings.language.first.title", defaultValue: "第一语言"),
                    description: localization.string("settings.language.first.description", defaultValue: "自动识别为其他语言时翻译到这里。")
                ) {
                    languagePicker(selection: messageClearing($firstLanguage))
                }

                PluginSettingsListDivider()

                fieldRow(
                    title: localization.string("settings.language.second.title", defaultValue: "第二语言"),
                    description: localization.string("settings.language.second.description", defaultValue: "识别为第一语言时翻译到这里。")
                ) {
                    languagePicker(selection: messageClearing($secondLanguage))
                }
            }
        }
    }

    private var providerListSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                sectionHeader(localization.string("settings.providerList.title", defaultValue: "翻译服务"), icon: "network")
                Spacer()
                Button {
                    addProfile()
                } label: {
                    Label(localization.string("settings.providerList.add", defaultValue: "添加"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            VStack(spacing: 0) {
                ForEach(profiles) { profile in
                    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                        providerRow(index: index)
                        if profile.id != profiles.last?.id {
                            PluginSettingsListDivider()
                        }
                    }
                }
            }
        }
    }

    private var providerDetailSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(localization.string("settings.providerDetail.title", defaultValue: "服务详情"), icon: "slider.horizontal.3")

            if let index = selectedProfileIndex {
                VStack(spacing: 0) {
                    editableFieldRow(
                        title: localization.string("settings.provider.name.title", defaultValue: "名称"),
                        description: localization.string("settings.provider.name.description", defaultValue: "显示在翻译结果卡片上。")
                    ) {
                        TextField("OpenAI", text: binding(for: index, keyPath: \.name))
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                    }

                    PluginSettingsListDivider()

                    editableFieldRow(
                        title: localization.string("settings.provider.baseURL.title", defaultValue: "服务地址"),
                        description: localization.string("settings.provider.baseURL.description", defaultValue: "OpenAI 或兼容网关地址。")
                    ) {
                        TextField("https://api.openai.com", text: binding(for: index, keyPath: \.baseURL))
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                    }

                    PluginSettingsListDivider()

                    editableFieldRow(
                        title: localization.string("settings.provider.apiKey.title", defaultValue: "接口密钥"),
                        description: localization.string("settings.provider.apiKey.description", defaultValue: "留空则保留当前钥匙串内容。")
                    ) {
                        SecureField("sk-...", text: apiKeyBinding(profileID: profiles[index].id))
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                    }

                    PluginSettingsListDivider()

                    editableFieldRow(
                        title: localization.string("settings.provider.model.title", defaultValue: "模型"),
                        description: localization.string("settings.provider.model.description", defaultValue: "用于翻译的模型名称。")
                    ) {
                        TextField("gpt-5.4-mini", text: binding(for: index, keyPath: \.model))
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                    }

                    PluginSettingsListDivider()

                    promptEditor(index: index)
                }
            } else {
                Text(localization.string("settings.providerDetail.empty", defaultValue: "请选择一个翻译服务。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .pluginSettingsListRowPadding()
            }
        }
    }

    private var actions: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Button(localization.string("settings.action.restoreDefaults", defaultValue: "恢复默认")) {
                profiles = [TranslatorProviderProfile.defaultProfile(localization: localization)]
                selectedProfileID = profiles[0].id
                apiKeys = [:]
                message = nil
                messageIsError = false
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            if let message {
                Text(message)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(messageIsError ? Color.red : Color.secondary)
            }

            Button(localization.string("settings.action.save", defaultValue: "保存")) {
                save()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private func providerRow(index: Int) -> some View {
        let profile = profiles[index]

        // The row toggle and move/delete buttons handle their own clicks. Only the name/model area
        // selects the row, avoiding nested interactive controls inside one row-level Button.
        return HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Toggle("", isOn: providerEnabledBinding(for: index))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

            Button {
                selectedProfileID = profile.id
            } label: {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(profile.normalizedName.isEmpty
                            ? localization.string("settings.providerRow.unnamed", defaultValue: "未命名服务")
                            : profile.normalizedName)
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? localization.string("settings.providerRow.missingModel", defaultValue: "未设置模型")
                            : profile.model)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                    if profile.isEnabled, let validationError = profile.validationError {
                        Text(validationError.errorDescription(localization: localization))
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            iconButton("chevron.up", help: localization.string("settings.providerRow.moveUpHelp", defaultValue: "上移")) {
                moveProfile(from: index, offset: -1)
            }
            .disabled(index == 0)

            iconButton("chevron.down", help: localization.string("settings.providerRow.moveDownHelp", defaultValue: "下移")) {
                moveProfile(from: index, offset: 1)
            }
            .disabled(index == profiles.count - 1)

            iconButton("trash", help: localization.string("settings.providerRow.deleteHelp", defaultValue: "删除")) {
                deleteProfile(at: index)
            }
            .disabled(profiles.count == 1)
        }
        .pluginSettingsListRowPadding(interactive: true)
        .background {
            if selectedProfileID == profile.id {
                RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
        }
    }

    private func promptEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Text(localization.string("settings.prompt.template.title", defaultValue: "模板"))
                .font(PluginSettingsTheme.Typography.rowTitle)
            Text(localization.string(
                "settings.prompt.template.description",
                defaultValue: "必须包含 {{text}}。可使用 {{source_language}} 和 {{target_language}}。"
            ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)

            TextEditor(text: binding(for: index, keyPath: \.promptTemplate))
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 130, idealHeight: 160, maxHeight: 220)
                .background(PluginSettingsTheme.Palette.fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field, style: .continuous))
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }

    private func fieldRow<Content: View>(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            content()
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func editableFieldRow<Content: View>(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        fieldRow(title: title, description: description, content: content)
    }

    private func languagePicker(selection: Binding<TranslatorLanguage>) -> some View {
        Picker("", selection: selection) {
            ForEach(TranslatorLanguage.allCases) { language in
                Text("\(language.flag) \(language.displayName(localization: localization))")
                    .tag(language)
            }
        }
        .labelsHidden()
        .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
    }

    private func iconButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var selectedProfileIndex: Int? {
        guard let selectedProfileID,
              let index = profiles.firstIndex(where: { $0.id == selectedProfileID })
        else {
            return profiles.indices.first
        }

        return index
    }

    private func binding<Value>(
        for index: Int,
        keyPath: WritableKeyPath<TranslatorProviderProfile, Value>
    ) -> Binding<Value> {
        Binding(
            get: { profiles[index][keyPath: keyPath] },
            set: {
                profiles[index][keyPath: keyPath] = $0
                message = nil
            }
        )
    }

    private func apiKeyBinding(profileID: String) -> Binding<String> {
        Binding(
            get: { apiKeys[profileID] ?? "" },
            set: {
                apiKeys[profileID] = $0
                message = nil
            }
        )
    }

    private func providerEnabledBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { profiles[index].isEnabled },
            set: { isEnabled in
                guard profiles[index].isEnabled != isEnabled else {
                    return
                }

                let previousState = providerListState()
                profiles[index].isEnabled = isEnabled
                message = nil
                messageIsError = false
                persistProviderListChange(previousState: previousState)
            }
        )
    }

    /// Wraps a language binding and clears the "saved" message when the user makes unsaved edits.
    private func messageClearing(_ binding: Binding<TranslatorLanguage>) -> Binding<TranslatorLanguage> {
        Binding(
            get: { binding.wrappedValue },
            set: {
                binding.wrappedValue = $0
                message = nil
                messageIsError = false
            }
        )
    }

    private func addProfile() {
        let previousState = providerListState()
        let profile = onMakeNewProfile(profiles)
        profiles.append(profile)
        selectedProfileID = profile.id
        message = nil
        messageIsError = false
        persistProviderListChange(previousState: previousState)
    }

    private func deleteProfile(at index: Int) {
        let previousState = providerListState()
        let deletedID = profiles[index].id
        profiles.remove(at: index)
        apiKeys.removeValue(forKey: deletedID)
        selectedProfileID = profiles.indices.contains(index) ? profiles[index].id : profiles.last?.id
        message = nil
        messageIsError = false
        persistProviderListChange(previousState: previousState)
    }

    private func moveProfile(from index: Int, offset: Int) {
        let target = index + offset
        guard profiles.indices.contains(index), profiles.indices.contains(target) else {
            return
        }

        let previousState = providerListState()
        profiles.swapAt(index, target)
        selectedProfileID = profiles[target].id
        message = nil
        messageIsError = false
        persistProviderListChange(previousState: previousState)
    }

    private func save() {
        let languagePair = TranslatorLanguagePair(first: firstLanguage, second: secondLanguage)

        guard languagePair.first != languagePair.second else {
            message = localization.string("settings.error.sameLanguages", defaultValue: "两种偏好语言不能相同。")
            messageIsError = true
            return
        }

        if let errorMessage = onSave(profiles, apiKeys, languagePair) {
            message = errorMessage
            messageIsError = true
        } else {
            savedLanguagePair = languagePair
            message = localization.string("settings.message.saved", defaultValue: "已保存")
            messageIsError = false
        }
    }

    private struct ProviderListState {
        var profiles: [TranslatorProviderProfile]
        var apiKeys: [String: String]
        var selectedProfileID: String?
    }

    private func providerListState() -> ProviderListState {
        ProviderListState(
            profiles: profiles,
            apiKeys: apiKeys,
            selectedProfileID: selectedProfileID
        )
    }

    private func persistProviderListChange(previousState: ProviderListState) {
        if let errorMessage = onSave(profiles, apiKeys, savedLanguagePair) {
            profiles = previousState.profiles
            apiKeys = previousState.apiKeys
            selectedProfileID = previousState.selectedProfileID
            message = errorMessage
            messageIsError = true
            return
        }

        message = localization.string("settings.message.saved", defaultValue: "已保存")
        messageIsError = false
    }
}
