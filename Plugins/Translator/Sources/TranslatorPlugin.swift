import AppKit
import ApplicationServices
import Carbon
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class TranslatorPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        TranslatorPluginProvider(context: context)
    }
}

@MainActor
private struct TranslatorPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [TranslatorPlugin(context: context)]
    }
}

typealias ScreenshotRegionCapturerFactory = @MainActor (@escaping () -> Bool) -> any ScreenshotRegionCapturing

@MainActor
final class TranslatorPlugin:
    MacToolsPlugin, PluginSettingsPresenting, PluginActionProviding, PluginActionPermissionProviding, PluginLegacyActionShortcutProviding {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        let descriptor = rowDescriptor
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: descriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("metadata.title", defaultValue: metadata.title),
                systemImage: metadata.iconName,
                control: .toggle,
                state: state,
                menuActionBehavior: descriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    private enum APIKeyState: Equatable {
        case unknown
        case present
        case missing
        case error(String)
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: TranslatorConstants.pluginID,
            title: localization.string("metadata.title", defaultValue: "翻译"),
            iconName: "text.bubble",
            iconTint: Color(nsColor: .systemBlue),
            order: 57,
            defaultDescription: localization.string("metadata.description", defaultValue: "划词与截图快捷键翻译")
        )
    }

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    var onPersistentPreferencesChange: (() -> Void)?
    private let storage: PluginStorage
    private var providerEditorRevision = 0
    private var credentialAuthorization: PortableCredentialAuthorization { .init(storage: storage) }
    private let accessibilityTrustProvider: () -> Bool
    private let accessibilityTrustRequester: (Bool) -> Bool
    private let screenRecordingPermissionProvider: () -> Bool
    private let selectTranslationStarter: (() -> Void)?
    private let screenshotTranslationStarter: (() -> Void)?
    private let secretStore: any TranslatorSecretStoring
    private let languagePreferenceStore: LanguagePreferenceStore
    private let panelController: any TranslatorPanelControlling
    private let selectedTextCapturePipeline: SelectedTextCapturePipeline
    private let screenshotRegionCapturer: (any ScreenshotRegionCapturing)?
    private let screenshotRegionCapturerFactory: ScreenshotRegionCapturerFactory
    private let ocrTextRecognizer: (any OCRTextRecognizing)?
    private let translationProviderFactoryOverride: TranslatorProviderFactory?
    private let providerProfileStore: TranslatorProviderProfileStore
    private let localization: PluginLocalization
    private var providerConfiguration: OpenAICompatibleConfiguration
    private var providerProfiles: [TranslatorProviderProfile]
    private var languagePair: TranslatorLanguagePair
    private var cachedAPIKey: String?
    private var cachedAPIKeys: [String: String]
    private var didLoadProfileAPIKeys: Set<String>
    private var didLoadAPIKey = false
    private var apiKeyState: APIKeyState
    private var coordinator: TranslatorCoordinator?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: TranslatorConstants.pluginID),
        accessibilityTrustProvider: @escaping () -> Bool = AccessibilityCheck.isTrusted,
        accessibilityTrustRequester: @escaping (Bool) -> Bool = AccessibilityCheck.requestTrust,
        screenRecordingPermissionProvider: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        selectTranslationStarter: (() -> Void)? = nil,
        screenshotTranslationStarter: (() -> Void)? = nil,
        secretStore: any TranslatorSecretStoring = OpenAICompatibleSecretStore(),
        panelController: (any TranslatorPanelControlling)? = nil,
        selectedTextCapturePipeline: SelectedTextCapturePipeline? = nil,
        screenshotRegionCapturer: (any ScreenshotRegionCapturing)? = nil,
        screenshotRegionCapturerFactory: ScreenshotRegionCapturerFactory? = nil,
        ocrTextRecognizer: (any OCRTextRecognizing)? = nil,
        translationProviderFactoryOverride: TranslatorProviderFactory? = nil,
        localization: PluginLocalization? = nil
    ) {
        let localization = localization ?? PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        self.storage = context.storage
        _ = Self.portableStore(storage: context.storage).recover()
        self.accessibilityTrustProvider = accessibilityTrustProvider
        self.accessibilityTrustRequester = accessibilityTrustRequester
        self.screenRecordingPermissionProvider = screenRecordingPermissionProvider
        self.selectTranslationStarter = selectTranslationStarter
        self.screenshotTranslationStarter = screenshotTranslationStarter
        self.secretStore = secretStore
        self.panelController = panelController ?? TranslatorPanelController(localization: localization)
        self.selectedTextCapturePipeline = selectedTextCapturePipeline ?? .live(localization: localization)
        self.screenshotRegionCapturer = screenshotRegionCapturer
        self.screenshotRegionCapturerFactory = screenshotRegionCapturerFactory ?? { permissionProvider in
            ScreenshotRegionCapturer(screenRecordingPermissionProvider: permissionProvider)
        }
        self.ocrTextRecognizer = ocrTextRecognizer
        self.translationProviderFactoryOverride = translationProviderFactoryOverride
        let providerProfileStore = TranslatorProviderProfileStore(storage: context.storage, localization: localization)
        let providerProfiles = providerProfileStore.loadProfiles()
        self.providerProfileStore = providerProfileStore
        self.providerProfiles = providerProfiles
        if !PortableCredentialAuthorization(storage: context.storage).seedIfNeeded(
            profiles: Dictionary(providerProfiles.map { ($0.id, $0.baseURL) }, uniquingKeysWith: { first, _ in first }),
            store: Self.portableStore(storage: context.storage)) {
            TranslatorLog.provider.error("Could not initialize local credential authorization.")
        }
        let languagePreferenceStore = LanguagePreferenceStore(storage: context.storage)
        self.languagePreferenceStore = languagePreferenceStore
        self.providerConfiguration = providerProfiles.first?.configuration
            ?? OpenAICompatibleConfiguration(storage: context.storage, localization: localization)
        self.languagePair = languagePreferenceStore.loadPair()
        self.cachedAPIKey = nil
        self.cachedAPIKeys = [:]
        self.didLoadProfileAPIKeys = []
        self.apiKeyState = .unknown
        self.panelController.onAction = { [weak self] action in
            self?.handlePanelAction(action)
        }
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: isShortcutEnabled,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: TranslatorConstants.PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能授权"),
                description: localization.string("permission.accessibility.description", defaultValue: "划词翻译需要读取当前选中文本。")
            ),
            PluginPermissionRequirement(
                id: TranslatorConstants.PermissionID.automation,
                kind: .automation,
                title: localization.string("permission.automation.title", defaultValue: "自动化授权"),
                description: localization.string("permission.automation.description", defaultValue: "浏览器划词可能需要允许 MacTools 控制当前浏览器。")
            ),
            PluginPermissionRequirement(
                id: TranslatorConstants.PermissionID.screenRecording,
                kind: .screenRecording,
                title: localization.string("permission.screenRecording.title", defaultValue: "屏幕录制授权"),
                description: localization.string("permission.screenRecording.description", defaultValue: "截图翻译需要读取框选区域的屏幕内容。")
            ),
        ]
    }


    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: TranslatorConstants.ShortcutID.selectTranslation,
                title: localization.string("shortcut.selectTranslation.title", defaultValue: "划词翻译"),
                description: localization.string("shortcut.selectTranslation.description", defaultValue: "翻译当前选中的文本。"),
                actionID: TranslatorConstants.ActionID.selectTranslation,
                scope: .global,
                defaultBinding: TranslatorConstants.Defaults.selectTranslationShortcut,
                isRequired: false
            ),
            PluginShortcutDefinition(
                id: TranslatorConstants.ShortcutID.screenshotTranslation,
                title: localization.string("shortcut.screenshotTranslation.title", defaultValue: "截图翻译"),
                description: localization.string("shortcut.screenshotTranslation.description", defaultValue: "框选截图区域并翻译识别出的文字。"),
                actionID: TranslatorConstants.ActionID.screenshotTranslation,
                scope: .global,
                defaultBinding: TranslatorConstants.Defaults.screenshotTranslationShortcut,
                isRequired: false
            ),
        ]
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(
                    providerID: metadata.id,
                    actionID: TranslatorConstants.ActionID.selectTranslation
                ),
                title: localization.string("shortcut.selectTranslation.title", defaultValue: "划词翻译"),
                description: localization.string(
                    "shortcut.selectTranslation.description",
                    defaultValue: "翻译当前选中的文本。"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "翻译"),
                    localization.string("shortcut.selectTranslation.title", defaultValue: "划词翻译"),
                ],
                systemImage: "text.cursor",
                externalInvocationPolicy: .allowed,
                capabilities: [.foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(
                    providerID: metadata.id,
                    actionID: TranslatorConstants.ActionID.screenshotTranslation
                ),
                title: localization.string("shortcut.screenshotTranslation.title", defaultValue: "截图翻译"),
                description: localization.string(
                    "shortcut.screenshotTranslation.description",
                    defaultValue: "框选截图区域并翻译识别出的文字。"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "翻译"),
                    localization.string("shortcut.screenshotTranslation.title", defaultValue: "截图翻译"),
                    "OCR",
                ],
                systemImage: "viewfinder",
                externalInvocationPolicy: .allowed,
                capabilities: [.foregroundInteractive]
            ),
        ]
    }

    var legacyActionShortcutAssignments: [LegacyActionShortcutAssignment] {
        shortcutDefinitions.compactMap { definition in
            guard let binding = shortcutBindingResolver?(definition.id) else {
                return nil
            }
            return LegacyActionShortcutAssignment(
                reference: ActionReference(
                    key: ActionKey(
                        providerID: metadata.id,
                        actionID: definition.actionID
                    )
                ),
                binding: binding,
                legacyShortcutDefinitionID: definition.id
            )
        }
    }

    func legacyActionShortcutsDidMigrate() {}

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        guard actionKey.providerID == metadata.id else { return [] }
        return switch actionKey.actionID {
        case TranslatorConstants.ActionID.selectTranslation:
            [
                TranslatorConstants.PermissionID.accessibility,
                TranslatorConstants.PermissionID.automation,
            ]
        case TranslatorConstants.ActionID.screenshotTranslation:
            [TranslatorConstants.PermissionID.screenRecording]
        default:
            []
        }
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard isShortcutEnabled else {
            return .unavailable(
                localization.string(
                    "action.unavailable.paused",
                    defaultValue: "翻译快捷键已暂停。"
                )
            )
        }
        switch reference.key.actionID {
        case TranslatorConstants.ActionID.selectTranslation:
            return accessibilityTrustProvider()
                ? .available
                : .unavailable(
                    localization.string(
                        "action.unavailable.accessibility",
                        defaultValue: "需要辅助功能授权。"
                    )
                )
        case TranslatorConstants.ActionID.screenshotTranslation:
            return screenRecordingPermissionProvider()
                ? .available
                : .unavailable(
                    localization.string(
                        "action.unavailable.screenRecording",
                        defaultValue: "需要屏幕录制授权。"
                    )
                )
        default:
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        handleShortcutAction(id: invocation.reference.key.actionID)
        return ActionExecutionHandle { .succeeded() }
    }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            promptBackupSection,
            PluginSettingsSection(
                id: "translator-settings",
                title: localization.string("settings.title", defaultValue: "翻译设置"),
                systemImage: "character.book.closed",
                presentation: .edgeToEdge
            ) { [weak self] _ in
                if let self {
                    TranslatorSettingsView(
                        profiles: self.providerProfiles,
                        apiKeys: [:],
                        languagePair: self.languagePair,
                        localization: self.localization,
                        onSave: { [weak self] profiles, apiKeys, languagePair in
                            self?.saveConfiguration(
                                profiles: profiles,
                                apiKeys: apiKeys,
                                languagePair: languagePair
                            )
                        },
                        onMakeNewProfile: { [weak self] profiles in
                            self?.providerProfileStore.makeNewProfile(existingProfiles: profiles)
                                ?? TranslatorProviderProfile(
                                    name: self?.localization.string("openAIClient.providerTitle", defaultValue: "OpenAI 翻译")
                                        ?? "OpenAI",
                                    isEnabled: false
                                )
                        }
                    )
                    .id(self.providerEditorRevision)
                }
            }
        ])
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else {
            return
        }

        guard isEnabled != isShortcutEnabled,
              portableStore.commit([TranslatorConstants.StorageKey.shortcutEnabled: .boolean(isEnabled)]) else { return }
        onPersistentPreferencesChange?()
        onStateChange?()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        switch permissionID {
        case TranslatorConstants.PermissionID.accessibility:
            let isGranted = accessibilityTrustProvider()
            return PluginPermissionState(
                isGranted: isGranted,
                footnote: isGranted
                    ? nil
                    : localization.string(
                        "permission.accessibility.footnote",
                        defaultValue: "前往系统设置 → 隐私与安全性 → 辅助功能，授权 MacTools。"
                    )
            )
        case TranslatorConstants.PermissionID.automation:
            return PluginPermissionState(
                isGranted: true,
                footnote: localization.string(
                    "permission.automation.footnote",
                    defaultValue: "macOS 会在首次控制浏览器时请求自动化授权。"
                ),
                statusText: localization.string("permission.automation.status", defaultValue: "按需确认"),
                statusSystemImage: "sparkles",
                statusTone: .neutral
            )
        case TranslatorConstants.PermissionID.screenRecording:
            let isGranted = screenRecordingPermissionProvider()
            return PluginPermissionState(
                isGranted: isGranted,
                footnote: isGranted
                    ? nil
                    : localization.string(
                        "permission.screenRecording.footnote",
                        defaultValue: "请在系统设置 → 隐私与安全性 → 录屏与系统录音（或录屏）中授权 MacTools。"
                    )
            )
        default:
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
    }

    func handlePermissionAction(id: String) {
        switch id {
        case TranslatorConstants.PermissionID.accessibility:
            _ = accessibilityTrustRequester(true)
            onStateChange?()
        case TranslatorConstants.PermissionID.automation:
            requestPermissionGuidance?(TranslatorConstants.PermissionID.automation)
            onStateChange?()
        case TranslatorConstants.PermissionID.screenRecording:
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
            onStateChange?()
        default:
            return
        }
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard case let .setBoolean(controlID, value) = action, controlID == Self.promptBackupKey else { return }
        setIncludesPromptText(value)
    }

    func deactivate(reason: PluginDeactivationReason) {
        guard reason.requiresStateCleanup else {
            return
        }

        if let coordinator {
            coordinator.close()
        } else {
            panelController.close()
        }
        coordinator = nil
    }

    func handleShortcutAction(id: String) {
        guard isShortcutEnabled else {
            return
        }

        switch id {
        case TranslatorConstants.ActionID.selectTranslation:
            if let selectTranslationStarter {
                selectTranslationStarter()
                return
            }

            let coordinator = coordinator ?? makeCoordinator()
            self.coordinator = coordinator
            coordinator.startSelectTranslation()
        case TranslatorConstants.ActionID.screenshotTranslation:
            if let screenshotTranslationStarter {
                screenshotTranslationStarter()
                return
            }

            let coordinator = coordinator ?? makeCoordinator()
            self.coordinator = coordinator
            coordinator.startScreenshotTranslation()
        default:
            return
        }
    }

    private var isShortcutEnabled: Bool {
        guard storage.object(forKey: TranslatorConstants.StorageKey.shortcutEnabled) != nil else {
            return TranslatorConstants.Defaults.shortcutEnabled
        }

        return storage.bool(forKey: TranslatorConstants.StorageKey.shortcutEnabled)
    }

    private var panelSubtitle: String {
        if !isShortcutEnabled {
            return localization.string("panel.subtitle.shortcutPaused", defaultValue: "快捷键已暂停")
        }
        if !accessibilityTrustProvider() {
            return localization.string("panel.subtitle.permissionRequired", defaultValue: "启用前需要辅助功能授权")
        }
        if enabledValidProfiles.isEmpty {
            return localization.string("panel.subtitle.needsProvider", defaultValue: "需要配置翻译服务")
        }

        switch apiKeyState {
        case .missing, .error:
            return localization.string("panel.subtitle.needsProvider", defaultValue: "需要配置翻译服务")
        case .unknown, .present:
            return localization.string("panel.subtitle.ready", defaultValue: "按 ⌥D 划词，⌥S 截图")
        }
    }

    private var enabledValidProfiles: [TranslatorProviderProfile] {
        providerProfiles.filter { $0.isEnabled && $0.validationError == nil }
    }

    private var hasKnownAPIKey: Bool {
        switch apiKeyState {
        case .present:
            return true
        case .unknown:
            return (try? secretStore.containsAPIKey()) == true
        case .missing, .error:
            return false
        }
    }

    func saveConfiguration(
        _ configuration: OpenAICompatibleConfiguration,
        apiKey: String,
        languagePair: TranslatorLanguagePair
    ) -> String? {
        let profile = TranslatorProviderProfile(
            id: TranslatorProviderProfile.defaultID,
            name: TranslatorProviderProfile.defaultName,
            isEnabled: true,
            baseURL: configuration.baseURL,
            model: configuration.model,
            promptTemplate: configuration.promptTemplate
        )
        return saveConfiguration(
            profiles: [profile],
            apiKeys: [profile.id: apiKey],
            languagePair: languagePair
        )
    }

    func saveConfiguration(
        profiles: [TranslatorProviderProfile],
        apiKeys: [String: String],
        languagePair: TranslatorLanguagePair
    ) -> String? {
        guard languagePair.first != languagePair.second else {
            return localization.string("settings.error.sameLanguages", defaultValue: "两种偏好语言不能相同。")
        }

        guard profiles.contains(where: \.isEnabled) else {
            return localization.string("settings.error.noEnabledProvider", defaultValue: "至少启用一个翻译服务。")
        }

        for profile in profiles where profile.isEnabled {
            if let validationError = profile.validationError {
                let title = profile.normalizedName.isEmpty
                    ? localization.string("settings.provider.fallbackName", defaultValue: "翻译服务")
                    : profile.normalizedName
                return localization.format(
                    "settings.error.providerValidationFormat",
                    defaultValue: "%@：%@",
                    title,
                    validationError.errorDescription(localization: localization)
                )
            }
        }

        do {
            // Complete credential validation before the first Keychain or preferences write.
            for profile in profiles where profile.isEnabled && Self.normalizedAPIKey(apiKeys[profile.id]) == nil {
                guard credentialAuthorization.allows(profileID: profile.id, baseURL: profile.baseURL),
                      try secretStore.containsAPIKey(forProfileID: profile.id)
                        || (profile.id == TranslatorProviderProfile.defaultID && hasKnownAPIKey) else {
                    apiKeyState = .missing
                    onStateChange?()
                    return localization.string("settings.error.blankAPIKey", defaultValue: "API Key 不能为空。")
                }
            }
            let profilesData = try JSONEncoder().encode(profiles.map { $0.normalized() })
            let retainedIDs = Set(profiles.map(\.id))
            let removedIDs = providerProfiles.map(\.id).filter { !retainedIDs.contains($0) }
            var replacements: [PortableCredentialAuthorization.Replacement] = []
            var endpoints: [String: String] = [:]
            for profile in profiles where profile.isEnabled {
                guard let key = Self.normalizedAPIKey(apiKeys[profile.id]) else { continue }
                endpoints[profile.id] = profile.baseURL
                replacements.append(.init(profileIDs: [profile.id],
                    load: { try self.loadRawAPIKey(forProfileID: profile.id) },
                    save: { try self.secretStore.saveAPIKey(key, forProfileID: profile.id) }))
            }
            for id in removedIDs {
                replacements.append(.init(profileIDs: [id],
                    load: { try self.loadRawAPIKey(forProfileID: id) },
                    save: { try self.secretStore.deleteAPIKey(forProfileID: id) }))
            }
            let previousBackup = makePortablePreferencesBackup()
            cachedAPIKeys.removeAll()
            didLoadProfileAPIKeys.removeAll()
            cachedAPIKey = nil
            didLoadAPIKey = false
            try credentialAuthorization.replaceCredentials(replacements, authorizing: endpoints, values: [
                TranslatorConstants.StorageKey.providerProfiles: .data(profilesData),
                TranslatorConstants.StorageKey.firstPreferredLanguage: .string(languagePair.first.rawValue),
                TranslatorConstants.StorageKey.secondPreferredLanguage: .string(languagePair.second.rawValue)
            ], store: portableStore)
            providerProfiles = providerProfileStore.loadProfiles()
            providerConfiguration = providerProfiles.first?.configuration
                ?? OpenAICompatibleConfiguration(
                    promptTemplate: OpenAICompatibleConfiguration.defaultPromptTemplate(localization: localization)
                )
            self.languagePair = languagePair
            cachedAPIKey = cachedAPIKeys[TranslatorProviderProfile.defaultID]
            didLoadAPIKey = didLoadProfileAPIKeys.contains(TranslatorProviderProfile.defaultID)
            apiKeyState = .present
            if let coordinator {
                coordinator.close()
            } else {
                panelController.close()
            }
            coordinator = nil
            if previousBackup != makePortablePreferencesBackup() { onPersistentPreferencesChange?() }
            onStateChange?()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func handlePanelAction(_ action: TranslatorPanelAction) {
        if action == .openSettings {
            requestSettingsPresentation?()
            return
        }

        if action == .close {
            if let coordinator {
                coordinator.close()
            } else {
                panelController.close()
            }
            return
        }

        guard let coordinator else { return }

        Task { await coordinator.handle(action) }
    }

    private func makeCoordinator() -> TranslatorCoordinator {
        TranslatorCoordinator(
            selectedTextCapturePipeline: selectedTextCapturePipeline,
            screenshotRegionCapturer: screenshotRegionCapturer
                ?? screenshotRegionCapturerFactory(screenRecordingPermissionProvider),
            ocrTextRecognizer: ocrTextRecognizer ?? VisionOCRTextRecognizer(),
            languagePreferenceStore: LanguagePreferenceStore(storage: storage),
            providerFactory: translationProviderFactoryOverride ?? { [weak self] in
                guard let self else {
                    return .missing(
                        message: PluginLocalization(bundle: .main).string(
                            "panelError.missingProvider",
                            defaultValue: "请先启用翻译服务"
                        )
                    )
                }

                let resolvedProviders = self.resolvedTranslationProviders()
                guard !resolvedProviders.isEmpty else {
                    return .missing(message: self.localization.string("panelError.missingProvider", defaultValue: "请先启用翻译服务"))
                }

                return .providers(resolvedProviders)
            },
            panelController: panelController,
            localization: localization
        )
    }

    private func resolvedTranslationProviders() -> [ResolvedTranslationProvider] {
        // Capture state before resolution: `loadAPIKey` may update `apiKeyState` early through
        // `updateLegacyAPIKeyCacheIfNeeded`. Compare against the pre-resolution value so state
        // change notifications are not missed.
        let previousState = apiKeyState
        let resolved = providerProfiles.filter(\.isEnabled).map { profile -> ResolvedTranslationProvider in
            if let validationError = profile.validationError {
                return ResolvedTranslationProvider(
                    id: profile.id,
                    title: profile.normalizedName.isEmpty
                        ? localization.string("settings.provider.fallbackName", defaultValue: "翻译服务")
                        : profile.normalizedName,
                    errorMessage: validationError.errorDescription(localization: localization)
                )
            }

            do {
                let apiKey = try loadAPIKey(for: profile)
                guard let trimmedKey = Self.normalizedAPIKey(apiKey) else {
                    return ResolvedTranslationProvider(
                        id: profile.id,
                        title: profile.normalizedName,
                        errorMessage: localization.string("panelError.missingAPIKey", defaultValue: "请配置 API Key")
                    )
                }

                return ResolvedTranslationProvider(
                    id: profile.id,
                    title: profile.normalizedName,
                    provider: OpenAITranslationProviderAdapter(
                        client: OpenAICompatibleClient(localization: localization),
                        configuration: profile.configuration,
                        apiKey: trimmedKey,
                        providerTitle: profile.normalizedName
                    )
                )
            } catch {
                return ResolvedTranslationProvider(
                    id: profile.id,
                    title: profile.normalizedName,
                    errorMessage: userFacingMessage(for: error)
                )
            }
        }

        updateAPIKeyState(forResolvedProviders: resolved, previousState: previousState)
        return resolved
    }

    /// Aggregates the overall API-key state after resolving all enabled profiles.
    /// A single usable provider counts as present so one profile with a missing key does not make
    /// the whole plugin look missing.
    private func updateAPIKeyState(
        forResolvedProviders resolved: [ResolvedTranslationProvider],
        previousState: APIKeyState
    ) {
        guard !resolved.isEmpty else { return }
        apiKeyState = resolved.contains { $0.provider != nil } ? .present : .missing
        if apiKeyState != previousState {
            onStateChange?()
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let error = error as? OpenAICompatibleClientError {
            return error.errorDescription(localization: localization)
        }
        if let error = error as? OpenAICompatibleConfigurationError {
            return error.errorDescription(localization: localization)
        }
        if let error = error as? TranslationPromptRendererError {
            return error.errorDescription(localization: localization)
        }
        if let error = error as? OpenAICompatibleSecretStoreError {
            return error.errorDescription(localization: localization)
        }
        if let error = error as? TranslatorProviderProfileValidationError {
            return error.errorDescription(localization: localization)
        }
        return error.localizedDescription
    }

    private static func hasNonEmptyAPIKey(_ apiKey: String?) -> Bool {
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func normalizedAPIKey(_ apiKey: String?) -> String? {
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedKey.isEmpty ? nil : trimmedKey
    }

    private func loadCachedAPIKeyIfNeeded() {
        guard !didLoadAPIKey else {
            return
        }
        let previousState = apiKeyState

        do {
            cachedAPIKey = try secretStore.loadAPIKey()
        } catch {
            cachedAPIKey = nil
            apiKeyState = .error(error.localizedDescription)
            didLoadAPIKey = true
            if apiKeyState != previousState {
                onStateChange?()
            }
            return
        }
        didLoadAPIKey = true
        apiKeyState = Self.hasNonEmptyAPIKey(cachedAPIKey) ? .present : .missing
        if apiKeyState != previousState {
            onStateChange?()
        }
    }

    private func loadAPIKey(for profile: TranslatorProviderProfile) throws -> String? {
        guard credentialAuthorization.allows(profileID: profile.id, baseURL: profile.baseURL) else { return nil }
        let profileID = profile.id
        if didLoadProfileAPIKeys.contains(profileID) {
            return cachedAPIKeys[profileID]
        }

        if let key = try loadRawAPIKey(forProfileID: profileID), Self.hasNonEmptyAPIKey(key) {
            cachedAPIKeys[profileID] = key
            didLoadProfileAPIKeys.insert(profileID)
            updateLegacyAPIKeyCacheIfNeeded(profileID: profileID, apiKey: key)
            return key
        }

        cachedAPIKeys.removeValue(forKey: profileID)
        didLoadProfileAPIKeys.insert(profileID)
        updateLegacyAPIKeyCacheIfNeeded(profileID: profileID, apiKey: nil)
        return nil
    }

    /// Raw resolution must throw on an unreadable scoped entry instead of falling back.
    private func loadRawAPIKey(forProfileID profileID: String) throws -> String? {
        let scoped = try secretStore.loadAPIKey(forProfileID: profileID)
        if Self.hasNonEmptyAPIKey(scoped) { return scoped }
        return profileID == TranslatorProviderProfile.defaultID ? try secretStore.loadAPIKey() : nil
    }

    private func updateLegacyAPIKeyCacheIfNeeded(profileID: String, apiKey: String?) {
        guard profileID == TranslatorProviderProfile.defaultID else {
            return
        }

        cachedAPIKey = apiKey
        didLoadAPIKey = true
        apiKeyState = Self.hasNonEmptyAPIKey(apiKey) ? .present : .missing
    }
}

extension TranslatorPlugin {
    private static let promptBackupKey = "preferences-backup.include-prompt-text"
    private var includesPromptText: Bool { storage.bool(forKey: Self.promptBackupKey) }
    private var promptBackupSection: PluginSettingsSection {
        PluginSettingsSection(
            id: "preferences-backup", title: localization.string("settings.backup.title", defaultValue: "偏好设置备份"),
            systemImage: "externaldrive", rows: [PluginSettingsRow(
                id: Self.promptBackupKey,
                title: localization.string("settings.backup.includePromptText", defaultValue: "将自定义提示词包含在备份中"),
                description: localization.string("settings.backup.scope", defaultValue: "同时用于手动备份、自动备份和云同步。不包含 API 密钥。"),
                control: .toggle(isOn: includesPromptText)
            )]
        )
    }
    private func setIncludesPromptText(_ value: Bool) {
        guard value != includesPromptText,
              portableStore.commit([Self.promptBackupKey: .boolean(value)]) else { return }
        onPersistentPreferencesChange?()
        onStateChange?()
    }
}

extension TranslatorPlugin: PluginPortablePreferencesProviding, PluginPortablePreferencesRestorationReporting,
    PluginPersistentPreferencesChangeSignaling {
    private struct PortableProfile: Codable {
        let id: String
        let name: String
        let isEnabled: Bool
        let baseURL: String
        let model: String
        let promptTemplate: String?
    }
    private struct PortablePreferences: Codable {
        let formatVersion: Int
        let profiles: [PortableProfile]
        let languagePair: TranslatorLanguagePair
        let shortcutEnabled: Bool
    }
    private static func portableStore(storage: any PluginStorage) -> PortablePreferencesStore {
        PortablePreferencesStore(storage: storage, fields: [
            TranslatorConstants.StorageKey.providerProfiles: .data(Data("[]".utf8), maximumBytes: 1_024 * 1_024) {
                (try? JSONDecoder().decode([TranslatorProviderProfile].self, from: $0)).map { $0.count <= 64 } == true
            },
            TranslatorConstants.StorageKey.shortcutEnabled: .boolean(true),
            TranslatorConstants.StorageKey.firstPreferredLanguage: .choice("zh-Hans", allowed: TranslatorLanguage.allCases.map(\.rawValue)),
            TranslatorConstants.StorageKey.secondPreferredLanguage: .choice("en", allowed: TranslatorLanguage.allCases.map(\.rawValue)),
            Self.promptBackupKey: .boolean(false),
            PortableCredentialAuthorization.key: PortableCredentialAuthorization.field
        ])
    }
    private var portableStore: PortablePreferencesStore { Self.portableStore(storage: storage) }
    private func decodedPortable(_ data: Data) -> PortablePreferences? {
        guard data.count <= 2 * 1_024 * 1_024, let payload = try? JSONDecoder().decode(PortablePreferences.self, from: data), payload.formatVersion == 1,
              payload.languagePair.first != payload.languagePair.second,
              (1...64).contains(payload.profiles.count), Set(payload.profiles.map(\.id)).count == payload.profiles.count,
              payload.profiles.allSatisfy({ profile in
                  let template = profile.promptTemplate ?? OpenAICompatibleConfiguration.defaultPromptTemplate(localization: localization)
                  let configuration = OpenAICompatibleConfiguration(baseURL: profile.baseURL, model: profile.model, promptTemplate: template)
                  return PortablePreferencesValidation.identifier(profile.id)
                      && PortablePreferencesValidation.text(profile.name, maximumBytes: 256, allowsEmpty: !profile.isEnabled)
                      && PortablePreferencesValidation.endpoint(profile.baseURL, allowsIncomplete: !profile.isEnabled)
                      && PortablePreferencesValidation.text(profile.model, maximumBytes: 256, allowsEmpty: !profile.isEnabled)
                      && template.utf8.count <= 65_536 && (!profile.isEnabled || configuration.validationError == nil)
              }) else { return nil }
        return payload
    }
    func makePortablePreferencesBackup() -> Data? {
        // Local profile records contain private prompt text; validate the portable projection below.
        guard portableStore.backup(including: [TranslatorConstants.StorageKey.shortcutEnabled,
            TranslatorConstants.StorageKey.firstPreferredLanguage,
            TranslatorConstants.StorageKey.secondPreferredLanguage]) != nil else { return nil }
        let payload = PortablePreferences(formatVersion: 1, profiles: providerProfiles.map {
            PortableProfile(id: $0.id, name: $0.name, isEnabled: $0.isEnabled, baseURL: $0.baseURL,
                model: $0.model, promptTemplate: includesPromptText ? $0.promptTemplate : nil)
        }, languagePair: languagePair, shortcutEnabled: isShortcutEnabled)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload), decodedPortable(data) != nil else { return nil }
        return data
    }
    func restorePortablePreferences(from data: Data) { _ = restorePortablePreferencesReportingResult(from: data) }
    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard credentialAuthorization.isInitialized, let payload = decodedPortable(data) else { return false }
        let before = makePortablePreferencesBackup()
        let previousProfiles = providerProfiles
        let defaultTemplate = OpenAICompatibleConfiguration.defaultPromptTemplate(localization: localization)
        let privateProfiles = providerProfiles.filter { $0.promptTemplate != defaultTemplate }
        let protected = includesPromptText ? [] : privateProfiles
        // An archive without prompt text must preserve destination-only text, regardless of export opt-in.
        let retained = payload.profiles.allSatisfy { $0.promptTemplate == nil } ? privateProfiles : protected
        guard !payload.profiles.contains(where: { incoming in
            guard let template = incoming.promptTemplate else { return false }
            return protected.contains { $0.id == incoming.id && $0.promptTemplate != template }
        }) else { return false }
        let restored = payload.profiles.map { incoming in
            TranslatorProviderProfile(id: incoming.id, name: incoming.name, isEnabled: incoming.isEnabled, baseURL: incoming.baseURL,
                model: incoming.model, promptTemplate: incoming.promptTemplate ?? providerProfiles.first { $0.id == incoming.id }?.promptTemplate ?? defaultTemplate)
        } + retained.filter { local in !payload.profiles.contains { $0.id == local.id } }
        guard restored.count <= 64, restored.allSatisfy({ !$0.isEnabled || $0.validationError == nil }),
              let profileData = try? JSONEncoder().encode(restored), portableStore.commit([
            TranslatorConstants.StorageKey.providerProfiles: .data(profileData),
            TranslatorConstants.StorageKey.shortcutEnabled: .boolean(payload.shortcutEnabled),
            TranslatorConstants.StorageKey.firstPreferredLanguage: .string(payload.languagePair.first.rawValue),
            TranslatorConstants.StorageKey.secondPreferredLanguage: .string(payload.languagePair.second.rawValue)
        ]) else { return false }
        providerProfiles = providerProfileStore.loadProfiles()
        languagePair = payload.languagePair
        providerConfiguration = providerProfiles.first?.configuration ?? OpenAICompatibleConfiguration()
        if let coordinator { coordinator.close() } else { panelController.close() }
        coordinator = nil
        if providerProfiles != previousProfiles { providerEditorRevision += 1 }
        if !providerProfiles.contains(where: { $0.isEnabled && credentialAuthorization.allows(profileID: $0.id, baseURL: $0.baseURL) }) { apiKeyState = .missing }
        if before != makePortablePreferencesBackup() { onPersistentPreferencesChange?() }
        onStateChange?()
        return true
    }
}
