import AppKit
import MacToolsPluginKit
import XCTest
@testable import AIAssistantPlugin
@testable import class MacTools.PluginHost
@testable import class MacTools.ShortcutStore
@testable import class MacTools.PreferencesBackupStore

@MainActor
final class AIAssistantPluginTests: XCTestCase {
    func testPromptSaveResolvesPendingRecoveryBeforeAcceptingEdits() throws {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        let original = AIAssistantPrompt(id: "existing", name: "Existing", template: "Original {{text}}", isEnabled: true)
        XCTAssertNil(plugin.savePromptsConfiguration([original]))
        plugin.handleSettingsAction(.setBoolean(controlID: "preferences-backup.include-prompt-text", value: true))
        let source = makePlugin()
        var imported = original
        imported.template = "Imported {{text}}"
        XCTAssertNil(source.savePromptsConfiguration([imported]))
        source.handleSettingsAction(.setBoolean(controlID: "preferences-backup.include-prompt-text", value: true))
        storage.blockedRemoveKeys = ["preferences-backup.restore.v2"]
        XCTAssertFalse(plugin.restorePortablePreferencesReportingResult(from: try XCTUnwrap(source.makePortablePreferencesBackup())))
        XCTAssertNotNil(storage.data(forKey: "preferences-backup.restore.v2"))

        var edited = original
        edited.template = "Local edit {{text}}"
        XCTAssertNotNil(plugin.savePromptsConfiguration([edited]))
        XCTAssertEqual(AIAssistantPromptStore(storage: storage).loadPrompts(), [original])
        storage.blockedRemoveKeys = []
        XCTAssertNil(plugin.savePromptsConfiguration([edited]))
        _ = makePlugin(storage: storage)
        XCTAssertEqual(AIAssistantPromptStore(storage: storage).loadPrompts(), [edited])
        XCTAssertNil(storage.object(forKey: "preferences-backup.restore.v2"))
    }

    func testIncludedDisabledPromptRetainsCustomizedShortcutThroughBackup() async throws {
        let plugin = makePlugin()
        var prompt = AIAssistantPrompt(id: "custom", name: "Custom prompt", template: "Process {{text}}",
            systemPrompt: nil, isEnabled: true)
        XCTAssertNil(plugin.savePromptsConfiguration([prompt]))
        plugin.handleSettingsAction(.setBoolean(controlID: "preferences-backup.include-prompt-text", value: true))
        let suite = "AIAssistantShortcutBackupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = ShortcutStore(userDefaults: defaults)
        let host = PluginHost(plugins: [plugin], shortcutStore: shortcuts,
            pluginOrderingStore: .init(userDefaults: defaults), preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: .init(registrar: FakeCarbonHotKeyRegistrar()), loadDynamicPluginsOnInit: false)
        defer { host.deactivateAllPlugins() }
        let shortcutID = "ai-assistant.shortcut." + (try XCTUnwrap(plugin.shortcutDefinitions.first)).id
        let binding = ShortcutBinding(keyCode: 97, modifiers: [.command, .option, .control, .shift])
        XCTAssertNil(host.setShortcutBindingAndReturnError(binding, for: shortcutID))
        let reference = ActionReference(key: .init(providerID: "ai-assistant", actionID: prompt.id))
        let canonicalBinding = ShortcutBinding(keyCode: 98, modifiers: [.command, .option, .control, .shift])
        guard case .success = host.setActionShortcutBinding(canonicalBinding, to: reference) else {
            return XCTFail("Could not assign the canonical shortcut")
        }
        prompt.isEnabled = false
        XCTAssertNil(plugin.savePromptsConfiguration([prompt]))
        host.refreshAll()
        for _ in 0..<100 where host.actionRegistry.definition(for: reference.key) != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(host.actionRegistry.definition(for: reference.key))

        let backup = try host.makePreferencesBackupExport().requiringSuccessfulSelection()
        XCTAssertEqual(backup.shortcutCustomizations[shortcutID], .custom(binding))
        XCTAssertTrue(backup.actionShortcutAssignments.contains { $0.reference == reference })
        let result = try host.importPreferences(backup)

        XCTAssertTrue(result.shortcutErrors.isEmpty)
        XCTAssertEqual(shortcuts.customization(for: shortcutID), .custom(binding))
        XCTAssertNotNil(host.shortcutAssignmentService.assignment(for: reference))
        XCTAssertEqual(plugin.shortcutDefinitions.first?.scope, .whilePluginActive)
        XCTAssertTrue(plugin.actionDefinitions.isEmpty)
    }

    func testFailedCredentialReplacementPreservesOnlyVerifiedUnchangedAccess() throws {
        for (changesKey, readFails) in [(false, false), (true, false), (false, true)] {
            let storage = AIAssistantInMemoryPluginStorage()
            let secret = CountingAIAssistantSecretStore(apiKey: "original-local-key")
            let plugin = makePlugin(storage: storage, secretStore: secret)
            let profile = AIAssistantProviderProfile.defaultProfile()
            var edited = profile
            edited.baseURL = "https://changed.example/v1"
            secret.saveFailure = (changesKey, readFails)
            XCTAssertNotNil(plugin.saveProviderConfiguration(profiles: [edited], apiKey: "replacement-local-key"))
            let authorization = PortableCredentialAuthorization(storage: storage)
            let preservesAccess = !changesKey && !readFails
            XCTAssertEqual(authorization.allows(profileID: profile.id, baseURL: profile.baseURL), preservesAccess)
            XCTAssertFalse(authorization.allows(profileID: edited.id, baseURL: edited.baseURL))
            secret.saveFailure = nil
            let reloaded = makePlugin(storage: storage, secretStore: secret)
            XCTAssertEqual(AIAssistantProviderProfileStore(storage: storage).loadProfiles(), [profile])
            XCTAssertEqual(reloaded.saveProviderConfiguration(profiles: [profile], apiKey: "") == nil, preservesAccess)
        }
    }

    func testPreferenceWriteFailureRestoresOnlyUnchangedCredentialGrants() throws {
        for key in ["original-local-key", "replacement-local-key"] {
            let storage = AIAssistantInMemoryPluginStorage()
            let secret = CountingAIAssistantSecretStore(apiKey: "original-local-key")
            let plugin = makePlugin(storage: storage, secretStore: secret)
            let original = AIAssistantProviderProfile.defaultProfile()
            XCTAssertNil(plugin.saveProviderConfiguration(profiles: [original], apiKey: ""))
            var edited = original
            edited.name = "Edited name"
            storage.blockedSetKeys = [AIAssistantConstants.StorageKey.providerProfiles]
            XCTAssertNotNil(plugin.saveProviderConfiguration(profiles: [edited], apiKey: key))
            XCTAssertEqual(AIAssistantProviderProfileStore(storage: storage).loadProfiles(), [original])
            XCTAssertEqual(PortableCredentialAuthorization(storage: storage).allows(profileID: original.id, baseURL: original.baseURL), key == "original-local-key")
            storage.blockedSetKeys = []
            let reloaded = makePlugin(storage: storage, secretStore: secret)
            XCTAssertEqual(reloaded.saveProviderConfiguration(profiles: [original], apiKey: "") == nil, key == "original-local-key")
        }
    }

    func testMetadataMatchesManifestContract() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.metadata.id, "ai-assistant")
        XCTAssertEqual(plugin.metadata.title, "AI 助手")
        XCTAssertEqual(plugin.metadata.defaultDescription, "划词调用 AI 翻译、总结、润色等")
        XCTAssertFalse(plugin.panelItems.isEmpty)
        XCTAssertNotNil(plugin.settingsPage)
    }

    func testSelectionShortcutUsesHostTargetResolvedAtActionStart() async {
        let capture = RecordingTargetCapture()
        let plugin = makePlugin(strategies: [capture])
        var providerCalls = 0
        plugin.focusedWindowTargetProvider = {
            providerCalls += 1
            return PluginFocusedWindowTarget(application: .current)
        }

        plugin.handleShortcutAction(id: "translate")
        plugin.focusedWindowTargetProvider = { nil }

        for _ in 0..<100 where capture.capturedPID == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(providerCalls, 1)
        XCTAssertEqual(capture.capturedPID, NSRunningApplication.current.processIdentifier)
    }

    func testShortcutDefinitionsDynamicallyFollowEnabledPrompts() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)

        // Default prompts are all enabled.
        let definitions = plugin.shortcutDefinitions
        XCTAssertEqual(definitions.map(\.actionID), ["translate", "summarize", "polish"])
        XCTAssertEqual(definitions.map(\.scope), [.global, .global, .global])
        XCTAssertEqual(definitions.map(\.defaultBinding), [
            AIAssistantConstants.Defaults.translateShortcut,
            AIAssistantConstants.Defaults.summarizeShortcut,
            AIAssistantConstants.Defaults.polishShortcut,
        ])

        // Disabled prompts retain editable definitions without global registration.
        let prompts = AIAssistantPromptStore(storage: storage).loadPrompts()
        let updated = prompts.map { prompt -> AIAssistantPrompt in
            var copy = prompt
            if copy.id == "summarize" {
                copy.isEnabled = false
            }
            return copy
        }
        let message = plugin.saveConfiguration(
            profiles: [AIAssistantProviderProfile.defaultProfile()],
            prompts: updated,
            apiKey: "sk-test"
        )

        XCTAssertNil(message)
        XCTAssertEqual(
            plugin.shortcutDefinitions.map(\.actionID),
            ["translate", "summarize", "polish"]
        )
        XCTAssertEqual(plugin.shortcutDefinitions.map(\.scope),
                       [.global, .whilePluginActive, .global])
        plugin.handleAction(.setSwitch(false))
        XCTAssertTrue(plugin.shortcutDefinitions.allSatisfy { $0.scope == .whilePluginActive })
        plugin.handleAction(.setSwitch(true))
        XCTAssertEqual(plugin.shortcutDefinitions.map(\.scope),
                       [.global, .whilePluginActive, .global])
    }

    func testHandleShortcutEventIgnoresDisabledPrompt() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        let prompts = AIAssistantPromptStore(storage: storage).loadPrompts()
        let updated = prompts.map { prompt -> AIAssistantPrompt in
            var copy = prompt
            if copy.id == "translate" {
                copy.isEnabled = false
            }
            return copy
        }
        _ = plugin.saveConfiguration(
            profiles: [AIAssistantProviderProfile.defaultProfile()],
            prompts: updated,
            apiKey: "sk-test"
        )

        // Disabled prompts must not start processing from a shortcut press.
        plugin.handleShortcutEvent(id: "translate", phase: .pressed)
        plugin.handleShortcutEvent(id: "translate", phase: .released)

        // Enabled prompts still process.
        plugin.handleShortcutEvent(id: "summarize", phase: .pressed)
    }

    func testShortcutDefinitionsIgnoreHostLegacyResolverAndKeepDefaultBindings() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)

        // The getter must derive default bindings directly from the prompt IDs
        // and must not consult the host's legacy binding resolver anymore.
        var resolverCalls = 0
        plugin.shortcutBindingResolver = { legacyID in
            _ = legacyID
            resolverCalls += 1
            return ShortcutBinding(keyCode: 1, modifiers: [.command])
        }

        let definitions = plugin.shortcutDefinitions
        XCTAssertEqual(definitions.map(\.actionID), ["translate", "summarize", "polish"])
        XCTAssertEqual(definitions.map(\.defaultBinding), [
            AIAssistantConstants.Defaults.translateShortcut,
            AIAssistantConstants.Defaults.summarizeShortcut,
            AIAssistantConstants.Defaults.polishShortcut,
        ])
        XCTAssertEqual(resolverCalls, 0)

        // A custom prompt has no built-in default binding.
        let customPrompt = AIAssistantPrompt(
            id: "custom",
            name: "自定义",
            template: "{{text}}",
            systemPrompt: nil,
            isEnabled: true
        )
        _ = plugin.saveConfiguration(
            profiles: [AIAssistantProviderProfile.defaultProfile()],
            prompts: [customPrompt],
            apiKey: "sk-test"
        )
        XCTAssertEqual(
            plugin.shortcutDefinitions.first { $0.actionID == "custom" }?.defaultBinding,
            nil
        )
        XCTAssertEqual(resolverCalls, 0)
    }

    func testDeclaresAccessibilityAndAutomationPermissions() {
        let requirements = makePlugin().permissionRequirements

        XCTAssertEqual(requirements.map(\.id), ["accessibility", "automation"])
        XCTAssertEqual(requirements.map(\.kind), [.accessibility, .automation])
    }

    func testPrimaryPanelReflectsPermissionState() {
        XCTAssertEqual(
            makePlugin(accessibilityTrustProvider: { false }).rowState.subtitle,
            "启用前需要辅助功能授权"
        )
    }

    func testSavingConfigurationPersistsPromptsAndNotifies() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        let customPrompt = AIAssistantPrompt(
            id: "custom",
            name: "自定义",
            template: "{{text}}",
            systemPrompt: nil,
            isEnabled: true
        )
        let message = plugin.saveConfiguration(
            profiles: [AIAssistantProviderProfile.defaultProfile()],
            prompts: [customPrompt],
            apiKey: "sk-test"
        )

        XCTAssertNil(message)
        XCTAssertTrue(didNotify)
        XCTAssertEqual(plugin.shortcutDefinitions.map(\.actionID), ["custom"])
    }

    func testSavingConfigurationRejectsPromptMissingTextPlaceholder() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)

        let invalidPrompt = AIAssistantPrompt(
            id: "bad",
            name: "坏模板",
            template: "没有占位符",
            systemPrompt: nil,
            isEnabled: true
        )
        let message = plugin.saveConfiguration(
            profiles: [AIAssistantProviderProfile.defaultProfile()],
            prompts: [invalidPrompt],
            apiKey: "sk-test"
        )

        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("{{text}}") == true)
    }

    func testSaveProviderConfigurationSucceedsAndNotifies() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        let result = plugin.saveProviderConfiguration(
            profiles: [AIAssistantProviderProfile.defaultProfile()],
            apiKey: "sk-provider-test"
        )

        XCTAssertNil(result)
        XCTAssertTrue(didNotify)
    }

    func testSavePromptsConfigurationPersistsAndNotifies() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        let customPrompt = AIAssistantPrompt(
            id: "auto-save-prompt",
            name: "自动保存模板",
            template: "润色：{{text}}",
            systemPrompt: nil,
            isEnabled: true
        )
        let result = plugin.savePromptsConfiguration([customPrompt])

        XCTAssertNil(result)
        XCTAssertTrue(didNotify)
        XCTAssertEqual(plugin.shortcutDefinitions.map(\.actionID), ["auto-save-prompt"])
    }

    func testPrimaryPanelTogglePersistsDisabledStateAndNotifies() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        plugin.handleAction(.setSwitch(false))

        XCTAssertEqual(storage.bool(forKey: "ai-assistant.shortcut.enabled"), false)
        XCTAssertTrue(didNotify)
        XCTAssertFalse(plugin.rowState.isOn)
    }

    func testActionDefinitionsFollowEnabledPrompts() {
        let plugin = makePlugin()

        let definitions = plugin.actionDefinitions
        XCTAssertEqual(definitions.map(\.key.actionID), ["translate", "summarize", "polish"])
        XCTAssertEqual(definitions.map(\.key.providerID), Array(repeating: "ai-assistant", count: 3))
        XCTAssertEqual(definitions.map(\.systemImage), Array(repeating: "sparkles", count: 3))
    }

    func testActionAvailabilityRequiresEnabledPromptAndPermissions() {
        let plugin = makePlugin(accessibilityTrustProvider: { false })

        let reference = ActionReference(
            key: ActionKey(providerID: "ai-assistant", actionID: "translate")
        )
        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)

        // Unknown or disabled prompt IDs are unavailable regardless of permissions.
        let unknown = ActionReference(
            key: ActionKey(providerID: "ai-assistant", actionID: "missing")
        )
        XCTAssertFalse(plugin.actionAvailability(for: unknown).isAvailable)
    }

    func testBeginActionRunsPromptProcessing() {
        let plugin = makePlugin()
        let invocation = ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: "ai-assistant", actionID: "translate")
            ),
            source: .unifiedSearch,
            mode: .foreground
        )

        XCTAssertNoThrow(try plugin.beginAction(invocation))
    }

    func testPermissionRequirementIDsCoverAccessibilityAndAutomation() {
        let ids = makePlugin().permissionRequirementIDs(
            for: ActionKey(providerID: "ai-assistant", actionID: "translate")
        )

        XCTAssertEqual(ids, ["accessibility", "automation"])
    }

    func testClipboardSettingAllowsFallbackWithoutAccessibilityPermission() async {
        let storage = AIAssistantInMemoryPluginStorage()
        let panel = RecordingAIAssistantPanelController()
        let plugin = makePlugin(
            storage: storage,
            accessibilityTrustProvider: { false },
            panelController: panel,
            clipboardTextProvider: { nil }
        )
        let actionKey = ActionKey(providerID: "ai-assistant", actionID: "polish")
        XCTAssertEqual(plugin.permissionRequirementIDs(for: actionKey), ["accessibility", "automation"])

        plugin.handleSettingsAction(.setBoolean(
            controlID: AIAssistantConstants.StorageKey.shortcutUsesClipboard,
            value: true
        ))
        plugin.handleShortcutAction(id: "polish")
        for _ in 0..<100 where panel.snapshot?.phase != .error(.missingClipboardText) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(storage.bool(forKey: AIAssistantConstants.StorageKey.shortcutUsesClipboard))
        XCTAssertEqual(plugin.permissionRequirementIDs(for: actionKey), [])
        XCTAssertEqual(panel.snapshot?.phase, .error(.missingClipboardText))
    }

    func testSameShortcutPrefersDirectSelectionOverClipboard() async {
        let storage = AIAssistantInMemoryPluginStorage()
        let panel = RecordingAIAssistantPanelController()
        let selection = StaticSelectionCapture(text: "selected text")
        let plugin = makePlugin(
            storage: storage,
            panelController: panel,
            clipboardTextProvider: { "earlier copy" },
            providerFactoryOverride: { .failure(AIAssistantProviderError(message: "unconfigured")) },
            strategies: [selection]
        )
        plugin.handleSettingsAction(.setBoolean(
            controlID: AIAssistantConstants.StorageKey.shortcutUsesClipboard,
            value: true
        ))

        plugin.handleShortcutAction(id: "polish")
        for _ in 0..<100 where panel.snapshot?.sourceText == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(selection.captureCount, 1)
        XCTAssertEqual(panel.snapshot?.sourceText, "selected text")
    }

    func testClipboardShortcutUsesNewCopyAfterHiddenSession() async {
        let storage = AIAssistantInMemoryPluginStorage()
        let panel = RecordingAIAssistantPanelController()
        var copiedText = "first copy"
        let plugin = makePlugin(
            storage: storage,
            panelController: panel,
            clipboardTextProvider: { copiedText },
            providerFactoryOverride: { .failure(AIAssistantProviderError(message: "unconfigured")) }
        )
        plugin.handleSettingsAction(.setBoolean(
            controlID: AIAssistantConstants.StorageKey.shortcutUsesClipboard,
            value: true
        ))

        plugin.handleShortcutAction(id: "polish")
        for _ in 0..<100 where panel.snapshot?.sourceText != "first copy" {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        copiedText = "second copy"
        panel.onAction?(.hide)
        plugin.handleShortcutAction(id: "polish")

        for _ in 0..<50 where panel.snapshot?.sourceText != "second copy" {
            await Task.yield()
        }

        XCTAssertEqual(panel.snapshot?.sourceText, "second copy")
        XCTAssertTrue(panel.isVisible)
    }

    func testImportedEndpointCannotReuseLocalKeyAcrossRepeatedRestoreAndRelaunch() async throws {
        let storage = AIAssistantInMemoryPluginStorage()
        let secret = CountingAIAssistantSecretStore(apiKey: "local-secret")
        let plugin = makePlugin(storage: storage, secretStore: secret)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(plugin.makePortablePreferencesBackup())) as? [String: Any])
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        profiles[0]["baseURL"] = "https://imported.example/v1"
        object["profiles"] = profiles
        let incoming = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: incoming))
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: incoming))
        let reloaded = makePlugin(storage: storage, secretStore: secret)
        let profile = try JSONDecoder().decode([AIAssistantProviderProfile].self, from: JSONSerialization.data(withJSONObject: profiles))[0]
        if case .success = await reloaded.fetchModels(profile: profile, apiKey: "") { XCTFail("Imported endpoint reused a local key") }
        if case .success = await reloaded.testConnection(profile: profile, apiKey: "") { XCTFail("Imported endpoint reused a local key") }
        XCTAssertEqual(secret.loadCount, 0)
        XCTAssertEqual(secret.saveCount, 0)
        XCTAssertNotNil(reloaded.saveProviderConfiguration(profiles: [profile], apiKey: ""))
        XCTAssertNil(reloaded.saveProviderConfiguration(profiles: [profile], apiKey: "explicit-new-key"))
        XCTAssertTrue(PortableCredentialAuthorization(storage: storage).allows(profileID: profile.id, baseURL: profile.baseURL))
    }

    func testLocalCredentialMigrationAndRekeyIgnoreIncompleteDisabledDraft() throws {
        let storage = AIAssistantInMemoryPluginStorage()
        let secret = CountingAIAssistantSecretStore(apiKey: "existing-local-key")
        let active = AIAssistantProviderProfile(id: "active", name: "Active", baseURL: "https://gateway.example/v1?api-version=2026-01-01")
        let draft = AIAssistantProviderProfile(id: "draft", name: "Draft", isEnabled: false, baseURL: "")
        let profiles = [active, draft]
        storage.set(try JSONEncoder().encode(profiles), forKey: AIAssistantConstants.StorageKey.providerProfiles)
        let plugin = makePlugin(storage: storage, secretStore: secret)
        let grants = PortableCredentialAuthorization(storage: storage)
        XCTAssertTrue(grants.isInitialized)
        XCTAssertTrue(grants.allows(profileID: active.id, baseURL: active.baseURL))
        XCTAssertFalse(grants.allows(profileID: draft.id, baseURL: draft.baseURL))
        XCTAssertNil(plugin.saveProviderConfiguration(profiles: profiles, apiKey: ""))
        XCTAssertNil(plugin.saveProviderConfiguration(profiles: profiles, apiKey: "replacement-local-key"))
        XCTAssertTrue(grants.allows(profileID: active.id, baseURL: active.baseURL))
        XCTAssertEqual(try JSONDecoder().decode([AIAssistantProviderProfile].self,
            from: XCTUnwrap(storage.data(forKey: AIAssistantConstants.StorageKey.providerProfiles))), profiles)
        XCTAssertEqual(secret.loadCount, 1)
        XCTAssertEqual(secret.saveCount, 1)
    }

    func testSavedIncompleteDisabledDraftTransfersWithoutCredentialAccess() throws {
        let source = makePlugin()
        let active = AIAssistantProviderProfile.defaultProfile()
        let draft = AIAssistantProviderProfile(id: "draft", name: "", isEnabled: false, baseURL: "", model: "")
        XCTAssertNil(source.saveProviderConfiguration(profiles: [active, draft], apiKey: ""))
        let data = try XCTUnwrap(source.makePortablePreferencesBackup())
        let storage = AIAssistantInMemoryPluginStorage()
        let secret = CountingAIAssistantSecretStore(apiKey: "local-secret")
        let destination = makePlugin(storage: storage, secretStore: secret)
        XCTAssertTrue(destination.restorePortablePreferencesReportingResult(from: data))
        let saved = try XCTUnwrap(storage.data(forKey: AIAssistantConstants.StorageKey.providerProfiles))
        let profiles = try JSONDecoder().decode([AIAssistantProviderProfile].self, from: saved)
        XCTAssertEqual(profiles.first { $0.id == draft.id }, draft)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var incoming = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        incoming[1]["isEnabled"] = true
        object["profiles"] = incoming
        XCTAssertFalse(destination.restorePortablePreferencesReportingResult(from: try JSONSerialization.data(withJSONObject: object)))
        incoming[1]["isEnabled"] = false
        incoming[1]["baseURL"] = "https://gateway.example/v1?api_key=secret"
        object["profiles"] = incoming
        XCTAssertFalse(destination.restorePortablePreferencesReportingResult(from: try JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(storage.data(forKey: AIAssistantConstants.StorageKey.providerProfiles), saved)
        XCTAssertEqual(secret.loadCount, 0)
        XCTAssertEqual(secret.saveCount, 0)
    }

    func testExcludedLegacyPromptStorageDoesNotBlockConfigurationTransfer() throws {
        let storage = AIAssistantInMemoryPluginStorage()
        let prompts = [AIAssistantPrompt(id: "private", name: "Private",
            template: String(repeating: "x", count: 2_097_153) + " {{text}}", systemPrompt: nil, isEnabled: true)]
        let raw = try JSONEncoder().encode(prompts)
        storage.set(raw, forKey: AIAssistantConstants.StorageKey.prompts)
        let secret = CountingAIAssistantSecretStore(apiKey: "existing-local-key")
        let plugin = makePlugin(storage: storage, secretStore: secret)
        let profile = AIAssistantProviderProfile.defaultProfile()
        let grants = PortableCredentialAuthorization(storage: storage)
        XCTAssertTrue(grants.isInitialized)
        XCTAssertTrue(grants.allows(profileID: profile.id, baseURL: profile.baseURL))
        XCTAssertNil(plugin.saveProviderConfiguration(profiles: [profile], apiKey: ""))
        let backup = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])["prompts"])
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: backup))
        XCTAssertEqual(storage.data(forKey: AIAssistantConstants.StorageKey.prompts), raw)
        XCTAssertTrue(grants.allows(profileID: profile.id, baseURL: profile.baseURL))
        XCTAssertEqual(secret.loadCount, 0)
        XCTAssertEqual(secret.saveCount, 0)
        plugin.handleSettingsAction(.setBoolean(controlID: "preferences-backup.include-prompt-text", value: true))
        XCTAssertNil(plugin.makePortablePreferencesBackup())
        XCTAssertEqual(storage.data(forKey: AIAssistantConstants.StorageKey.prompts), raw)
        XCTAssertNil(plugin.savePromptsConfiguration(prompts))
        XCTAssertEqual(AIAssistantPromptStore(storage: storage).loadPrompts(), prompts)
    }

    func testPromptOptOutPreservesPrivateTextAndOmittedDefinitionsHaveNoIndex() throws {
        let plugin = makePlugin(storage: AIAssistantInMemoryPluginStorage())
        let local = AIAssistantPrompt(id: "private", name: "Private", template: "Private {{text}}", systemPrompt: nil, isEnabled: true)
        XCTAssertNil(plugin.savePromptsConfiguration([local]))
        let incomingPlugin = makePlugin(storage: AIAssistantInMemoryPluginStorage())
        let incoming = try XCTUnwrap(incomingPlugin.makePortablePreferencesBackup())
        XCTAssertEqual(plugin.actionReferences(inPortablePreferences: incoming), [])
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: incoming))
        XCTAssertEqual(plugin.shortcutDefinitions.map(\.actionID), ["private"])
        XCTAssertFalse(String(decoding: try XCTUnwrap(plugin.makePortablePreferencesBackup()), as: UTF8.self).contains("Private {{text}}"))
        incomingPlugin.handleSettingsAction(.setBoolean(controlID: "preferences-backup.include-prompt-text", value: true))
        XCTAssertNil(incomingPlugin.savePromptsConfiguration([AIAssistantPrompt(id: "private", name: "Other", template: "Different {{text}}", systemPrompt: nil, isEnabled: true)]))
        let before = plugin.makePortablePreferencesBackup()
        XCTAssertFalse(plugin.restorePortablePreferencesReportingResult(from: try XCTUnwrap(incomingPlugin.makePortablePreferencesBackup())))
        XCTAssertEqual(plugin.makePortablePreferencesBackup(), before)
    }

    func testRecorderImportRequiresSuccessfulSelectedDefinition() async throws {
        for scenario in ["accepted", "rejected", "definition-unselected", "shortcuts-unselected"] {
            let sourceStorage = AIAssistantInMemoryPluginStorage()
            let source = makePlugin(storage: sourceStorage)
            let destinationStorage = AIAssistantInMemoryPluginStorage()
            let panel = RecordingAIAssistantPanelController()
            let destination = makePlugin(storage: destinationStorage, panelController: panel,
                providerFactoryOverride: { .success(ResolvedAIProvider(title: "Synthetic", client: ValidationEchoAIProcessor(),
                    configuration: AIAssistantProviderProfile.defaultProfile().configuration, apiKey: "synthetic-key")) },
                strategies: [StaticSelectionCapture(text: "synthetic")])
            let id = "shared"
            let sourcePrompt = AIAssistantPrompt(id: id, name: "Source", template: "Source {{text}}", isEnabled: true)
            let destinationPrompt = AIAssistantPrompt(id: id, name: "Destination", template: "Destination {{text}}", isEnabled: true)
            XCTAssertNil(source.savePromptsConfiguration([sourcePrompt]))
            XCTAssertNil(destination.savePromptsConfiguration([destinationPrompt]))
            source.handleSettingsAction(.setBoolean(controlID: "preferences-backup.include-prompt-text", value: true))
            if scenario == "accepted" {
                destination.handleSettingsAction(.setBoolean(controlID: "preferences-backup.include-prompt-text", value: true))
            }
            let sourceSuite = "ValidationSource." + UUID().uuidString
            let destinationSuite = "ValidationDestination." + UUID().uuidString
            let sourceDefaults = try XCTUnwrap(UserDefaults(suiteName: sourceSuite))
            let destinationDefaults = try XCTUnwrap(UserDefaults(suiteName: destinationSuite))
            defer { sourceDefaults.removePersistentDomain(forName: sourceSuite); destinationDefaults.removePersistentDomain(forName: destinationSuite) }
            let sourceHost = PluginHost(plugins: [source], shortcutStore: .init(userDefaults: sourceDefaults),
                pluginOrderingStore: .init(userDefaults: sourceDefaults), preferencesBackupStore: PreferencesBackupStore(userDefaults: sourceDefaults),
                globalShortcutManager: .init(registrar: FakeCarbonHotKeyRegistrar()), loadDynamicPluginsOnInit: false)
            let destinationShortcuts = ShortcutStore(userDefaults: destinationDefaults)
            let registrar = FakeCarbonHotKeyRegistrar()
            let destinationHost = PluginHost(plugins: [destination], shortcutStore: destinationShortcuts,
                pluginOrderingStore: .init(userDefaults: destinationDefaults), preferencesBackupStore: PreferencesBackupStore(userDefaults: destinationDefaults),
                globalShortcutManager: .init(registrar: registrar), loadDynamicPluginsOnInit: false)
            defer { sourceHost.deactivateAllPlugins(); destinationHost.deactivateAllPlugins() }
            let shortcutID = "ai-assistant.shortcut." + (try XCTUnwrap(source.shortcutDefinitions.first)).id
            let chord = ShortcutBinding(keyCode: 97, modifiers: [.command, .option, .control, .shift])
            let canonicalChord = ShortcutBinding(keyCode: 98, modifiers: [.command, .option, .control, .shift])
            let originalDestinationChord = ShortcutBinding(keyCode: 96, modifiers: [.command, .option, .control, .shift])
            XCTAssertNil(sourceHost.setShortcutBindingAndReturnError(chord, for: shortcutID))
            XCTAssertNil(destinationHost.setShortcutBindingAndReturnError(originalDestinationChord, for: shortcutID))
            let reference = ActionReference(key: .init(providerID: "ai-assistant", actionID: id))
            guard case .success = sourceHost.setActionShortcutBinding(canonicalChord, to: reference) else {
                return XCTFail("Unable to create canonical control")
            }
            let archive = try sourceHost.makePreferencesBackupExport().requiringSuccessfulSelection()
            var selection = archive.effectiveSelection
            if scenario == "definition-unselected" { selection.pluginPreferenceIDs = [] }
            if scenario == "shortcuts-unselected" { selection.includesShortcuts = false }
            let result = try destinationHost.importPreferences(archive, selection: selection)
            let rejected = result.shortcutErrors["plugin-preferences.ai-assistant"] != nil
            let recorderAttached = destinationShortcuts.customization(for: shortcutID) == .custom(chord)
            let canonicalAttached = destinationHost.shortcutAssignmentService.assignment(for: reference) != nil
            XCTAssertEqual(rejected, scenario == "rejected" || scenario == "shortcuts-unselected")
            XCTAssertEqual(recorderAttached, scenario == "accepted")
            XCTAssertEqual(canonicalAttached, scenario == "accepted")
            let expectedPrompt = scenario == "accepted" ? sourcePrompt : destinationPrompt
            XCTAssertEqual(AIAssistantPromptStore(storage: destinationStorage).loadPrompts(), [expectedPrompt])
            if scenario == "shortcuts-unselected" {
                XCTAssertEqual(destinationShortcuts.customization(for: shortcutID), .custom(originalDestinationChord))
            } else if scenario == "accepted" {
                XCTAssertTrue(registrar.registeredBindings.contains(chord))
            } else {
                XCTAssertEqual(destinationShortcuts.customization(for: shortcutID), .inheritDefault)
            }
            destination.handleShortcutEvent(id: id, phase: .pressed)
            for _ in 0..<100 where panel.snapshot?.phase != .success {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(panel.snapshot?.result?.text, scenario == "accepted" ? "Source synthetic" : "Destination synthetic")

        }
    }

    // MARK: - Helpers

    private func makePlugin(
        storage: AIAssistantInMemoryPluginStorage? = nil,
        accessibilityTrustProvider: @escaping () -> Bool = { true },
        secretStore: (any AIAssistantSecretStoring)? = nil,
        panelController: RecordingAIAssistantPanelController? = nil,
        clipboardTextProvider: @escaping () -> String? = { nil },
        providerFactoryOverride: AIAssistantProviderFactory? = nil,
        strategies: [any SelectedTextCapturing] = []
    ) -> AIAssistantPlugin {
        let storage = storage ?? AIAssistantInMemoryPluginStorage()
        return AIAssistantPlugin(
            context: PluginRuntimeContext(pluginID: "ai-assistant", storage: storage),
            accessibilityTrustProvider: accessibilityTrustProvider,
            accessibilityTrustRequester: { _ in true },
            secretStore: secretStore ?? CountingAIAssistantSecretStore(apiKey: "sk-test"),
            panelController: panelController ?? RecordingAIAssistantPanelController(),
            selectedTextCapturePipeline: SelectedTextCapturePipeline(strategies: strategies),
            providerFactoryOverride: providerFactoryOverride,
            clipboardTextProvider: clipboardTextProvider
        )
    }
}

@MainActor
private final class RecordingTargetCapture: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID = .accessibility
    private(set) var capturedPID: pid_t?

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        capturedPID = context.frontmostApplicationProcessIdentifier
        return .missing
    }
}

@MainActor
private final class StaticSelectionCapture: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID = .accessibility
    let text: String
    private(set) var captureCount = 0

    init(text: String) {
        self.text = text
    }

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        captureCount += 1
        return SelectedTextCaptureResult(
            text: text,
            strategyID: strategyID,
            isEditable: false,
            sourceApplicationBundleID: context.frontmostApplicationBundleID,
            failureReason: nil
        )
    }
}

private final class CountingAIAssistantSecretStore: AIAssistantSecretStoring, @unchecked Sendable {
    private var apiKey: String?
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    var saveFailure: (changesKey: Bool, readFails: Bool)?

    init(apiKey: String?) {
        self.apiKey = apiKey
    }

    func containsAPIKey() throws -> Bool {
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func loadAPIKey() throws -> String? {
        loadCount += 1
        if saveCount > 0, saveFailure?.readFails == true { throw CocoaError(.fileReadUnknown) }
        return apiKey
    }

    func saveAPIKey(_ apiKey: String) throws {
        saveCount += 1
        if let saveFailure {
            if saveFailure.changesKey { self.apiKey = apiKey }
            throw CocoaError(.fileWriteUnknown)
        }
        self.apiKey = apiKey
    }

    func deleteAPIKey() throws {
        apiKey = nil
    }
}

@MainActor
private final class RecordingAIAssistantPanelController: AIAssistantPanelControlling {
    var onAction: ((AIAssistantPanelAction) -> Void)?
    var isVisible = false
    private(set) var snapshot: AIAssistantPanelSnapshot?

    func show(snapshot: AIAssistantPanelSnapshot) {
        isVisible = true
        self.snapshot = snapshot
    }

    func update(snapshot: AIAssistantPanelSnapshot) {
        self.snapshot = snapshot
    }

    func hide() {
        isVisible = false
    }

    func close() {
        isVisible = false
    }
}

private struct ValidationEchoAIProcessor: AIProcessing {
    func complete(prompt: String, systemPrompt: String?, configuration: OpenAICompatibleConfiguration, apiKey: String) async throws -> AIProcessResult {
        AIProcessResult(providerTitle: "Synthetic", text: prompt, reasoningText: nil, sourceText: "", promptName: "")
    }
}
