import AppKit
import AVFoundation
import MacToolsPluginKit
import XCTest

@testable import ScreenshotPlugin

@MainActor
final class ScreenshotPluginTests: XCTestCase {
    private var permissionGranted = true
    func testHostPanelActionsShortcutsAndPermissionContracts() {
        let plugin = makePlugin()
        XCTAssertEqual(plugin.metadata.id, "screenshot")
        XCTAssertTrue(plugin.rowState.isEnabled)
        XCTAssertFalse(plugin.rowState.isOn)
        XCTAssertNil(plugin.rowState.errorMessage)
        XCTAssertEqual(plugin.permissionRequirements.map(\.id),
                       RecordingAuthorization.hostSupportsAudio ? ["screen-recording", "microphone"] : ["screen-recording"])
        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["capture", "quick-capture", "extract-text", "scrolling-capture", "record"])
        XCTAssertEqual(plugin.shortcutDefinitions.map(\.actionID), ["capture", "quick-capture", "extract-text", "scrolling-capture", "record"])
        XCTAssertTrue(plugin.shortcutDefinitions.allSatisfy { $0.scope == .global })
        for definition in plugin.actionDefinitions {
            XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
            XCTAssertEqual(definition.capabilities, [.foregroundInteractive])
            XCTAssertEqual(plugin.permissionRequirementIDs(for: definition.key), ["screen-recording"])
        }
        XCTAssertTrue(plugin.shortcutDefinitions.allSatisfy { $0.defaultBinding == nil && !$0.isRequired })
    }

    func testShortcutSettingsUseCanonicalActionsAndFollowLegacyAssignments() {
        let captureBinding = ShortcutBinding(keyCode: 8, modifiers: [.command, .shift])
        let quickBinding = ShortcutBinding(keyCode: 9, modifiers: [.command, .shift])
        let plugin = makePlugin()
        plugin.shortcutBindingResolver = { definitionID in
            switch definitionID {
            case "capture": captureBinding
            case "quick-capture": quickBinding
            default: nil
            }
        }

        XCTAssertEqual(
            plugin.actionShortcutSettingsConfiguration.actionIDs,
            ["capture", "quick-capture", "extract-text", "scrolling-capture", "record"]
        )
        XCTAssertEqual(
            Set(plugin.legacyActionShortcutAssignments),
            [
                LegacyActionShortcutAssignment(
                    reference: reference(actionID: "capture"),
                    binding: captureBinding,
                    legacyShortcutDefinitionID: "capture"
                ),
                LegacyActionShortcutAssignment(
                    reference: reference(actionID: "quick-capture"),
                    binding: quickBinding,
                    legacyShortcutDefinitionID: "quick-capture"
                ),
            ]
        )
    }

    func testSavingImageBuildsMissingDirectories() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Desktop/screenshot", isDirectory: true)
        let environment = ScreenshotEnvironment(
            context: PluginRuntimeContext(pluginID: "screenshot", storage: ScreenshotTestStorage())
        )
        environment.saveFolder = folder

        let url = environment.fileURL(prefix: "Fixture", ext: "png")
        let data = Data([0, 1, 2, 3])
        try await ScreenshotImageEncoder.write(data, to: url)
        XCTAssertEqual(try Data(contentsOf: url), data)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testPanelAndShortcutsDispatchCaptureModesAndIgnoreUnknownControls() {
        var modes: [CaptureEntry] = []
        let plugin = makePlugin(capture: { modes.append($0) })
        plugin.handleAction(.invokeAction(controlID: "unknown"))
        plugin.handleAction(.setSwitch(true))
        plugin.handleShortcutAction(id: "unknown")
        XCTAssertTrue(modes.isEmpty)
        plugin.handleAction(.invokeAction(controlID: "execute"))
        plugin.handleShortcutAction(id: "capture")
        plugin.handleShortcutAction(id: "quick-capture")
        plugin.handleShortcutAction(id: "extract-text")
        plugin.handleShortcutAction(id: "scrolling-capture")
        if #available(macOS 15, *) { plugin.handleShortcutAction(id: "record") }
        var expected: [CaptureEntry] = [.capture, .capture, .quickCapture, .text, .scroll]
        if #available(macOS 15, *) { expected.append(.record) }
        XCTAssertEqual(modes, expected)
    }

    func testDeniedPermissionRequestsHostGuidanceWithoutCapturing() {
        var count = 0
        var requested: [String] = []
        let plugin = makePlugin(screenAccess: { false }, capture: { _ in count += 1 })
        plugin.requestPermissionGuidance = { requested.append($0) }
        plugin.handleAction(.invokeAction(controlID: "execute"))
        XCTAssertEqual(count, 0)
        XCTAssertEqual(requested, ["screen-recording"])
        XCTAssertFalse(plugin.permissionState(for: "screen-recording").isGranted)
        XCTAssertNotNil(plugin.rowState.errorMessage)
        XCTAssertFalse(plugin.actionAvailability(for: reference()).isAvailable)
    }

    func testPermissionIsRecheckedOnEveryCaptureAndRefreshClearsPermissionError() {
        var count = 0
        let plugin = makePlugin(screenAccess: { self.permissionGranted }, capture: { _ in count += 1 })
        permissionGranted = false
        plugin.handleShortcutAction(id: "capture")
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(plugin.rowState.errorMessage)
        permissionGranted = true
        plugin.refresh()
        XCTAssertNil(plugin.rowState.errorMessage)
        XCTAssertTrue(plugin.permissionState(for: "screen-recording").isGranted)
        plugin.handleShortcutAction(id: "capture")
        XCTAssertEqual(count, 1)
    }

    func testPermissionActionOnlyRequestsKnownPermissionAndRefreshesState() {
        var granted = false
        var requests = 0
        let plugin = makePlugin(screenAccess: { granted }, requestScreenAccess: {
            requests += 1
            granted = true
        })
        plugin.handlePermissionAction(id: "unknown")
        XCTAssertEqual(requests, 0)
        plugin.handlePermissionAction(id: "screen-recording")
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(plugin.permissionState(for: "screen-recording").isGranted)
    }

    func testCanonicalActionRunsOnlyWhenHandleIsExecuted() async throws {
        var modes: [CaptureEntry] = []
        let plugin = makePlugin(capture: { modes.append($0) })
        for entry in CaptureEntry.allCases {
            if entry == .record, #unavailable(macOS 15) { continue }
            let previous = modes
            let handle = try plugin.beginAction(invocation(actionID: entry.rawValue))
            XCTAssertEqual(modes, previous)
            let result = await handle.result()
            XCTAssertEqual(result, .succeeded())
            XCTAssertEqual(modes, previous + [entry])
        }
    }

    func testCancelledHandleCannotLaunchCapture() async throws {
        var count = 0
        let plugin = makePlugin(capture: { _ in count += 1 })
        let handle = try plugin.beginAction(invocation())
        handle.cancel()
        let result = await handle.result()
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(count, 0)
    }

    func testBackgroundAndAutomaticActionsCannotCapture() async throws {
        var count = 0
        let plugin = makePlugin(capture: { _ in count += 1 })
        for request in [invocation(mode: .background), invocation(source: .automaticRule)] {
            let result = await (try plugin.beginAction(request)).result()
            guard case .failed = result else { return XCTFail("Expected foreground-only rejection") }
        }
        XCTAssertEqual(count, 0)
    }

    func testUnknownProviderActionAndSchemaAreUnavailable() async throws {
        let plugin = makePlugin()
        for value in [
            ActionReference(key: ActionKey(providerID: "other", actionID: "capture")),
            reference(actionID: "unknown"),
            ActionReference(key: reference().key, schemaVersion: 2),
        ] {
            XCTAssertFalse(plugin.actionAvailability(for: value).isAvailable)
            let result = await (try plugin.beginAction(ActionInvocation(reference: value, source: .test, mode: .foreground))).result()
            guard case .failed = result else { return XCTFail("Expected unknown action rejection") }
        }
        XCTAssertEqual(plugin.permissionRequirementIDs(for: ActionKey(providerID: "other", actionID: "capture")), [])
    }

    func testDeactivationRejectsPendingAndNewActions() async throws {
        var count = 0
        let plugin = makePlugin(capture: { _ in count += 1 })
        let pending = try plugin.beginAction(invocation())
        plugin.deactivate(reason: .updating)
        let result = await pending.result()
        guard case .failed = result else { return XCTFail("Pending action must not reopen a disabled plugin") }
        plugin.handleShortcutAction(id: "capture")
        XCTAssertEqual(count, 0)
        XCTAssertFalse(plugin.rowState.isEnabled)
    }

    func testFolderSettingsPersistInPluginStorageAndCancelledPickerPreservesValue() {
        let storage = ScreenshotTestStorage()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotPluginTests", isDirectory: true)
        var selection: URL? = folder
        var picked = 0
        let plugin = makePlugin(storage: storage, folderPicker: { _ in
            picked += 1
            return selection
        })
        plugin.handleSettingsAction(.invoke(controlID: "unknown"))
        XCTAssertEqual(picked, 0)
        plugin.handleSettingsAction(.invoke(controlID: "save-folder"))
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: storage))
        XCTAssertEqual(environment.saveFolder, folder)
        selection = nil
        plugin.handleSettingsAction(.invoke(controlID: "save-folder"))
        XCTAssertEqual(environment.saveFolder, folder)
        selection = URL(string: "https://example.com/")
        plugin.handleSettingsAction(.invoke(controlID: "save-folder"))
        XCTAssertEqual(environment.saveFolder, folder)
        plugin.deactivate(reason: .disabled)
        let countBeforeDeactivation = picked
        plugin.handleSettingsAction(.invoke(controlID: "save-folder"))
        XCTAssertEqual(picked, countBeforeDeactivation)
    }

    func testRecordingSettingsShareToolbarPreferencesAndRefreshDisconnectedInputs() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Recording requires macOS 15") }
        let storage = ScreenshotTestStorage()
        let microphoneFixture = MicrophoneFixture(RecordingMicrophoneSnapshot(
            devices: [.init(id: "usb", name: "Studio Input")], defaultName: "Built-in Input"))
        var discoveries = 0
        var requests = 0
        let plugin = ScreenshotPlugin(
            context: PluginRuntimeContext(pluginID: "screenshot", storage: storage),
            screenAccess: { true }, requestScreenAccess: { requests += 1 }, capture: { _ in },
            discoverMicrophones: { discoveries += 1; return microphoneFixture.value }, hostSupportsAudio: { true }
        )
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: storage))
        var updates = 0
        plugin.onStateChange = { updates += 1 }
        _ = plugin.settingsPage
        XCTAssertEqual(discoveries, 0, "Reading a settings snapshot must not scan hardware")
        plugin.settingsPage?.visibilityHandler?(true)
        plugin.handleSettingsAction(.setBoolean(controlID: "recording-system-audio", value: true))
        plugin.handleSettingsAction(.setBoolean(controlID: "recording-microphone", value: true))
        plugin.handleSettingsAction(.setSelection(controlID: "recording-microphone-device", optionID: "usb"))
        XCTAssertEqual(environment.recordingAudio, .init(systemAudio: true, microphone: true, microphoneID: "usb"))
        XCTAssertGreaterThan(updates, 0)
        XCTAssertEqual(requests, 0, "Changing preferences must not ask for capture permission")

        let toolbar = RecordingControlsView(environment: environment, discoverMicrophones: { microphoneFixture.value })
        toolbar.activate()
        defer { toolbar.deactivate(); plugin.deactivate(reason: .disabled) }
        XCTAssertEqual(toolbar.devices.itemTitle(at: 0), "Studio Input")
        microphoneFixture.value = .init(devices: [], defaultName: nil)
        NotificationCenter.default.post(name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        let rows = try recordingRows(plugin)
        let device = try XCTUnwrap(rows.first { $0.id == "recording-microphone-device" })
        XCTAssertNotNil(device.help)
        XCTAssertEqual(environment.recordingAudio.microphoneID, "usb", "Disconnection must not silently change the source")
        plugin.handleSettingsAction(.setSelection(controlID: "recording-microphone-device", optionID: "invalid"))
        XCTAssertEqual(environment.recordingAudio.microphoneID, "usb")
        plugin.handleSettingsAction(.setSelection(controlID: "recording-microphone-device", optionID: "system-default"))
        XCTAssertNil(environment.recordingAudio.microphoneID)
        plugin.handleSettingsAction(.setBoolean(controlID: "recording-microphone", value: false))
        XCTAssertFalse(try XCTUnwrap(recordingRows(plugin).first { $0.id == "recording-microphone-device" }).isEnabled)
        plugin.handleSettingsAction(.setSelection(controlID: "recording-microphone-device", optionID: "usb"))
        XCTAssertNil(environment.recordingAudio.microphoneID)
        plugin.handleSettingsAction(.setBoolean(controlID: "recording-auto-zoom", value: false))
        XCTAssertFalse(environment.recordingAutoZoom)
    }

    func testOlderHostCanDisableSavedAudioButCannotEnableItFromSettings() {
        let storage = ScreenshotTestStorage()
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: storage))
        environment.recordingAudio = .init(systemAudio: true, microphone: true)
        let plugin = ScreenshotPlugin(context: PluginRuntimeContext(pluginID: "screenshot", storage: storage),
                                      screenAccess: { true }, capture: { _ in }, hostSupportsAudio: { false })
        for id in ["recording-system-audio", "recording-microphone"] {
            plugin.handleSettingsAction(.setBoolean(controlID: id, value: false))
            plugin.handleSettingsAction(.setBoolean(controlID: id, value: true))
        }
        XCTAssertEqual(environment.recordingAudio, .init())
    }

    private func recordingRows(_ plugin: ScreenshotPlugin) throws -> [PluginSettingsRow] {
        guard case .form(let sections) = plugin.settingsPage?.body,
              case .rows(let rows) = sections.first(where: { $0.id == "recording" })?.content else {
            XCTFail("Expected recording settings")
            return []
        }
        return rows
    }

    private final class MicrophoneFixture {
        var value: RecordingMicrophoneSnapshot
        init(_ value: RecordingMicrophoneSnapshot) { self.value = value }
    }

    private func makePlugin(
        storage: PluginStorage? = nil,
        screenAccess: @escaping @MainActor @Sendable () -> Bool = { true },
        requestScreenAccess: @escaping @MainActor @Sendable () -> Void = {},
        capture: @escaping @MainActor @Sendable (CaptureEntry) -> Void = { _ in },
        folderPicker: @escaping @MainActor @Sendable (URL) -> URL? = { _ in nil }
    ) -> ScreenshotPlugin {
        ScreenshotPlugin(
            context: PluginRuntimeContext(pluginID: "screenshot", storage: storage ?? ScreenshotTestStorage()),
            screenAccess: screenAccess,
            requestScreenAccess: requestScreenAccess,
            capture: capture,
            folderPicker: folderPicker
        )
    }

    private func reference(actionID: String = "capture") -> ActionReference {
        ActionReference(key: ActionKey(providerID: "screenshot", actionID: actionID))
    }

    private func invocation(
        actionID: String = "capture",
        source: ActionExecutionSource = .test,
        mode: ActionExecutionMode = .foreground
    ) -> ActionInvocation {
        ActionInvocation(reference: reference(actionID: actionID), source: source, mode: mode)
    }
}

@MainActor
final class ScreenshotTestStorage: PluginStorage {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}
