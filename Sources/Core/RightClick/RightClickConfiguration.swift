import Foundation

/// Shared state for the MacTools Finder right-click menu.
///
/// The host app writes both user preferences and the lightweight lifecycle gate
/// (`menuEnabled`). The sandboxed extension reads the same file to decide
/// whether to show anything, then which items to include.
///
/// This type is compiled into BOTH the host app and the extension targets (they
/// can't import each other); the JSON written by one is decoded by the other.
struct RightClickConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3
    var schemaVersion = Self.currentSchemaVersion
    var menuEnabled = false
    var preferredLanguages: [String]?
    var undoAvailable = false
    var enabledActions: Set<RightClickAction> = [
        .newFolder, .newFile, .terminal, .openWith,
        .copyName, .copyPath, .copyRelative, .copyShell, .copyURL,
        .copyTo, .moveTo, .goTo, .undo
    ]
    var categoryOrder = RightClickCategory.allCases
    var actionOrder = RightClickAction.allCases
    var locations = RightClickLocation.defaults
    var resources: [RightClickResource] = []
    var openWithApps: [RightClickOpenWithApp] = []
    var preferredAppID: UUID?
    var terminal = RightClickTerminal.terminal
    var terminalNewTab = false
    var enabledFileExtensions = RightClickNewFile.supportedExtensions
    var showIcons = true
    var askForName = false
    var openAfterCreating = false

    func isEnabled(_ action: RightClickAction) -> Bool { enabledActions.contains(action) }

    mutating func setEnabled(_ action: RightClickAction, _ value: Bool) {
        if value { enabledActions.insert(action) } else { enabledActions.remove(action) }
    }

    var orderedCategories: [RightClickCategory] { Self.unique(categoryOrder + RightClickCategory.allCases) }
    var orderedActions: [RightClickAction] { Self.unique(actionOrder + RightClickAction.allCases) }
    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    /// Missing or invalid configuration keeps Finder menus inactive.
    static let inactiveDefault = RightClickConfiguration()
    static let activeDefault = RightClickConfiguration(menuEnabled: true)
}

extension RightClickConfiguration {
    fileprivate static let backupDecodingKey = CodingUserInfoKey(rawValue: "right-click.preferences-backup.strict")!
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case menuEnabled
        case preferredLanguages
        case undoAvailable
        case enabledActions
        case categoryOrder
        case actionOrder
        case locations
        case resources
        case openWithApps
        case preferredAppID
        case terminal
        case terminalNewTab
        case enabledFileExtensions
        case showIcons
        case askForName
        case openAfterCreating
    }
    private enum LegacyKeys: String, CodingKey {
        case newFolder
        case newFile
        case openInTerminal
        case copyFileName
        case copyAbsolutePath
        case copyRelativePath
        case copyShellEscapedPath
        case copyFileURL
    }
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.schemaVersion), !container.contains(.enabledActions) {
            throw DecodingError.keyNotFound(CodingKeys.enabledActions,
                .init(codingPath: decoder.codingPath, debugDescription: "Versioned configuration requires enabled actions."))
        }
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? schemaVersion
        menuEnabled = try container.decodeIfPresent(Bool.self, forKey: .menuEnabled) ?? menuEnabled
        preferredLanguages = try container.decodeIfPresent([String].self, forKey: .preferredLanguages)
        undoAvailable = try container.decodeIfPresent(Bool.self, forKey: .undoAvailable) ?? undoAvailable
        enabledActions = try container.decodeIfPresent(Set<RightClickAction>.self, forKey: .enabledActions) ?? enabledActions
        categoryOrder = try container.decodeIfPresent([RightClickCategory].self, forKey: .categoryOrder) ?? categoryOrder
        actionOrder = try container.decodeIfPresent([RightClickAction].self, forKey: .actionOrder) ?? actionOrder
        locations = try container.decodeIfPresent([RightClickLocation].self, forKey: .locations) ?? locations
        resources = try container.decodeIfPresent([RightClickResource].self, forKey: .resources) ?? resources
        openWithApps = try container.decodeIfPresent([RightClickOpenWithApp].self, forKey: .openWithApps) ?? openWithApps
        preferredAppID = try container.decodeIfPresent(UUID.self, forKey: .preferredAppID)
        terminal = try container.decodeIfPresent(RightClickTerminal.self, forKey: .terminal) ?? terminal
        terminalNewTab = try container.decodeIfPresent(Bool.self, forKey: .terminalNewTab) ?? terminalNewTab
        enabledFileExtensions = try container.decodeIfPresent([String].self, forKey: .enabledFileExtensions) ?? enabledFileExtensions
        showIcons = try container.decodeIfPresent(Bool.self, forKey: .showIcons) ?? showIcons
        askForName = try container.decodeIfPresent(Bool.self, forKey: .askForName) ?? askForName
        openAfterCreating = try container.decodeIfPresent(Bool.self, forKey: .openAfterCreating) ?? openAfterCreating
        if !container.contains(.enabledActions) {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            if let enabled = try legacy.decodeIfPresent(Bool.self, forKey: .newFolder) { setEnabled(.newFolder, enabled) }
            if let enabled = try legacy.decodeIfPresent(Bool.self, forKey: .newFile) { setEnabled(.newFile, enabled) }
            if let enabled = try legacy.decodeIfPresent(Bool.self, forKey: .openInTerminal) { setEnabled(.terminal, enabled) }
            if let enabled = try legacy.decodeIfPresent(Bool.self, forKey: .copyFileName) { setEnabled(.copyName, enabled) }
            if let enabled = try legacy.decodeIfPresent(Bool.self, forKey: .copyAbsolutePath) { setEnabled(.copyPath, enabled) }
            if let enabled = try legacy.decodeIfPresent(Bool.self, forKey: .copyRelativePath) { setEnabled(.copyRelative, enabled) }
            if let enabled = try legacy.decodeIfPresent(Bool.self, forKey: .copyShellEscapedPath) { setEnabled(.copyShell, enabled) }
            if let enabled = try legacy.decodeIfPresent(Bool.self, forKey: .copyFileURL) { setEnabled(.copyURL, enabled) }
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(menuEnabled, forKey: .menuEnabled)
        try container.encodeIfPresent(preferredLanguages, forKey: .preferredLanguages)
        try container.encode(undoAvailable, forKey: .undoAvailable)
        try container.encode(enabledActions.sorted { $0.rawValue < $1.rawValue }, forKey: .enabledActions)
        try container.encode(categoryOrder, forKey: .categoryOrder)
        try container.encode(actionOrder, forKey: .actionOrder)
        try container.encode(locations, forKey: .locations)
        try container.encode(resources, forKey: .resources)
        try container.encode(openWithApps, forKey: .openWithApps)
        try container.encodeIfPresent(preferredAppID, forKey: .preferredAppID)
        try container.encode(terminal, forKey: .terminal)
        try container.encode(terminalNewTab, forKey: .terminalNewTab)
        try container.encode(enabledFileExtensions, forKey: .enabledFileExtensions)
        try container.encode(showIcons, forKey: .showIcons)
        try container.encode(askForName, forKey: .askForName)
        try container.encode(openAfterCreating, forKey: .openAfterCreating)
    }
    func openWithApplications(matching targets: [URL]) -> [RightClickOpenWithApp] {
        openWithApps.filter { app in !app.isUnresolved && targets.contains { app.matches(fileExtension: $0.pathExtension) } }
    }
    var newFolder: Bool { get { isEnabled(.newFolder) } set { setEnabled(.newFolder, newValue) } }
    var newFile: Bool { get { isEnabled(.newFile) } set { setEnabled(.newFile, newValue) } }
    var openInTerminal: Bool { get { isEnabled(.terminal) } set { setEnabled(.terminal, newValue) } }
    var copyFileName: Bool { get { isEnabled(.copyName) } set { setEnabled(.copyName, newValue) } }
    var copyAbsolutePath: Bool { get { isEnabled(.copyPath) } set { setEnabled(.copyPath, newValue) } }
    var copyRelativePath: Bool { get { isEnabled(.copyRelative) } set { setEnabled(.copyRelative, newValue) } }
    var copyShellEscapedPath: Bool { get { isEnabled(.copyShell) } set { setEnabled(.copyShell, newValue) } }
    var copyFileURL: Bool { get { isEnabled(.copyURL) } set { setEnabled(.copyURL, newValue) } }
}

/// A user-configured "open with" application entry.
struct RightClickOpenWithApp: Codable, Equatable, Identifiable, Sendable {
    var scope: RightClickAppScope = .all
    var id: UUID
    var name: String
    var appPath: String
    /// Lowercased file extensions this entry applies to; empty = all files.
    var fileExtensions: [String]
    /// Opaque portable identity retained when the app is missing on this Mac.
    var portableApplicationReference: Data?

    var isUnresolved: Bool { appPath.isEmpty }

    init(id: UUID = UUID(), name: String, appPath: String, fileExtensions: [String] = []) {
        self.id = id
        self.name = name
        self.appPath = appPath
        self.fileExtensions = fileExtensions
        self.portableApplicationReference = nil
    }

    func matches(_ item: RightClickSelectionItem) -> Bool {
        if scope == .files && item.isDirectory { return false }
        if scope == .folders && !item.isDirectory { return false }
        return matches(fileExtension: item.url.pathExtension)
    }

    /// Whether this entry should appear for a file with the given (lowercased)
    /// extension. An empty `fileExtensions` matches everything.
    func matches(fileExtension ext: String) -> Bool {
        !isUnresolved && (fileExtensions.isEmpty || fileExtensions.contains(ext.lowercased()))
    }
}

extension RightClickOpenWithApp {
    private enum CodingKeys: String, CodingKey { case id, name, appPath, fileExtensions, scope, portableApplicationReference }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        appPath = try container.decode(String.self, forKey: .appPath)
        fileExtensions = try container.decodeIfPresent([String].self, forKey: .fileExtensions) ?? []
        scope = try container.decodeIfPresent(RightClickAppScope.self, forKey: .scope) ?? .all
        portableApplicationReference = try container.decodeIfPresent(Data.self, forKey: .portableApplicationReference)
    }
}

/// Reads/writes `RightClickConfiguration` via a JSON file under the user's real
/// home directory.
///
/// Why a plain file at the real home — and neither an app group nor
/// `UserDefaults(suiteName:)`: the non-sandboxed host app is denied write access
/// to the app group container (containermanagerd), and the host's cfprefsd
/// domain is separate from the sandboxed extension's, so neither bridges the
/// boundary. The host writes a file it can write (its real Application Support),
/// and the sandboxed extension reads it through a read-only
/// `temporary-exception.files.home-relative-path` entitlement. Both sides resolve
/// the real home via `getpwuid` and read the same relative path from Info.plist,
/// so Release and Debug builds do not accidentally share Finder Sync settings.
enum RightClickConfigurationStore {
    /// Real user home directory, bypassing the sandbox container redirection so
    /// the host app and the sandboxed extension resolve the exact same file.
    private static let realHomeDirectory: String = {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return String(cString: home)
        }
        return NSHomeDirectory()
    }()

    /// File path relative to the real home. The extension's read-only
    /// `home-relative-path` entitlement must stay in sync with this build setting.
    static var configFileHomeRelativePath: String {
        if let path = Bundle.main.object(forInfoDictionaryKey: "MTRightClickConfigurationHomeRelativePath") as? String,
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path
        }
        return "Library/Application Support/MacTools/right-click-menu.json"
    }

    static var configFileURL: URL {
        URL(fileURLWithPath: realHomeDirectory)
            .appendingPathComponent(configFileHomeRelativePath)
    }

    static func load(from fileURL: URL = configFileURL) -> RightClickConfiguration {
        guard let data = try? Data(contentsOf: fileURL),
              let configuration = try? JSONDecoder().decode(RightClickConfiguration.self, from: data),
              configuration.schemaVersion == RightClickConfiguration.currentSchemaVersion
        else {
            return .inactiveDefault
        }
        return configuration
    }

    /// Missing files use defaults; existing unreadable or malformed state must not become a backup.
    static func loadForPreferencesBackup(from fileURL: URL = configFileURL) -> RightClickConfiguration? {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.userInfo[RightClickConfiguration.backupDecodingKey] = true
            return try decoder.decode(RightClickConfiguration.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .inactiveDefault
        } catch {
            return nil
        }
    }

    static func setMenuEnabled(_ enabled: Bool, fileURL: URL = configFileURL) {
        var configuration = load(from: fileURL)
        if enabled, configuration == .inactiveDefault {
            configuration = .activeDefault
        }
        configuration.undoAvailable = false
        configuration.menuEnabled = enabled
        _ = save(configuration, to: fileURL)
    }

    @discardableResult
    static func save(_ configuration: RightClickConfiguration, to fileURL: URL = configFileURL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(configuration)
            let previous = try? Data(contentsOf: fileURL)
            try data.write(to: fileURL, options: .atomic)
            guard (try? Data(contentsOf: fileURL)) == data else {
                if let previous { try? previous.write(to: fileURL, options: .atomic) }
                else { try? FileManager.default.removeItem(at: fileURL) }
                return false
            }
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("MacTools.RightClickConfigurationChanged"), object: fileURL.path, userInfo: nil, deliverImmediately: true
            )
            return true
        } catch {
            return false
        }
    }
}
