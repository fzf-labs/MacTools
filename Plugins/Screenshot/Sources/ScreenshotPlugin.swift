import AppKit
import AVFoundation
import MacToolsPluginKit
import SwiftUI

public final class ScreenshotPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        ScreenshotPluginProvider(context: context)
    }
}

@MainActor
private struct ScreenshotPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [ScreenshotPlugin(context: context)]
    }
}

@MainActor
final class ScreenshotPlugin: MacToolsPlugin, PluginActionProviding, PluginActionPermissionProviding, PluginActionShortcutSettingsProviding, PluginLegacyActionShortcutProviding, DisplayTopologyRefreshing {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    private enum ID {
        static let plugin = "screenshot"
        static let capture = CaptureEntry.capture.rawValue
        static let quickCapture = CaptureEntry.quickCapture.rawValue
        static let shortcutPlacement = "shortcut-placement"
        static let execute = "execute"
        static let permission = "screen-recording"
        static let microphonePermission = "microphone"
        static let folder = "save-folder"
        static let autoZoom = "recording-auto-zoom"
        static let systemAudio = "recording-system-audio"
        static let microphone = "recording-microphone"
        static let microphoneDevice = "recording-microphone-device"
        static let defaultMicrophone = "system-default"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: ID.plugin,
            title: environment.string("metadata.title", "截图"),
            iconName: "camera.viewfinder",
            iconTint: Color(nsColor: .systemBlue),
            order: 105,
            defaultDescription: environment.string("metadata.summary", "截图、标注、提取文字与录屏")
        )
    }
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let environment: ScreenshotEnvironment
    private let coordinator: ScreenshotCoordinator
    private let screenAccess: @MainActor () -> Bool
    private let requestScreenAccess: @MainActor () -> Void
    private let capture: @MainActor (CaptureEntry) -> Void
    private let folderPicker: @MainActor (URL) -> URL?
    private let revealFolder: @MainActor (URL) throws -> Void
    private let discoverMicrophones: @MainActor () -> RecordingMicrophoneSnapshot
    private let hostSupportsAudio: @MainActor () -> Bool
    private var microphones = RecordingMicrophoneSnapshot(devices: [], defaultName: nil)
    private var settingsObservers: [NSObjectProtocol] = []
    private var isGranted: Bool
    private var isActive = true
    private var lastError: String?
    private var microphoneAuthorizationTask: Task<Void, Never>?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "screenshot"),
        screenAccess: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
        requestScreenAccess: @escaping @MainActor () -> Void = ScreenshotPlugin.openScreenCaptureSettings,
        capture: (@MainActor (CaptureEntry) -> Void)? = nil,
        folderPicker: (@MainActor (URL) -> URL?)? = nil,
        revealFolder: @escaping @MainActor (URL) throws -> Void = { folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        },
        discoverMicrophones: @escaping @MainActor () -> RecordingMicrophoneSnapshot = { .current() },
        hostSupportsAudio: @escaping @MainActor () -> Bool = { RecordingAuthorization.hostSupportsAudio }
    ) {
        let environment = ScreenshotEnvironment(context: context)
        let coordinator = ScreenshotCoordinator(environment: environment)
        self.environment = environment
        self.coordinator = coordinator
        self.screenAccess = screenAccess
        self.requestScreenAccess = requestScreenAccess
        self.capture = capture ?? { [weak coordinator] entry in coordinator?.capture(entry: entry) }
        self.revealFolder = revealFolder
        self.discoverMicrophones = discoverMicrophones
        self.hostSupportsAudio = hostSupportsAudio
        self.folderPicker = folderPicker ?? { folder in
            Self.chooseFolder(folder, environment: environment)
        }
        self.isGranted = screenAccess()
        coordinator.onStateChange = { [weak self] in self?.onStateChange?() }
        coordinator.onError = { [weak self] message in
            self?.lastError = message
            self?.onStateChange?()
        }
        environment.onPreferencesChange = { [weak self] in self?.onStateChange?() }
    }

    var rowDescriptor: PluginPanelRowDescriptor {
        PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitle: coordinator.isRecording
                ? environment.string("panel.stopRecording", "停止录屏")
                : coordinator.isScrolling
                    ? environment.string("panel.finishScrolling", "完成")
                    : environment.string("action.capture.title", "截图")
        )
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: coordinator.isBusy,
            isEnabled: isActive && (!coordinator.isBusy || canFinishSession),
            isAvailable: true,
            detail: nil,
            errorMessage: lastError
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        var requirements = [PluginPermissionRequirement(
            id: ID.permission,
            kind: .screenRecording,
            title: environment.string("permission.screenRecording.title", "录屏权限"),
            description: environment.string("permission.screenRecording.description", "用于截取屏幕内容和录屏，图像与识别结果仅在本机处理。")
        )]
        if hostSupportsAudio() {
            requirements.append(PluginPermissionRequirement(
                id: ID.microphonePermission,
                kind: .screenRecording,
                title: environment.string("record.audio.microphone", "麦克风"),
                description: environment.string("record.microphone.purpose", "仅在开启麦克风录制时收录讲解，并保存到录像。")
            ))
        }
        return requirements
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: ID.plugin, actionID: ID.capture),
                title: environment.string("action.capture.title", "截图"),
                description: environment.string("action.capture.description", "框选区域或窗口，标注、识别文字或二维码，也可滚动截图和录屏。"),
                keywords: [metadata.title, "screenshot", "OCR", "Snap"],
                systemImage: "camera.viewfinder",
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: ID.plugin, actionID: ID.quickCapture),
                title: environment.string("action.quickCapture.title", "快速截图"),
                description: environment.string("action.quickCapture.description", "框选后立即复制到剪贴板。"),
                keywords: [metadata.title, "screenshot", "clipboard"],
                systemImage: "camera",
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: ID.plugin, actionID: CaptureEntry.text.rawValue),
                title: environment.string("overlay.recognition.text", "提取文字"),
                description: environment.string("action.text.description", "框选后直接识别文字。"),
                keywords: [metadata.title, "OCR", "text"],
                systemImage: "text.viewfinder",
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: ID.plugin, actionID: CaptureEntry.scroll.rawValue),
                title: environment.string("overlay.mode.scroll", "滚动截图"),
                description: environment.string("action.scroll.description", "直接选择滚动截图区域，准备好后开始。"),
                keywords: [metadata.title, "scroll", "long screenshot"],
                systemImage: "arrow.down.doc",
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: ID.plugin, actionID: CaptureEntry.record.rawValue),
                title: environment.string("overlay.mode.record", "录屏"),
                description: environment.string("action.record.description", "选择录制目标和声音后开始；录制中再次按下停止。"),
                keywords: [metadata.title, "record", "video"],
                systemImage: "record.circle",
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            ),
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        actionDefinitions.map { definition in
            PluginShortcutDefinition(
                id: definition.key.actionID,
                title: definition.title,
                description: definition.description,
                actionID: definition.key.actionID,
                scope: .global,
                defaultBinding: nil,
                isRequired: false
            )
        }
    }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            // The host inserts the canonical action-shortcut section after this
            // zero-row anchor, keeping output settings below the shortcuts.
            PluginSettingsSection(id: ID.shortcutPlacement, rows: []),
            PluginSettingsSection(
                id: "output",
                title: environment.string("settings.output.title", "保存"),
                systemImage: "folder",
                footer: environment.string("settings.output.description", "快速截图复制到剪贴板；截图可保存为 PNG，录屏自动保存为 MOV。")
            ) { [weak self, environment] _ in
                ScreenshotSaveFolderView(
                    folder: environment.saveFolder,
                    title: environment.string("settings.folder.title", "保存位置"),
                    chooseTitle: environment.string("settings.folder.choose", "选择文件夹…"),
                    revealTitle: environment.string("settings.folder.reveal", "在访达中显示"),
                    copyTitle: environment.string("settings.folder.copy", "复制路径"),
                    choose: { self?.handleSettingsAction(.invoke(controlID: ID.folder)) },
                    reveal: { self?.showSaveFolder() }
                )
            },
            PluginSettingsSection(
                id: "recording",
                title: environment.string("settings.recording.title", "录屏"),
                systemImage: "record.circle",
                footer: recordingSettingsDescription,
                rows: recordingSettingsRows
            ),
        ]).onVisibilityChange { [weak self] visible in self?.setSettingsVisible(visible) }
    }

    private var recordingSettingsRows: [PluginSettingsRow] {
        let audio = environment.recordingAudio
        let supportsAudio = hostSupportsAudio() && supportsRecording
        let defaultTitle = environment.string("record.audio.default", "系统默认")
        let defaultName = microphones.defaultName.map { "\(defaultTitle) · \($0)" } ?? defaultTitle
        var options = [PluginSettingsOption(id: ID.defaultMicrophone, title: defaultName)]
        options += microphones.devices.map { PluginSettingsOption(id: $0.id, title: $0.name) }
        let missing = audio.microphoneID.map { id in !microphones.devices.contains { $0.id == id } } ?? false
        let unavailable = environment.string("record.microphone.unavailable", "所选麦克风已断开，请重新选择")
        if let id = audio.microphoneID, missing { options.append(PluginSettingsOption(id: id, title: unavailable)) }
        return [
            PluginSettingsRow(
                id: ID.systemAudio,
                title: environment.string("record.audio.system", "系统声音"),
                description: environment.string("settings.audio.system.description", "录下电脑播放的声音。"),
                systemImage: "speaker.wave.2",
                isEnabled: supportsAudio || audio.systemAudio,
                control: .toggle(isOn: audio.systemAudio)
            ),
            PluginSettingsRow(
                id: ID.microphone,
                title: environment.string("record.audio.microphone", "麦克风"),
                description: environment.string("settings.audio.microphone.description", "录下你的讲解。"),
                systemImage: "mic",
                isEnabled: supportsAudio || audio.microphone,
                control: .toggle(isOn: audio.microphone)
            ),
            PluginSettingsRow(
                id: ID.microphoneDevice,
                title: environment.string("settings.audio.device", "输入设备"),
                systemImage: "mic.badge.plus",
                help: audio.microphone && missing ? unavailable : nil,
                isEnabled: supportsAudio && audio.microphone,
                control: .picker(selectionID: audio.microphoneID ?? ID.defaultMicrophone, options: options, style: .menu)
            ),
            PluginSettingsRow(
                id: ID.autoZoom,
                title: environment.string("settings.autoZoom.title", "自动缩放"),
                description: environment.string("settings.autoZoom.description", "仅区域和显示器录制可用。点击或滚动时放大该位置，随后恢复全景。"),
                systemImage: "plus.magnifyingglass",
                isEnabled: supportsRecording,
                control: .toggle(isOn: environment.recordingAutoZoom)
            ),
        ]
    }

    private var recordingSettingsDescription: String {
        guard supportsRecording else { return environment.string("record.requiresNewerSystem", "录屏需要 macOS 15 或更高版本") }
        guard hostSupportsAudio() else {
            return environment.string("record.audio.hostUpdate", "当前版本的 MacTools 不支持录音，请更新主程序后使用。仍可无声录屏。")
        }
        return environment.string("settings.recording.sync", "与录屏工具栏同步；录制中的更改将在下次生效。")
    }

    var actionShortcutSettingsConfiguration: PluginActionShortcutSettingsConfiguration {
        PluginActionShortcutSettingsConfiguration(
            title: environment.string("settings.shortcuts.title", "快捷键"),
            description: environment.string("settings.shortcuts.description", "设置常用功能的全局快捷键，默认不绑定。"),
            actionIDs: Set(CaptureEntry.allCases.map(\.rawValue)),
            placementAfterSectionID: ID.shortcutPlacement
        )
    }

    var legacyActionShortcutAssignments: [LegacyActionShortcutAssignment] {
        shortcutDefinitions.compactMap { definition in
            guard let binding = shortcutBindingResolver?(definition.id) else { return nil }
            return LegacyActionShortcutAssignment(
                reference: ActionReference(
                    key: ActionKey(providerID: ID.plugin, actionID: definition.actionID)
                ),
                binding: binding,
                legacyShortcutDefinitionID: definition.id
            )
        }
    }

    func legacyActionShortcutsDidMigrate() {}

    func refresh() {
        let granted = screenAccess()
        guard granted != isGranted else { return }
        isGranted = granted
        if granted {
            lastError = nil
        } else {
            coordinator.cancel()
        }
        onStateChange?()
    }

    func activate(context: PluginRuntimeContext) {
        isActive = true
        refresh()
        coordinator.prepareCaptureSurfaces()
        onStateChange?()
    }

    func refreshDisplayTopology() {
        guard isActive else { return }
        coordinator.refreshDisplayTopology()
    }

    func deactivate(reason: PluginDeactivationReason) {
        isActive = false
        setSettingsVisible(false)
        microphoneAuthorizationTask?.cancel()
        microphoneAuthorizationTask = nil
        coordinator.cancel()
        lastError = nil
        onStateChange?()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        if permissionID == ID.microphonePermission {
            let granted = RecordingAuthorization.microphoneStatus == .authorized
            return PluginPermissionState(isGranted: granted, footnote: nil,
                                         statusText: granted ? nil : environment.string("record.permission.optional", "按需授权"),
                                         statusTone: granted ? .positive : .neutral)
        }
        return PluginPermissionState(
            isGranted: permissionID != ID.permission || isGranted,
            footnote: permissionID == ID.permission && !isGranted ? permissionGuidance : nil
        )
    }

    func handlePermissionAction(id: String) {
        if id == ID.microphonePermission, hostSupportsAudio() {
            guard microphoneAuthorizationTask == nil else { return }
            microphoneAuthorizationTask = Task { [weak self] in
                let granted = await RecordingAuthorization.requestMicrophone()
                guard let self else { return }
                microphoneAuthorizationTask = nil
                guard !Task.isCancelled, isActive else { return }
                if !granted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
                onStateChange?()
            }
            return
        }
        guard id == ID.permission else { return }
        requestScreenAccess()
        refresh()
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        isKnownAction(actionKey) ? [ID.permission] : []
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard isKnownAction(reference.key), reference.schemaVersion == 1, isActive else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        if reference.key.actionID == CaptureEntry.record.rawValue, !supportsRecording {
            return .unavailable(environment.string("record.requiresNewerSystem", "录屏需要 macOS 15 或更高版本"))
        }
        if canFinishSession || coordinator.isPreparingCapture { return .available }
        guard isGranted else { return .unavailable(permissionGuidance) }
        guard !coordinator.isBusy else { return .unavailable(panelSubtitle) }
        return .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { [weak self] in
            guard let self, !Task.isCancelled else { return .cancelled }
            guard invocation.mode == .foreground, invocation.source != .automaticRule else {
                return .failed(message: PluginKitLocalization.actionUnavailable)
            }
            let availability = actionAvailability(for: invocation.reference)
            guard availability.isAvailable else {
                return .failed(message: availability.reason ?? PluginKitLocalization.actionUnavailable)
            }
            guard let entry = CaptureEntry(rawValue: invocation.reference.key.actionID) else { return .cancelled }
            return beginCapture(entry: entry)
                ? .succeeded() : .failed(message: lastError ?? PluginKitLocalization.actionUnavailable)
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case .invokeAction(ID.execute) = action else { return }
        beginCapture(entry: .capture)
    }

    func handleShortcutAction(id: String) {
        guard let entry = CaptureEntry(rawValue: id) else { return }
        beginCapture(entry: entry)
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard isActive else { return }
        if case .setBoolean(ID.autoZoom, let isOn) = action {
            environment.recordingAutoZoom = isOn
            return
        }
        if case .setBoolean(let id, let isOn) = action, id == ID.systemAudio || id == ID.microphone {
            guard !isOn || (hostSupportsAudio() && supportsRecording) else { return }
            var audio = environment.recordingAudio
            if id == ID.systemAudio { audio.systemAudio = isOn } else { audio.microphone = isOn }
            environment.recordingAudio = audio
            return
        }
        if case .setSelection(ID.microphoneDevice, let id) = action {
            guard hostSupportsAudio(), supportsRecording, environment.recordingAudio.microphone else { return }
            refreshMicrophones()
            guard id == ID.defaultMicrophone || microphones.devices.contains(where: { $0.id == id }) else { return }
            var audio = environment.recordingAudio
            audio.microphoneID = id == ID.defaultMicrophone ? nil : id
            environment.recordingAudio = audio
            return
        }
        guard case .invoke(ID.folder) = action,
              let folder = folderPicker(environment.saveFolder), isActive, folder.isFileURL else { return }
        environment.saveFolder = folder
    }

    private func showSaveFolder() {
        guard isActive else { return }
        do { try revealFolder(environment.saveFolder) }
        catch { environment.showToast(environment.captureErrorDescription(error)) }
    }

    private func setSettingsVisible(_ visible: Bool) {
        for token in settingsObservers { NotificationCenter.default.removeObserver(token) }
        settingsObservers.removeAll()
        guard visible, isActive else { return }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification,
                     NSApplication.didBecomeActiveNotification] {
            settingsObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMicrophones() }
            })
        }
        refreshMicrophones()
    }

    private func refreshMicrophones() {
        microphones = discoverMicrophones()
        onStateChange?()
    }

    private var supportsRecording: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    @discardableResult
    private func beginCapture(entry: CaptureEntry) -> Bool {
        guard isActive else { return false }
        guard entry != .record || supportsRecording else {
            lastError = environment.string("record.requiresNewerSystem", "录屏需要 macOS 15 或更高版本")
            onStateChange?()
            return false
        }
        isGranted = screenAccess()
        guard isGranted || canFinishSession else {
            lastError = permissionGuidance
            onStateChange?()
            requestPermissionGuidance?(ID.permission)
            return false
        }
        guard !coordinator.isBusy || canFinishSession || coordinator.isPreparingCapture else { return false }
        lastError = nil
        capture(entry)
        onStateChange?()
        return true
    }

    private var canFinishSession: Bool { coordinator.isRecording || coordinator.isScrolling }

    private var permissionGuidance: String {
        environment.string("permission.screenRecording.guidance", "请在系统设置 → 隐私与安全性 → 录屏与系统录音（或录屏）中授权 MacTools。")
    }

    private var panelSubtitle: String {
        if coordinator.isRecording {
            return environment.string("panel.recording", "正在录屏，再次点击或使用截图快捷键停止")
        }
        if coordinator.isScrolling {
            return environment.string("panel.scrolling", "滚动页面后点击完成，或使用截图快捷键完成")
        }
        if coordinator.isBusy { return environment.string("panel.capturing", "正在截图…") }
        return isGranted ? metadata.defaultDescription : permissionGuidance
    }

    private func isKnownAction(_ key: ActionKey) -> Bool {
        key.providerID == ID.plugin && CaptureEntry(rawValue: key.actionID) != nil
    }

    private static func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func chooseFolder(_ current: URL, environment: ScreenshotEnvironment) -> URL? {
        let panel = NSOpenPanel()
        environment.savePanel = panel
        defer { if environment.savePanel === panel { environment.savePanel = nil } }
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = current
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct ScreenshotSaveFolderView: View {
    let folder: URL
    let title: String
    let chooseTitle: String
    let revealTitle: String
    let copyTitle: String
    let choose: () -> Void
    let reveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            ViewThatFits(in: .horizontal) {
                PluginSettingsItem(title: title, systemImage: "folder") { buttons }
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Label(title, systemImage: "folder")
                        .font(PluginSettingsTheme.Typography.rowTitle)
                    buttons
                }
            }
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Text(folder.path)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(folder.path)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(folder.path, forType: .string)
                } label: {
                    Label(copyTitle, systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(copyTitle)
                .accessibilityLabel(copyTitle)
                .accessibilityIdentifier("screenshot.settings.copyFolder")
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Button(chooseTitle, action: choose)
                .accessibilityIdentifier("screenshot.settings.chooseFolder")
            Button(revealTitle, action: reveal)
                .accessibilityIdentifier("screenshot.settings.revealFolder")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
    }
}
