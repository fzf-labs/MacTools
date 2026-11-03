import Foundation
import MacToolsPluginKit
@testable import MacTools

// Frozen release 2.1.0 fields and decoder from 08754ad4, with only the enclosing type renamed.
struct LegacyFormat7PreferencesBackup: Decodable, Sendable {
    static let currentFormatVersion = 7
    static let maximumFileSize = 16 * 1024 * 1024

    struct ApplicationPreferences: Codable, Equatable, Sendable {
        let appearancePreference: String
        let floatingPanelAppearance: String?
        let languagePreference: String
        // Decode older backups only; current exports store the panel order instead.
        let menuBarClickBehavior: String?
        let settingsSidebarPluginSortMode: String?
        let settingsSidebarCustomPluginOrder: [String]?

        init(
            appearancePreference: String,
            floatingPanelAppearance: String? = nil,
            languagePreference: String,
            menuBarClickBehavior: String? = nil,
            settingsSidebarPluginSortMode: String? = nil,
            settingsSidebarCustomPluginOrder: [String]? = nil
        ) {
            self.appearancePreference = appearancePreference
            self.floatingPanelAppearance = floatingPanelAppearance
            self.languagePreference = languagePreference
            self.menuBarClickBehavior = menuBarClickBehavior
            self.settingsSidebarPluginSortMode = settingsSidebarPluginSortMode
            self.settingsSidebarCustomPluginOrder = settingsSidebarCustomPluginOrder
        }
    }

    let formatVersion: Int
    let exportedAt: Date
    let application: ApplicationPreferences
    let pluginDisplay: PluginDisplayPreferencesBackup
    let shortcutCustomizations: [String: ShortcutCustomization]
    let actionShortcutAssignments: [ActionShortcutAssignmentRecord]
    private(set) var actionShortcutAssignmentsWereEncoded = true
    let pluginPreferences: [String: Data]
    let pluginPreferenceActionReferences: [String: [ActionReference]]
    let actionInvocationPresets: [ActionInvocationPreset]?
    let workflows: [WorkflowDefinition]?
    let automationRules: [AutomationRule]?
    let selection: PreferencesBackupSelection?

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case exportedAt
        case application
        case pluginDisplay
        case shortcutCustomizations
        case actionShortcutAssignments
        case pluginPreferences
        case pluginPreferenceActionReferences
        case actionInvocationPresets
        case workflows
        case automationRules
        case selection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        application = try container.decode(ApplicationPreferences.self, forKey: .application)
        pluginDisplay = try container.decode(PluginDisplayPreferencesBackup.self, forKey: .pluginDisplay)
        shortcutCustomizations = try container.decode(
            [String: ShortcutCustomization].self,
            forKey: .shortcutCustomizations
        )
        actionShortcutAssignmentsWereEncoded = container.contains(.actionShortcutAssignments)
        actionShortcutAssignments = try container.decodeIfPresent(
            [ActionShortcutAssignmentRecord].self,
            forKey: .actionShortcutAssignments
        ) ?? []
        pluginPreferences = try container.decodeIfPresent(
            [String: Data].self,
            forKey: .pluginPreferences
        ) ?? [:]
        let decodedPluginPreferenceActionReferences = try container.decodeIfPresent(
            [String: [ActionReference]].self,
            forKey: .pluginPreferenceActionReferences
        )
        pluginPreferenceActionReferences = decodedPluginPreferenceActionReferences ?? [:]
        actionInvocationPresets = try container.decodeIfPresent(
            [ActionInvocationPreset].self,
            forKey: .actionInvocationPresets
        )
        workflows = try container.decodeIfPresent(
            [WorkflowDefinition].self,
            forKey: .workflows
        )
        automationRules = try container.decodeIfPresent(
            [AutomationRule].self,
            forKey: .automationRules
        )
        selection = try container.decodeIfPresent(
            PreferencesBackupSelection.self,
            forKey: .selection
        )
        if formatVersion >= 4,
           actionInvocationPresets == nil || workflows == nil || automationRules == nil {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Format 4 backups must include Run Link presets, workflows, and automation rules."
                )
            )
        }
        if formatVersion >= 5, selection == nil {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Format 5 backups must describe the selected preference categories."
                )
            )
        }
        if formatVersion >= 6, decodedPluginPreferenceActionReferences == nil {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Format 6 backups must include plugin action dependencies."
                )
            )
        }
        if formatVersion >= 6, !actionShortcutAssignmentsWereEncoded {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Format 6 backups must include action shortcut assignments."
                )
            )
        }
    }

}
