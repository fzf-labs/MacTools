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

    convenience init(localization: PluginLocalization = PluginLocalization(bundle: .main), configurationFileURL: URL) {
        self.init(localization: localization, configurationURL: configurationFileURL)
    }

    func makePortablePreferencesBackup() -> Data? {
        guard var value = RightClickConfigurationStore.loadForPreferencesBackup(from: configurationURL),
              value.schemaVersion == RightClickConfiguration.currentSchemaVersion,
              value.openWithApps.count <= 512, value.openWithApps.allSatisfy(validPortableApplication) else { return nil }
        for index in value.openWithApps.indices {
            let entry = value.openWithApps[index]
            let identity: PortableApplicationReference
            if let data = entry.portableApplicationReference {
                guard let retained = try? JSONDecoder().decode(PortableApplicationReference.self, from: data), retained.isValid else { return nil }
                identity = retained
            } else {
                identity = PortableApplicationReference(url: entry.appPath.hasPrefix("/") ? URL(fileURLWithPath: entry.appPath) : nil)
            }
            guard identity.isValid else { return nil }
            value.openWithApps[index].portableApplicationReference = portableIdentityData(identity)
            value.openWithApps[index].appPath = ""
        }
        value.undoAvailable = false
        value.menuEnabled = false
        value.preferredLanguages = nil
        value.locations = []
        return try? JSONEncoder().encode(value)
    }

    func restorePortablePreferences(from data: Data) { _ = restorePortablePreferencesReportingResult(from: data) }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard data.count <= 1_048_576,
              let current = RightClickConfigurationStore.loadForPreferencesBackup(from: configurationURL) else { return false }
        var value: RightClickConfiguration
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if object?["formatVersion"] != nil {
            guard let payload = decodedPortable(data) else { return false }
            value = current
            value.newFolder = payload.newFolder
            value.newFile = payload.newFile
            value.openInTerminal = payload.openInTerminal
            value.copyFileName = payload.copyFileName
            value.copyAbsolutePath = payload.copyAbsolutePath
            value.copyRelativePath = payload.copyRelativePath
            value.copyShellEscapedPath = payload.copyShellEscapedPath
            value.copyFileURL = payload.copyFileURL
            value.openWithApps = payload.applications.map { incoming in
                var entry = RightClickOpenWithApp(id: incoming.id, name: incoming.name, appPath: "", fileExtensions: incoming.fileExtensions)
                entry.portableApplicationReference = portableIdentityData(incoming.application)
                return entry
            }
        } else {
            guard let decoded = try? JSONDecoder().decode(RightClickConfiguration.self, from: data) else { return false }
            value = decoded
        }
        guard value.schemaVersion == RightClickConfiguration.currentSchemaVersion,
              value.locations.count <= 256, value.openWithApps.count <= 512, value.resources.count <= 256,
              Set(value.locations.map(\.id)).count == value.locations.count,
              Set(value.resources.map(\.id)).count == value.resources.count,
              Set(value.openWithApps.map(\.id)).count == value.openWithApps.count,
              value.openWithApps.allSatisfy(validPortableApplication),
              value.locations.allSatisfy({ $0.path.hasPrefix("/") && !$0.path.utf8.contains(0) }),
              value.resources.allSatisfy({ RightClickResourceStore.safeComponent($0.filename) && $0.filename.hasPrefix($0.id.uuidString) }),
              value.enabledFileExtensions.allSatisfy({ RightClickNewFile.supportedExtensions.contains($0) }) else { return false }
        var resolved = Set<String>()
        for index in value.openWithApps.indices {
            let entry = value.openWithApps[index]
            if let data = entry.portableApplicationReference {
                guard let identity = try? JSONDecoder().decode(PortableApplicationReference.self, from: data), identity.isValid else { return false }
                let url = identity.resolvedURL()
                value.openWithApps[index].appPath = url.flatMap { resolved.insert($0.path).inserted ? $0.path : nil } ?? ""
            } else if !entry.appPath.hasPrefix("/") || !entry.appPath.hasSuffix(".app") || entry.appPath.utf8.contains(0) {
                return false
            }
        }
        value.undoAvailable = current.undoAvailable
        value.menuEnabled = current.menuEnabled
        value.preferredLanguages = current.preferredLanguages
        // Locations and resource payloads remain local; portable resource metadata can reconnect imported packages.
        value.locations = current.locations
        let incomingResourceIDs = Set(value.resources.map(\.id))
        value.resources += current.resources.filter { !incomingResourceIDs.contains($0.id) }
        guard value.resources.count <= 256 else { return false }
        guard value == current || RightClickConfigurationStore.save(value, to: configurationURL) else { return false }
        session.reload()
        if value != current { preferencesChanges.didPersist() }
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

extension RightClickPlugin {
    private func validPortableApplication(_ entry: RightClickOpenWithApp) -> Bool {
        !entry.name.isEmpty && entry.name.utf8.count <= 256
            && !entry.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && entry.fileExtensions.count <= 64 && Set(entry.fileExtensions).count == entry.fileExtensions.count
            && entry.fileExtensions.allSatisfy { ext in
                !ext.isEmpty && ext.utf8.count <= 64 && ext == ext.lowercased()
                    && ext.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).contains($0) }
            }
    }
    private func portableIdentityData(_ identity: PortableApplicationReference) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(identity)
    }
    private struct PortableApp: Codable {
        let id: UUID
        let name: String
        let application: PortableApplicationReference
        let fileExtensions: [String]
    }
    private struct PortablePreferences: Codable {
        let formatVersion: Int
        let newFolder: Bool
        let copyFileName: Bool
        let copyAbsolutePath: Bool
        let copyRelativePath: Bool
        let copyShellEscapedPath: Bool
        let copyFileURL: Bool
        let newFile: Bool
        let openInTerminal: Bool
        let applications: [PortableApp]
    }
    private func decodedPortable(_ data: Data) -> PortablePreferences? {
        guard data.count <= 1_024 * 1_024,
              let payload = try? JSONDecoder().decode(PortablePreferences.self, from: data), payload.formatVersion == 1,
              payload.applications.count <= 512, Set(payload.applications.map(\.id)).count == payload.applications.count,
              payload.applications.allSatisfy({ entry in
                  entry.application.isValid && !entry.name.isEmpty && entry.name.utf8.count <= 256
                      && !entry.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                      && entry.fileExtensions.count <= 64 && Set(entry.fileExtensions).count == entry.fileExtensions.count
                      && entry.fileExtensions.allSatisfy { ext in
                          !ext.isEmpty && ext.utf8.count <= 64 && ext == ext.lowercased()
                              && ext.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).contains($0) }
                      }
              }) else { return nil }
        return payload
    }
}
