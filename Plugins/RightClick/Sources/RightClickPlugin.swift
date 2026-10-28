import AppKit
import FinderSync
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class RightClickPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        RightClickPluginProvider(context: context)
    }
}

@MainActor
private struct RightClickPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [RightClickPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

private enum RightClickPermissionID {
    static let finderExtension = "finder-extension"
}

@MainActor
final class RightClickPlugin: MacToolsPlugin, PluginPortablePreferencesProviding,
    PluginPortablePreferencesRestorationReporting, PluginPersistentPreferencesChangeSignaling {
    private let preferencesChanges = PluginPersistentPreferencesChangeEmitter()
    var onPersistentPreferencesChange: (() -> Void)? {
        get { preferencesChanges.onChange }
        set { preferencesChanges.onChange = newValue }
    }
    private lazy var session: RightClickSettingsSession = {
        let session = RightClickSettingsSession(fileURL: configurationURL)
        session.onPersist = { [weak self] in self?.preferencesChanges.didPersist() }
        return session
    }()

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "right-click",
            title: localization.string("metadata.title", defaultValue: "右键工具"),
            iconName: "contextualmenu.and.cursorarrow",
            iconTint: Color(nsColor: .systemTeal),
            order: 74,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "自定义 Finder 操作、模板、常用位置和文件工具"
            )
        )
    }

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let configurationURL: URL
    private let localization: PluginLocalization
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "RightClickPlugin"
    )
    private var activationObserver: NSObjectProtocol?

    init(localization: PluginLocalization = PluginLocalization(bundle: .main),
         configurationURL: URL = RightClickConfigurationStore.configFileURL) {
        self.configurationURL = configurationURL
        self.localization = localization
    }

    func activate(context _: PluginRuntimeContext) {
        RightClickConfigurationStore.setMenuEnabled(true, fileURL: configurationURL)
        session.startObserving()

        guard activationObserver == nil else {
            return
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onStateChange?()
            }
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        session.stopObserving()
        if reason.requiresStateCleanup {
            RightClickConfigurationStore.setMenuEnabled(false, fileURL: configurationURL)
        }

        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: RightClickPermissionID.finderExtension,
                kind: .finderExtension,
                title: localization.string("permission.finderExtension.title", defaultValue: "Finder 扩展"),
                description: localization.string(
                    "permission.finderExtension.description",
                    defaultValue: "在系统设置中打开 MacTools 右键工具。"
                )
            )
        ]
    }

    var settingsPage: PluginSettingsPage? {
        .workspace(description: localization.string("Configure Finder actions and menu layout", defaultValue: "设置 Finder 右键功能与菜单布局"), scrolling: .selfManaged) { [localization, session] _ in
            RightClickWorkspaceView(session: session, localization: localization)
        }
    }

    func makePortablePreferencesBackup() -> Data? {
        var value = RightClickConfigurationStore.load(from: configurationURL)
        value.undoAvailable = false
        value.menuEnabled = false
        value.preferredLanguages = nil
        return try? JSONEncoder().encode(value)
    }

    func restorePortablePreferences(from data: Data) {
        _ = restorePortablePreferencesReportingResult(from: data)
    }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard data.count <= 1_048_576,
              var value = try? JSONDecoder().decode(RightClickConfiguration.self, from: data),
              value.schemaVersion == RightClickConfiguration.currentSchemaVersion,
              value.locations.count <= 256, value.openWithApps.count <= 256, value.resources.count <= 256,
              Set(value.locations.map(\.id)).count == value.locations.count,
              Set(value.resources.map(\.id)).count == value.resources.count,
              Set(value.openWithApps.map(\.id)).count == value.openWithApps.count,
              value.openWithApps.allSatisfy({ $0.appPath.hasPrefix("/") && $0.appPath.hasSuffix(".app") && !$0.appPath.utf8.contains(0) }),
              value.locations.allSatisfy({ $0.path.hasPrefix("/") && !$0.path.utf8.contains(0) }),
              value.resources.allSatisfy({ RightClickResourceStore.safeComponent($0.filename) && $0.filename.hasPrefix($0.id.uuidString) }),
              value.enabledFileExtensions.allSatisfy({ RightClickNewFile.supportedExtensions.contains($0) })
        else { return false }
        let current = RightClickConfigurationStore.load(from: configurationURL)
        value.undoAvailable = current.undoAvailable
        value.menuEnabled = current.menuEnabled
        value.preferredLanguages = current.preferredLanguages
        guard RightClickConfigurationStore.save(value, to: configurationURL) else { return false }
        session.reload()
        preferencesChanges.didPersist()
        onStateChange?()
        return true
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == RightClickPermissionID.finderExtension else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }

        let enabled = FIFinderSyncController.isExtensionEnabled
        return PluginPermissionState(
            isGranted: enabled,
            footnote: localization.string(
                "permission.finderExtension.footnote",
                defaultValue: "入口：登录项与扩展 > Finder 扩展。"
            ),
            statusText: enabled
                ? localization.string("permission.finderExtension.status.enabled", defaultValue: "已启用")
                : localization.string("permission.finderExtension.status.disabled", defaultValue: "未启用"),
            statusSystemImage: enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            statusTone: enabled ? .positive : .caution
        )
    }

    func handlePermissionAction(id permissionID: String) {
        guard permissionID == RightClickPermissionID.finderExtension else {
            return
        }

        openExtensionManagementInterface()
    }

    private func openExtensionManagementInterface() {
        logger.info("Opening Finder extension management interface")
        FIFinderSyncController.showExtensionManagementInterface()
        onStateChange?()
    }
}
